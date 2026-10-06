namespace SapB1AnalitzaSync.Shared.Logging;

/// <summary>
/// Noms, format i retenció del log de fitxer del Worker. Viu a Shared, i no al
/// Worker, perquè és lògica pura i així té tests (Regla 05).
/// </summary>
public static class FileLogPolicy
{
    public const string Prefix = "worker-";
    public const string Extension = ".log";

    private const string DayFormat = "yyyyMMdd";

    public static string FileName(DateOnly day) => Prefix + day.ToString(DayFormat) + Extension;

    public static bool TryParseDay(string fileName, out DateOnly day)
    {
        day = default;

        var name = Path.GetFileName(fileName);
        if (!name.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase)) return false;
        if (!name.EndsWith(Extension, StringComparison.OrdinalIgnoreCase)) return false;

        var stamp = name.Substring(Prefix.Length, name.Length - Prefix.Length - Extension.Length);
        return DateOnly.TryParseExact(stamp, DayFormat, out day);
    }

    /// <summary>
    /// Els fitxers que ja es poden esborrar, conservant <paramref name="retentionDays"/>
    /// dies comptant el d'avui.
    /// </summary>
    /// <remarks>
    /// Dues decisions deliberades, perquè això esborra fitxers en una màquina que
    /// no és nostra:
    /// <list type="bullet">
    /// <item>Un nom que no segueix el patró no es toca mai: només esborrem el que
    /// hem escrit nosaltres.</item>
    /// <item><c>retentionDays &lt;= 0</c> no esborra res, en comptes d'esborrar-ho
    /// tot. Un zero per badada a la configuració no ha de buidar la carpeta.</item>
    /// </list>
    /// Un fitxer amb data futura —rellotge tocat— tampoc s'esborra.
    /// </remarks>
    public static IReadOnlyList<string> FilesToPurge(
        IEnumerable<string> fileNames, DateOnly today, int retentionDays)
    {
        if (retentionDays <= 0) return Array.Empty<string>();

        var purge = new List<string>();
        foreach (var fileName in fileNames)
        {
            if (!TryParseDay(fileName, out var day)) continue;
            if (today.DayNumber - day.DayNumber >= retentionDays) purge.Add(fileName);
        }
        return purge;
    }

    /// <summary>
    /// Una línia de log. El segell va en <b>UTC</b> i amb la Z al davant dels
    /// camps, perquè la referència amb què es compara és
    /// <c>sap_raw.sync_state.updated_at</c>, que també és UTC.
    /// </summary>
    public static string FormatLine(DateTime utc, string level, string category, string message)
        => string.Concat(
            utc.ToString("yyyy-MM-dd HH:mm:ss"), "Z ",
            level.PadRight(3), " ",
            ShortCategory(category), " ",
            message);

    /// <summary>
    /// Només l'últim tram del nom de la categoria: amb el complet
    /// (<c>SapB1AnalitzaSync.Worker.Services.ServiceLayerClient</c>) el missatge
    /// queda tan a la dreta que el log deixa de ser llegible d'una passada.
    /// </summary>
    public static string ShortCategory(string category)
    {
        if (string.IsNullOrEmpty(category)) return "-";
        var dot = category.LastIndexOf('.');
        return dot < 0 || dot == category.Length - 1 ? category : category[(dot + 1)..];
    }
}
