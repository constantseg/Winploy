using CommunityToolkit.Mvvm.ComponentModel;

namespace WinPloy.Core.Models;

/// <summary>Ligne du tableau « Suivi par poste » : notifie l'interface à chaque changement de propriété.</summary>
public sealed partial class HostRow : ObservableObject
{
    public HostRow(string poste) => Poste = poste;

    public string Poste { get; }

    [ObservableProperty]
    private string _etat = HostStates.Pending;

    [ObservableProperty]
    private string _winRM = "";

    [ObservableProperty]
    private string _info = "";

    [ObservableProperty]
    private string _duree = "";
}
