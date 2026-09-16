# Rota la contrasenya del login analitza_ro a AE01SAPSQL.
#
# PER QUE EXISTEIX
# ----------------
# La contrasenya d'analitza_ro es un placeholder desconegut des que es va
# crear: ningu la te apuntada. No es pot lliurar a Analitza una credencial que
# no sabem quina es, i sense lliurar-la la integracio no es pot provar d'extrem
# a extrem. Aixo bloqueja el handoff.
#
# Demana les contrasenyes interactivament i no les escriu enlloc: ni a
# l'historial de la consola, ni en cap fitxer, ni en cap parametre.
# Compatible amb PowerShell 5.1.
#
#   .\Rotate-AnalitzaPassword.ps1
#
# Despres d'executar-lo, apunta la contrasenya nova al gestor de contrasenyes
# i passa-la a Analitza per un canal a part del correu. No es pot recuperar.

# Cal executar-lo amb un administrador del servidor (-AdminUser sa): rotar un
# login es una operacio de servidor i ohijazo_sql, que es el compte del dia a
# dia, no hi arriba a proposit. Es una operacio manual i rara; no val la pena
# obrir-li permisos de servidor per aixo.

param(
    [string]$Server    = 'AE01SAPSQL',
    [string]$Login     = 'analitza_ro',
    [string]$AdminUser = 'sa'
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
Write-Host "Rotar la contrasenya de '$Login' a $Server" -ForegroundColor Cyan
Write-Host ""

$adminPwd = Read-Plain "Contrasenya de $AdminUser (per connectar)"
$newPwd   = Read-Plain "Contrasenya NOVA per a $Login"
$confirm  = Read-Plain "Repeteix-la"

if ($newPwd -ne $confirm) { Write-Host "No coincideixen." -ForegroundColor Red; exit 1 }
if ($newPwd.Length -lt 16) {
    Write-Host "Massa curta: minim 16 caracters. Viatja fora de la xarxa i entra per VPN." -ForegroundColor Red
    exit 1
}

$conn = New-SqlConn $Server 'master' $AdminUser $adminPwd
$conn.Open()

try {
    # El permis PRIMER, i l'existencia despres.
    #
    # sys.sql_logins nomes ensenya els logins sobre els quals tens permisos:
    # un compte sense ALTER ANY LOGIN hi veu el seu i prou. Si es comprova
    # l'existencia abans que el permis, un compte acotat rep
    # "el login no existeix" quan el que passa es que no el pot veure -i
    # llavors va a crear-ne un que ja hi era. El 31/08/2026 va passar,
    # executant-ho amb ohijazo_sql.
    $perm = $conn.CreateCommand()
    $perm.CommandText = "SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY LOGIN');"
    if ([int]$perm.ExecuteScalar() -eq 0) {
        Write-Host ""
        Write-Host "'$AdminUser' no te ALTER ANY LOGIN: canviar la contrasenya d'un login es una" -ForegroundColor Red
        Write-Host "operacio de servidor i aquest compte no en te permisos." -ForegroundColor Red
        Write-Host ""
        Write-Host "Torna-ho a executar amb un administrador del servidor:" -ForegroundColor Yellow
        Write-Host "    .\Rotate-AnalitzaPassword.ps1 -AdminUser sa" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "NO afegeixis ALTER ANY LOGIN a '$AdminUser': permet canviar la contrasenya de" -ForegroundColor Yellow
        Write-Host "qualsevol login, sysadmins inclosos, o sigui que equival a fer-lo sysadmin." -ForegroundColor Yellow
        exit 2
    }

    $exists = $conn.CreateCommand()
    $exists.CommandText = "SELECT COUNT(*) FROM sys.sql_logins WHERE name = @login;"
    [void]$exists.Parameters.AddWithValue('@login', $Login)
    if ([int]$exists.ExecuteScalar() -eq 0) {
        Write-Host "El login '$Login' no existeix. Executa abans create_analitza_user.sql." -ForegroundColor Red
        exit 1
    }

    # La contrasenya va per parametre i no concatenada al text de la comanda:
    # aixi no acaba a cap pla d'execucio ni a cap traca de SQL Server.
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
DECLARE @s nvarchar(max) = N'ALTER LOGIN ' + QUOTENAME(@login)
    + N' WITH PASSWORD = ' + QUOTENAME(@pwd, '''') + N', CHECK_POLICY = ON;';
EXEC sp_executesql @s;
"@
    [void]$cmd.Parameters.AddWithValue('@login', $Login)
    [void]$cmd.Parameters.AddWithValue('@pwd', $newPwd)
    [void]$cmd.ExecuteNonQuery()
    Write-Host "  Contrasenya canviada." -ForegroundColor Green
}
finally {
    $conn.Close()
    $adminPwd = $null
    [GC]::Collect()
}

# Comprovacio de debo: connectar-s'hi amb la contrasenya nova i mirar que veu.
# Lliurar una credencial sense haver-la provat surt una volta sencera de correu.
try {
    $test = New-SqlConn $Server 'IntercanviSAP' $Login $newPwd
    $test.Open()

    $c = $test.CreateCommand()
    $c.CommandText = @"
DECLARE @ok_contracte bit = 0, @sapraw_denegat bit = 1, @x int;
BEGIN TRY SELECT TOP 1 @x = 1 FROM dbo.est_clients; SET @ok_contracte = 1;   END TRY BEGIN CATCH END CATCH
BEGIN TRY SELECT TOP 1 @x = 1 FROM sap_raw.OCRD;    SET @sapraw_denegat = 0; END TRY BEGIN CATCH END CATCH
SELECT CAST(@ok_contracte AS int) AS llegeix_est, CAST(@sapraw_denegat AS int) AS sapraw_denegat;
"@
    $rd = $c.ExecuteReader()
    if ($rd.Read()) {
        $a = $rd.GetInt32(0); $b = $rd.GetInt32(1)
        Write-Host ""
        Write-Host ("  Es connecta i llegeix dbo.est_* : {0}" -f $(if($a){'si'}else{'NO -- malament'}))
        Write-Host ("  sap_raw li es denegat           : {0}" -f $(if($b){'si'}else{'NO -- malament'}))
    }
    $rd.Close()
    $test.Close()

    Write-Host ""
    Write-Host "Fet. Apunta-la al gestor i passa-la a Analitza per un canal a part" -ForegroundColor Yellow
    Write-Host "del correu. No es pot recuperar." -ForegroundColor Yellow
}
finally {
    $newPwd = $null; $confirm = $null
    [GC]::Collect()
}
