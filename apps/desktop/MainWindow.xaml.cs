using System.Net.Http;
using System.Net.Http.Json;
using System.Windows;
using System.Windows.Media;

namespace NativeApp.Desktop;

public partial class MainWindow : Window
{
#if DEBUG
    private const string ApiBaseUrl = "http://localhost:5130/";
#else
    private const string ApiBaseUrl = "http://localhost:5000/";
#endif

    private static readonly HttpClient ApiClient = new() { BaseAddress = new Uri(ApiBaseUrl) };

    public MainWindow()
    {
        InitializeComponent();
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        await RefreshApiAsync();
    }

// Test note
    private async void RefreshApi_Click(object sender, RoutedEventArgs e)
    {
        await RefreshApiAsync();
    }

    private async Task RefreshApiAsync()
    {
        ApiStatusText.Text = "Connecting to the API…";
        ApiStatusText.Foreground = new SolidColorBrush(Color.FromRgb(104, 115, 134));
        try
        {
            var forecast = await ApiClient.GetFromJsonAsync<WeatherForecast[]>("weatherforecast");
            var first = forecast?.FirstOrDefault();
            ApiStatusText.Text = first is null ? "Connected, but no data was returned" : "Connected to the API";
            if (first is not null)
            {
                ApiStatusText.Foreground = new SolidColorBrush(Color.FromRgb(22, 163, 74));
                WeatherSummaryText.Text = $"Next forecast: {first.Summary}, {first.TemperatureC}°C";
            }
        }
        catch (HttpRequestException)
        {
            ApiStatusText.Text = "API unavailable — start apps/api to connect";
            WeatherSummaryText.Text = "The dashboard is still available offline.";
        }
    }

    private void CreatePipeline_Click(object sender, RoutedEventArgs e)
    {
        MessageBox.Show("Pipeline creation is ready to be connected.", "Create a pipeline", MessageBoxButton.OK, MessageBoxImage.Information);
    }
}

public sealed record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary);
