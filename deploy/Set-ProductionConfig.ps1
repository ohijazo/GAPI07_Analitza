<#
    Set-ProductionConfig.ps1 -- escriu appsettings.Production.json al servidor.

    Es llenca PER RDP a la maquina que allotja el Worker. Les contrasenyes es
    demanen interactivament i no surten mai per pantalla, ni per parametre, ni
    per Teams, ni per correu: el fitxer es genera alla on ha de viure.

    Dos modes:

      -FixCompanyDb DB_FARIN_TEST
          Nomes canvia ServiceLayer:CompanyDb del fitxer que ja hi ha i deixa
          la resta intacta. Es el mode que vols si la config ja hi es i el que
          passa es que arrossega el nom d'una companyia que ja no existeix.
          No demana cap contrasenya.

      (sense parametres)
          Crea el fitxer de zero, demanant les dues contrasenyes.

    Sempre fa copia de seguretat del fitxer anterior abans de tocar-lo.

    Per que la cadena de SQL es construeix amb SqlConnectionStringBuilder i no
    concatenant: si la contrasenya porta ';' o '=', concatenar-la trenca la
    cadena i el client ni arriba a preguntar-ho al servidor. El que veus es un
    'Login failed' identic al d'una credencial dolenta. El 16/09/2026 aixo va
    fer creure durant una tarda que una contrasenya estava rotada quan no ho
    estava.
#>
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(ParameterSetName = 'Fix', Mandatory = $true)]
    [string]$FixCompanyDb,

    [Parameter(ParameterSetName = 'Create')]
    [string]$CompanyDb   = 'DB_FARIN_TEST',

    [Parameter(ParameterSetName = 'Create')]
    [string]$BaseUrl     = 'https://192.168.11.238:50000/b1s/v1/',

    [Parameter(ParameterSetName = 'Create')]
    [string]$SapUser     = 'OHijazo',

    [Parameter(ParameterSetName = 'Create')]
    [string]$SqlServer   = 'AE01SAPSQL',

    [Parameter(ParameterSetName = 'Create')]
    [string]$SqlUser     = 'gapi07_worker',

    [string]$AppDir      = 'C:\Apps\SapB1AnalitzaSync',

    # Salta la prova de connexio a SQL. Nomes per si la fas fora de la maquina.
    [switch]$SkipSqlTest
)

$ErrorActionPreference = 'Stop'

$cfgPath = Join-Path $AppDir 'appsettings.Production.json'

function Backup-Config {
    if (-not (Test-Path $cfgPath)) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$cfgPath.$stamp.bak"
    Copy-Item $cfgPath $bak
    Write-Host "Copia de seguretat: $bak" -ForegroundColor Gray
}

