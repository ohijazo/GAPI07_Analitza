using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Options;
using SapB1AnalitzaSync.Shared.Configuration;
using SapB1AnalitzaSync.Shared.ServiceLayer;

namespace SapB1AnalitzaSync.Worker.Services;

/// <summary>
/// Client de SAP B1 Service Layer: gestiona la sessió (Login, renovació
/// proactiva, relogin davant d'un 401) i paginació de col·leccions OData.
///
/// Verificat contra SAP B1 10.0 FP 2602. Els detalls que semblen arbitraris
/// estan documentats a la Regla 02 i cadascun ve d'un bug real.
/// </summary>
internal sealed class ServiceLayerClient : IAsyncDisposable
{
    /// <summary>
    /// SL distingeix majúscules als noms de propietat JSON: el cos del Login ha
    /// de ser exactament "CompanyDB"/"UserName"/"Password". La política web per
    /// defecte de .NET 8 els passaria a camelCase i el Login retornaria HTTP 400
    /// amb {"error":{"code":206,"message":"Invalid login credential."}}.
    /// Per això NO s'hi posa cap PropertyNamingPolicy.
    /// </summary>
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    private readonly HttpClient _http;
    private readonly ServiceLayerOptions _opts;
    private readonly ILogger<ServiceLayerClient> _log;
    private readonly SemaphoreSlim _loginLock = new(1, 1);
    private DateTime _sessionExpiresAtUtc = DateTime.MinValue;

    public ServiceLayerClient(HttpClient http, IOptions<ServiceLayerOptions> opts, ILogger<ServiceLayerClient> log)
    {
        _http = http;
        _opts = opts.Value;
        _log = log;
    }

    // ---------------- Sessió ----------------

    private async Task EnsureLoggedInAsync(CancellationToken ct)
    {
        // Comparar sumant al present i no restant a _sessionExpiresAtUtc:
        // DateTime.MinValue.AddMinutes(-1) desborda.
        if (_sessionExpiresAtUtc > DateTime.UtcNow.AddMinutes(1)) return;

        await _loginLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_sessionExpiresAtUtc > DateTime.UtcNow.AddMinutes(1)) return;

            _log.LogInformation("Login a Service Layer {BaseUrl} (CompanyDB={Db}, usuari={User})",
                _http.BaseAddress, _opts.CompanyDb, _opts.UserName);

            var payload = new { CompanyDB = _opts.CompanyDb, UserName = _opts.UserName, Password = _opts.Password };
            using var resp = await _http.PostAsJsonAsync("Login", payload, JsonOpts, ct).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                throw new HttpRequestException($"Login a Service Layer ha fallat amb {(int)resp.StatusCode}: {Truncate(body, 500)}");
            }

            // Les cookies B1SESSION i ROUTEID les recull el CookieContainer.
            _sessionExpiresAtUtc = DateTime.UtcNow.AddMinutes(_opts.SessionMinutes);
        }
        finally
        {
            _loginLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_sessionExpiresAtUtc > DateTime.MinValue)
        {
            try { await _http.PostAsync("Logout", content: null).ConfigureAwait(false); }
            catch (Exception ex) { _log.LogWarning(ex, "Logout ha fallat (no és greu)"); }
        }
        _loginLock.Dispose();
    }

    // ---------------- Lectura ----------------

    private async Task<HttpResponseMessage> SendAsync(string url, CancellationToken ct)
    {
        await EnsureLoggedInAsync(ct).ConfigureAwait(false);
        _log.LogDebug("SL GET {Url}", url);

        var resp = await _http.GetAsync(url, ct).ConfigureAwait(false);
        if (resp.StatusCode != HttpStatusCode.Unauthorized) return resp;

        // 401: la sessió pot haver mort abans d'hora. Un relogin i un reintent.
        resp.Dispose();
        _log.LogWarning("SL ha retornat 401; refent el login i reintentant un cop");
        _sessionExpiresAtUtc = DateTime.MinValue;
        await EnsureLoggedInAsync(ct).ConfigureAwait(false);
        return await _http.GetAsync(url, ct).ConfigureAwait(false);
    }

    private async Task<ODataPage<T>> GetPageAsync<T>(string url, CancellationToken ct)
    {
        using var resp = await SendAsync(url, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            _log.LogError("SL GET {Url} ha retornat {Status}. Cos: {Body}", url, (int)resp.StatusCode, Truncate(body, 800));
            resp.EnsureSuccessStatusCode();
        }
        return await resp.Content.ReadFromJsonAsync<ODataPage<T>>(JsonOpts, ct).ConfigureAwait(false)
               ?? new ODataPage<T>();
    }

    /// <summary>
    /// Recorre TOTES les pàgines seguint odata.nextLink. No s'emet mai $top
    /// (Regla 02): la mida de pàgina la marca la capçalera Prefer, que ja va
    /// posada com a default request header al Program.
    /// </summary>
    public async IAsyncEnumerable<T> EnumerateAsync<T>(
        string firstUrl,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        var next = firstUrl;
        var page = 0;
        while (!string.IsNullOrEmpty(next) && !ct.IsCancellationRequested)
        {
            var result = await GetPageAsync<T>(next, ct).ConfigureAwait(false);
            page++;
            foreach (var row in result.Value ?? new List<T>())
                yield return row;

            next = result.ResolveNextLink();
            if (page % 25 == 0)
                _log.LogInformation("... {Pages} pàgines llegides de {Url}", page, firstUrl.Split('?')[0]);
        }
    }

    /// <summary>
    /// Com <see cref="EnumerateAsync{T}"/>, però si la consulta principal falla
    /// amb HTTP 400 cau a una variant alternativa. Serveix per al cas del
    /// $select combinat amb $expand, que segons la build de SL s'accepta o no.
    /// </summary>
    public async IAsyncEnumerable<T> EnumerateWithFallbackAsync<T>(
        string firstUrl,
        string fallbackUrl,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        string urlToUse;
        try
        {
            // Una sola pàgina de prova per saber quina de les dues formes accepta SL.
            await GetPageAsync<T>(firstUrl, ct).ConfigureAwait(false);
            urlToUse = firstUrl;
        }
        catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.BadRequest)
        {
            _log.LogWarning("SL rebutja el $select combinat amb $expand; s'usa la variant sense $select");
            urlToUse = fallbackUrl;
        }

        await foreach (var row in EnumerateAsync<T>(urlToUse, ct).ConfigureAwait(false))
            yield return row;
    }

    /// <summary>Primera pàgina i prou. La sonda de Fase 0 en té prou amb una mostra.</summary>
    public async Task<IReadOnlyList<T>> GetFirstPageAsync<T>(string url, CancellationToken ct)
    {
        var page = await GetPageAsync<T>(url, ct).ConfigureAwait(false);
        return page.Value ?? new List<T>();
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];
}
