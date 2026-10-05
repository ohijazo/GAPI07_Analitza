<#
    Check-WorkerHost.ps1 -- sonda del servidor que allotja el Worker.

    Es llenca PER RDP a la maquina que ha de refrescar sap_raw (AE02SAPRDP des
    del canvi de servidor del setembre 2026; abans AE01SAPRDP) i contesta d'un
    sol tret les set coses que fan que el cicle nocturn falli en silenci.

    NO escriu res, NO toca SAP i NO imprimeix cap contrasenya: de
    l'appsettings.Production.json en treu nomes CompanyDb, BaseUrl, l'usuari i
    el servidor de SQL. Es pot executar amb un compte normal; el que necessiti
    administrador surt marcat com a NO COMPROVABLE en comptes de petar.

    Us:
        powershell -ExecutionPolicy Bypass -File Check-WorkerHost.ps1
        powershell -ExecutionPolicy Bypass -File Check-WorkerHost.ps1 -ExpectedCompanyDb DB_FARINERA_PROD

    Per que existeix: el 24/09/2026 el job de les 03:00 va avortar dues nits
    seguides amb ABORTED_STALE_MIRROR i no hi havia manera de saber des de fora
    si el problema era la config, la tasca, el tallafocs o el compte. Cap
    d'aquests quatre deixa rastre enlloc: el simptoma des de SQL es sempre el
    mateix, que el mirall es fa vell.
#>
[CmdletBinding()]
param(
    [string]$AppDir             = 'C:\Apps\SapB1AnalitzaSync',
    [string]$ExpectedCompanyDb  = 'DB_FARIN_TEST',
    [string]$SqlHost            = '192.168.11.238',
    [string]$TaskName           = 'GAPI07 Refresca sap_raw',
    [string]$ServiceAccount     = 'AGRIENERGIA\sapsistema'
)

$ErrorActionPreference = 'Continue'

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "=== $Title ===" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Msg)   Write-Host "  OK       $Msg" -ForegroundColor Green }
function Write-Bad     { param([string]$Msg)   Write-Host "  PROBLEMA $Msg" -ForegroundColor Red }
function Write-Warn    { param([string]$Msg)   Write-Host "  AVIS     $Msg" -ForegroundColor Yellow }
function Write-Info    { param([string]$Msg)   Write-Host "           $Msg" -ForegroundColor Gray }

