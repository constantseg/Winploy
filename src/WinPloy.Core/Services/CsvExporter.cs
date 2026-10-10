using System.Globalization;
using System.Text;
using WinPloy.Core.Models;

namespace WinPloy.Core.Services;

/// <summary>Export des résultats, même format qu'Export-Csv -Delimiter ';' -Encoding UTF8 (Windows PowerShell 5.1).</summary>
public static class CsvExporter
{
    private static readonly string[] Header = ["Ordinateur", "Paquet", "Id", "Statut", "Message", "Horodatage"];

    public static void Export(string path, IEnumerable<PackageResult> rows)
        => File.WriteAllText(path, Build(rows, CultureInfo.CurrentCulture), new UTF8Encoding(true));

    public static string Build(IEnumerable<PackageResult> rows, CultureInfo culture)
    {
        var builder = new StringBuilder();
        builder.Append(Line(Header)).Append("\r\n");
        foreach (var row in rows)
        {
            builder.Append(Line([row.Ordinateur, row.Paquet, row.Id, row.Statut, row.Message, row.Horodatage.ToString(culture)]))
                   .Append("\r\n");
        }
        return builder.ToString();
    }

    private static string Line(IEnumerable<string> values)
        => string.Join(";", values.Select(v => "\"" + v.Replace("\"", "\"\"") + "\""));
}
