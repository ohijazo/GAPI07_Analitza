using System.Data;
using Microsoft.Extensions.Options;
using SapB1AnalitzaSync.Shared.Configuration;
using SapB1AnalitzaSync.Shared.ServiceLayer;

namespace SapB1AnalitzaSync.Worker.Services;

/// <summary>
/// Refresca el mirall <c>sap_raw</c> a partir de Service Layer.
///
/// Dues estratègies, i la diferència no és estètica:
///
///  - MESTRES (clients+adreces, articles, famílies, agents, formes de pagament):
///    cens complet cada cicle. Són poques files i així es replica exactament el
///    que feia l'ETL abans (TRUNCATE + INSERT), sense haver de detectar mai un
///    esborrat.
///
///  - DOCUMENTS (albarans, devolucions, abonaments, factures): incremental per
///    UpdateDate amb overlap. Aquí sí que cal, perquè és l'històric sencer.
///
/// L'ordre importa: primer els mestres, després els documents. Si un document
/// arriba abans que el seu client, els checks de qualitat de l'ETL el veurien
/// com a orfe i bloquejarien el swap.
/// </summary>
internal sealed class MirrorSyncService
{
    private readonly ServiceLayerClient _sl;
    private readonly MirrorRepository _repo;
    private readonly SyncStateStore _state;
    private readonly SyncOptions _sync;
    private readonly ILogger<MirrorSyncService> _log;

    public MirrorSyncService(
        ServiceLayerClient sl,
        MirrorRepository repo,
        SyncStateStore state,
        IOptions<SyncOptions> sync,
        ILogger<MirrorSyncService> log)
    {
        _sl = sl;
        _repo = repo;
        _state = state;
        _sync = sync.Value;
        _log = log;
    }

    public async Task RunOnceAsync(CancellationToken ct)
    {
        var started = DateTime.UtcNow;

        await SyncCustomersAsync(ct).ConfigureAwait(false);
        await SyncItemsAsync(ct).ConfigureAwait(false);
        await SyncItemGroupsAsync(ct).ConfigureAwait(false);
        await SyncSalesPersonsAsync(ct).ConfigureAwait(false);
        await SyncPaymentMethodsAsync(ct).ConfigureAwait(false);

        await SyncSalesDocumentsAsync("DeliveryNotes", "ODLN", "DLN1", ct).ConfigureAwait(false);
        await SyncSalesDocumentsAsync("Returns",       "ORDN", "RDN1", ct).ConfigureAwait(false);
        await SyncSalesDocumentsAsync("CreditNotes",   "ORIN", "RIN1", ct).ConfigureAwait(false);
        await SyncInvoicesAsync(ct).ConfigureAwait(false);

        _log.LogInformation("Cicle complet en {Elapsed:hh\\:mm\\:ss}", DateTime.UtcNow - started);
    }

    // ---------------- Mestres ----------------

    /// <summary>
    /// Clients i adreces alhora: a Service Layer les adreces són una col·lecció
    /// dins del client, no una entitat pròpia. Les dues taules del mirall
    /// s'escriuen del mateix recorregut.
    /// </summary>
    private async Task SyncCustomersAsync(CancellationToken ct)
    {
        var ocrd = MirrorTables.NewOcrd();
        var crd1 = MirrorTables.NewCrd1();
        var seenAddress = new HashSet<(string, int)>();

        await foreach (var bp in _sl.EnumerateWithFallbackAsync<PartnerRow>(
                           ODataQueryBuilder.BuildCustomersWithAddresses(),
                           ODataQueryBuilder.BuildCustomersWithAddressesFallback(), ct).ConfigureAwait(false))
        {
            if (string.IsNullOrEmpty(bp.CardCode)) continue;
            MirrorTables.AddOcrd(ocrd, bp);

            foreach (var addr in bp.BPAddresses ?? new List<BPAddressRow>())
            {
                // La PK del mirall és (CardCode, LineNum). SAP pot donar dues
                // adreces amb el mateix RowNum si una és ship-to i l'altra
                // bill-to; ens quedem la primera i avisem, perquè si passa vol
                // dir que RowNum no serveix com a LineNum (Fase 0, forat B1).
                var key = (bp.CardCode, addr.RowNum ?? 0);
                if (!seenAddress.Add(key))
                {
                    _log.LogWarning("RowNum duplicat a {CardCode}: {RowNum}. Reviseu el forat B1 de la Fase 0.",
                        bp.CardCode, addr.RowNum);
                    continue;
                }
                MirrorTables.AddCrd1(crd1, bp.CardCode, addr);
            }
        }

        await _repo.ReplaceAllAsync("OCRD", ocrd, ct).ConfigureAwait(false);
        await _repo.ReplaceAllAsync("CRD1", crd1, ct).ConfigureAwait(false);
        await _state.SaveAsync("customers", null, ocrd.Rows.Count, fullCensus: true, ct).ConfigureAwait(false);
    }

