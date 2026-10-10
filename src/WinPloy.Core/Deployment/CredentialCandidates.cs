using System.Management.Automation;

namespace WinPloy.Core.Deployment;

/// <summary>
/// Comptes essayés pour ouvrir la session WinRM.
/// Un nom sans domaine ("admin") est essayé tel quel puis qualifié en compte local ("POSTE\admin").
/// ".\admin" devient "POSTE\admin".
/// </summary>
public static class CredentialCandidates
{
    public static IReadOnlyList<string> BuildUserNames(string computer, string userName)
    {
        if (!userName.Contains('\\') && !userName.Contains('@'))
        {
            return [userName, $@"{computer}\{userName}"];
        }
        if (userName.StartsWith(@".\", StringComparison.Ordinal))
        {
            return [$@"{computer}\{userName[2..]}"];
        }
        return [userName];
    }

    /// <summary>Sans identifiants, un seul essai avec le contexte courant (null).</summary>
    public static IReadOnlyList<PSCredential?> Build(string computer, PSCredential? credential)
    {
        if (credential is null)
        {
            return [null];
        }

        return BuildUserNames(computer, credential.UserName)
            .Select(user => user == credential.UserName ? credential : new PSCredential(user, credential.Password))
            .ToList();
    }
}
