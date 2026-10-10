using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using WinPloy.Core.Deployment;
using WinPloy.Core.Models;
using WinPloy.Core.Services;
using WinPloy.Services;

namespace WinPloy.Views;

public partial class WingetPackageWindow : Window
{
    private readonly WingetSearchService _search = new();
    private readonly LogService _log;
    private CancellationTokenSource? _pending;

    public WingetPackageWindow(CatalogueEntry? existing, LogService log)
    {
        InitializeComponent();
        _log = log;
        Title = existing is null ? "Ajouter une application WinGet" : "Modifier l'application WinGet";
        if (existing is not null)
        {
            TxtName.Text = existing.Name;
            TxtId.Text = existing.Id;
            TxtSearch.Text = existing.Name;
        }
    }

    public CatalogueEntry? Result { get; private set; }

    protected override void OnClosed(EventArgs e)
    {
        _pending?.Cancel();
        base.OnClosed(e);
    }

    private void TxtSearch_KeyDown(object sender, KeyEventArgs e)
    {
        // Entrée lance la recherche au lieu de valider la fenêtre.
        if (e.Key == Key.Return)
        {
            e.Handled = true;
            _ = SearchAsync();
        }
    }

    private void BtnSearch_Click(object sender, RoutedEventArgs e) => _ = SearchAsync();

    private async Task SearchAsync()
    {
        var query = TxtSearch.Text.Trim();
        _pending?.Cancel();
        using var cancellation = new CancellationTokenSource();
        _pending = cancellation;

        BtnSearch.IsEnabled = false;
        TxtSearchStatus.Text = "Recherche en ligne…";
        try
        {
            var hits = await _search.SearchAsync(query, cancellation.Token);
            if (cancellation.IsCancellationRequested)
            {
                return;
            }

            LstResults.ItemsSource = hits;
            TxtSearchStatus.Text = hits.Count == 0
                ? $"Aucune application trouvée pour « {query} »."
                : $"{hits.Count} application(s) trouvée(s). Cliquez sur une ligne pour remplir les champs ci-dessous.";
        }
        catch (WingetSearchException ex)
        {
            TxtSearchStatus.Text = ex.Message;
            _log.Write($"Recherche WinGet : {ex.Message}", LogService.Warning);
        }
        catch (OperationCanceledException)
        {
            // Fenêtre fermée ou nouvelle recherche lancée.
        }
        catch (Exception ex)
        {
            TxtSearchStatus.Text = $"Recherche impossible : {ex.Message}";
            _log.Write($"Recherche WinGet : {ex.Message}", LogService.Error);
        }
        finally
        {
            // Une recherche plus récente garde la main sur le bouton et le statut.
            if (ReferenceEquals(_pending, cancellation))
            {
                _pending = null;
                BtnSearch.IsEnabled = true;
            }
        }
    }

    private void LstResults_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LstResults.SelectedItem is WingetSearchHit hit)
        {
            TxtName.Text = hit.Name;
            TxtId.Text = hit.Id;
        }
    }

    private void LnkCopy_Click(object sender, RoutedEventArgs e)
    {
        ClipboardHelper.Copy(WingetSearchService.BrowseUrl, _log);
        TxtSearchStatus.Text = $"Lien copié : {WingetSearchService.BrowseUrl}";
    }

    private void BtnOk_Click(object sender, RoutedEventArgs e)
    {
        var name = TxtName.Text.Trim();
        var id = TxtId.Text.Trim();
        if (name.Length == 0 || id.Length == 0)
        {
            Warn("Nom et identifiant requis.");
            return;
        }
        if (!PackageValidation.IsValidWingetId(id))
        {
            Warn($"Identifiant WinGet invalide : {id}");
            return;
        }

        Result = CatalogueEntry.Create(id, name);
        DialogResult = true;
    }

    private void Warn(string text) => MessageBox.Show(this, text, "Erreur", MessageBoxButton.OK, MessageBoxImage.Warning);
}