# ---------------------------------------------------------------------------
# 1. Quina maquina i quin compte
# ---------------------------------------------------------------------------
Write-Section '1. Maquina i compte'
$ips = @()
try {
    $ips = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
           ForEach-Object { $_.IPAddress } |
           Where-Object { $_ -and $_ -notmatch ':' }
} catch { }
Write-Info "Maquina  : $env:COMPUTERNAME"
Write-Info "IPv4     : $($ips -join ', ')"
Write-Info "Sessio   : $env:USERDOMAIN\$env:USERNAME"
Write-Info "Data     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') (local)"

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
                   [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
Write-Info "Admin    : $isAdmin"

# ---------------------------------------------------------------------------
# 2. Els binaris
# ---------------------------------------------------------------------------
Write-Section '2. Binaris'
$exe = Join-Path $AppDir 'SapB1AnalitzaSync.Worker.exe'
if (-not (Test-Path $AppDir)) {
    Write-Bad "La carpeta $AppDir NO existeix. El Worker no esta desplegat en aquesta maquina."
} elseif (-not (Test-Path $exe)) {
    Write-Bad "$AppDir existeix pero no hi ha SapB1AnalitzaSync.Worker.exe."
    Get-ChildItem $AppDir -ErrorAction SilentlyContinue |
        Select-Object -First 15 | ForEach-Object { Write-Info "  $($_.Name)" }
} else {
    $f = Get-Item $exe
    Write-Ok "$exe"
    Write-Info "Modificat: $($f.LastWriteTime)   Mida: $([math]::Round($f.Length/1KB)) KB"
    $n = (Get-ChildItem $AppDir -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Info "Fitxers a la carpeta: $n"
}

# ---------------------------------------------------------------------------
# 3. La configuracio -- la causa mes probable, i la que mes enganya
# ---------------------------------------------------------------------------
Write-Section '3. appsettings.Production.json'
$cfgPath = Join-Path $AppDir 'appsettings.Production.json'
if (-not (Test-Path $cfgPath)) {
    Write-Bad "NO hi ha $cfgPath."
    Write-Info 'Sense aquest fitxer el Worker arrenca amb els placeholders i surt amb codi 3.'
} else {
    Write-Ok "$cfgPath   (modificat: $((Get-Item $cfgPath).LastWriteTime))"
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

        $company = $cfg.ServiceLayer.CompanyDb
        Write-Info "ServiceLayer:BaseUrl   = $($cfg.ServiceLayer.BaseUrl)"
        Write-Info "ServiceLayer:UserName  = $($cfg.ServiceLayer.UserName)"
        Write-Info "ServiceLayer:CompanyDb = $company"

        if ([string]::IsNullOrWhiteSpace($company) -or $company -like '*<*') {
            Write-Bad 'CompanyDb buit o amb el placeholder. El Worker surt amb codi 3.'
        } elseif ($company -eq $ExpectedCompanyDb) {
            Write-Ok "CompanyDb coincideix amb l'esperat ($ExpectedCompanyDb)."
        } elseif ($company -eq 'DB_FARINERA_TEST') {
            Write-Bad "CompanyDb = DB_FARINERA_TEST, que esta OFFLINE des del 22/09/2026."
            Write-Info "Ha de dir $ExpectedCompanyDb. El Login respon 'Invalid login credential',"
            Write-Info 'que sembla un problema de contrasenya i no ho es.'
        } else {
            Write-Warn "CompanyDb = $company, i s'esperava $ExpectedCompanyDb. Confirma-ho abans de res."
        }

        if ([string]::IsNullOrWhiteSpace($cfg.ServiceLayer.Password) -or $cfg.ServiceLayer.Password -like '*<*') {
            Write-Bad "ServiceLayer:Password buida o amb placeholder."
        } else {
            Write-Ok 'ServiceLayer:Password informada (no es mostra).'
        }

        # De la cadena de SQL nomes en surt el servidor i l'usuari. Mai la contrasenya.
        $cs = $cfg.Database.ConnectionString
        if ([string]::IsNullOrWhiteSpace($cs) -or $cs -like '*<*') {
            Write-Bad 'Database:ConnectionString buida o amb placeholder.'
        } else {
            $srv = ([regex]::Match($cs, '(?i)\b(?:Server|Data Source)\s*=\s*([^;]+)')).Groups[1].Value
            $usr = ([regex]::Match($cs, '(?i)\b(?:User Id|UID)\s*=\s*([^;]+)')).Groups[1].Value
            Write-Info "Database:Server        = $srv"
            Write-Info "Database:User Id       = $usr"
            if ($usr -and $usr -ne 'gapi07_worker') {
                Write-Warn "El Worker hauria d'anar amb gapi07_worker, no amb $usr."
            }
        }
    } catch {
        Write-Bad "El JSON no es pot llegir: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 4. Permisos de la carpeta
# ---------------------------------------------------------------------------
Write-Section '4. ACL de la carpeta'
if (Test-Path $AppDir) {
    # Sense 2>&1: a PS 5.1 redirigir stderr d'un exe natiu embolcalla cada linia
    # en un ErrorRecord i fa semblar que ha fallat quan ha sortit amb codi 0.
    $acl = (icacls $AppDir) -join "`n"
    Write-Info $acl
    if ($acl -match '\\Users:|\\Everyone:|\bEveryone:') {
        Write-Bad 'Hi apareix Users o Everyone: dins la carpeta hi ha credencials de SAP i de SQL.'
    } else {
        Write-Ok 'Sense Users ni Everyone.'
    }
} else {
    Write-Info 'No aplica: la carpeta no existeix.'
}

# ---------------------------------------------------------------------------
# 5. La tasca programada
# ---------------------------------------------------------------------------
Write-Section '5. Tasca programada'
$task = $null
try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }

if ($task) {
    Write-Ok "Tasca '$TaskName' registrada."
    Write-Info "Estat    : $($task.State)"
    Write-Info "Principal: $($task.Principal.UserId)  (LogonType: $($task.Principal.LogonType))"
    foreach ($a in $task.Actions) { Write-Info "Accio    : $($a.Execute) $($a.Arguments)" }
    foreach ($t in $task.Triggers) { Write-Info "Trigger  : $($t.StartBoundary)  enabled=$($t.Enabled)" }

    if ($task.State -eq 'Disabled') { Write-Bad 'La tasca esta DESACTIVADA: no corre cap nit.' }

    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        $rc   = $info.LastTaskResult
        $hex  = '0x{0:X}' -f $rc
        Write-Info "Ultima execucio : $($info.LastRunTime)"
        Write-Info "Ultim resultat  : $hex ($rc)"
        Write-Info "Propera         : $($info.NextRunTime)"
        if ($rc -eq 0) {
            Write-Ok 'Ultim resultat 0. Compte: un 0 nomes diu que el proces va acabar, no que escrivis res. La prova bona es sap_raw.sync_state.'
        } elseif ($rc -eq 267011) {
            Write-Warn 'La tasca no ha corregut mai.'
        } else {
            Write-Bad "Ultim resultat $hex, diferent de 0."
            Write-Info "0x4 = falta el dret 'Log on as a batch job' per al compte de la tasca."
            Write-Info '0x2 = no troba l executable. 0x3 = la config porta placeholders (guarda del Worker).'
            Write-Info '0x1 = el Worker ha petat: normalment el Login de Service Layer.'
        }
    } catch {
        Write-Warn "No es pot llegir Get-ScheduledTaskInfo: $($_.Exception.Message)"
    }
} else {
    Write-Warn "No he pogut llegir la tasca '$TaskName'."
    Write-Info "Aixo NO vol dir que no existeixi: si la va crear un administrador, el descriptor"
    Write-Info "de seguretat pot no deixar-la veure a un compte normal (passava a AE01SAPRDP)."
    Write-Info 'Provant amb schtasks, que de vegades si que la veu:'
    $out = (schtasks /query /tn "$TaskName" /fo LIST /v) -join "`n"
    Write-Info $out
    Write-Info 'I buscant qualsevol tasca que anomeni el Worker:'
    $all = (schtasks /query /fo LIST) -join "`n"
    $hit = $all -split "`n" | Where-Object { $_ -match 'GAPI07|SapB1Analitza' }
    if ($hit) { $hit | ForEach-Object { Write-Info $_ } } else { Write-Info '  (cap coincidencia visible amb aquest compte)' }
}

# ---------------------------------------------------------------------------
# 6. Xarxa cap a AE01SAPSQL -- canvia amb la maquina, i ningu ho recorda
# ---------------------------------------------------------------------------
Write-Section "6. Sortida cap a $SqlHost"
foreach ($p in @(50000, 1433)) {
    $label = if ($p -eq 50000) { 'Service Layer' } else { 'SQL Server' }
    $ok = $false
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ok = $c.ConnectAsync($SqlHost, $p).Wait(5000)
        $c.Close()
    } catch { }
    if ($ok) { Write-Ok  "${SqlHost}:$p ($label) accessible." }
    else     { Write-Bad "${SqlHost}:$p ($label) NO accessible. La regla de tallafocs anava des de 192.168.11.239; des d'aquesta maquina pot no existir." }
}

