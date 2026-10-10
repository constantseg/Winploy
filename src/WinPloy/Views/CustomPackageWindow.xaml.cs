using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using WinPloy.Core.Deployment;
using WinPloy.Core.Models;

namespace WinPloy.Views;

public partial class CustomPackageWindow : Window
{
    private readonly CatalogueEntry? _existing;
    private readonly string _depotRoot;

    public CustomPackageWindow(CatalogueEntry? existing, string depotRoot)
    {
        InitializeComponent();
        _existing = existing;
        _depotRoot = depotRoot;

        if (existing is null)
        {
            Title = "Créer un paquet personnalisé";
            return;
        }

        Title = "Modifier le paquet personnalisé";
        TxtName.Text = existing.Name;
        TxtInstall.Text = existing.InstallScript;
        TxtUninstall.Text = existing.UninstallScript;
        ChkRunAsSystem.IsChecked = existing.RunsAsSystem;
    }

    public CatalogueEntry? Result { get; private set; }

    private void BtnBrowseInstall_Click(object sender, RoutedEventArgs e) => Browse(TxtInstall);

    private void BtnBrowseUninstall_Click(object sender, RoutedEventArgs e) => Browse(TxtUninstall);

    private void Browse(TextBox target)
    {
        var dialog = new OpenFileDialog
        {
            Filter = PackageValidation.FileDialogFilter,
            InitialDirectory = _depotRoot,
        };
        if (dialog.ShowDialog(this) == true)
        {
            target.Text = dialog.FileName;
        }
    }

    private void BtnOk_Click(object sender, RoutedEventArgs e)
    {
        var name = TxtName.Text.Trim();
        var install = TxtInstall.Text.Trim();
        var uninstall = TxtUninstall.Text.Trim();

        string? error;
        if (name.Length == 0)
        {
            error = "Nom du paquet requis.";
        }
        else if (install.Length == 0)
        {
            error = "Script d'installation requis.";
        }
        else
        {
            error = PackageValidation.ValidateScriptPath(install, "Script d'installation", _depotRoot);
            if (error is null && uninstall.Length > 0)
            {
                error = PackageValidation.ValidateScriptPath(uninstall, "Script de désinstallation", _depotRoot);
            }
        }

        if (error is not null)
        {
            MessageBox.Show(this, error, "Erreur", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var id = _existing?.Id ?? PackageValidation.MakeCustomId(name);
        var runAs = ChkRunAsSystem.IsChecked == true ? CatalogueEntry.RunAsSystem : CatalogueEntry.RunAsUser;
        Result = CatalogueEntry.Create(id, name, install, uninstall, runAs);
        DialogResult = true;
    }
}
