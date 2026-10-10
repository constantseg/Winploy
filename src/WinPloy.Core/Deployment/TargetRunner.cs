using System.Management.Automation;
using WinPloy.Core.Models;

namespace WinPloy.Core.Deployment;

public interface ITargetRunner
{
    /// <summary>Traite un poste. Méthode bloquante, appelée hors du thread de l'interface.</summary>
    IReadOnlyList<TargetResult> Run(string computer, DeploymentRequest request, IProgress<TargetStatus> progress, CancellationToken cancellationToken);
}

/// <summary>
/// Traitement d'un poste : contrôle WinRM, copie des paquets personnalisés, exécution distante.
/// </summary>
public sealed class TargetRunner : ITargetRunner
{
    private const string CreateStageScript = """
        $d = Join-Path $env:windir ("Temp\WinPloy\stage_{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -Path $d -ItemType Directory -Force | Out-Null
        $d
        """;

    private const string RemoveStageScript = """
        param([string]$Path)
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        """;

    public IReadOnlyList<TargetResult> Run(string computer, DeploymentRequest request, IProgress<TargetStatus> progress, CancellationToken cancellationToken)
    {
        progress.Report(new TargetStatus("Vérification du port WinRM 5985...", "Vérification..."));
        if (!TcpProbe.IsOpen(computer, RemoteSession.WinRmPort, TimeSpan.FromSeconds(3), cancellationToken))
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw new TargetException($"WinRM injoignable sur {computer} (port 5985). Vérifier que le poste est allumé et que WinRM est activé par GPO.");
        }
        progress.Report(new TargetStatus("WinRM joignable, ouverture de la session...", "Accessible"));

        using var session = RemoteSession.Open(computer, request.Credential, cancellationToken);
        progress.Report(new TargetStatus("Session WinRM ouverte, exécution...", "Actif"));

        var results = new List<TargetResult>();
        var staged = new List<PSObject>();
        foreach (var package in request.Packages.Where(p => p.IsCustom))
        {
            try
            {
                staged.Add(Stage(session, package, request, cancellationToken));
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                results.Add(new TargetResult(package.Id, package.Name, ResultStatus.Failed, $"Préparation : {ex.Message}"));
            }
        }

        var winget = request.Packages
            .Where(p => !p.IsCustom)
            .Select(p => NewObject(("Id", p.Id), ("Name", p.Name)))
            .ToArray();
        var errors = new List<string>();
        var output = session.Invoke(RemoteScripts.RemoteAction, errors, winget, staged.ToArray(), request.Action.ToString(), request.PackageTimeoutMin);

        var remote = output.Select(ToResult).OfType<TargetResult>().ToList();
        if (remote.Count == 0 && errors.Count > 0)
        {
            remote.Add(TargetResult.ForAll(ResultStatus.Failed, FriendlyErrors.Describe(string.Join(" | ", errors))));
        }
        results.AddRange(remote);
        return results;
    }

    private static PSObject Stage(RemoteSession session, CatalogueEntry package, DeploymentRequest request, CancellationToken cancellationToken)
    {
        var install = request.Action == DeployAction.Install;
        var scriptPath = install ? package.InstallScript : package.UninstallScript;
        if (string.IsNullOrWhiteSpace(scriptPath))
        {
            throw new TargetException($"Aucun script {(install ? "d'installation" : "de désinstallation")} défini pour ce paquet.");
        }

        var sourceDir = Path.GetDirectoryName(scriptPath) ?? "";
        if (!File.Exists(scriptPath))
        {
            throw new TargetException($"Script introuvable depuis la machine d'administration : {scriptPath}");
        }
        if (request.DepotRoot.Length > 0 && PackageValidation.SameDirectory(sourceDir, request.DepotRoot))
        {
            throw new TargetException("Le script est à la racine du dépôt : tout le dépôt serait copié. Placer chaque paquet dans son propre sous-dossier.");
        }

        var stageDir = session.InvokeOrThrow(CreateStageScript)
            .Select(o => o?.BaseObject?.ToString())
            .LastOrDefault(s => !string.IsNullOrEmpty(s))
            ?? throw new TargetException("Création du dossier temporaire impossible sur le poste.");
        try
        {
            RemoteFileCopier.CopyDirectory(session, sourceDir, stageDir, cancellationToken);
        }
        catch (Exception) when (!cancellationToken.IsCancellationRequested)
        {
            RemoveQuietly(session, stageDir);
            throw;
        }

        return NewObject(
            ("Id", package.Id),
            ("Name", package.Name),
            ("Leaf", Path.GetFileName(scriptPath)),
            ("StageDir", stageDir),
            ("RunAs", package.RunAs));
    }

    private static void RemoveQuietly(RemoteSession session, string stageDir)
    {
        try
        {
            session.Invoke(RemoveStageScript, new List<string>(), stageDir);
        }
        catch (Exception)
        {
            // Le dossier temporaire reste sur le poste : l'erreur de copie d'origine est plus utile.
        }
    }

    /// <summary>Objet PSCustomObject, désérialisé sur le poste comme celui de Select-Object.</summary>
    private static PSObject NewObject(params (string Name, object? Value)[] properties)
    {
        var obj = new PSObject();
        foreach (var (name, value) in properties)
        {
            obj.Properties.Add(new PSNoteProperty(name, value));
        }
        return obj;
    }

    private static TargetResult? ToResult(PSObject? obj)
    {
        if (obj?.Properties["Statut"] is null)
        {
            return null;
        }
        return new TargetResult(Text(obj, "Id"), Text(obj, "Name"), Text(obj, "Statut"), Text(obj, "Message"));
    }

    private static string Text(PSObject obj, string name) => obj.Properties[name]?.Value?.ToString() ?? "";
}