    private async Task SyncItemsAsync(CancellationToken ct)
    {
        var dt = MirrorTables.NewOitm();
        await foreach (var r in _sl.EnumerateAsync<ItemRow>(ODataQueryBuilder.BuildItems(), ct).ConfigureAwait(false))
            if (!string.IsNullOrEmpty(r.ItemCode)) MirrorTables.AddOitm(dt, r);

        await _repo.ReplaceAllAsync("OITM", dt, ct).ConfigureAwait(false);
        await _state.SaveAsync("items", null, dt.Rows.Count, fullCensus: true, ct).ConfigureAwait(false);
    }

    private async Task SyncItemGroupsAsync(CancellationToken ct)
    {
        var dt = MirrorTables.NewOitb();
        await foreach (var r in _sl.EnumerateAsync<ItemGroupRow>(ODataQueryBuilder.BuildItemGroups(), ct).ConfigureAwait(false))
            if (r.Number is not null) MirrorTables.AddOitb(dt, r);

        await _repo.ReplaceAllAsync("OITB", dt, ct).ConfigureAwait(false);
        await _state.SaveAsync("item_groups", null, dt.Rows.Count, fullCensus: true, ct).ConfigureAwait(false);
    }

    private async Task SyncSalesPersonsAsync(CancellationToken ct)
    {
        var dt = MirrorTables.NewOslp();
        await foreach (var r in _sl.EnumerateAsync<SalesPersonRow>(ODataQueryBuilder.BuildSalesPersons(), ct).ConfigureAwait(false))
            if (r.SalesEmployeeCode is not null) MirrorTables.AddOslp(dt, r);

        await _repo.ReplaceAllAsync("OSLP", dt, ct).ConfigureAwait(false);
        await _state.SaveAsync("sales_persons", null, dt.Rows.Count, fullCensus: true, ct).ConfigureAwait(false);
    }

    private async Task SyncPaymentMethodsAsync(CancellationToken ct)
    {
        var dt = MirrorTables.NewOpym();
        await foreach (var r in _sl.EnumerateAsync<PaymentMethodRow>(ODataQueryBuilder.BuildPaymentMethods(), ct).ConfigureAwait(false))
            if (!string.IsNullOrEmpty(r.PaymentMethodCode)) MirrorTables.AddOpym(dt, r);

        await _repo.ReplaceAllAsync("OPYM", dt, ct).ConfigureAwait(false);
        await _state.SaveAsync("payment_methods", null, dt.Rows.Count, fullCensus: true, ct).ConfigureAwait(false);
    }

    // ---------------- Documents ----------------

    /// <summary>
    /// Cursor per a documents: es resta l'overlap perquè el filtre només pot
    /// mirar UpdateDate i no UpdateTime (Regla 02). Sense cursor, s'arrenca del
    /// BackfillFrom configurat, o de tot l'històric si no n'hi ha.
    /// </summary>
    private async Task<DateTime?> ResolveSinceAsync(string entity, CancellationToken ct)
    {
        // --backfill ha de manar sobre el cursor. Si no, un cop hi ha cursor no
        // hi hauria manera de rellegir l'historic sense esborrar sync_state a ma.
        if (_sync.ForceBackfill) return _sync.BackfillFrom;

        var cursor = await _state.GetCursorAsync(entity, ct).ConfigureAwait(false);
        if (cursor is null) return _sync.BackfillFrom;
        return cursor.Value.Date.AddDays(-_sync.OverlapDays);
    }

