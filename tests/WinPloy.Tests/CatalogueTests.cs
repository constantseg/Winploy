using System.Text.Json.Nodes;
using WinPloy.Core.Models;
using WinPloy.Core.Services;

namespace WinPloy.Tests;

public class CatalogueEntryTests
{
    [Fact]
    public void Create_EmptyId_ReturnsNull()
    {
        Assert.Null(CatalogueEntry.Create("  ", "Nom"));
    }

    [Fact]
    public void Create_WinGet_TrimsIdAndUsesIdWhenNameMissing()
    {
        var entry = CatalogueEntry.Create("  Git.Git ", "")!;

        Assert.Equal(PackageType.WinGet, entry.Type);
        Assert.Equal("Git.Git", entry.Id);
        Assert.Equal("Git.Git", entry.Name);
        Assert.Equal("Git.Git", entry.Label);
    }

    [Fact]
    public void Create_CustomPrefixIgnoresCase_AndNormalizesRunAs()
    {
        var entry = CatalogueEntry.Create("Custom:Outil", "Outil", @"\\srv\d\Outil\i.ps1", null, "system")!;

        Assert.True(entry.IsCustom);
        Assert.Equal(CatalogueEntry.RunAsSystem, entry.RunAs);
        Assert.Equal("", entry.UninstallScript);
        Assert.Equal("Outil [Custom]", entry.Label);
    }

    [Fact]
    public void Create_CustomUnknownRunAs_IsUser()
    {
        var entry = CatalogueEntry.Create("custom:X", "X", runAs: "Admin")!;

        Assert.Equal(CatalogueEntry.RunAsUser, entry.RunAs);
    }

    [Fact]
    public void FromJson_PropertyNamesIgnoreCase()
    {
        var node = JsonNode.Parse("""{ "id": "custom:A", "NAME": "A", "installscript": "\\\\s\\d\\A\\i.ps1", "runas": "System" }""");

        var entry = CatalogueEntry.FromJson(node)!;

        Assert.Equal("custom:A", entry.Id);
        Assert.Equal("A", entry.Name);
        Assert.Equal(@"\\s\d\A\i.ps1", entry.InstallScript);
        Assert.True(entry.RunsAsSystem);
    }

    [Fact]
    public void ToJson_WinGetHasOnlyTypeIdName()
    {
        var json = CatalogueEntry.Create("Git.Git", "Git")!.ToJson();

        Assert.Equal(new[] { "Type", "Id", "Name" }, json.Select(p => p.Key));
        Assert.Equal("WinGet", (string?)json["Type"]);
    }

    [Fact]
    public void ToJson_CustomHasScriptsAndRunAs()
    {
        var json = CatalogueEntry.Create("custom:A", "A", "i", "u", "System")!.ToJson();

        Assert.Equal(new[] { "Type", "Id", "Name", "InstallScript", "UninstallScript", "RunAs" }, json.Select(p => p.Key));
    }
}

public class CatalogueServiceTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly CatalogueService _service;
    private readonly string _path;

    public CatalogueServiceTests()
    {
        _path = _temp.File(@"depot\catalogue.json");
        _service = new CatalogueService(() => _path, new LogService(_temp.File("test.log")));
    }

    public void Dispose() => _temp.Dispose();

    [Fact]
    public void Read_MissingFile_Throws()
    {
        var error = Assert.Throws<CatalogueException>(() => _service.Read());

        Assert.StartsWith("Catalogue introuvable", error.Message);
    }

    [Fact]
    public void Import_MissingFile_ReturnsEmpty()
    {
        Assert.Empty(_service.Import());
    }

    [Fact]
    public void Read_EmptyFile_ReturnsEmpty()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, "  ");

        Assert.Empty(_service.Read());
    }

    [Fact]
    public void Read_SingleObjectWithBom_IsAccepted()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, """{ "Type": "WinGet", "Id": "Git.Git", "Name": "Git" }""", new System.Text.UTF8Encoding(true));

        var entry = Assert.Single(_service.Read());

        Assert.Equal("Git.Git", entry.Id);
    }

    [Fact]
    public void Read_SkipsEntriesWithoutId()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, """[ { "Name": "Sans Id" }, "texte", { "Id": "7zip.7zip" } ]""");

        var entry = Assert.Single(_service.Read());

        Assert.Equal("7zip.7zip", entry.Name);
    }

    [Fact]
    public void Add_CreatesFolderAndFile_WithoutTemporaryFile()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, "[]");

        _service.Add(CatalogueEntry.Create("Git.Git", "Git")!);
        _service.Add(CatalogueEntry.Create("custom:Outil", "Outil", @"\\s\d\Outil\i.ps1")!);

        Assert.Equal(2, _service.Read().Count);
        Assert.Single(Directory.GetFiles(Path.GetDirectoryName(_path)!));
    }

    [Fact]
    public void Add_DuplicateIdIgnoringCase_Throws()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, """[ { "Id": "Git.Git", "Name": "Git" } ]""");

        Assert.Throws<CatalogueException>(() => _service.Add(CatalogueEntry.Create("git.git", "Git")!));
    }

    [Fact]
    public void Update_ReplacesEntry_AndRejectsIdConflict()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, """[ { "Id": "A.A", "Name": "A" }, { "Id": "B.B", "Name": "B" } ]""");

        var updated = _service.Update("A.A", CatalogueEntry.Create("A.A", "A modifié")!);
        Assert.Equal("A modifié", updated.Single(e => e.Id == "A.A").Name);

        Assert.Throws<CatalogueException>(() => _service.Update("A.A", CatalogueEntry.Create("B.B", "B")!));
        Assert.Throws<CatalogueException>(() => _service.Update("Z.Z", CatalogueEntry.Create("Z.Z", "Z")!));
    }

    [Fact]
    public void Remove_DeletesSelectedIds()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, """[ { "Id": "A.A" }, { "Id": "B.B" }, { "Id": "C.C" } ]""");

        var updated = _service.Remove(["a.a", "C.C"]);

        Assert.Equal(new[] { "B.B" }, updated.Select(e => e.Id));
    }
}
