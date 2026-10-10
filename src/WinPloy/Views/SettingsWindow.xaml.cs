using System.Globalization;
using System.Windows;
using Microsoft.Win32;
using WinPloy.Core.Models;
using WinPloy.Core.Services;

namespace WinPloy.Views;

public partial class SettingsWindow : Window
{
    private readonly Func<AppSettings, bool> _trySave;

    public SettingsWindow(AppSettings current, Func<AppSettings, bool> trySave)
    {
        InitializeComponent();
        _trySave = trySave;
        TxtCataloguePath.Text = current.CataloguePath;
        TxtTimeout.Text = current.PackageTimeoutMin.ToString(CultureInfo.InvariantCulture);
        TxtParallel.Text = current.MaxParallel.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>Réglages enregistrés, renseignés quand la fenêtre se ferme par « Enregistrer ».</summary>
    public AppSettings? Result { get; private set; }

    private void BtnBrowse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Filter = "Catalogue JSON (*.json)|*.json|Tous les fichiers (*.*)|*.*",
            CheckFileExists = false,
        };
        if (dialog.ShowDialog(this) == true)
        {
            TxtCataloguePath.Text = dialog.FileName;
        }
    }

    private void BtnSave_Click(object sender, RoutedEventArgs e)
    {
        var path = TxtCataloguePath.Text.Trim();
        var timeout = SettingsService.ParseClamped(TxtTimeout.Text.Trim(), AppSettings.MinTimeoutMin, AppSettings.MaxTimeoutMin, -1);
        var parallel = SettingsService.ParseClamped(TxtParallel.Text.Trim(), AppSettings.MinParallel, AppSettings.MaxParallelLimit, -1);

        if (path.Length == 0)
        {
            Warn("Le chemin du catalogue est obligatoire.");
            return;
        }
        if (timeout < 0)
        {
            Warn("Le délai doit être compris entre 1 et 240 minutes.");
            return;
        }
        if (parallel < 0)
        {
            Warn("Le parallélisme doit être compris entre 1 et 50.");
            return;
        }

        var updated = new AppSettings { CataloguePath = path, PackageTimeoutMin = timeout, MaxParallel = parallel };
        if (!_trySave(updated))
        {
            return;
        }

        Result = updated;
        DialogResult = true;
    }

    private void Warn(string text) => MessageBox.Show(this, text, "Réglages", MessageBoxButton.OK, MessageBoxImage.Warning);
}
