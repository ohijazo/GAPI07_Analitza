using System.Net;
using SapB1AnalitzaSync.Shared.Configuration;
using SapB1AnalitzaSync.Worker.Logging;
using SapB1AnalitzaSync.Worker.Services;

// Punt d'entrada del Worker. Tres modes, tots d'un sol tret (no hi ha
// scheduler continu): qui marca el ritme és el job Analitza_ETL_Daily de SQL
// Agent, que crida aquest executable com a pas 1 i etl.sp_run_all com a pas 2.
//
//   --probe      sonda de la Fase 0; llegeix SAP i compara amb baseline. NO escriu.
//   --once       refresca sap_raw i surt.  <- el que crida el job
//   --backfill   com --once, però des de la data indicada amb --from.
//   --metadata   llista les propietats d'un EntityType del $metadata. NO escriu.

var builder = Host.CreateApplicationBuilder(args);

builder.Services.Configure<ServiceLayerOptions>(builder.Configuration.GetSection(ServiceLayerOptions.SectionName));
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection(DatabaseOptions.SectionName));
builder.Services.Configure<SyncOptions>(builder.Configuration.GetSection(SyncOptions.SectionName));

var slOptions = builder.Configuration.GetSection(ServiceLayerOptions.SectionName).Get<ServiceLayerOptions>()
                ?? new ServiceLayerOptions();

// El log també a fitxer: la tasca de les 02:45 no redirigeix la sortida i la
// consola es perd. Es registra abans de qualsevol LogX perquè el fitxer porti
// també les guardes d'arrencada, que són les que diuen què s'ha configurat mal.
var fileLogOptions = builder.Configuration.GetSection(FileLogOptions.SectionName).Get<FileLogOptions>()
                     ?? new FileLogOptions();
if (fileLogOptions.Enabled)
    builder.Logging.AddProvider(new FileLoggerProvider(fileLogOptions, AppContext.BaseDirectory));

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
builder.Services.AddSingleton<MetadataProbeService>();

using var host = builder.Build();

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

var log = host.Services.GetRequiredService<ILogger<Program>>();

// La guarda cobria només BaseUrl, i deixava fora precisament la clau que canvia
// al cutover. Sense això, una CompanyDb oblidada arriba al Login i torna
// "Invalid login credential", que envia qui ho depuri a mirar la contrasenya.
// Això NO detecta apuntar a una companyia existent però equivocada: cap guarda
// ho fa, i és per això que el primer cicle contra una companyia nova es fa a mà
// i es comparen els recomptes (veure docs/runbook_cutover.md).
foreach (var (key, value) in new[]
         {
             ("ServiceLayer:BaseUrl", slOptions.BaseUrl),
             ("ServiceLayer:CompanyDb", slOptions.CompanyDb),
             ("ServiceLayer:UserName", slOptions.UserName),
             ("ServiceLayer:Password", slOptions.Password),
         })
{
    if (!string.IsNullOrWhiteSpace(value) && !value.Contains('<')) continue;

    log.LogError("{Key} no està configurat (és buit o encara porta el placeholder). A DEV: " +
                 "dotnet user-secrets set \"{Key}\" \"...\" i executa amb DOTNET_ENVIRONMENT=Development " +
                 "(els user-secrets només es carreguen en Development). A PRD: appsettings.Production.json " +
                 "al costat de l'executable.", key, key);
    return 3;
}

var mode = args.FirstOrDefault(a => a.StartsWith("--", StringComparison.Ordinal)) ?? "--once";

try
{
    switch (mode)
    {
        case "--probe":
            return await host.Services.GetRequiredService<ProbeService>().RunAsync(cts.Token);

        // --raw <url>   GET cru contra Service Layer. NOMÉS llegeix; existeix
        // perquè el $metadata de v1 no declara el tipus de les línies de
        // document i l'única manera de saber què exposa SL és demanar-ho.
        case "--raw":
        {
            var url = args.SkipWhile(a => a != "--raw").Skip(1)
                          .FirstOrDefault(a => !a.StartsWith("--", StringComparison.Ordinal));
            if (url is null) { log.LogError("--raw necessita una url, p. ex. --raw \"DeliveryNotes?$top=1\""); return 3; }

            var body = await host.Services.GetRequiredService<ServiceLayerClient>().GetRawAsync(url, cts.Token);
            Console.WriteLine(body);
            return 0;
        }

        // --metadata <EntityType> [filtre]   p. ex.  --metadata DocumentLine Price
        case "--metadata":
        {
            var rest = args.SkipWhile(a => a != "--metadata").Skip(1)
                           .Where(a => !a.StartsWith("--", StringComparison.Ordinal)).ToArray();
            var entity = rest.ElementAtOrDefault(0) ?? "DocumentLine";
            var match = rest.ElementAtOrDefault(1);
            return await host.Services.GetRequiredService<MetadataProbeService>().RunAsync(entity, match, cts.Token);
        }

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
            sync.ForceBackfill = true;
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
