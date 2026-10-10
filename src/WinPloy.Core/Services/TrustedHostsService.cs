using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace WinPloy.Core.Services;

/// <summary>
/// Les cibles sont ajoutées à TrustedHosts du client WinRM : sans cela, toute bascule
/// de Kerberos vers NTLM (compte local, SPN, DNS, contexte courant) fait échouer la session.
/// Mise à jour par l'API COM WSMan.Automation (équivalent de Set-Item WSMan:\localhost\Client\TrustedHosts).
/// </summary>
public sealed class TrustedHostsService
{
    private const string ClientConfigUri = "winrm/config/client";
    private const string WinRmServiceName = "WinRM";

    private static readonly TimeSpan ServiceStartTimeout = TimeSpan.FromSeconds(30);

    private readonly LogService _log;

    public TrustedHostsService(LogService log) => _log = log;

    /// <summary>Nouvelle valeur de TrustedHosts, ou null si rien n'est à ajouter.</summary>
    public static string? Merge(string? current, IEnumerable<string> computers, out IReadOnlyList<string> missing)
    {
        missing = [];
        var items = Regex.Split((current ?? "").Trim(), @"\s*,\s*").Where(s => s.Length > 0).ToList();
        if (items.Contains("*"))
        {
            return null;
        }

        var toAdd = computers
            .Where(c => !items.Contains(c, StringComparer.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (toAdd.Count == 0)
        {
            return null;
        }

        missing = toAdd;
        return string.Join(",", items.Concat(toAdd));
    }

    public void Add(IReadOnlyCollection<string> computers)
    {
        if (computers.Count == 0)
        {
            return;
        }

        EnsureWinRmServiceRunning();

        var type = Type.GetTypeFromProgID("WSMan.Automation", throwOnError: true)!;
        object? wsman = null;
        object? session = null;
        try
        {
            wsman = Activator.CreateInstance(type)!;
            session = ((dynamic)wsman).CreateSession();
            dynamic client = session!;
            string xml = client.Get(ClientConfigUri, 0);

            var document = XDocument.Parse(xml);
            var node = document.Descendants().FirstOrDefault(e => e.Name.LocalName == "TrustedHosts")
                ?? throw new InvalidOperationException("Paramètre TrustedHosts absent de la configuration du client WinRM.");
            var updated = Merge(node.Value, computers, out var missing);
            if (updated is null)
            {
                return;
            }
            if (IsFromPolicy(node))
            {
                throw new InvalidOperationException("TrustedHosts est imposé par GPO : ajouter les postes dans la stratégie de groupe.");
            }

            // Les paramètres imposés par GPO sont en lecture seule : ils ne sont pas renvoyés.
            foreach (var locked in document.Descendants().Where(e => e != node && IsFromPolicy(e)).ToList())
            {
                locked.Remove();
            }
            node.Value = updated;
            client.Put(ClientConfigUri, document.ToString(SaveOptions.DisableFormatting), 0);

            _log.Write($"TrustedHosts WinRM : ajout de {string.Join(", ", missing)}.");
        }
        finally
        {
            if (session is not null)
            {
                Marshal.FinalReleaseComObject(session);
            }
            if (wsman is not null)
            {
                Marshal.FinalReleaseComObject(wsman);
            }
        }
    }

    /// <summary>La configuration du client WinRM n'est accessible que si le service WinRM local tourne.</summary>
    private void EnsureWinRmServiceRunning()
    {
        using var service = new ServiceController(WinRmServiceName);
        if (service.Status == ServiceControllerStatus.Running)
        {
            return;
        }

        if (service.Status != ServiceControllerStatus.StartPending)
        {
            service.Start();
        }
        service.WaitForStatus(ServiceControllerStatus.Running, ServiceStartTimeout);
        _log.Write("Service WinRM local démarré (nécessaire pour TrustedHosts).");
    }

    private static bool IsFromPolicy(XElement element)
        => string.Equals((string?)element.Attribute("Source"), "GPO", StringComparison.OrdinalIgnoreCase);
}
