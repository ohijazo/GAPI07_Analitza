# Deploy IntercanviSAP via PowerShell (sqlcmd no esta instal.lat en aquest sistema).
# Executa els fitxers .sql en l'ordre correcte, dividint per batches "GO".
#
# AQUESTA LLISTA HA DE COINCIDIR AMB sql\deploy.sql. Son el mateix desplegament
# per dos camins, i el 31/08/2026 havien divergit: aqui faltaven 04_migracions
# (el discount es quedava a decimal(5,2) i formula_break hauria saltat cada nit),
# etl_vw_kais_codes (les tres vistes, sense les quals els cinc SP que hi fan JOIN
# ni tan sols es creen) i el job de SQL Agent. Com que sqlcmd no esta instal.lat,
# qui munti la productiva al novembre fara servir AQUEST fitxer: si tornen a
# divergir, la que quedara mal desplegada es la productiva.
#
# NO inclou schema\01_create_database.sql: fa DROP de les vuit dbo.est_* i es
# creacio inicial, no desplegament. Els canvis d'esquema sobre una BD viva van a
# schema\04_migracions.sql, que si que hi es.
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
    "$Root\schema\02_create_sap_raw.sql",
    "$Root\schema\04_migracions.sql",
    # Les vistes primer: els SP de sota hi fan JOIN i no es crearien.
    "$Root\procs\etl_vw_kais_codes.sql",
    "$Root\procs\etl_sp_assign_client_ship_no.sql",
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
    "$Root\cfg\seed_zone_code_mapping.sql",
    # Abans del job: el seu pas corre com a gapi07_etl i sense l'usuari falla.
    "$Root\security\create_etl_user.sql",
    "$Root\jobs\sqlagent_analitza_etl_daily.sql"
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