    private async Task SyncSalesDocumentsAsync(string entitySet, string headerTable, string lineTable, CancellationToken ct)
    {
        var entity = entitySet.ToLowerInvariant();
        var since = await ResolveSinceAsync(entity, ct).ConfigureAwait(false);
        _log.LogInformation("{Entity}: sincronitzant des de {Since}", entitySet,
            since?.ToString("yyyy-MM-dd") ?? "l'inici de l'històric");

        var headers = MirrorTables.NewSalesHeader();
        var lines = MirrorTables.NewSalesLine();
        var docEntries = new List<int>();
        long total = 0;
        DateTime? maxUpdate = null;

        await foreach (var doc in _sl.EnumerateWithFallbackAsync<DocumentRow>(
                           ODataQueryBuilder.BuildSalesDocuments(entitySet, since),
                           ODataQueryBuilder.BuildSalesDocumentsFallback(entitySet, since), ct).ConfigureAwait(false))
        {
            if (doc.DocEntry is null) continue;

            MirrorTables.AddSalesHeader(headers, doc);
            foreach (var line in doc.DocumentLines ?? new List<DocumentLineRow>())
                MirrorTables.AddSalesLine(lines, doc.DocEntry.Value, line, _sync);

            docEntries.Add(doc.DocEntry.Value);
            if (doc.UpdateDate is not null && (maxUpdate is null || doc.UpdateDate > maxUpdate))
                maxUpdate = doc.UpdateDate;

            if (docEntries.Count >= _sync.DocumentFlushSize)
            {
                total += await FlushSalesAsync(headerTable, headers, lineTable, lines, docEntries, ct).ConfigureAwait(false);
                headers = MirrorTables.NewSalesHeader();
                lines = MirrorTables.NewSalesLine();
                docEntries = new List<int>();
            }
        }

        total += await FlushSalesAsync(headerTable, headers, lineTable, lines, docEntries, ct).ConfigureAwait(false);

        // El cursor només avança si hem vist alguna cosa: si SL no retorna res,
        // deixar-lo com estava és el comportament segur.
        await _state.SaveAsync(entity, maxUpdate, total, fullCensus: false, ct).ConfigureAwait(false);
        _log.LogInformation("{Entity}: {Docs} documents al mirall (cursor -> {Cursor})",
            entitySet, total, maxUpdate?.ToString("yyyy-MM-dd") ?? "sense canvi");
    }

    private async Task<int> FlushSalesAsync(
        string headerTable, DataTable headers, string lineTable, DataTable lines,
        List<int> docEntries, CancellationToken ct)
    {
        if (docEntries.Count == 0) return 0;
        await _repo.ReplaceDocumentsAsync(headerTable, headers, lineTable, lines, docEntries, ct).ConfigureAwait(false);
        return docEntries.Count;
    }

    private async Task SyncInvoicesAsync(CancellationToken ct)
    {
        const string entity = "invoices";
        var since = await ResolveSinceAsync(entity, ct).ConfigureAwait(false);
        _log.LogInformation("Invoices: sincronitzant des de {Since}", since?.ToString("yyyy-MM-dd") ?? "l'inici de l'històric");

        var headers = MirrorTables.NewInvoiceHeader();
        var docEntries = new List<int>();
        long total = 0;
        DateTime? maxUpdate = null;

        await foreach (var doc in _sl.EnumerateAsync<DocumentRow>(ODataQueryBuilder.BuildInvoices(since), ct).ConfigureAwait(false))
        {
            if (doc.DocEntry is null) continue;

            MirrorTables.AddInvoiceHeader(headers, doc);
            docEntries.Add(doc.DocEntry.Value);
            if (doc.UpdateDate is not null && (maxUpdate is null || doc.UpdateDate > maxUpdate))
                maxUpdate = doc.UpdateDate;

            if (docEntries.Count >= _sync.DocumentFlushSize)
            {
                await _repo.ReplaceDocumentsAsync("OINV", headers, null, null, docEntries, ct).ConfigureAwait(false);
                total += docEntries.Count;
                headers = MirrorTables.NewInvoiceHeader();
                docEntries = new List<int>();
            }
        }

        if (docEntries.Count > 0)
        {
            await _repo.ReplaceDocumentsAsync("OINV", headers, null, null, docEntries, ct).ConfigureAwait(false);
            total += docEntries.Count;
        }

        await _state.SaveAsync(entity, maxUpdate, total, fullCensus: false, ct).ConfigureAwait(false);
        _log.LogInformation("Invoices: {Docs} documents al mirall (cursor -> {Cursor})",
            total, maxUpdate?.ToString("yyyy-MM-dd") ?? "sense canvi");
    }
}
