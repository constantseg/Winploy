using System.Net.Sockets;

namespace WinPloy.Core.Deployment;

public static class TcpProbe
{
    /// <summary>Vrai si une connexion TCP s'ouvre avant le délai.</summary>
    public static bool IsOpen(string host, int port, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(timeout);
        using var client = new TcpClient();
        try
        {
            client.ConnectAsync(host, port, limit.Token).AsTask().GetAwaiter().GetResult();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
