using System.Globalization;
using System.Text.Json.Nodes;
using WinPloy.Core.Models;
using WinPloy.Core.Services;

namespace WinPloy.Tests;

public class SettingsServiceTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly SettingsService _service;

    public SettingsServiceTests()
    {
        _service = new SettingsService(_temp.File("config.json"), new LogService(_temp.File("test.log")));
    }

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void Load_MissingFile_ReturnsDefaults()
    {
        Assert.Equal(new AppSettings(), _service.Load());
    }

    [Fact]
    public void Load_InvalidJson_ReturnsDefaults()
    {
        File.WriteAllText(_temp.File("config.json"), "{ pas du json");

        Assert.Equal(new AppSettings(), _service.Load());
    }

    [Fact]
    public void Load_OutOfRangeValues_UseDefaults()
    {
        File.WriteAllText(_temp.File("config.json"), """{ "CataloguePath": "", "PackageTimeoutMin": 500, "MaxParallel": "abc" }""");

        var settings = _service.Load();

        Assert.Equal(AppSettings.DefaultCataloguePath, settings.CataloguePath);
        Assert.Equal(AppSettings.DefaultTimeoutMin, settings.PackageTimeoutMin);
        Assert.Equal(AppSettings.DefaultParallel, settings.MaxParallel);
    }

    [Fact]
    public void Load_AcceptsNumbersWrittenAsText()
    {
        File.WriteAllText(_temp.File("config.json"), """{ "packagetimeoutmin": "45", "MaxParallel": 4 }""");

        var settings = _service.Load();

        Assert.Equal(45, settings.PackageTimeoutMin);
        Assert.Equal(4, settings.MaxParallel);
    }

    [Fact]
    public void Save_ThenLoad_RoundTrips()
    {
        var expected = new AppSettings { CataloguePath = @"\\srv\depot\catalogue.json", PackageTimeoutMin = 12, MaxParallel = 3 };

        Assert.True(_service.TrySave(expected, out _));
        Assert.Equal(expected, _service.Load());
    }

    [Theory]
    [InlineData("1", 1)]
    [InlineData("240", 240)]
    [InlineData("0", -1)]
    [InlineData("241", -1)]
    [InlineData("12.5", -1)]
    [InlineData("", -1)]
    public void ParseClamped_RespectsBounds(string text, int expected)
    {
        Assert.Equal(expected, SettingsService.ParseClamped(text, 1, 240, -1));
    }

    [Fact]
    public void DepotRoot_IsCatalogueFolder()
    {
        Assert.Equal(@"\\SERVEUR\Depot", new AppSettings().DepotRoot);
    }
}

public class HistoryServiceTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void Append_KeepsExistingEntries_AndLimitsTo200()
    {
        var file = _temp.File("historique.json");
        var existing = new JsonArray();
        for (var i = 0; i < HistoryService.MaxEntries; i++)
        {
            existing.Add(new JsonObject { ["Date"] = $"ancien-{i}", ["Resultats"] = new JsonArray() });
        }
        File.WriteAllText(file, existing.ToJsonString());

        var service = new HistoryService(file, new LogService(_temp.File("test.log")));
        service.Append([new PackageResult("PC1", "Git", "Git.Git", ResultStatus.Ok, "ok", DateTime.Now)]);

        var history = JsonNode.Parse(File.ReadAllText(file))!.AsArray();
        Assert.Equal(HistoryService.MaxEntries, history.Count);
        Assert.Equal("ancien-1", (string?)history[0]!["Date"]);
        Assert.Equal("PC1", (string?)history[^1]!["Resultats"]![0]!["Ordinateur"]);
    }

    [Fact]
    public void Append_CorruptFile_StartsNewHistory()
    {
        var file = _temp.File("historique.json");
        File.WriteAllText(file, "corrompu");

        new HistoryService(file, new LogService(_temp.File("test.log"))).Append([]);

        Assert.Single(JsonNode.Parse(File.ReadAllText(file))!.AsArray());
    }
}

public class LogServiceTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void Write_FormatsLine_AndRaisesEvent()
    {
        var log = new LogService(_temp.File("gui.log"));
        string? raised = null;
        log.LineWritten += line => raised = line;

        log.Write("Bonjour", LogService.Warning);

        Assert.Matches(@"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[ATTENTION\] Bonjour$", raised);
        Assert.Contains("Bonjour", File.ReadAllText(_temp.File("gui.log")));
    }
}

