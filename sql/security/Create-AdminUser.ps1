# Crea un login nominal per a la feina d'administracio de GAPI07, acotat a
# IntercanviSAP, i el deixa configurat als user-secrets del Worker.
#
# PER QUE
# -------
# Fins ara tot el que no era el job anava amb `sa`: els desplegaments, la sonda
# i la cadena de connexio dels user-secrets. La contrasenya de `sa` va quedar
# exposada el 25/08/2026 i s'ha de rotar, pero aquest servidor allotja SAP B1 i
# no es pot verificar qui mes la fa servir. La sortida no es rotar-la a cegues,
# es deixar de necessitar-la: quan aquest login cobreixi el que feiem amb `sa`,
# rotar-la deixa de ser un risc per a nosaltres.
#
# QUE POT I QUE NO POT
# --------------------
#   IntercanviSAP     db_owner            desplegar l'esquema, els SP i els
#                                         seeds, i llegir baseline/dbo per a
#                                         la sonda (--probe)
#   msdb              SQLAgentOperatorRole desplegar i mirar el job. Sense
#                                         aixo, sqlagent_analitza_etl_daily.sql
#                                         falla a mitges i algu tornaria a
#                                         agafar `sa`, que es justament el cami
#                                         de tornada que volem tancar
#   DB_FARINERA_TEST  DENY CONNECT        cap acces a SAP (Regla 01)
#   SBO-COMMON        DENY CONNECT        idem
#
# No es sysadmin, i per tant no pot arribar a les BD de SAP encara que algu hi
# escrigui un SELECT.
#
# PER QUE NOMINAL I NO UN COMPTE TECNIC
# -------------------------------------
# Perque el fa servir una persona, no un proces. Els comptes tecnics
# (gapi07_worker, gapi07_etl) son per al que corre sol i no ha de dependre de
# ningu; aquest es per a la feina manual, i a l'auditoria hi ha de constar qui
# la va fer. Si algun dia entra algu mes al projecte, se li'n fa un altre.
#
# No te fitxer .sql germa com els altres comptes a proposit: no forma part de
# cap desplegament, i necessita una contrasenya que no pot viure al repositori.
#
# Compatible amb PowerShell 5.1. Demana les contrasenyes interactivament i no
# les escriu enlloc excepte, si ho autoritzes, als user-secrets.
#
#   .\Create-AdminUser.ps1
#   .\Create-AdminUser.ps1 -Login algu_altre

param(
    [string]$Server    = 'AE01SAPSQL.Agrienergia.local',
    [string]$Login     = 'ohijazo_sql',
    [string]$AdminUser = 'sa',
    [string]$WorkerProject = 'P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker'
)

$ErrorActionPreference = 'Stop'

function Read-Plain([string]$prompt) {
    $sec = Read-Host $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# La contrasenya NO va interpolada dins de la cadena de connexio.
#
# "Password=$pwd;Encrypt=False" es trenca si la contrasenya porta ';', '=' o
# cometes: el client no arriba ni a preguntar-ho al servidor i el que veus es un
# "Login failed" que sembla una credencial dolenta. Amb SqlCredential la
# contrasenya viatja a part i no passa mai pel parser de la cadena.
function New-SqlConn([string]$server, [string]$db, [string]$user, [string]$plainPwd) {
    $sec = ConvertTo-SecureString $plainPwd -AsPlainText -Force
    $sec.MakeReadOnly()
    $cred = New-Object System.Data.SqlClient.SqlCredential($user, $sec)
    return New-Object System.Data.SqlClient.SqlConnection(
        "Server=$server;Database=$db;Encrypt=False;TrustServerCertificate=True;Connection Timeout=15", $cred)
}

Write-Host ""
Write-Host "Crear el login nominal '$Login' a $Server" -ForegroundColor Cyan
Write-Host ""

$adminPwd = Read-Plain "Contrasenya de $AdminUser (per connectar)"
$newPwd   = Read-Plain "Contrasenya NOVA per a $Login"
$confirm  = Read-Plain "Repeteix-la"

if ($newPwd -ne $confirm) { Write-Host "No coincideixen." -ForegroundColor Red; exit 1 }
if ($newPwd.Length -lt 16) { Write-Host "Massa curta: minim 16 caracters." -ForegroundColor Red; exit 1 }

$conn = New-SqlConn $Server 'master' $AdminUser $adminPwd
$conn.Open()

function Exec([string]$db, [string]$sql) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "USE [$db];" + $sql
    $cmd.CommandTimeout = 120
    [void]$cmd.ExecuteNonQuery()
}

