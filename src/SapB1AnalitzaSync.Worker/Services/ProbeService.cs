using System.Text;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SapB1AnalitzaSync.Shared.Configuration;
using SapB1AnalitzaSync.Shared.ServiceLayer;

namespace SapB1AnalitzaSync.Worker.Services;

/// <summary>
/// Sonda de la Fase 0. NO escriu res: llegeix una mostra de Service Layer i la
/// contrasta amb la fotografia de referència (<c>baseline.est_*</c>, o
/// <c>dbo.est_*</c> si encara no s'ha pres), que és sortida del pipeline antic.
///
/// Serveix per tancar amb xifres els dos forats que poden invalidar la migració:
///
///   B1 — BPAddress.RowNum és el CRD1.LineNum? id_client_location és el
///        contracte amb Analitza (Regla 04): si no coincideix, cal taula de
///        mapatge i no es pot tirar endavant sense decidir-ho.
///
///   B2 — Quina propietat de SL fa de DLN1.StockPrice (product_cost). SL no
///        exposa StockPrice; es proven els candidats contra el valor real.
///
/// I de passada confirma si PriceBefDi és UnitPrice o Price, cosa que cap check
/// de qualitat detectaria si l'encertem al revés: el net_amount quedaria
/// coherent amb ell mateix però malament.
/// </summary>
internal sealed class ProbeService
{
    private readonly ServiceLayerClient _sl;
    private readonly DatabaseOptions _db;
    private readonly ILogger<ProbeService> _log;

    public ProbeService(ServiceLayerClient sl, IOptions<DatabaseOptions> db, ILogger<ProbeService> log)
    {
        _sl = sl;
        _db = db.Value;
        _log = log;
    }

    public async Task<int> RunAsync(CancellationToken ct)
    {
        var report = new StringBuilder();
        report.AppendLine();
        report.AppendLine("================ SONDA FASE 0 ================");

        await using var conn = new SqlConnection(_db.ConnectionString);
        await conn.OpenAsync(ct).ConfigureAwait(false);

        var schema = await ResolveReferenceSchemaAsync(conn, ct).ConfigureAwait(false);
        if (schema is null)
        {
            _log.LogError("No hi ha ni baseline.est_clients ni dbo.est_clients: sense referència no es pot verificar res.");
            return 2;
        }
        report.AppendLine($"Referència: {schema}.est_*");

        var b1Ok = await ProbeAddressesAsync(conn, schema, report, ct).ConfigureAwait(false);
        var b2Ok = await ProbeDeliveryLinesAsync(conn, schema, report, ct).ConfigureAwait(false);
        await ProbeLegacyCodesAsync(report, ct).ConfigureAwait(false);
        await ReportVolumeAsync(conn, schema, report, ct).ConfigureAwait(false);

        report.AppendLine("==============================================");
        _log.LogInformation("{Report}", report.ToString());

        return b1Ok && b2Ok ? 0 : 1;
    }

