using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SapB1AnalitzaSync.Shared.Configuration;

namespace SapB1AnalitzaSync.Worker.Services;

/// <summary>
/// Escriptura al mirall <c>sap_raw</c>. Dues operacions i prou:
///
///  - <see cref="ReplaceAllAsync"/> per als mestres: TRUNCATE + BULK INSERT dins
///    d'una transacció. Replica la semàntica que ja tenia l'ETL (una foto
///    sencera cada nit) i evita haver de detectar esborrats.
///
///  - <see cref="ReplaceDocumentsAsync"/> per als documents: esborra els
///    DocEntry del lot i els torna a inserir. Delete+insert en comptes de MERGE
///    perquè una línia esborrada a SAP ha de desaparèixer del mirall, i un
///    MERGE per (DocEntry, LineNum) la deixaria òrfena.
///
/// Les dues són idempotents: rellegir de més per l'overlap del cursor no fa mal.
/// </summary>
internal sealed class MirrorRepository
{
    private readonly DatabaseOptions _opts;
    private readonly ILogger<MirrorRepository> _log;

    public MirrorRepository(IOptions<DatabaseOptions> opts, ILogger<MirrorRepository> log)
    {
        _opts = opts.Value;
        _log = log;
    }

    public SqlConnection CreateConnection() => new(_opts.ConnectionString);

    /// <summary>Substitueix el contingut sencer d'una taula del mirall.</summary>
    public async Task<int> ReplaceAllAsync(string table, DataTable rows, CancellationToken ct)
    {
        await using var conn = CreateConnection();
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct).ConfigureAwait(false);

        try
        {
            await ExecuteAsync(conn, tx, $"TRUNCATE TABLE sap_raw.{table};", ct).ConfigureAwait(false);
            await BulkCopyAsync(conn, tx, $"sap_raw.{table}", rows, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            await tx.RollbackAsync(ct).ConfigureAwait(false);
            throw;
        }

        _log.LogInformation("sap_raw.{Table}: {Rows} files (reemplaçament complet)", table, rows.Rows.Count);
        return rows.Rows.Count;
    }

    /// <summary>
    /// Reescriu un lot de documents i les seves línies. <paramref name="lineTable"/>
    /// pot ser null per als documents que no en porten (factures).
    /// </summary>
    public async Task ReplaceDocumentsAsync(
        string headerTable,
        DataTable headers,
        string? lineTable,
        DataTable? lines,
        IReadOnlyCollection<int> docEntries,
        CancellationToken ct)
    {
        if (docEntries.Count == 0) return;

        await using var conn = CreateConnection();
        await conn.OpenAsync(ct).ConfigureAwait(false);
        await using var tx = (SqlTransaction)await conn.BeginTransactionAsync(ct).ConfigureAwait(false);

        try
        {
            // La llista de DocEntry va per taula temporal i no per un IN (...)
            // gegant: amb lots de centenars, el text de la comanda es dispara i
            // el pla es recompila cada cop.
            await ExecuteAsync(conn, tx, "CREATE TABLE #docs (DocEntry int NOT NULL PRIMARY KEY);", ct).ConfigureAwait(false);

            var keys = new DataTable();
            keys.Columns.Add("DocEntry", typeof(int));
            foreach (var e in docEntries) keys.Rows.Add(e);
            await BulkCopyAsync(conn, tx, "#docs", keys, ct).ConfigureAwait(false);

            if (lineTable is not null)
                await ExecuteAsync(conn, tx,
                    $"DELETE l FROM sap_raw.{lineTable} l JOIN #docs d ON d.DocEntry = l.DocEntry;", ct).ConfigureAwait(false);

            await ExecuteAsync(conn, tx,
                $"DELETE h FROM sap_raw.{headerTable} h JOIN #docs d ON d.DocEntry = h.DocEntry;", ct).ConfigureAwait(false);

            await BulkCopyAsync(conn, tx, $"sap_raw.{headerTable}", headers, ct).ConfigureAwait(false);
            if (lineTable is not null && lines is not null && lines.Rows.Count > 0)
                await BulkCopyAsync(conn, tx, $"sap_raw.{lineTable}", lines, ct).ConfigureAwait(false);

            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            await tx.RollbackAsync(ct).ConfigureAwait(false);
            throw;
        }
    }

    // ---------------- helpers ----------------

    private async Task ExecuteAsync(SqlConnection conn, SqlTransaction tx, string sql, CancellationToken ct)
    {
        await using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        cmd.CommandTimeout = _opts.CommandTimeoutSeconds;
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    private async Task BulkCopyAsync(SqlConnection conn, SqlTransaction tx, string destination, DataTable dt, CancellationToken ct)
    {
        if (dt.Rows.Count == 0) return;

        using var bulk = new SqlBulkCopy(conn, SqlBulkCopyOptions.Default, tx)
        {
            DestinationTableName = destination,
            BulkCopyTimeout = _opts.CommandTimeoutSeconds,
            BatchSize = _opts.BulkBatchSize,
        };
        foreach (DataColumn col in dt.Columns)
            bulk.ColumnMappings.Add(col.ColumnName, col.ColumnName);

        await bulk.WriteToServerAsync(dt, ct).ConfigureAwait(false);
    }
}
