using System.DirectoryServices;
using System.Text;
using System.Text.RegularExpressions;

namespace WinPloy.Core.Services;

/// <summary>
/// Recherche LDAP dans le domaine du compte courant. Remplace Get-ADComputer et Get-ADOrganizationalUnit :
/// les RSAT ne sont plus nécessaires sur le poste d'administration.
/// </summary>
public sealed class ActiveDirectoryService
{
    private const string EnabledComputers = "(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2))";

    /// <summary>Postes activés du domaine dont le nom contient <paramref name="searchText"/>.</summary>
    public IReadOnlyList<string> SearchComputers(string? searchText)
    {
        using var searcher = new DirectorySearcher(null, BuildComputerFilter(searchText), ["name"], SearchScope.Subtree)
        {
            PageSize = 1000,
        };
        return ReadValues(searcher, "name");
    }

    public static string BuildComputerFilter(string? searchText)
    {
        var text = searchText?.Trim() ?? "";
        if (text.Length == 0)
        {
            return $"(&{EnabledComputers})";
        }

        var pattern = Regex.Replace($"*{EscapeFilterValue(text)}*", @"\*{2,}", "*");
        return $"(&{EnabledComputers}(name={pattern}))";
    }

    /// <summary>Échappe une valeur de filtre LDAP (RFC 4515). L'étoile reste un joker, comme avec -like.</summary>
    public static string EscapeFilterValue(string value)
    {
        var builder = new StringBuilder(value.Length);
        foreach (var c in value)
        {
            builder.Append(c switch
            {
                '\\' => @"\5c",
                '(' => @"\28",
                ')' => @"\29",
                '\0' => @"\00",
                _ => c.ToString(),
            });
        }
        return builder.ToString();
    }

    private static List<string> ReadValues(DirectorySearcher searcher, string property)
    {
        var values = new List<string>();
        using var results = searcher.FindAll();
        foreach (SearchResult result in results)
        {
            var found = result.Properties[property];
            if (found.Count > 0 && found[0]?.ToString() is { Length: > 0 } value)
            {
                values.Add(value);
            }
        }
        values.Sort(StringComparer.CurrentCultureIgnoreCase);
        return values;
    }
}
