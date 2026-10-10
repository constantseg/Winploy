using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace WinPloy.Core.Services;

/// <summary>Lecture et écriture JSON compatibles avec les fichiers produits par la version PowerShell.</summary>
internal static class JsonHelpers
{
    public static readonly UTF8Encoding Utf8NoBom = new(false);

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private static readonly JsonDocumentOptions ReadOptions = new()
    {
        AllowTrailingCommas = true,
        CommentHandling = JsonCommentHandling.Skip,
    };

    /// <summary>Lit un fichier JSON (avec ou sans BOM). Retourne null si le fichier est vide.</summary>
    public static JsonNode? ParseFile(string path)
    {
        var text = File.ReadAllText(path);
        return string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text, documentOptions: ReadOptions);
    }

    public static string Serialize(JsonNode node) => node.ToJsonString(WriteOptions);

    /// <summary>Un document peut contenir un objet seul au lieu d'un tableau : il est alors placé dans un tableau.</summary>
    public static JsonArray ToArray(JsonNode? node) => node switch
    {
        null => new JsonArray(),
        JsonArray array => array,
        _ => new JsonArray(node),
    };

    /// <summary>Recherche une propriété sans tenir compte de la casse.</summary>
    public static bool TryGetProperty(JsonObject obj, string name, out JsonNode? value)
    {
        foreach (var property in obj)
        {
            if (string.Equals(property.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }

        value = null;
        return false;
    }

    /// <summary>Équivalent de [string]$valeur : null donne une chaîne vide, un nombre donne son texte.</summary>
    public static string AsString(JsonNode? node) => node switch
    {
        null => "",
        JsonValue value when value.TryGetValue<string>(out var text) => text ?? "",
        _ => node.ToJsonString(),
    };
}
