using System.Xml.Linq;

namespace SapB1AnalitzaSync.Worker.Services;

// Llista les propietats d'un EntityType del $metadata de Service Layer.
//
// PER QUE EXISTEIX. El 25/08/2026 es va concloure que "Service Layer no exposa
// cap propietat equivalent a DLN1.StockPrice" després d'haver provat DOS
// candidats —StockInmPrice i GrossBuyPrice—, no d'haver llegit la llista. Sobre
// aquella conclusió hi penja el forat B2 (§6.2), que a 08/10/2026 encara és
// l'únic punt obert del contracte amb Analitza. Decidir sobre una llista que
// ningú ha mirat surt car.
//
// Torna a fer falta cada cop que SAP puja de Feature Package (les propietats
// canvien) i quan es crea un UDF, que fins que no es reinicia el servei no hi
// surt (Regla 02).
//
// NO escriu enlloc: és un GET.
internal sealed class MetadataProbeService(ServiceLayerClient sl, ILogger<MetadataProbeService> log)
{
    public async Task<int> RunAsync(string entityType, string? match, CancellationToken ct)
    {
        var xml = await sl.GetRawAsync("$metadata", ct).ConfigureAwait(false);
        var doc = XDocument.Parse(xml);

        // EntityType I ComplexType: a SL v1 (OData v3) les línies d'un document
        // són un ComplexType (`Document_Lines`), no una entitat pròpia. Buscar
        // només entre les entitats és el que fa dir "això no hi és".
        var entities = doc.Descendants()
            .Where(e => e.Name.LocalName is "EntityType" or "ComplexType").ToList();
        var entity = entities.FirstOrDefault(e =>
            string.Equals((string?)e.Attribute("Name"), entityType, StringComparison.OrdinalIgnoreCase));

        if (entity is null)
        {
            var similar = entities.Select(e => (string?)e.Attribute("Name") ?? "")
                                  .Where(n => n.Contains(entityType, StringComparison.OrdinalIgnoreCase))
                                  .Take(20).ToList();
            log.LogError("No hi ha cap EntityType '{Entity}' al $metadata ({Total} de totals). S'hi assemblen: {Similar}",
                         entityType, entities.Count, similar.Count > 0 ? string.Join(", ", similar) : "cap");
            return 2;
        }

        var props = entity.Elements()
            .Where(p => p.Name.LocalName == "Property")
            .Select(p => new { Name = (string?)p.Attribute("Name") ?? "", Type = (string?)p.Attribute("Type") ?? "" })
            .Where(p => match is null || p.Name.Contains(match, StringComparison.OrdinalIgnoreCase))
            .OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var report = new System.Text.StringBuilder();
        report.AppendLine();
        report.AppendLine("=== $metadata: " + entityType + (match is null ? "" : "  (filtre: " + match + ")") + " ===");
        report.AppendLine(props.Count + " propietats");
        foreach (var p in props) report.AppendLine("   " + p.Name.PadRight(32) + p.Type);
        log.LogInformation("{Report}", report.ToString());

        return props.Count > 0 ? 0 : 1;
    }
}
