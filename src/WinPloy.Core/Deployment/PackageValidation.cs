using System.Text.RegularExpressions;

namespace WinPloy.Core.Deployment;

/// <summary>Règles de saisie des paquets du catalogue.</summary>
public static class PackageValidation
{
    public static readonly IReadOnlyList<string> ScriptExtensions = [".msi", ".ps1", ".bat", ".cmd", ".exe"];

    /// <summary>Filtre de la boîte « Parcourir… », aligné sur <see cref="ScriptExtensions" />.</summary>
    public const string FileDialogFilter =
        "Installeurs et scripts (*.msi;*.ps1;*.bat;*.cmd;*.exe)|*.msi;*.ps1;*.bat;*.cmd;*.exe|Paquet Windows Installer (*.msi)|*.msi|Tous les fichiers|*.*";

    private static readonly Regex WingetIdPattern = new(@"^[A-Za-z0-9][A-Za-z0-9._+-]*$");
    private static readonly Regex InvalidIdChars = new(@"[^\w\.-]+");

    public static bool IsValidWingetId(string id) => WingetIdPattern.IsMatch(id);

    /// <summary>Id d'un paquet personnalisé : "custom:" + nom nettoyé.</summary>
    public static string MakeCustomId(string name)
        => Models.CatalogueEntry.CustomPrefix + InvalidIdChars.Replace(name, "_").Trim('_');

    public static bool SameDirectory(string a, string b)
        => string.Equals(a.TrimEnd('\\'), b.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    /// <summary>Contrôle un chemin de script. Retourne le message d'erreur, ou null si le chemin est valide.</summary>
    public static string? ValidateScriptPath(string path, string label, string depotRoot, Func<string, bool>? fileExists = null)
    {
        fileExists ??= File.Exists;
        if (!path.StartsWith(@"\\", StringComparison.Ordinal))
        {
            return $@"{label} : chemin UNC requis (\\serveur\partage\...), accessible à tous les administrateurs.";
        }
        if (!ScriptExtensions.Contains(Path.GetExtension(path).ToLowerInvariant()))
        {
            return $"{label} : extension non supportée (msi, ps1, bat, cmd, exe).";
        }
        if (!fileExists(path))
        {
            return $"{label} : fichier introuvable ({path}).";
        }
        if (SameDirectory(Path.GetDirectoryName(path) ?? "", depotRoot))
        {
            return $"{label} : placer le script dans un sous-dossier dédié (le dossier entier est copié sur le poste).";
        }
        return null;
    }
}
