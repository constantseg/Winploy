namespace WinPloy.Core.Models;

/// <summary>Résultat d'un paquet sur un poste (onglet « Détail par paquet », export CSV, historique).</summary>
public sealed class PackageResult
{
    public PackageResult(string ordinateur, string paquet, string id, string statut, string message, DateTime horodatage)
    {
        Ordinateur = ordinateur;
        Paquet = paquet;
        Id = id;
        Statut = statut;
        Message = message;
        Horodatage = horodatage;
    }

    public string Ordinateur { get; }

    public string Paquet { get; }

    public string Id { get; }

    public string Statut { get; }

    public string Message { get; }

    public DateTime Horodatage { get; }
}
