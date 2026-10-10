using System.Diagnostics;
using System.Globalization;

namespace WinPloy.Core.Services;

/// <summary>Journal de l'interface : onglet « Journal » et fichier gui.log (rotation à 5 Mo).</summary>
public sealed class LogService
{
    public const string Info = "INFO";
    public const string Error = "ERREUR";
    public const string Warning = "ATTENTION";

    private const long MaxBytes = 5 * 1024 * 1024;

    private readonly string _file;
    private readonly object _sync = new();

    public LogService(string file) => _file = file;

    /// <summary>Levé pour chaque ligne écrite, sur le thread de l'appelant.</summary>
    public event Action<string>? LineWritten;

    public void Write(string message, string level = Info)
    {
        var line = $"[{DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)}] [{level}] {message}";
        LineWritten?.Invoke(line);

        lock (_sync)
        {
            try
            {
                var info = new FileInfo(_file);
                if (info.Exists && info.Length > MaxBytes)
                {
                    File.Move(_file, _file + ".1", overwrite: true);
                }
                File.AppendAllText(_file, line + Environment.NewLine, JsonHelpers.Utf8NoBom);
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Journal fichier indisponible : {ex.Message}");
            }
        }
    }
}
