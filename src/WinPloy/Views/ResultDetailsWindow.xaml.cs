using System.Globalization;
using System.Windows;
using WinPloy.Core.Models;
using WinPloy.Core.Services;
using WinPloy.Services;

namespace WinPloy.Views;

public partial class ResultDetailsWindow : Window
{
    private readonly LogService _log;

    public ResultDetailsWindow(PackageResult result, LogService log)
    {
        InitializeComponent();
        _log = log;
        TxtDetails.Text = string.Join("\r\n",
            $"Ordinateur  : {result.Ordinateur}",
            $"Paquet      : {result.Paquet}",
            $"Identifiant : {result.Id}",
            $"Statut      : {result.Statut}",
            $"Date/heure  : {result.Horodatage.ToString(CultureInfo.CurrentCulture)}",
            "",
            "Message :",
            result.Message);
    }

    private void BtnCopy_Click(object sender, RoutedEventArgs e) => ClipboardHelper.Copy(TxtDetails.Text, _log);
}
