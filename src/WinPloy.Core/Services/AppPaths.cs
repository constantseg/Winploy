namespace WinPloy.Core.Services;

/// <summary>Fichiers locaux de WinPloy (réglages, historique, journal).</summary>
public sealed class AppPaths
{
    public AppPaths(string dataDir) => DataDir = dataDir;

    public static AppPaths Default { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "WinPloy"));

    public string DataDir { get; }

    public string ConfigFile => Path.Combine(DataDir, "config.json");

    public string HistoryFile => Path.Combine(DataDir, "historique-deploiements.json");

    public string LogFile => Path.Combine(DataDir, "gui.log");

    public void EnsureDataDir() => Directory.CreateDirectory(DataDir);
}
