using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using SapB1AnalitzaSync.Shared.Configuration;

namespace SapB1AnalitzaSync.Worker.Services;

/// <summary>
/// Cursor de sincronització per entitat, persistit a <c>sap_raw.sync_state</c>.
/// Cal que sobrevisqui a reinicis: sense ell, cada arrencada tornaria a baixar
/// tot l'històric de documents.
/// </summary>
internal sealed class SyncStateStore
{
    private readonly DatabaseOptions _opts;

    public SyncStateStore(IOptions<DatabaseOptions> opts) => _opts = opts.Value;

    public async Task<DateTime?> GetCursorAsync(string entity, CancellationToken ct)
    {
        const string sql = "SELECT last_update_date FROM sap_raw.sync_state WHERE entity = @entity;";
        await using var conn = new SqlConnection(_opts.ConnectionString);
        return await conn.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
            sql, new { entity }, commandTimeout: _opts.CommandTimeoutSeconds, cancellationToken: ct)).ConfigureAwait(false);
    }

    public async Task SaveAsync(string entity, DateTime? lastUpdateDate, long rows, bool fullCensus, CancellationToken ct)
    {
        const string sql = @"
MERGE sap_raw.sync_state AS tgt
USING (SELECT @entity AS entity) AS src ON tgt.entity = src.entity
WHEN MATCHED THEN UPDATE SET
    last_update_date = COALESCE(@lastUpdateDate, tgt.last_update_date),
    last_full_at     = CASE WHEN @fullCensus = 1 THEN SYSUTCDATETIME() ELSE tgt.last_full_at END,
    last_rows        = @rows,
    updated_at       = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (entity, last_update_date, last_full_at, last_rows)
    VALUES (@entity, @lastUpdateDate, CASE WHEN @fullCensus = 1 THEN SYSUTCDATETIME() ELSE NULL END, @rows);";

        await using var conn = new SqlConnection(_opts.ConnectionString);
        await conn.ExecuteAsync(new CommandDefinition(
            sql,
            new { entity, lastUpdateDate, rows, fullCensus },
            commandTimeout: _opts.CommandTimeoutSeconds,
            cancellationToken: ct)).ConfigureAwait(false);
    }
}
