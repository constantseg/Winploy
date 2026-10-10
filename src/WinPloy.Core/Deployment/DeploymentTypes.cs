using System.Management.Automation;
using WinPloy.Core.Models;

namespace WinPloy.Core.Deployment;

/// <summary>Paramètres figés d'une opération (installation ou désinstallation) sur une liste de postes.</summary>
public sealed class DeploymentRequest
{
    public required IReadOnlyList<string> Targets { get; init; }

    public required IReadOnlyList<CatalogueEntry> Packages { get; init; }

    public required DeployAction Action { get; init; }

    /// <summary>Null = contexte du compte qui exécute WinPloy.</summary>
    public PSCredential? Credential { get; init; }

    public required int PackageTimeoutMin { get; init; }

    public required int MaxParallel { get; init; }

    public required string DepotRoot { get; init; }

    /// <summary>Remplace le délai global calculé (tests).</summary>
    public TimeSpan? JobTimeoutOverride { get; init; }

    /// <summary>Délai global par poste : délai par paquet x nombre de paquets + 5 min.</summary>
    public TimeSpan JobTimeout => JobTimeoutOverride ?? TimeSpan.FromMinutes(PackageTimeoutMin * Math.Max(1, Packages.Count) + 5);
}

/// <summary>Résultat brut d'un paquet renvoyé par le poste.</summary>
public sealed record TargetResult(string Id, string Name, string Statut, string Message)
{
    public const string AllPackagesName = "(tous)";

    /// <summary>Résultat unique qui couvre tous les paquets du poste (poste injoignable, arrêt, délai).</summary>
    public static TargetResult ForAll(string statut, string message) => new("", AllPackagesName, statut, message);
}

/// <summary>Avancement d'un poste : texte de la colonne « Détail » et état WinRM.</summary>
public sealed record TargetStatus(string Message, string WinRM);

/// <summary>Erreur attendue sur un poste : le message est affiché tel quel.</summary>
public sealed class TargetException : Exception
{
    public TargetException(string message)
        : base(message)
    {
    }
}
