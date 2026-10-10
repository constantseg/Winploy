using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using WinPloy.Core.Models;
using WinPloy.ViewModels;

namespace WinPloy.Views;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;

        // Taille de départ limitée à la zone utile de l'écran (portables, mise à l'échelle 125-150 %).
        var workArea = SystemParameters.WorkArea;
        Width = Math.Min(Width, workArea.Width - 12);
        Height = Math.Min(Height, workArea.Height - 12);

        viewModel.LogLineAdded += AppendLog;
    }

    private void AppendLog(string line)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.InvokeAsync(() => AppendLog(line));
            return;
        }

        LogBox.AppendText(line + "\r\n");
        LogBox.ScrollToEnd();
    }

    private void LstPcAll_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (LstPcAll.SelectedItem is string computer)
        {
            _viewModel.AddComputers([computer]);
        }
    }

    private void GridCatalogue_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (GridCatalogue.SelectedItem is CatalogueEntry entry)
        {
            _viewModel.EditPackage(entry);
        }
    }

    private void GridResults_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (GridResults.SelectedItem is PackageResult result)
        {
            _viewModel.ShowResultDetails(result);
        }
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (!_viewModel.ConfirmClose())
        {
            e.Cancel = true;
        }
    }

    private void Window_Closed(object? sender, EventArgs e) => _viewModel.Shutdown();
}