public class CsvExporterTests
{
    [Fact]
    public void Build_QuotesEveryValue_AndDoublesQuotes()
    {
        var date = new DateTime(2026, 10, 9, 14, 3, 22);
        var rows = new[] { new PackageResult("PC1", "Git", "Git.Git", "ECHEC", "Erreur \"x\"; fin", date) };

        var csv = CsvExporter.Build(rows, CultureInfo.InvariantCulture);

        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("\"Ordinateur\";\"Paquet\";\"Id\";\"Statut\";\"Message\";\"Horodatage\"", lines[0]);
        Assert.Equal("\"PC1\";\"Git\";\"Git.Git\";\"ECHEC\";\"Erreur \"\"x\"\"; fin\";\"10/09/2026 14:03:22\"", lines[1]);
    }
}

public class ActiveDirectoryFilterTests
{
    [Fact]
    public void BuildComputerFilter_NoText_ListsEnabledComputers()
    {
        Assert.Equal(
            "(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))",
            ActiveDirectoryService.BuildComputerFilter("  "));
    }

    [Fact]
    public void BuildComputerFilter_EscapesSpecialCharacters_KeepsWildcard()
    {
        var filter = ActiveDirectoryService.BuildComputerFilter(@"*PC(1)\a*");

        Assert.EndsWith(@"(name=*PC\281\29\5ca*))", filter);
    }
}

public class TextMatchTests
{
    [Theory]
    [InlineData("PC-COMPTA-01", "compta", true)]
    [InlineData("PC-COMPTA-01", "PC*01", true)]
    [InlineData("PC-COMPTA-01", "RH", false)]
    [InlineData("PC[1]", "[", true)]
    public void ContainsLike_BehavesLikePowerShell(string value, string pattern, bool expected)
    {
        Assert.Equal(expected, TextMatch.ContainsLike(value, pattern));
    }

    [Fact]
    public void FormatElapsed_ShowsTotalMinutes()
    {
        Assert.Equal("75:07", TextMatch.FormatElapsed(TimeSpan.FromSeconds(75 * 60 + 7)));
    }
}

public class TrustedHostsTests
{
    [Fact]
    public void Merge_AddsOnlyMissingComputers()
    {
        var value = TrustedHostsService.Merge(" pc1 , PC2", ["PC1", "PC3", "pc3"], out var missing);

        Assert.Equal("pc1,PC2,PC3", value);
        Assert.Equal(new[] { "PC3" }, missing);
    }

    [Fact]
    public void Merge_WildcardOrNothingToAdd_ReturnsNull()
    {
        Assert.Null(TrustedHostsService.Merge("*", ["PC1"], out _));
        Assert.Null(TrustedHostsService.Merge("PC1", ["pc1"], out _));
    }
}

public class WingetSearchServiceTests
{
    private const string Response = """
        {
          "total": 2,
          "data": [
            { "_id": "7zip.7zip", "name": "7-Zip", "publisher": "Igor Pavlov", "desc": "Archiveur", "latestVersion": "24.09" },
            { "_id": "VideoLAN.VLC", "name": "VLC media player", "publisher": "VideoLAN", "latestVersion": "3.0.24" },
            { "_id": "7zip.7zip", "name": "Doublon ignoré" },
            { "name": "Sans identifiant" },
            "pas un objet"
          ]
        }
        """;

    [Fact]
    public void Parse_KeepsFirstOccurrenceOfEachId()
    {
        var hits = WingetSearchService.Parse(Response);

        Assert.Equal(new[] { "7zip.7zip", "VideoLAN.VLC" }, hits.Select(h => h.Id));
        Assert.Equal("7-Zip", hits[0].Name);
        Assert.Equal("7zip.7zip  ·  Igor Pavlov  ·  v24.09", hits[0].Details);
        Assert.Equal("VideoLAN.VLC  ·  VideoLAN  ·  v3.0.24", hits[1].Details);
    }

    [Fact]
    public void Parse_UnexpectedShape_ReturnsEmpty()
    {
        Assert.Empty(WingetSearchService.Parse("{}"));
        Assert.Empty(WingetSearchService.Parse("""{ "data": "non" }"""));
        Assert.Empty(WingetSearchService.Parse("[]"));
    }

    [Fact]
    public async Task SearchAsync_TooShort_DoesNotCallTheNetwork()
    {
        var error = await Assert.ThrowsAsync<WingetSearchException>(() => new WingetSearchService().SearchAsync("a", CancellationToken.None));

        Assert.Contains("au moins", error.Message);
    }
}
