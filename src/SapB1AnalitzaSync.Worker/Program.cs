using System.Net;
using SapB1AnalitzaSync.Shared.Configuration;
using SapB1AnalitzaSync.Worker.Services;

// Punt d'entrada del Worker. Tres modes, tots d'un sol tret (no hi ha
// scheduler continu): qui marca el ritme és el job Analitza_ETL_Daily de SQL
// Agent, que crida aquest executable com a pas 1 i etl.sp_run_all com a pas 2.
//
//   --probe      sonda de la Fase 0; llegeix SAP i compara amb baseline. NO escriu.
//   --once       refresca sap_raw i surt.  <- el que crida el job
//   --backfill   com --once, però des de la data indicada amb --from.

var builder = Host.CreateApplicationBuilder(args);

builder.Services.Configure<ServiceLayerOptions>(builder.Configuration.GetSection(ServiceLayerOptions.SectionName));
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection(DatabaseOptions.SectionName));
builder.Services.Configure<SyncOptions>(builder.Configuration.GetSection(SyncOptions.SectionName));

var slOptions = builder.Configuration.GetSection(ServiceLayerOptions.SectionName).Get<ServiceLayerOptions>()
                ?? new ServiceLayerOptions();

builder.Services.AddHttpClient<ServiceLayerClient>(http =>
    {
        http.BaseAddress = new Uri(EnsureTrailingSlash(slOptions.BaseUrl));
        http.Timeout = TimeSpan.FromSeconds(slOptions.RequestTimeoutSeconds);

        // Sense aquesta capçalera SL retorna 20 registres per pàgina (el default
        // de b1s.conf) i la sincronització es fa vuit vegades més lenta. NO és
        // un $top: es paginen totes les pàgines seguint odata.nextLink (Regla 02).
        http.DefaultRequestHeaders.Add("Prefer", $"odata.maxpagesize={slOptions.PageSize}");
    })
    .ConfigurePrimaryHttpMessageHandler(() =>
    {
        var handler = new HttpClientHandler
        {
            // SL manté la sessió amb les cookies B1SESSION i ROUTEID.
            CookieContainer = new CookieContainer(),
            UseCookies = true,
        };
        if (slOptions.AllowInvalidCertificates)
            handler.ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
        return handler;
    });

builder.Services.AddSingleton<MirrorRepository>();
builder.Services.AddSingleton<SyncStateStore>();
builder.Services.AddSingleton<MirrorSyncService>();
builder.Services.AddSingleton<ProbeService>();

using var host = builder.Build();

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

var log = host.Services.GetRequiredService<ILogger<Program>>();

if (string.IsNullOrWhiteSpace(slOptions.BaseUrl) || slOptions.BaseUrl.Contains('<'))
{
    log.LogError("ServiceLayer:BaseUrl no està configurat. A DEV: dotnet user-secrets set \"ServiceLayer:BaseUrl\" \"https://...:50000/b1s/v1/\" " +
                 "i executa amb DOTNET_ENVIRONMENT=Development (els user-secrets només es carreguen en Development).");
    return 3;
}

var mode = args.FirstOrDefault(a => a.StartsWith("--", StringComparison.Ordinal)) ?? "--once";

try
{
    switch (mode)
    {
        case "--probe":
            return await host.Services.GetRequiredService<ProbeService>().RunAsync(cts.Token);

        case "--backfill":
        {
            var from = ParseFrom(args);
            if (from is null)
            {
                log.LogError("--backfill necessita --from yyyy-MM-dd");
                return 3;
            }
            var sync = host.Services.GetRequiredService<Microsoft.Extensions.Options.IOptions<SyncOptions>>().Value;
            sync.BackfillFrom = from;
            log.LogInformation("Backfill des de {From}", from.Value.ToString("yyyy-MM-dd"));
            await host.Services.GetRequiredService<MirrorSyncService>().RunOnceAsync(cts.Token);
            return 0;
        }

        case "--once":
            await host.Services.GetRequiredService<MirrorSyncService>().RunOnceAsync(cts.Token);
            return 0;

        default:
            log.LogError("Mode desconegut: {Mode}. Opcions: --probe, --once, --backfill --from yyyy-MM-dd", mode);
            return 3;
    }
}
catch (OperationCanceledException)
{
    log.LogWarning("Cancel-lat per l'usuari");
    return 130;
}
catch (Exception ex)
{
    // Codi de sortida != 0 perquè el pas del job de SQL Agent falli i no
    // s'executi l'ETL sobre un mirall a mig refrescar.
    log.LogError(ex, "El cicle ha fallat");
    return 1;
}

static string EnsureTrailingSlash(string url) =>
    string.IsNullOrEmpty(url) || url.EndsWith('/') ? url : url + "/";

static DateTime? ParseFrom(string[] args)
{
    var i = Array.IndexOf(args, "--from");
    if (i < 0 || i + 1 >= args.Length) return null;
    return DateTime.TryParse(args[i + 1], System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.None, out var d) ? d : null;
}