function Write-Json {
    param([object]$Obj)
    # UTF-8 sense BOM. Set-Content -Encoding utf8 a PS 5.1 hi posa BOM.
    $json = $Obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($cfgPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Plain {
    param([string]$Prompt)
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not (Test-Path $AppDir)) {
    throw "La carpeta $AppDir no existeix. Demana-la a Sistemes abans de res (veure deploy/README.md)."
}

# ---------------------------------------------------------------------------
# Mode 1: nomes canviar la companyia
# ---------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Fix') {
    if (-not (Test-Path $cfgPath)) {
        throw "No hi ha $cfgPath. Executa l'script sense -FixCompanyDb per crear-lo."
    }

    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $abans = $cfg.ServiceLayer.CompanyDb

    if ($abans -eq $FixCompanyDb) {
        Write-Host "CompanyDb ja val '$FixCompanyDb'. No toco res." -ForegroundColor Green
        return
    }

    Write-Host "CompanyDb: '$abans'  ->  '$FixCompanyDb'" -ForegroundColor Yellow
    Backup-Config
    $cfg.ServiceLayer.CompanyDb = $FixCompanyDb
    Write-Json $cfg

    $rellegit = (Get-Content $cfgPath -Raw | ConvertFrom-Json).ServiceLayer.CompanyDb
    if ($rellegit -eq $FixCompanyDb) {
        Write-Host "Fet. CompanyDb = $rellegit" -ForegroundColor Green
        Write-Host 'La resta del fitxer no s ha tocat (contrasenyes incloses).' -ForegroundColor Gray
    } else {
        throw "He escrit el fitxer pero rellegint-lo diu '$rellegit'. Mira-ho."
    }
    return
}

# ---------------------------------------------------------------------------
# Mode 2: crear-lo de zero
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Creare $cfgPath" -ForegroundColor Cyan
Write-Host "  Service Layer : $BaseUrl" -ForegroundColor Gray
Write-Host "  Companyia     : $CompanyDb" -ForegroundColor Gray
Write-Host "  Usuari SAP    : $SapUser" -ForegroundColor Gray
Write-Host "  SQL           : $SqlServer / IntercanviSAP / $SqlUser" -ForegroundColor Gray
Write-Host ''

if ($CompanyDb -eq 'DB_FARINERA_TEST') {
    Write-Host 'ATURA T: DB_FARINERA_TEST esta OFFLINE des del 22/09/2026.' -ForegroundColor Red
    Write-Host 'La companyia de test ara es DB_FARIN_TEST.' -ForegroundColor Red
    return
}

$sapPwd = Read-Plain "Contrasenya de Service Layer per a $SapUser"
if (-not $sapPwd) { throw 'Contrasenya de SAP buida.' }

$sqlPwd = Read-Plain "Contrasenya de SQL per a $SqlUser"
if (-not $sqlPwd) { throw 'Contrasenya de SQL buida.' }

# Construida, no concatenada: aixi les cometes i els ';' de la contrasenya
# queden escapats com toca.
$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$b['Server']                 = $SqlServer
$b['Database']               = 'IntercanviSAP'
$b['User Id']                = $SqlUser
$b['Password']               = $sqlPwd
$b['Encrypt']                = $false
$b['TrustServerCertificate'] = $true
$connStr = $b.ConnectionString

if (-not $SkipSqlTest) {
    Write-Host ''
    Write-Host 'Provant la connexio a SQL des d aquesta maquina...' -ForegroundColor Cyan
    # Provar-ho abans d escriure el fitxer: una credencial que no s ha provat
    # OBRINT UNA CONNEXIO no esta provada. Aixo valida alhora la contrasenya i
    # que la sortida cap al port 1433 estigui oberta des d aqui.
    $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT SUSER_SNAME() AS qui, DB_NAME() AS bd, @@SERVERNAME AS servidor"
        $r = $cmd.ExecuteReader()
        if ($r.Read()) {
            Write-Host "  OK: connectat com a $($r['qui']) a $($r['bd']) de $($r['servidor'])" -ForegroundColor Green
        }
        $r.Close()
    } catch {
        Write-Host "  FALLA: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host '  18456 = contrasenya dolenta.' -ForegroundColor Yellow
        Write-Host '  916   = la contrasenya es BONA, pero el login te DENY CONNECT a alguna BD.' -ForegroundColor Yellow
        Write-Host '  error de xarxa = falta obrir la sortida cap al port 1433 des d aquesta maquina.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'No escric el fitxer.' -ForegroundColor Red
        return
    } finally { $conn.Close() }
}

$cfg = [ordered]@{
    ServiceLayer = [ordered]@{
        BaseUrl                  = $BaseUrl
        CompanyDb                = $CompanyDb
        UserName                 = $SapUser
        Password                 = $sapPwd
        AllowInvalidCertificates = $true
    }
    Database = [ordered]@{
        ConnectionString = $connStr
    }
}

Backup-Config
Write-Json $cfg

# Rellegir-lo i ensenyar nomes el que no es secret.
$v = Get-Content $cfgPath -Raw | ConvertFrom-Json
Write-Host ''
Write-Host "Escrit: $cfgPath" -ForegroundColor Green
Write-Host "  CompanyDb = $($v.ServiceLayer.CompanyDb)" -ForegroundColor Gray
Write-Host "  BaseUrl   = $($v.ServiceLayer.BaseUrl)" -ForegroundColor Gray
Write-Host "  UserName  = $($v.ServiceLayer.UserName)" -ForegroundColor Gray
Write-Host "  Password  = (informada, $($v.ServiceLayer.Password.Length) caracters)" -ForegroundColor Gray
Write-Host ''
Write-Host 'Seguent pas: comprova l ACL i llenca el Worker a ma.' -ForegroundColor Cyan
Write-Host "  icacls $AppDir" -ForegroundColor Gray
Write-Host "  $AppDir\SapB1AnalitzaSync.Worker.exe --once" -ForegroundColor Gray
Write-Host ''
Write-Host 'Compte: --once llancat amb el teu compte prova la config, NO prova' -ForegroundColor Yellow
Write-Host 'el compte que correra de nit. La prova bona es la tasca.' -ForegroundColor Yellow
