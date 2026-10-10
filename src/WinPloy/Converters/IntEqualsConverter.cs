using System.Globalization;
using System.Windows.Data;

namespace WinPloy.Converters;

/// <summary>
/// Lie un groupe de boutons radio à une valeur entière : coché quand la valeur vaut le paramètre.
/// </summary>
public sealed class IntEqualsConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is int current && int.TryParse(parameter?.ToString(), out var expected) && current == expected;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is true && int.TryParse(parameter?.ToString(), out var expected) ? expected : Binding.DoNothing;
}
