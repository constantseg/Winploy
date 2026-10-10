namespace WinPloy.Core.Deployment;

/// <summary>
/// Copie un dossier de la machine d'administration vers le poste, par la session WinRM
/// (équivalent de Copy-Item -ToSession). Le poste cible n'accède jamais au partage.
/// </summary>
internal static class RemoteFileCopier
{
    /// <summary>Taille d'un bloc : reste sous la limite par objet reçu de l'endpoint WinRM (10 Mo par défaut).</summary>
    public const int ChunkSize = 2 * 1024 * 1024;

    private const string CreateDirectoryScript = """
        param([string]$Path)
        $ErrorActionPreference = 'Stop'
        [void][IO.Directory]::CreateDirectory($Path)
        """;

    private const string WriteChunkScript = """
        param([string]$Path, [byte[]]$Data, [bool]$Append)
        $ErrorActionPreference = 'Stop'
        $mode = if ($Append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $stream = [IO.File]::Open($Path, $mode, [IO.FileAccess]::Write)
        try { if ($Data.Length) { $stream.Write($Data, 0, $Data.Length) } } finally { $stream.Dispose() }
        """;

    public static void CopyDirectory(RemoteSession session, string sourceDir, string targetDir, CancellationToken cancellationToken)
    {
        foreach (var dir in Directory.EnumerateDirectories(sourceDir, "*", SearchOption.AllDirectories))
        {
            cancellationToken.ThrowIfCancellationRequested();
            session.InvokeOrThrow(CreateDirectoryScript, RemotePath(targetDir, sourceDir, dir));
        }

        var buffer = new byte[ChunkSize];
        foreach (var file in Directory.EnumerateFiles(sourceDir, "*", SearchOption.AllDirectories))
        {
            var remotePath = RemotePath(targetDir, sourceDir, file);
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.SequentialScan);
            var append = false;
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var read = stream.ReadAtLeast(buffer, buffer.Length, throwOnEndOfStream: false);
                var chunk = read == buffer.Length ? buffer : buffer.AsSpan(0, read).ToArray();
                session.InvokeOrThrow(WriteChunkScript, remotePath, chunk, append);
                append = true;
                if (read < buffer.Length)
                {
                    break;
                }
            }
        }
    }

    private static string RemotePath(string targetDir, string sourceDir, string localPath)
        => targetDir.TrimEnd('\\') + "\\" + Path.GetRelativePath(sourceDir, localPath);
}
