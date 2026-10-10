using System.Management.Automation;

namespace WinPloy.Core.Services;

public static class TextMatch
{
    /// <summary>Équivalent de $valeur -like "*$motif*" : * et ? restent des jokers, sans tenir compte de la casse.</summary>
    public static bool ContainsLike(string value, string pattern)
    {
        try
        {
            return new WildcardPattern($"*{pattern}*", WildcardOptions.IgnoreCase).IsMatch(value);
        }
        catch (WildcardPatternException)
        {
            return value.Contains(pattern, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>Durée au format mm:ss (les minutes peuvent dépasser 59).</summary>
    public static string FormatElapsed(TimeSpan elapsed)
        => $"{(int)Math.Floor(elapsed.TotalMinutes):00}:{elapsed.Seconds:00}";

    public static bool SameHost(string? a, string? b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
}
