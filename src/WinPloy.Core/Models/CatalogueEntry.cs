using System.Text.Json.Nodes;
using WinPloy.Core.Services;

namespace WinPloy.Core.Models;

/// <summary>
/// Entrée du catalogue partagé.
///   WinGet : { "Type": "WinGet", "Id": "Git.Git", "Name": "Git" }
///   Custom : { "Type": "Custom", "Id": "custom:Nom", "Name": "Nom",
///              "InstallScript": "\\srv\partage\Nom\install.ps1",
///              "UninstallScript": "\\srv\partage\Nom\uninstall.ps1", "RunAs": "User|System" }
/// Le type est toujours déduit de l'Id (préfixe "custom:").
/// </summary>
public sealed class CatalogueEntry
{
    public const string CustomPrefix = "custom:";
    public const string RunAsUser = "User";
    public const string RunAsSystem = "System";

    private CatalogueEntry(PackageType type, string id, string name, string installScript, string uninstallScript, string runAs)
    {
        Type = type;
        Id = id;
        Name = name;
        InstallScript = installScript;
        UninstallScript = uninstallScript;
        RunAs = runAs;
    }

    public PackageType Type { get; }

    public string Id { get; }

    public string Name { get; }

    public string InstallScript { get; }

    public string UninstallScript { get; }

    public string RunAs { get; }

    public bool IsCustom => Type == PackageType.Custom;

    public bool RunsAsSystem => RunAs == RunAsSystem;

    public string Label => IsCustom ? $"{Name} [Custom]" : Name;

    /// <summary>Libellé du type pour l'interface.</summary>
    public string TypeLabel => IsCustom ? "Personnalisé" : "WinGet";

    /// <summary>Normalise une entrée. Retourne null si l'Id est vide.</summary>
    public static CatalogueEntry? Create(string? id, string? name, string? installScript = null, string? uninstallScript = null, string? runAs = null)
    {
        var cleanId = (id ?? "").Trim();
        if (cleanId.Length == 0)
        {
            return null;
        }

        var displayName = string.IsNullOrEmpty(name) ? cleanId : name;
        if (!cleanId.StartsWith(CustomPrefix, StringComparison.OrdinalIgnoreCase))
        {
            return new CatalogueEntry(PackageType.WinGet, cleanId, displayName, "", "", RunAsUser);
        }

        var mode = string.Equals(runAs, RunAsSystem, StringComparison.OrdinalIgnoreCase) ? RunAsSystem : RunAsUser;
        return new CatalogueEntry(PackageType.Custom, cleanId, displayName, installScript ?? "", uninstallScript ?? "", mode);
    }

    /// <summary>Lit une entrée JSON. Les noms de propriété ne tiennent pas compte de la casse, comme en PowerShell.</summary>
    public static CatalogueEntry? FromJson(JsonNode? node)
    {
        if (node is not JsonObject obj)
        {
            return null;
        }

        return Create(Read(obj, "Id"), Read(obj, "Name"), Read(obj, "InstallScript"), Read(obj, "UninstallScript"), Read(obj, "RunAs"));
    }

    public JsonObject ToJson()
    {
        var obj = new JsonObject
        {
            ["Type"] = Type.ToString(),
            ["Id"] = Id,
            ["Name"] = Name,
        };
        if (IsCustom)
        {
            obj["InstallScript"] = InstallScript;
            obj["UninstallScript"] = UninstallScript;
            obj["RunAs"] = RunAs;
        }
        return obj;
    }

    public bool HasSameId(string? id) => string.Equals(Id, id, StringComparison.OrdinalIgnoreCase);

    public override string ToString() => Label;

    private static string Read(JsonObject obj, string name)
        => JsonHelpers.TryGetProperty(obj, name, out var value) ? JsonHelpers.AsString(value) : "";
}
