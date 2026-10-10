namespace WinPloy.Core.Models;

/// <summary>État d'un poste dans le tableau « Suivi par poste ».</summary>
public static class HostStates
{
    public const string Pending = "EN ATTENTE";
    public const string Running = "EN COURS";
    public const string Ok = "OK";
    public const string Failed = "ECHEC";
    public const string Stopped = "ARRÊTÉ";

    public static bool IsActive(string state) => state is Pending or Running;

    public static bool IsFailure(string state) => state is Failed or Stopped;
}

/// <summary>Statut d'un paquet sur un poste (onglet « Détail par paquet »).</summary>
public static class ResultStatus
{
    public const string Ok = "OK";
    public const string Failed = "ECHEC";
    public const string Stopped = "ARRÊTÉ";
}

public enum DeployAction
{
    Install,
    Uninstall,
}

public enum PackageType
{
    WinGet,
    Custom,
}
