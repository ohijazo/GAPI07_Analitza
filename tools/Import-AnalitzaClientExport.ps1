# Carrega l'exportacio de client_locations que Analitza ens passa a
# cfg.analitza_client_export, que es LA UNICA REFERENCIA valida per comprovar
# que els nostres id_client_location son els que ells tenen.
#
# PER QUE EXISTEIX
# ----------------
# baseline.est_* NO serveix per a aixo i ja ha enganyat tres vegades: es sortida
# del pipeline ANTIC ja apuntat a SAP, o sigui que compara SAP amb SAP i dona un
# fals 100%. dbo.est_* tampoc, que es la nostra propia sortida d'ahir.
#
# L'error que va destapar aixo -el numero d'adreca congelat el 01/09/2026 no era
# el de KAIS, i 804 ubicacions apuntaven a l'adreca equivocada- nomes es veu
# comparant contra el cens de KAIS que Analitza fa servir de debo.
#
# PER QUE NO BULK INSERT
# ----------------------
# El CSV va entre cometes, porta comes dins dels camps
# ("MIQUEL ALIM.GRUP, SA.(PROV.9089)") i cometes dobles escapades
# ("PRODUCTES ""EL DE CALDES, S.A."""), que es justament la dada que va amagar
# el problema. Un parser a mitges donaria un percentatge inventat. Import-Csv
# implementa RFC 4180 i ja esta provat: no n'escrivim un de nou.
#
# PER QUE ES PERSISTEIX A UNA TAULA
# ---------------------------------
# Aixi la comprovacio es una consulta SQL que qualsevol pot repetir, el numero
# deixa de dependre de qui l'ha mesurat, i el runbook del cutover ja preveu
# tornar a demanar l'exportacio la setmana del 27-31 d'octubre de 2026.
#
# Compatible amb PowerShell 5.1 i en ASCII (Regla 05). Demana la contrasenya
# interactivament i no la escriu enlloc.
#
#   .\Import-AnalitzaClientExport.ps1 -Csv ..\docs\client_locations.csv -ExportedAt 2026-08-28
#
# Es IDEMPOTENT: buida la taula i la torna a omplir amb el fitxer que li passes.

param(
    [Parameter(Mandatory = $true)][string]$Csv,
    [Parameter(Mandatory = $true)][string]$ExportedAt,   # AAAA-MM-DD: quan ens el van exportar
    [string]$Server = 'AE01SAPSQL',
    [string]$Database = 'IntercanviSAP',
    [string]$User = 'ohijazo_sql'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Csv)) { Write-Host "No trobo $Csv" -ForegroundColor Red; exit 1 }

$exported = $null
if (-not [DateTime]::TryParseExact($ExportedAt, 'yyyy-MM-dd', $null, 'None', [ref]$exported)) {
    Write-Host "-ExportedAt ha de ser AAAA-MM-DD." -ForegroundColor Red; exit 1
}

function Read-Plain([string]$prompt) {
    $sec = Read-Host $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# La contrasenya NO va interpolada dins de la cadena de connexio: si porta ';',
# '=' o cometes, el client no arriba ni a preguntar-ho al servidor i el que veus
# es un "Login failed" que sembla una credencial dolenta.
$plain = Read-Plain "Contrasenya de $User"
$sec = ConvertTo-SecureString $plain -AsPlainText -Force
$sec.MakeReadOnly()
$cred = New-Object System.Data.SqlClient.SqlCredential($User, $sec)
$conn = New-Object System.Data.SqlClient.SqlConnection(
    "Server=$Server;Database=$Database;Encrypt=False;TrustServerCertificate=True;Connection Timeout=15", $cred)
$conn.Open()

function Invoke-NonQuery([string]$sql) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 300
    [void]$cmd.ExecuteNonQuery()
}

Write-Host ""
Write-Host "Carregant $Csv a $Database.cfg.analitza_client_export" -ForegroundColor Cyan

Invoke-NonQuery @"
IF OBJECT_ID('cfg.analitza_client_export') IS NULL
CREATE TABLE cfg.analitza_client_export (
    id_client_location varchar(13)   NOT NULL CONSTRAINT PK_cfg_analitza_client_export PRIMARY KEY,
    [name]             nvarchar(120) NULL,
    active             varchar(4)    NULL,
    [address]          nvarchar(120) NULL,
    city               nvarchar(120) NULL,
    zip_code           nvarchar(20)  NULL,
    country_code       varchar(8)    NULL,
    salesmen_id        varchar(8)    NULL,
    new_code           varchar(13)   NULL,
    phone_number       nvarchar(60)  NULL,
    email              nvarchar(200) NULL,
    exported_at        date          NOT NULL,
    loaded_at          datetime2(3)  NOT NULL CONSTRAINT DF_cfg_ace_loaded DEFAULT SYSUTCDATETIME()
);
"@

# Columnes mes amples que les nostres est_clients a proposit: aixo es el que
# ELLS tenen, i si arriba mes llarg del que esperem ho volem veure, no truncat.

$rows = Import-Csv -Path $Csv
if ($rows.Count -eq 0) { Write-Host "El CSV no porta files." -ForegroundColor Red; exit 1 }

$needed = @('id_client_location','name','active','address','city','zip_code',
            'country_code','salesmen_id','new_code','phone_number','email')
$have = $rows[0].PSObject.Properties.Name
$missing = $needed | Where-Object { $have -notcontains $_ }
if ($missing) {
    Write-Host ("Falten columnes al CSV: " + ($missing -join ', ')) -ForegroundColor Red
    exit 1
}

Invoke-NonQuery "TRUNCATE TABLE cfg.analitza_client_export;"

$table = New-Object System.Data.DataTable
foreach ($c in $needed) { [void]$table.Columns.Add($c, [string]) }
[void]$table.Columns.Add('exported_at', [datetime])

$dups = @{}
$skipped = 0
foreach ($r in $rows) {
    $id = ("" + $r.id_client_location).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { $skipped++; continue }
    if ($dups.ContainsKey($id)) { $skipped++; continue }   # clau primaria: el primer guanya
    $dups[$id] = $true
    $row = $table.NewRow()
    foreach ($c in $needed) { $row[$c] = ("" + $r.$c) }
    $row['id_client_location'] = $id
    $row['exported_at'] = $exported
    $table.Rows.Add($row)
}

$bulk = New-Object System.Data.SqlClient.SqlBulkCopy($conn)
$bulk.DestinationTableName = 'cfg.analitza_client_export'
foreach ($c in $table.Columns) { [void]$bulk.ColumnMappings.Add($c.ColumnName, $c.ColumnName) }
$bulk.WriteToServer($table)
$bulk.Close()

Write-Host ("Carregades " + $table.Rows.Count + " files (ignorades " + $skipped + ": sense id o duplicades).") -ForegroundColor Green
Write-Host ""
Write-Host "La comprovacio que val es aquesta (ha de donar ~99,2%):" -ForegroundColor Cyan
Write-Host "  sql\verify_ship_no.sql" -ForegroundColor Gray

$conn.Close()
