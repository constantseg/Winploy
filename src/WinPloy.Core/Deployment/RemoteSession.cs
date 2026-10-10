using System.Collections.ObjectModel;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;

namespace WinPloy.Core.Deployment;

/// <summary>
/// Session WinRM vers un poste : runspace distant sur l'endpoint par défaut (Microsoft.PowerShell,
/// donc Windows PowerShell 5.1 sur le poste). Toute commande en cours s'arrête à l'annulation.
/// </summary>
internal sealed class RemoteSession : IDisposable
{
    public const int WinRmPort = 5985;

    private const string ShellUri = "http://schemas.microsoft.com/powershell/Microsoft.PowerShell";
    private const int OpenTimeoutMs = 30000;

    private readonly Runspace _runspace;
    private readonly CancellationToken _cancellationToken;

    private RemoteSession(Runspace runspace, CancellationToken cancellationToken)
    {
        _runspace = runspace;
        _cancellationToken = cancellationToken;
    }

    public static RemoteSession Open(string computer, PSCredential? credential, CancellationToken cancellationToken)
    {
        var lastError = "";
        foreach (var candidate in CredentialCandidates.Build(computer, credential))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var connection = new WSManConnectionInfo(false, computer, WinRmPort, "/wsman", ShellUri, candidate)
            {
                AuthenticationMechanism = AuthenticationMechanism.Negotiate,
                OpenTimeout = OpenTimeoutMs,
                // Pas de délai par opération : une installation peut durer longtemps.
                OperationTimeout = 0,
            };
            var runspace = RunspaceFactory.CreateRunspace(connection);
            try
            {
                runspace.Open();
                return new RemoteSession(runspace, cancellationToken);
            }
            catch (Exception ex)
            {
                lastError = ex.Message;
                runspace.Dispose();
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        var who = credential is null ? "le contexte courant" : $"le compte '{credential.UserName}'";
        throw new TargetException($"Ouverture de session WinRM refusée sur {computer} avec {who}. {lastError}");
    }

    /// <summary>Exécute un script dans la session. Les erreurs non bloquantes sont ajoutées à <paramref name="errors"/>.</summary>
    public Collection<PSObject> Invoke(string script, ICollection<string> errors, params object?[] arguments)
    {
        _cancellationToken.ThrowIfCancellationRequested();
        using var shell = PowerShell.Create();
        shell.Runspace = _runspace;
        shell.AddScript(script);
        foreach (var argument in arguments)
        {
            shell.AddArgument(argument);
        }

        Collection<PSObject> output;
        using (_cancellationToken.Register(() => StopQuietly(shell)))
        {
            output = shell.Invoke();
        }

        _cancellationToken.ThrowIfCancellationRequested();
        foreach (var error in shell.Streams.Error)
        {
            errors.Add(error.ToString());
        }
        return output;
    }

    /// <summary>Exécute un script et lève une exception si le poste renvoie une erreur.</summary>
    public Collection<PSObject> InvokeOrThrow(string script, params object?[] arguments)
    {
        var errors = new List<string>();
        var output = Invoke(script, errors, arguments);
        if (errors.Count > 0)
        {
            throw new TargetException(string.Join(" | ", errors));
        }
        return output;
    }

    public void Dispose()
    {
        try
        {
            _runspace.Dispose();
        }
        catch (Exception)
        {
            // Session déjà coupée (poste éteint, réseau) : rien à libérer de plus.
        }
    }

    private static void StopQuietly(PowerShell shell)
    {
        try
        {
            shell.BeginStop(null, null);
        }
        catch (Exception)
        {
            // Commande déjà terminée.
        }
    }
}

/// <summary>Scripts PowerShell embarqués dans l'assembly.</summary>
internal static class RemoteScripts
{
    private static readonly Lazy<string> Action = new(() => Load("WinPloy.RemoteAction.ps1"));

    public static string RemoteAction => Action.Value;

    private static string Load(string name)
    {
        using var stream = typeof(RemoteScripts).Assembly.GetManifestResourceStream(name)
            ?? throw new InvalidOperationException($"Ressource introuvable : {name}");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }
}
