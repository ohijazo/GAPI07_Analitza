# Deploy IntercanviSAP via PowerShell (sqlcmd no esta instal.lat en aquest sistema).
# Executa els fitxers .sql en l'ordre correcte, dividint per batches "GO".
#
# La contrasenya NO va aqui (Regla 03). Passa-la per variable d'entorn:
#     $env:SQLPASS = Read-Host 'Password' -AsSecureString | ConvertFrom-SecureString -AsPlainText
#     .\deploy_via_powershell.ps1
# o deixa -User buit i fes servir autenticacio integrada de Windows.
#
# NO inclou schema\03_create_baseline.sql: la fotografia de referencia es pren
# una sola vegada i a ma. Veure el capcal d'aquell fitxer.

param(
    [string]$Server = 'AE01SAPSQL',
    [string]$User   = 'sa',
    [string]$Root   = 'P:\GAPI07_Analitza\sql'
)

$ErrorActionPreference = 'Stop'

$files = @(
    "$Root\schema\01_create_database.sql",
    "$Root\schema\02_create_sap_raw.sql",
    "$Root\procs\etl_sp_load_product_categories.sql",
    "$Root\procs\etl_sp_load_salesmen.sql",
    "$Root\procs\etl_sp_load_clients.sql",
    "$Root\procs\etl_sp_load_products.sql",
    "$Root\procs\etl_sp_load_invoice_lines.sql",
    "$Root\procs\etl_sp_load_client_attributes.sql",
    "$Root\procs\etl_sp_load_product_attributes.sql",
    "$Root\procs\etl_sp_load_receivables.sql",
    "$Root\procs\etl_sp_data_quality_checks.sql",
    "$Root\procs\etl_sp_swap_staging_to_prod.sql",
    "$Root\procs\etl_sp_run_all.sql",
    "$Root\cfg\seed_country_code_overrides.sql",
    "$Root\cfg\seed_attribute_mapping.sql",
    "$Root\cfg\seed_zone_code_mapping.sql"
)

if ([string]::IsNullOrWhiteSpace($User)) {
    $connStr = "Server=$Server;Integrated Security=True;Encrypt=False;TrustServerCertificate=True;Connection Timeout=15"
} else {
    if ([string]::IsNullOrWhiteSpace($env:SQLPASS)) {
        Write-Host 'Falta $env:SQLPASS (o deixa -User buit per anar amb autenticacio integrada).' -ForegroundColor Red
        exit 2
    }
    $connStr = "Server=$Server;User Id=$User;Password=$($env:SQLPASS);Encrypt=False;TrustServerCertificate=True;Connection Timeout=15"
}

$conn = New-Object System.Data.SqlClient.SqlConnection $connStr
$conn.Open()

foreach ($f in $files) {
    Write-Host "=== $($f.Split('\')[-1]) ===" -ForegroundColor Cyan
    if (-not (Test-Path $f)) { Write-Host "SKIP (missing): $f" -ForegroundColor Yellow; continue }
    $content = Get-Content $f -Raw -Encoding UTF8
    # Divideix per linies que continguin nomes "GO" (case-insensitive, tolera espais i tabuladors)
    $batches = [regex]::Split($content, '(?im)^[ \t]*GO[ \t]*(?:\r?\n|$)')
    $i = 0
    foreach ($batch in $batches) {
        $t = $batch.Trim()
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $i++
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $t
        $cmd.CommandTimeout = 600
        try {
            [void]$cmd.ExecuteNonQuery()
        } catch {
            Write-Host "  BATCH $i FAILED:" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  --- SQL ---" -ForegroundColor DarkGray
            Write-Host $t.Substring(0, [Math]::Min(500, $t.Length)) -ForegroundColor DarkGray
            $conn.Close()
            exit 1
        }
    }
    Write-Host "  OK ($i batches)" -ForegroundColor Green
}
$conn.Close()
Write-Host 'Deploy complete.' -ForegroundColor Green
Write-Host 'Recorda: els SP llegeixen sap_raw. Refresca el mirall abans de correr l ETL:' -ForegroundColor Yellow
Write-Host '  dotnet run --project P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker -- --once' -ForegroundColor Yellow
