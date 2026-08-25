namespace SapB1AnalitzaSync.Shared.Configuration;

/// <summary>
/// Connexió a SAP B1 Service Layer. Els valors reals mai van a appsettings.json:
/// a DEV venen de user-secrets, a PRD de variables d'entorn (Regla 03).
/// </summary>
public sealed class ServiceLayerOptions
{
    public const string SectionName = "ServiceLayer";

    public string BaseUrl { get; set; } = string.Empty;

    /// <summary>
    /// Companyia de SAP. AQUESTA és la clau que canvia al cutover de Novembre
    /// 2026 (DB_FARINERA_TEST → DB_FARINERA_PROD). Ja no és cfg.settings.SBO_DB.
    /// </summary>
    public string CompanyDb { get; set; } = string.Empty;

    public string UserName { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;

    public int ConnectTimeoutSeconds { get; set; } = 10;
    public int RequestTimeoutSeconds { get; set; } = 120;

    /// <summary>
    /// Va a la capçalera <c>Prefer: odata.maxpagesize</c>. Sense aquesta
    /// capçalera SL retorna 20 registres per pàgina (el default de b1s.conf) i
    /// la sincronització es fa vuit vegades més lenta. NO és un <c>$top</c>:
    /// es paginen totes les pàgines seguint <c>odata.nextLink</c>.
    /// </summary>
    public int PageSize { get; set; } = 100;

    /// <summary>
    /// Només per a entorns de proves amb certificat autofirmat. A PRD ha de ser
    /// false: si cal posar-ho a true, el problema és el certificat, no el codi.
    /// </summary>
    public bool AllowInvalidCertificates { get; set; }

    /// <summary>Minuts de vida de la sessió abans de renovar-la proactivament (SL en dóna 30).</summary>
    public int SessionMinutes { get; set; } = 29;
}