try {
    # La contrasenya va per parametre i no concatenada al text de la comanda:
    # aixi no acaba a cap pla d'execucio ni a cap traca de SQL Server.
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    DECLARE @s nvarchar(max) = N'CREATE LOGIN ' + QUOTENAME(@login)
        + N' WITH PASSWORD = ' + QUOTENAME(@pwd, '''')
        + N', CHECK_POLICY = ON, DEFAULT_DATABASE = IntercanviSAP;';
    EXEC sp_executesql @s;
    SELECT 'creat' AS resultat;
END
ELSE
BEGIN
    DECLARE @a nvarchar(max) = N'ALTER LOGIN ' + QUOTENAME(@login)
        + N' WITH PASSWORD = ' + QUOTENAME(@pwd, '''') + N';';
    EXEC sp_executesql @a;
    SELECT 'ja existia, contrasenya actualitzada' AS resultat;
END
"@
    [void]$cmd.Parameters.AddWithValue('@login', $Login)
    [void]$cmd.Parameters.AddWithValue('@pwd', $newPwd)
    Write-Host ("  Login: {0}" -f $cmd.ExecuteScalar()) -ForegroundColor Green

    Exec 'IntercanviSAP' @"
IF USER_ID('$Login') IS NULL CREATE USER [$Login] FOR LOGIN [$Login];
ALTER ROLE db_owner ADD MEMBER [$Login];
"@
    Write-Host "  IntercanviSAP: db_owner" -ForegroundColor Green

    Exec 'msdb' @"
IF USER_ID('$Login') IS NULL CREATE USER [$Login] FOR LOGIN [$Login];
ALTER ROLE SQLAgentOperatorRole ADD MEMBER [$Login];
"@
    Write-Host "  msdb: SQLAgentOperatorRole" -ForegroundColor Green

    foreach ($db in @('DB_FARINERA_TEST', 'SBO-COMMON')) {
        try {
            Exec $db @"
IF USER_ID('$Login') IS NULL CREATE USER [$Login] FOR LOGIN [$Login];
DENY CONNECT TO [$Login];
"@
            Write-Host "  DENY CONNECT a $db" -ForegroundColor Green
        } catch {
            Write-Host "  $db : no s'ha pogut ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }
}
finally {
    $conn.Close()
    $adminPwd = $null
    [GC]::Collect()
}

# Comprovacio de debo: connectar-s'hi i mirar que veu i que no.
try {
    $t = New-SqlConn $Server 'IntercanviSAP' $Login $newPwd
    $t.Open()
    $c = $t.CreateCommand()
    $c.CommandText = @"
DECLARE @dbo bit = 0, @base bit = 0, @raw bit = 0, @x int;
BEGIN TRY SELECT TOP 1 @x = 1 FROM dbo.est_clients;      SET @dbo  = 1; END TRY BEGIN CATCH END CATCH
BEGIN TRY SELECT TOP 1 @x = 1 FROM baseline.est_clients; SET @base = 1; END TRY BEGIN CATCH END CATCH
BEGIN TRY SELECT TOP 1 @x = 1 FROM sap_raw.OCRD;         SET @raw  = 1; END TRY BEGIN CATCH END CATCH
SELECT CAST(@dbo AS int) AS a, CAST(@base AS int) AS b, CAST(@raw AS int) AS c;
"@
    $rd = $c.ExecuteReader()
    if ($rd.Read()) {
        Write-Host ""
        Write-Host ("  Llegeix dbo.est_*      : {0}" -f $(if($rd.GetInt32(0)){'si'}else{'NO -- malament'}))
        Write-Host ("  Llegeix baseline.est_* : {0}" -f $(if($rd.GetInt32(1)){'si'}else{'no (--probe cauria a dbo)'}))
        Write-Host ("  Llegeix sap_raw        : {0}" -f $(if($rd.GetInt32(2)){'si'}else{'NO -- malament'}))
    }
    $rd.Close(); $t.Close()

    # I el que NO ha de poder fer: entrar a la BD de SAP.
    try {
        $sap = New-Object System.Data.SqlClient.SqlConnection `
            ($connStr -replace 'Database=IntercanviSAP', 'Database=DB_FARINERA_TEST')
        $sap.Open(); $sap.Close()
        Write-Host "  Entra a DB_FARINERA_TEST : SI -- malament, revisa el DENY CONNECT" -ForegroundColor Red
    } catch {
        Write-Host "  Entra a DB_FARINERA_TEST : no (correcte)"
    }

    # Els user-secrets. Nomes afecta el teu entorn de desenvolupament; a
    # AE01SAPRDP la configuracio va a appsettings.Production.json i alla el
    # Worker ha d'anar amb gapi07_worker, no amb aixo.
    Write-Host ""
    $ans = Read-Host "Poso aquesta cadena als user-secrets del Worker? (s/N)"
    if ($ans -eq 's' -or $ans -eq 'S') {
        $id = ([xml](Get-Content (Join-Path $WorkerProject '*.csproj' | Get-Item | Select-Object -First 1))).Project.PropertyGroup.UserSecretsId | Where-Object { $_ }
        $path = Join-Path $env:APPDATA "Microsoft\UserSecrets\$id\secrets.json"
        if (-not (Test-Path $path)) { Write-Host "No trobo $path" -ForegroundColor Red }
        else {
            $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $json.'Database:ConnectionString' = $connStr
            $out = $json | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($path, $out, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "  Fet. Els user-secrets ja no porten sa." -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Apunta la contrasenya al gestor: no es pot recuperar." -ForegroundColor Yellow
}
finally {
    $newPwd = $null; $confirm = $null; $connStr = $null
    [GC]::Collect()
}