    /// <summary>La fotografia si existeix; si no, la taula viva, avisant.</summary>
    private async Task<string?> ResolveReferenceSchemaAsync(SqlConnection conn, CancellationToken ct)
    {
        var hasBaseline = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT CASE WHEN OBJECT_ID('baseline.est_clients') IS NULL THEN 0 ELSE 1 END",
            cancellationToken: ct)).ConfigureAwait(false);
        if (hasBaseline == 1) return "baseline";

        var hasDbo = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT CASE WHEN OBJECT_ID('dbo.est_clients') IS NULL THEN 0 ELSE 1 END",
            cancellationToken: ct)).ConfigureAwait(false);
        if (hasDbo == 1)
        {
            _log.LogWarning("No hi ha fotografia baseline; s'usa dbo.est_*. Executa sql/schema/03_create_baseline.sql abans de la validació de debò.");
            return "dbo";
        }
        return null;
    }

    // ---------------- B1: RowNum vs LineNum ----------------

    private async Task<bool> ProbeAddressesAsync(SqlConnection conn, string schema, StringBuilder report, CancellationToken ct)
    {
        report.AppendLine();
        report.AppendLine("--- B1: BPAddress.RowNum -> id_client_location ---");

        var page = await _sl.GetFirstPageAsync<PartnerRow>(
            ODataQueryBuilder.BuildCustomersWithAddresses(), ct).ConfigureAwait(false);

        if (page.Count == 0)
        {
            report.AppendLine("Service Layer no ha retornat cap client. Res a comparar.");
            return false;
        }

        int checkedRows = 0, matched = 0;
        var misses = new List<string>();

        foreach (var bp in page)
        {
            foreach (var addr in bp.BPAddresses ?? new List<BPAddressRow>())
            {
                if (SapEnums.AddressType(addr.AddressType) != "S") continue;

                var id = $"{bp.CardCode?.TrimEnd()}-{(addr.RowNum ?? 0):000}";
                if (id.Length > 13) id = id[..13];

                var exists = await conn.ExecuteScalarAsync<int>(new CommandDefinition(
                    $"SELECT COUNT(*) FROM {schema}.est_clients WHERE id_client_location = @id",
                    new { id }, cancellationToken: ct)).ConfigureAwait(false);

                checkedRows++;
                if (exists > 0) matched++;
                else if (misses.Count < 10) misses.Add($"{id} (adreça '{addr.AddressName}')");
            }
        }

        if (checkedRows == 0)
        {
            report.AppendLine("Cap adreça de tipus ship-to a la mostra. Amplia la mostra abans de concloure.");
            return false;
        }

        var pct = 100.0 * matched / checkedRows;
        report.AppendLine($"Adreces ship-to comprovades: {checkedRows}");
        report.AppendLine($"Coincidents a {schema}.est_clients: {matched} ({pct:F1}%)");

        if (misses.Count > 0)
        {
            report.AppendLine("Exemples que NO hi són:");
            foreach (var m in misses) report.AppendLine("   " + m);
        }

        if (pct >= 99.9)
        {
            report.AppendLine("VEREDICTE B1: RowNum ES POT fer servir com a LineNum.");
            return true;
        }

        report.AppendLine("VEREDICTE B1: RowNum NO coincideix amb LineNum.");
        report.AppendLine("   Cal la taula de mapatge sap_raw.crd1_linenum_map abans de continuar,");
        report.AppendLine("   o els IDs de client que veu Analitza canviaran (Regla 04).");
        return false;
    }

    // ---------------- B2: cost i preu de línia ----------------

    private async Task<bool> ProbeDeliveryLinesAsync(SqlConnection conn, string schema, StringBuilder report, CancellationToken ct)
    {
        report.AppendLine();
        report.AppendLine("--- B2: preu i cost de línia d'albarà ---");

        // Els albarans més recents són els que segur que hi ha a la referència.
        var docs = await _sl.GetFirstPageAsync<DocumentRow>(
            ODataQueryBuilder.BuildSalesDocuments("DeliveryNotes", DateTime.Today.AddMonths(-3)), ct).ConfigureAwait(false);

        if (docs.Count == 0)
        {
            report.AppendLine("Cap albarà dels últims 3 mesos a Service Layer. Res a comparar.");
            return false;
        }

        int compared = 0;
        int priceUnit = 0, pricePrice = 0, priceDiffer = 0;
        int costStockInm = 0, costGrossBuy = 0, costZero = 0;
        var costMisses = new List<string>();

        foreach (var doc in docs)
        {
            if (doc.DocEntry is null) continue;
            foreach (var line in doc.DocumentLines ?? new List<DocumentLineRow>())
            {
                if (line.LineNum is null || string.IsNullOrEmpty(line.ItemCode)) continue;
                if (SapEnums.LineType(line.LineType) == "T") continue;

                var id = 100000000 + doc.DocEntry.Value * 100 + line.LineNum.Value;
                var reference = await conn.QueryFirstOrDefaultAsync<LineReference>(new CommandDefinition(
                    $@"SELECT product_price AS ProductPrice, product_cost AS ProductCost, discount AS Discount
                       FROM {schema}.est_linies_albara WHERE id_invoice_line = @id",
                    new { id }, cancellationToken: ct)).ConfigureAwait(false);

                if (reference is null) continue;
                compared++;

                if (Near(line.UnitPrice, reference.ProductPrice)) priceUnit++;
                if (Near(line.Price, reference.ProductPrice)) pricePrice++;

                // Nomes les linies on UnitPrice i Price difereixen (les que porten
                // descompte de linia) poden decidir quin dels dos es PriceBefDi.
                if (!NearBoth(line.Price, line.UnitPrice)) priceDiffer++;

                if (Near(line.StockInmPrice, reference.ProductCost)) costStockInm++;
                if (Near(line.GrossBuyPrice, reference.ProductCost)) costGrossBuy++;
                else if (costMisses.Count < 10)
                    costMisses.Add($"id={id} cost_ref={reference.ProductCost:F4} GrossBuyPrice={line.GrossBuyPrice:F4} " +
                                   $"StockInmPrice={line.StockInmPrice:F4} item={line.ItemCode}");
                if (reference.ProductCost == 0m) costZero++;
            }
        }

        if (compared == 0)
        {
            report.AppendLine($"Cap línia de la mostra existeix a {schema}.est_linies_albara.");
            report.AppendLine("   Comprova que la referència està carregada i que la fórmula de");
            report.AppendLine("   id_invoice_line (1e8 + DocEntry*100 + LineNum) segueix vigent.");
            return false;
        }

        report.AppendLine($"Línies comparades: {compared}");
        report.AppendLine($"   product_price == UnitPrice      : {Pct(priceUnit, compared)}");
        report.AppendLine($"   product_price == Price          : {Pct(pricePrice, compared)}");
        report.AppendLine($"   product_cost  == StockInmPrice  : {Pct(costStockInm, compared)}");
        report.AppendLine($"   product_cost  == GrossBuyPrice  : {Pct(costGrossBuy, compared)}");
        report.AppendLine($"   product_cost  == 0 a la referència: {Pct(costZero, compared)}");

        report.AppendLine($"   linies on UnitPrice != Price     : {Pct(priceDiffer, compared)}");

        bool priceOk;
        if (priceDiffer == 0)
        {
            // Sense cap linia amb descompte, UnitPrice i Price son identics i la
            // mostra no pot dir quin dels dos es PriceBefDi. Dir "quadra" aqui
            // seria enganyar-se: el que passa es que no hi ha prova.
            priceOk = false;
            report.AppendLine("VEREDICTE preu: NO CONCLOENT. Cap linia de la mostra porta descompte,");
            report.AppendLine("   aixi que UnitPrice i Price valen el mateix i no es poden distingir.");
            report.AppendLine("   Cal una mostra amb descomptes de linia (o dades reals) per decidir-ho.");
            report.AppendLine("   Mentrestant es queda el default \"UnitPrice\", que es el que diu la DI API.");
        }
        else if (priceUnit > pricePrice)
        {
            priceOk = priceUnit * 100 / compared >= 95;
            report.AppendLine("VEREDICTE preu: Sync:PriceField = \"UnitPrice\" (el default).");
        }
        else if (pricePrice > priceUnit)
        {
            priceOk = false;
            report.AppendLine("VEREDICTE preu: guanya Price -> posa Sync:PriceField = \"Price\".");
        }
        else
        {
            priceOk = false;
            report.AppendLine("VEREDICTE preu: empat amb linies amb descompte pel mig. Mirar-ho a ma.");
        }

        string costVerdict;
        if (costStockInm * 100 / compared >= 95) costVerdict = "Sync:CostField = \"StockInmPrice\"";
        else if (costGrossBuy * 100 / compared >= 95) costVerdict = "Sync:CostField = \"GrossBuyPrice\"";
        else if (costZero * 100 / compared >= 95) costVerdict = "Sync:CostField = \"none\" (la referència ja té el cost a 0)";
        else if (costGrossBuy * 100 / compared >= 80)
            costVerdict = "GrossBuyPrice s hi acosta pero no hi arriba. Mira les discrepancies de sota "
                        + "abans de decidir; si son casos de cost canviat despres de l albara, es esperable.";
        else costVerdict = "cap candidat quadra -> decidir amb Analitza; product_cost és opcional a la seva guia";
        report.AppendLine("VEREDICTE cost: " + costVerdict);

        if (costMisses.Count > 0)
        {
            report.AppendLine("   Linies on GrossBuyPrice NO coincideix:");
            foreach (var m in costMisses) report.AppendLine("      " + m);
        }

        return priceOk;
    }

    // ---------------- Codis heretats de KAIS ----------------

    /// <summary>
    /// Analitza construeix el seu historic sobre els IDs que li arribaven de
    /// KAIS. Al cutover passen a ser els de SAP, i si no coincideixen, l'historic
    /// deixa de lligar. Aixo mira si SAP guarda el codi antic en algun UDF.
    /// No dona un veredicte: dona xifres per contestar l'Adria amb dades.
    /// </summary>
    private async Task ProbeLegacyCodesAsync(StringBuilder report, CancellationToken ct)
    {
        report.AppendLine();
        report.AppendLine("--- Continuitat d'IDs KAIS -> SAP ---");

        var sps = await _sl.GetFirstPageAsync<SalesPersonRow>(
            ODataQueryBuilder.BuildSalesPersonsWithKaisCode(), ct).ConfigureAwait(false);
        var withKais = sps.Where(s => !string.IsNullOrWhiteSpace(s.U_FCCodiKais)).ToList();

        // La comparacio ha de ser contra el id_salesman que emet l'ETL, no
        // contra el SlpCode cru: sp_load_salesmen fa RIGHT('000'+SlpCode,3) i
        // mapeja els negatius a '000'. Comparar '2' amb '006' no vol dir res.
        static string IdSalesman(int? slp) =>
            slp is null || slp < 0 ? "000" : slp.Value.ToString("000");

        var sameCode = withKais.Count(s => s.U_FCCodiKais!.Trim() == IdSalesman(s.SalesEmployeeCode));

        report.AppendLine($"COMERCIALS (SalesPersons): {sps.Count} a la mostra");
        report.AppendLine($"   amb U_FCCodiKais informat : {withKais.Count}");
        report.AppendLine($"   dels quals id_salesman actual == codi KAIS : {sameCode} de {withKais.Count}");
        foreach (var s in withKais.Take(8))
            report.AppendLine($"      SlpCode={s.SalesEmployeeCode} -> id_salesman='{IdSalesman(s.SalesEmployeeCode)}'  " +
                              $"KAIS='{s.U_FCCodiKais}'  {(IdSalesman(s.SalesEmployeeCode) == s.U_FCCodiKais!.Trim() ? "IGUAL" : "DIFEREIX")}  {s.SalesEmployeeName}");

        var bps = await _sl.GetFirstPageAsync<PartnerRow>(
            ODataQueryBuilder.BuildCustomersWithLinkCode(), ct).ConfigureAwait(false);
        var withLink = bps.Where(b => !string.IsNullOrWhiteSpace(b.U_SEICodienllac)).ToList();

        report.AppendLine($"CLIENTS (BusinessPartners): {bps.Count} a la mostra");
        report.AppendLine($"   amb U_SEICodienllac informat : {withLink.Count}");
        foreach (var b in withLink.Take(8))
            report.AppendLine($"      CardCode={b.CardCode}  codienllac='{b.U_SEICodienllac}'  {b.CardName}");
        if (withLink.Count == 0 && bps.Count > 0)
            report.AppendLine($"      (mostra de CardCodes: {string.Join(", ", bps.Take(6).Select(b => b.CardCode))})");

        var groups = await _sl.GetFirstPageAsync<ItemGroupRow>(
            ODataQueryBuilder.BuildItemGroups(), ct).ConfigureAwait(false);
        // El nom del grup sembla portar un codi antic al davant ("010001-BLAT...").
        // Si es aixi, l'id que veu Analitza avui podria ser aquest i no el Number.
        var rx = new System.Text.RegularExpressions.Regex(@"^\d{4,8}-");
        var prefixed = groups.Count(g => g.GroupName is not null && rx.IsMatch(g.GroupName));
        report.AppendLine($"FAMILIES (ItemGroups): {groups.Count} a la mostra");
        report.AppendLine($"   amb el nom en format <codi>-<descripcio> : {prefixed} de {groups.Count}");
        foreach (var g in groups.Take(8))
            report.AppendLine($"      ItmsGrpCod={g.Number}  nom='{g.GroupName}'");

        var items = await _sl.GetFirstPageAsync<ItemRow>(
            ODataQueryBuilder.BuildItems(), ct).ConfigureAwait(false);
        report.AppendLine($"ARTICLES (Items): mostra de codis: {string.Join(", ", items.Take(10).Select(i => i.ItemCode))}");
    }

    private async Task ReportVolumeAsync(SqlConnection conn, string schema, StringBuilder report, CancellationToken ct)
    {
        report.AppendLine();
        report.AppendLine("--- Volum a dimensionar per al backfill ---");

        var v = await conn.QueryFirstOrDefaultAsync<VolumeInfo>(new CommandDefinition(
            $@"SELECT COUNT_BIG(*) AS Lines,
                      MIN([date])  AS MinDate,
                      MAX([date])  AS MaxDate,
                      COUNT(DISTINCT (id_invoice_line / 100)) AS Documents
               FROM {schema}.est_linies_albara",
            commandTimeout: _db.CommandTimeoutSeconds, cancellationToken: ct)).ConfigureAwait(false);

        if (v is null || v.Lines == 0)
        {
            report.AppendLine("Sense línies a la referència.");
            return;
        }

        report.AppendLine($"Línies: {v.Lines:N0}   Documents aprox.: {v.Documents:N0}");
        report.AppendLine($"Rang de dates: {v.MinDate:yyyy-MM-dd} .. {v.MaxDate:yyyy-MM-dd}");
        report.AppendLine("   Aquest és el volum que ha de baixar el backfill inicial per Service Layer.");
    }

    // ---------------- helpers ----------------

    /// <summary>
    /// Un cèntim de tolerància: la referència guarda decimal(16,6) i SL envia
    /// Edm.Double, així que exigir igualtat exacta donaria falsos negatius.
    /// </summary>
    private static bool Near(double? sl, decimal reference) =>
        sl is not null && Math.Abs((decimal)sl.Value - reference) <= 0.01m;

    /// <summary>Compara dos valors de Service Layer entre ells, no contra la referencia.</summary>
    private static bool NearBoth(double? a, double? b) =>
        a is not null && b is not null && Math.Abs(a.Value - b.Value) <= 0.01;

    private static string Pct(int hits, int total) => $"{hits}/{total} ({100.0 * hits / total:F1}%)";

    private sealed class LineReference
    {
        public decimal ProductPrice { get; set; }
        public decimal ProductCost { get; set; }
        public decimal? Discount { get; set; }
    }

    private sealed class VolumeInfo
    {
        public long Lines { get; set; }
        public long Documents { get; set; }
        public DateTime? MinDate { get; set; }
        public DateTime? MaxDate { get; set; }
    }
}