# ---------------------------------------------------------------------------
# 7. El dret 'Log on as a batch job'
# ---------------------------------------------------------------------------
Write-Section "7. Dret 'Log on as a batch job' per a $ServiceAccount"
if (-not $isAdmin) {
    Write-Warn "NO COMPROVABLE sense administrador local (secedit /export el demana)."
    Write-Info 'Si la tasca esta registrada i el resultat es 0x4, es aixo.'
    Write-Info 'A AE01SAPRDP estava concedit per directiva LOCAL, no per GPO: en una maquina'
    Write-Info 'nova no hi es, i el simptoma es que la tasca falla cada nit sense soroll.'
} else {
    $tmp = Join-Path $env:TEMP "secpol_$PID.inf"
    secedit /export /cfg $tmp /areas USER_RIGHTS | Out-Null
    $line = Select-String -Path $tmp -Pattern 'SeBatchLogonRight' -ErrorAction SilentlyContinue
    Remove-Item $tmp -ErrorAction SilentlyContinue
    if ($line) {
        Write-Info $line.Line
        try {
            $sid = (New-Object Security.Principal.NTAccount($ServiceAccount)).Translate(
                       [Security.Principal.SecurityIdentifier]).Value
            if ($line.Line -match [regex]::Escape($sid)) { Write-Ok "$ServiceAccount el te concedit." }
            else { Write-Bad "$ServiceAccount NO surt a SeBatchLogonRight. La tasca fallara amb 0x4." }
        } catch {
            Write-Warn "No he pogut resoldre el SID de ${ServiceAccount}: $($_.Exception.Message)"
        }
    } else {
        Write-Warn 'SeBatchLogonRight no surt a l export de directives.'
    }
}

Write-Host ''
Write-Host 'Fet. Res d aixo ha escrit enlloc.' -ForegroundColor Cyan
Write-Host 'Recorda: la prova que compta no es cap d aquestes, es sap_raw.sync_state' -ForegroundColor Cyan
Write-Host 'segellat despres de les 02:45 per la tasca, no per un --once llancat a ma.' -ForegroundColor Cyan
