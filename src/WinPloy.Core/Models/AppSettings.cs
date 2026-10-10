namespace WinPloy.Core.Models;

/// <summary>Réglages enregistrés dans ProgramData\WinPloy\config.json.</summary>
public sealed record AppSettings
{
    public const string DefaultCataloguePath = @"\\SERVEUR\Depot\catalogue.json";
    public const int DefaultTimeoutMin = 30;
    public const int MinTimeoutMin = 1;
    public const int MaxTimeoutMin = 240;
    public const int DefaultParallel = 10;
    public const int MinParallel = 1;
    public const int MaxParallelLimit = 50;

    public string CataloguePath { get; init; } = DefaultCataloguePath;

    public int PackageTimeoutMin { get; init; } = DefaultTimeoutMin;

    public int MaxParallel { get; init; } = DefaultParallel;

    /// <summary>Dossier du catalogue : racine du dépôt des paquets personnalisés.</summary>
    public string DepotRoot => Path.GetDirectoryName(CataloguePath) ?? "";
}
