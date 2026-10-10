using System.Globalization;
using System.Windows.Data;
using WinPloy.Core.Models;

namespace WinPloy.Converters;

/// <summary>
/// Libellé affiché pour un état de poste ou un statut de paquet.
/// Les valeurs internes (EN COURS, ECHEC...) restent celles des fichiers d'historique et des exports.
/// </summary>
public sealed class StatusLabelConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => value switch
    {
        HostStates.Pending => "En attente",
        HostStates.Running => "En cours",
        HostStates.Ok => "Réussi",
        HostStates.Failed => "Échec",
        HostStates.Stopped => "Arrêté",
        _ => value?.ToString() ?? "",
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
