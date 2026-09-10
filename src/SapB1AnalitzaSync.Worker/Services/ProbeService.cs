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
    private readonly SyncOptions _sync;
    private readonly ILogger<ProbeService> _log;

    public ProbeService(ServiceLayerClient sl, IOptions<DatabaseOptions> db,
                        IOptions<SyncOptions> sync, ILogger<ProbeService> log)
    {
        _sl = sl;
        _db = db.Value;
        _sync = sync.Value;
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
        await ProbeLegacyCodesAsync(conn, schema, report, ct).ConfigureAwait(false);
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
            // Aixo NO diu que l'id de client quadri amb el que te Analitza. La
            // referencia d'aqui es baseline/dbo, que a test ja es sortida del
            // pipeline apuntat a SAP: compara SAP amb SAP. Mesurat contra
            // l'exportacio real d'Analitza el 28/08/2026, el LineNum de SAP
            // nomes encertava el 6% dels clients, perque KAIS numerava les
            // adreces seqüencialment per client. Ho resol etl.vw_client_ship.
            report.AppendLine("   ATENCIO: aixo compara SAP amb SAP. Que el numero d'adreça");
            report.AppendLine("   sigui el que Analitza té a l'historic ho diu la comparacio");
            report.AppendLine("   contra el cens de KAIS, mes avall, no aquest veredicte.");
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
    private async Task ProbeLegacyCodesAsync(SqlConnection conn, string schema, StringBuilder report, CancellationToken ct)
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

        // Un UDF acabat de crear a SAP no apareix a Service Layer fins que se li
        // refresquen les metadades (reinici del servei). Mentrestant, demanar-lo
        // al $select respon 400 "Property ... is invalid". La sonda ho ha de dir,
        // no petar: si peta, qui l'executa no sap si el problema es el camp, la
        // xarxa o les credencials.
        var customersUrl = ODataQueryBuilder.BuildCustomersWithLinkCode();
        var udfsVisibles = true;
        try
        {
            await _sl.GetFirstPageAsync<PartnerRow>(customersUrl, ct).ConfigureAwait(false);
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.BadRequest)
        {
            udfsVisibles = false;
            customersUrl = ODataQueryBuilder.BuildCustomersWithLinkCodeFallback();
        }

        // Cens SENCER, no la primera pagina. La cobertura de U_FCCodiKais es una
        // xifra de la qual depen el cutover: si es mesura sobre una mostra, un
        // 100% no vol dir res i els clients sense codi apareixen a Analitza com
        // a clients nous el dia 2 de novembre. Aixo es la mateixa trampa que la
        // Regla 02 (un $top que sembla el total i no ho es), pero pel cantó del
        // qui llegeix l'informe.
        var bps = new List<PartnerRow>();
        await foreach (var b in _sl.EnumerateAsync<PartnerRow>(customersUrl, ct).ConfigureAwait(false))
            bps.Add(b);

        var bpWithKais = bps.Where(b => !string.IsNullOrWhiteSpace(b.U_FCCodiKais)).ToList();

        report.AppendLine($"CLIENTS (BusinessPartners): {bps.Count} al cens complet");

        if (!udfsVisibles)
        {
            report.AppendLine("   >>> Service Layer NO exposa encara U_FCCodiKais.");
            report.AppendLine("       El camp existeix a SAP pero SL es cacheja les metadades:");
            report.AppendLine("       cal reiniciar el servei Service Layer i tornar a executar la sonda.");
            ReportSuccessorLink(bps, kaisVisible: false, report);
            return;
        }

        // Cobertura de U_FCCodiKais: ha d'arribar al 100% dels clients
        // preexistents abans de l'1 de novembre. Si un es queda buit, el
        // COALESCE cau al CardCode de SAP i Analitza el veu com un client nou.
        report.AppendLine($"   U_FCCodiKais informat    : {Pct(bpWithKais.Count, bps.Count)}");

        if (bpWithKais.Count == 0)
        {
            report.AppendLine("   >>> El camp existeix pero encara no s'ha poblat cap client. Data limit: 1/11/2026.");
        }
        else
        {
            foreach (var b in bpWithKais.Take(3))
                report.AppendLine($"      exemple: CardCode={b.CardCode}  KAIS='{b.U_FCCodiKais}'  {b.CardName}");

            // sp_load_clients emet TOTS els cCustomer, actius i inactius (nomes
            // en canvia el flag "active"). Un client de baixa sense codi tambe
            // arriba a Analitza, i tambe hi arriba com a client nou: la llista
            // de pendents no es pot filtrar per Valid.
            var sensecodi = bps.Where(b => string.IsNullOrWhiteSpace(b.U_FCCodiKais)).ToList();
            if (sensecodi.Count == 0)
            {
                report.AppendLine("   >>> Cobertura 100% al cens complet. Cap client cauria al CardCode de SAP.");
            }
            else
            {
                report.AppendLine($"   >>> PENDENTS: {sensecodi.Count} clients sense U_FCCodiKais. " +
                                  "Cadascun apareixera a Analitza com a client nou.");
                const int maxLlistats = 40;
                foreach (var b in sensecodi.Take(maxLlistats))
                    report.AppendLine($"      CardCode={b.CardCode}  Valid={b.Valid}  {b.CardName}");
                if (sensecodi.Count > maxLlistats)
                    report.AppendLine($"      ... i {sensecodi.Count - maxLlistats} mes no llistats.");
            }

            await CheckKaisCoverageAsync(bpWithKais, report, ct).ConfigureAwait(false);
        }

        ReportSuccessorLink(bps, kaisVisible: true, report);

        var groups = await _sl.GetFirstPageAsync<ItemGroupRow>(
            ODataQueryBuilder.BuildItemGroups(), ct).ConfigureAwait(false);
        // El nom del grup sembla portar un codi antic al davant ("010001-BLAT...").
        // Si es aixi, l'id que veu Analitza avui podria ser aquest i no el Number.
        var rx = new System.Text.RegularExpressions.Regex(@"^\d{4,8}-");
        var prefixed = groups.Count(g => g.GroupName is not null && rx.IsMatch(g.GroupName));
        var grpWithKais = groups.Count(g => !string.IsNullOrWhiteSpace(g.U_FCCodiKais));
        report.AppendLine($"FAMILIES (ItemGroups): {groups.Count} a la mostra");
        report.AppendLine($"   U_FCCodiKais informat : {Pct(grpWithKais, groups.Count)}");
        report.AppendLine($"   amb el nom en format <codi>-<descripcio> : {prefixed} de {groups.Count}");
        foreach (var g in groups.Take(8))
            report.AppendLine($"      ItmsGrpCod={g.Number}  KAIS='{g.U_FCCodiKais}'  nom='{g.GroupName}'");

        var items = new List<ItemRow>();
        await foreach (var i in _sl.EnumerateAsync<ItemRow>(ODataQueryBuilder.BuildItems(), ct).ConfigureAwait(false))
            items.Add(i);
        report.AppendLine($"ARTICLES (Items): {items.Count} al cens complet. " +
                          $"Mostra de codis: {string.Join(", ", items.Take(10).Select(i => i.ItemCode))}");

        // Analitza no fa servir com a "familia" el que SAP en diu ItemGroup: el
        // que tenen a est_families_productes son categories comercials
        // ("TRADICIONALS", "KM0", "ECOLOGIQUES"), no classes de materia primera
        // ("BLAT SUPER FORCA").
        //
        // I son DOS nivells, no un. La seva resposta de l'01/09/2026 ho va
        // destapar: tenen FAMILIA (12 valors) i SUBFAMILIA (20). El que llegim
        // avui es U_SEISubFamCialCat, que pel nom i pels valors es el segon; el
        // primer viu a U_SEIFamCialCat, que existeix al $metadata i no el
        // miravem. Sense saber com estan poblats els dos camps, la pregunta de
        // quina taxonomia va a est_families_productes no es pot contestar:
        // Analitza recomana no passar de ~25 families i SAP en te 110.
        ReportTaxonomy(report, items, "U_SEIFamCialCat", i => i.U_SEIFamCialCat);
        ReportTaxonomy(report, items, "U_SEISubFamCialCat", i => i.U_SEISubFamCialCat);
    }

    /// <summary>
    /// D'on surt el new_code: qui es el successor d'un client que ha canviat de
    /// rao social. Analitza ho fa servir per no comptar el canvi com un client
    /// perdut mes un de guanyat.
    ///
    /// El camp es U_SEICodienllac, de la implantacio. El 25/08/2026 la sonda el
    /// va mirar buscant-hi el codi de KAIS, va veure 10 clients de 500 i el va
    /// descartar per poca cobertura. La lectura era equivocada: no es un pont al
    /// codi antic, es l'enllac al successor, i llavors 10 de 500 es la xifra que
    /// toca perque son els clients que han canviat de rao social.
    ///
    /// Aquest bloc ha de contestar QUE hi ha guardat dins, perque sp_load_clients
    /// hi ha de fer un JOIN i la clau no es evident: si el valor es un codi de
    /// KAIS i el JOIN va contra CardCode, no lliga cap fila, new_code surt NULL
    /// per a tothom i no salta cap validacio.
    ///
    /// La xifra d'autoreferencies es la que protegeix de tornar a llegir malament
    /// el camp: un valor que apunta al propi client no es cap successor.
    /// </summary>
    private static void ReportSuccessorLink(List<PartnerRow> bps, bool kaisVisible, StringBuilder report)
    {
        static string? Net(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

        var ambEnllac = bps.Where(b => Net(b.U_SEICodienllac) is not null).ToList();

        report.AppendLine();
        report.AppendLine("   --- U_SEICodienllac: l'enllac al client successor (new_code) ---");
        report.AppendLine($"   informat : {Pct(ambEnllac.Count, bps.Count)}");
        if (ambEnllac.Count == 0)
        {
            report.AppendLine("   >>> Cap client l'omple: new_code sortiria NULL per a tothom.");
            return;
        }

        var perCardCode = new Dictionary<string, PartnerRow>(StringComparer.OrdinalIgnoreCase);
        var perKais = new Dictionary<string, PartnerRow>(StringComparer.OrdinalIgnoreCase);
        foreach (var b in bps)
        {
            if (Net(b.CardCode) is string cc) perCardCode[cc] = b;
            if (kaisVisible && Net(b.U_FCCodiKais) is string kais) perKais[kais] = b;
        }

        // El camp es text lliure i el valor no ve tal com esta guardat a l'altra
        // banda: la primera mesura (10/09/2026) va donar 0 de 160 resolts, i
        // mirant-ho a ull hi havia C211431 -> '211433' amb el client C211433
        // existint al mateix cens. O sigui que hi falta la 'C', i als codis de
        // KAIS hi poden faltar els zeros de l'esquerra (8 digits).
        //
        // Les normalitzacions es proven aqui i es compten per separat en comptes
        // de triar-ne una a ma: la que guanyi es la clau del JOIN de
        // sp_load_clients, i encertar-la de memoria es com es fabrica un JOIN
        // que no lliga i un new_code buit que no denuncia ningu.
        static string Pad8(string s) => s.Length < 8 && s.All(char.IsDigit) ? s.PadLeft(8, '0') : s;

        var estrategies = new (string Nom, Func<string, PartnerRow?> Resol)[]
        {
            ("CardCode exacte",          v => perCardCode.GetValueOrDefault(v)),
            ("CardCode amb la C davant", v => perCardCode.GetValueOrDefault("C" + v)),
            ("U_FCCodiKais exacte",      v => perKais.GetValueOrDefault(v)),
            ("U_FCCodiKais amb zeros",   v => perKais.GetValueOrDefault(Pad8(v))),
        };

        var encerts = new int[estrategies.Length];
        var autoRef = 0;
        var mostra = new List<string>();
        var noResolts = new List<string>();
        var ambigus = new List<string>();

        foreach (var b in ambEnllac)
        {
            var val = Net(b.U_SEICodienllac)!;
            PartnerRow? desti = null;

            for (var i = 0; i < estrategies.Length; i++)
                if (estrategies[i].Resol(val) is PartnerRow d)
                {
                    encerts[i]++;
                    desti ??= d;

                    // Dues normalitzacions que porten a clients diferents: el
                    // valor no identifica ningu sense dir quina val, i triar-ne
                    // una a l'atzar assigna l'historic a qui no toca.
                    if (!string.Equals(d.CardCode, desti.CardCode, StringComparison.OrdinalIgnoreCase))
                        ambigus.Add($"      CardCode={b.CardCode}  ->  '{val}'  = {desti.CardCode} o {d.CardCode}");
                }

            if (desti is null)
                noResolts.Add($"      CardCode={b.CardCode}  ->  '{val}'  (no existeix)  {b.CardName}");
            else if (string.Equals(desti.CardCode, b.CardCode, StringComparison.OrdinalIgnoreCase))
                autoRef++;

            const int maxMostra = 20;
            if (mostra.Count < maxMostra)
                mostra.Add($"      CardCode={b.CardCode}  ->  '{val}'  " +
                           (desti is null ? "(no resol)" : $"= {desti.CardCode} {desti.CardName}"));
        }

        for (var i = 0; i < estrategies.Length; i++)
        {
            var esKais = estrategies[i].Nom.StartsWith("U_FCCodiKais", StringComparison.Ordinal);
            report.AppendLine($"   resolen per {estrategies[i].Nom,-24} : " +
                              (esKais && !kaisVisible ? "n/d (SL no exposa el camp)" : encerts[i].ToString()));
        }
        report.AppendLine($"   no resolen enlloc                     : {noResolts.Count}");
        report.AppendLine($"   apunten al propi client               : {autoRef}");

        var millor = Array.IndexOf(encerts, encerts.Max());
        if (encerts[millor] == 0)
            report.AppendLine("   >>> Cap valor resol amb cap normalitzacio. Parar i mirar que hi ha guardat.");
        else if (autoRef * 2 > encerts.Sum())
            report.AppendLine("   >>> La majoria s'autoapunten: NO es l'enllac al successor, es el codi del propi client.");
        else
            report.AppendLine($"   >>> sp_load_clients ha de resoldre el successor per {estrategies[millor].Nom}.");

        if (ambigus.Count > 0)
        {
            report.AppendLine($"   >>> {ambigus.Count} valors resolen a DOS clients diferents segons la normalitzacio:");
            foreach (var x in ambigus.Take(10)) report.AppendLine(x);
        }

        ReportSuccessorDirection(ambEnllac, v => estrategies[millor].Resol(v), report);

        foreach (var l in mostra) report.AppendLine(l);
        if (mostra.Count < ambEnllac.Count)
            report.AppendLine($"      ... i {ambEnllac.Count - mostra.Count} mes no llistats.");

        // Cadascun d'aquests es un canvi de rao social que Analitza comptara com
        // un client perdut i un de nou.
        if (noResolts.Count > 0)
        {
            const int max = 25;
            report.AppendLine($"   >>> {noResolts.Count} enllacos que no apunten a cap client de SAP:");
            foreach (var x in noResolts.Take(max)) report.AppendLine(x);
            if (noResolts.Count > max) report.AppendLine($"      ... i {noResolts.Count - max} mes no llistats.");
        }
    }

    /// <summary>
    /// En quina direccio apunta l'enllac. new_code ha de ser el codi NOU: si el
    /// camp guarda el client d'on ve i no cap on va, emetre'l tal qual lliga
    /// l'historic al reves i Analitza acumula les vendes al registre mort.
    ///
    /// El nom del camp ("codi enllac") no ho diu i la cobertura tampoc. El que
    /// ho diu es quin dels dos extrems esta de baixa: d'un canvi de rao social
    /// en queda un registre viu i un de mort, i el viu es sempre el nou.
    /// </summary>
    private static void ReportSuccessorDirection(
        List<PartnerRow> ambEnllac, Func<string, PartnerRow?> resol, StringBuilder report)
    {
        static bool Actiu(PartnerRow p) => p.Valid == "tYES";

        int viuAMort = 0, mortAViu = 0, viuAViu = 0, mortAMort = 0;
        foreach (var b in ambEnllac)
        {
            var desti = resol(b.U_SEICodienllac!.Trim());
            if (desti is null) continue;
            if (Actiu(b) && !Actiu(desti)) viuAMort++;
            else if (!Actiu(b) && Actiu(desti)) mortAViu++;
            else if (Actiu(b)) viuAViu++;
            else mortAMort++;
        }

        report.AppendLine($"   direccio: viu -> de baixa : {viuAMort}   (el camp guarda el PREDECESSOR)");
        report.AppendLine($"   direccio: de baixa -> viu : {mortAViu}   (el camp guarda el SUCCESSOR)");
        report.AppendLine($"   tots dos vius : {viuAViu}   tots dos de baixa : {mortAMort}");

        if (viuAMort > mortAViu)
            report.AppendLine("   >>> Apunta ENRERE. new_code demana el codi nou: emetre'l tal qual el posaria del reves.");
        else if (mortAViu > viuAMort)
            report.AppendLine("   >>> Apunta ENDAVANT: es el successor i va directe a new_code.");
        else
            report.AppendLine("   >>> Direccio no concloent. No es pot cablejar cap dels dos sentits sense mirar-ho a ma.");

        // Si apunta enrere, sp_load_clients ha d'INVERTIR la relacio: el new_code
        // d'un client es el codi de qui l'apunta a ell. Invertir una relacio que
        // no es 1:1 multiplica files, i a est_clients una fila de mes vol dir un
        // id_client_location duplicat.
        var successorsPer = ambEnllac
            .Select(b => (Successor: b, Predecessor: resol(b.U_SEICodienllac!.Trim())))
            .Where(x => x.Predecessor is not null)
            .GroupBy(x => x.Predecessor!.CardCode ?? "", StringComparer.OrdinalIgnoreCase)
            .ToList();

        var multiples = successorsPer.Where(g => g.Count() > 1).ToList();
        var codisAmbEnllac = new HashSet<string>(ambEnllac.Select(b => b.CardCode ?? ""), StringComparer.OrdinalIgnoreCase);
        var cadenes = successorsPer.Count(g => codisAmbEnllac.Contains(g.Key));

        report.AppendLine($"   predecessors diferents apuntats : {successorsPer.Count}");
        report.AppendLine($"   amb MES D'UN successor          : {multiples.Count}");
        report.AppendLine($"   cadenes (el predecessor en te un altre al darrere) : {cadenes}");

        foreach (var g in multiples.Take(10))
            report.AppendLine($"      {g.Key} <- {string.Join(", ", g.Select(x => x.Successor.CardCode))}");

        if (multiples.Count > 0)
            report.AppendLine("   >>> La inversio NO es 1:1: cal triar-ne un de sol o est_clients duplica files.");
    }

    /// <summary>
    /// Quants valors diferents te un camp de classificacio i quants articles es
    /// queden sense.
    ///
    /// Ho dona dues vegades: sobre el cens sencer i sobre els articles ACTIUS.
    /// La segona xifra es la que decideix, perque el cens porta anys d'articles
    /// donats de baixa que ningu tornara a classificar i que a Analitza ni hi
    /// arriben (la seva SQL n'exclou centenars a ma). Un "87% sense familia"
    /// sobre el cens sencer fa descartar una opcio que potser esta be.
    ///
    /// Tambe avisa dels valors que nomes es diferencien per espais o
    /// majuscules: a SAP son text lliure, i 'KM0' i 'KM 0' hi conviuen sense
    /// que res es queixi. A Analitza serien dues families, una amb un article.
    /// </summary>
    private static void ReportTaxonomy(
        StringBuilder report, List<ItemRow> items, string field, Func<ItemRow, string?> pick)
    {
        static List<IGrouping<string, ItemRow>> Group(IEnumerable<ItemRow> src, Func<ItemRow, string?> p) =>
            src.GroupBy(i => (p(i) ?? "").Trim()).OrderByDescending(g => g.Count()).ToList();

        var actius = items.Where(i => i.Valid == "tYES" && i.Frozen != "tYES").ToList();
        var groups = Group(items, pick);
        var groupsActius = Group(actius, pick);

        static int Buits(List<IGrouping<string, ItemRow>> g) =>
            g.FirstOrDefault(x => x.Key.Length == 0)?.Count() ?? 0;

        report.AppendLine($"   {field}: {groups.Count(g => g.Key.Length > 0)} valors diferents");
        report.AppendLine($"      sense classificar, cens sencer : {Buits(groups)} de {items.Count}");
        report.AppendLine($"      sense classificar, nomes ACTIUS: {Buits(groupsActius)} de {actius.Count}");

        // Text lliure: dos valors que nomes difereixen en espais o majuscules
        // son la mateixa cosa per a qui els va escriure i dues families per a
        // Analitza. Val mes veure-ho aqui que a la seva aplicacio.
        var collisions = groups.Where(g => g.Key.Length > 0)
            .GroupBy(g => g.Key.Replace(" ", "").ToUpperInvariant())
            .Where(c => c.Count() > 1)
            .ToList();
        foreach (var c in collisions)
            report.AppendLine($"      >>> valors que son el mateix amb un espai o una majuscula pel mig: " +
                              string.Join(" / ", c.Select(g => $"'{g.Key}' ({g.Count()})")));

        foreach (var g in groups.Where(g => g.Key.Length > 0))
            report.AppendLine($"      '{g.Key}'  ({g.Count()} articles, {g.Count(i => i.Valid == "tYES" && i.Frozen != "tYES")} actius)");
    }

    /// <summary>
    /// "Quants camps estan plens" no es la pregunta. La pregunta es quants dels
    /// clients que Analitza té AVUI segueixen existint demà amb el mateix id.
    /// Un U_FCCodiKais ple pero amb un codi que no es de KAIS compta com a ple i
    /// trenca l'historic igual; i dos clients de SAP amb el mateix codi fusionen
    /// dos clients d'Analitza en un.
    ///
    /// La referencia NO pot ser baseline.est_clients: a l'entorn de test la
    /// fotografia es va prendre amb el pipeline antic ja apuntat a SAP, i per
    /// tant ja porta CardCodes. L'unic cens de KAIS que existeix es l'exportacio
    /// que ens passa Analitza (client_locations.csv). Cal tornar-la a demanar
    /// abans del tall: els clients donats d'alta entremig no hi son.
    /// </summary>
    private async Task CheckKaisCoverageAsync(
        List<PartnerRow> bpWithKais, StringBuilder report, CancellationToken ct)
    {
        var path = _sync.KaisClientExportPath;
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            report.AppendLine($"   --- Encaix amb el cens de KAIS: OMES (no hi ha '{path}') ---");
            return;
        }

        // El codi de client es el tros de id_client_location anterior al guio:
        // "00201021-000" -> "00201021". Els ship-to no son clients diferents.
        var kaisCodes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var linies = 0;
        foreach (var line in await File.ReadAllLinesAsync(path, ct).ConfigureAwait(false))
        {
            if (linies++ == 0) continue;
            var first = line.Split(',')[0].Trim('"', ' ');
            var dash = first.IndexOf('-');
            if (dash > 0) kaisCodes.Add(first[..dash]);
        }

        var sapCodes = bpWithKais
            .GroupBy(b => b.U_FCCodiKais!.Trim(), StringComparer.OrdinalIgnoreCase)
            .ToList();

        report.AppendLine($"   --- Encaix amb el cens de KAIS ({kaisCodes.Count} clients que Analitza té avui) ---");

        var orfes = kaisCodes.Where(k => !sapCodes.Any(g => string.Equals(g.Key, k, StringComparison.OrdinalIgnoreCase)))
                             .OrderBy(k => k, StringComparer.Ordinal).ToList();
        var desconeguts = sapCodes.Where(g => !kaisCodes.Contains(g.Key)).ToList();
        var duplicats = sapCodes.Where(g => g.Count() > 1).ToList();

        report.AppendLine($"   codis de KAIS amb client a SAP     : {Pct(kaisCodes.Count - orfes.Count, kaisCodes.Count)}");
        report.AppendLine($"   codis a SAP que no son de cap KAIS : {desconeguts.Count}");
        report.AppendLine($"   codis de KAIS repetits a SAP       : {duplicats.Count}");

        // Un client de KAIS sense cap client de SAP que en porti el codi
        // desapareix de la sortida. Analitza no veu un error: veu un client que
        // ha deixat de comprar, i se n'endu l'historic (Regla 04).
        Llista("clients d'Analitza que es perdrien (cap client de SAP porta el seu codi)",
               orfes.Select(k => $"      KAIS={k}"));
        Llista("codis a U_FCCodiKais que no existeixen a KAIS (typo? codi inventat?)",
               desconeguts.Select(g => $"      KAIS='{g.Key}' -> {string.Join(", ", g.Select(b => b.CardCode))}"));
        // Dos CardCode amb el mateix codi de KAIS fusionen dos clients
        // d'Analitza en un de sol, i les vendes d'un s'atribueixen a l'altre.
        Llista("codis de KAIS duplicats (fusionarien dos clients d'Analitza en un)",
               duplicats.Select(g => $"      KAIS='{g.Key}' -> {string.Join(", ", g.Select(b => b.CardCode))}"));

        void Llista(string titol, IEnumerable<string> linies)
        {
            const int max = 25;
            var l = linies.ToList();
            if (l.Count == 0) return;
            report.AppendLine($"   >>> {l.Count} {titol}:");
            foreach (var x in l.Take(max)) report.AppendLine(x);
            if (l.Count > max) report.AppendLine($"      ... i {l.Count - max} mes no llistats.");
        }
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

    /// <summary>
    /// Amb un decimal, 4689 de 4691 s'arrodoneix a "100,0%" i qui llegeix
    /// l'informe dona la cobertura per tancada quan encara hi ha dos clients
    /// que arribarien a Analitza com a clients nous. Mentre en falti un, no es
    /// pot escriure 100%.
    /// </summary>
    private static string Pct(int hits, int total)
    {
        if (total == 0) return "0/0 (n/a)";
        var pct = 100.0 * hits / total;
        var text = hits < total && pct >= 99.95 ? "<" + 100.0.ToString("F1") : pct.ToString("F1");
        return $"{hits}/{total} ({text}%)";
    }

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
