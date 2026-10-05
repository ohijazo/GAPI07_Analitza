# Crea -o reajusta- el login gapi07_worker a AE01SAPSQL.
#
# Es IDEMPOTENT: si el login ja existeix no se salta res. Li torna a aplicar la
# contrasenya que escriguis, DEFAULT_DATABASE = IntercanviSAP i els permisos.
# Abans sortia per "ja existia" sense tocar res mes, i un login mal configurat
# es quedava mal configurat per sempre (Regla 05: tot script de sql/ ha de ser
# idempotent).
#
# Demana les contrasenyes interactivament i no les escriu enlloc: ni a
# l'historial de la consola, ni en cap fitxer, ni en cap parametre.
# Compatible amb PowerShell 5.1.
#
#   .\Create-WorkerUser.ps1
#
# Despres d'executar-lo, apunta la contrasenya del worker al gestor de
# contrasenyes: la necessitaras per a l'appsettings.json de AE02SAPRDP i no hi
# ha manera de recuperar-la.
#
# AVIS: com que reaplica la contrasenya sempre, si el Worker ja esta desplegat
# cal actualitzar-li l'appsettings.Production.json despres d'executar-lo.

param(
    [string]$Server   = 'AE01SAPSQL',
    [string]$Login    = 'gapi07_worker',
    [string]$AdminUser = 'sa'
)

$ErrorActionPreference = 'Stop'

# Les BD de SAP d'aquest servidor: aqui nomes hi entrem per denegar-hi CONNECT.
# DB_FARIN_TEST es la companyia de test des del 22/09/2026; DB_FARINERA_TEST es
# la d'abans, que el 22/09/2026 ja estava OFFLINE. DB_FARINERA (sense sufix) es
# una altra BD de SAP d'aquest servidor, ONLINE. Cap d'elles s'ha de poder
# obrir des d'aqui; el try/catch de sota tolera que no hi siguin o siguin
# OFFLINE.
$SapDatabases = @('DB_FARIN_TEST', 'DB_FARINERA', 'DB_FARINERA_TEST')

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
Write-Host "Crear o reajustar el login '$Login' a $Server" -ForegroundColor Cyan
Write-Host ""

$adminPwd = Read-Plain "Contrasenya de $AdminUser (per connectar)"
$newPwd   = Read-Plain "Contrasenya NOVA per a $Login"
$confirm  = Read-Plain "Repeteix-la"

if ($newPwd -ne $confirm) { Write-Host "No coincideixen." -ForegroundColor Red; exit 1 }
if ($newPwd.Length -lt 16) {
    Write-Host "Massa curta: minim 16 caracters. Viura en un fitxer de configuracio d'una maquina compartida." -ForegroundColor Red
    exit 1
}

$conn = New-SqlConn $Server 'master' $AdminUser $adminPwd
$conn.Open()

function Exec([string]$db, [string]$sql, [hashtable]$params = @{}) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "USE [$db];" + $sql
    foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $params[$k]) }
    $cmd.CommandTimeout = 120
    [void]$cmd.ExecuteNonQuery()
}

try {
    # Crear-lo si no hi es, i en tots dos casos deixar-lo amb la contrasenya i la
    # base de dades per defecte que toquen.
    #
    # Abans aixo era un IF NOT EXISTS que sortia per 'ja existia' i no aplicava
    # res mes. Un login creat a ma, o creat per una versio anterior d'aquest
    # script, es quedava amb DEFAULT_DATABASE = master per sempre -- i amb el
    # DENY CONNECT de mes avall, sense poder connectar-se enlloc. El 16/09/2026
    # va costar una tarda de depuracio al servidor: error 916 a AE01SAPRDP.
    #
    # La contrasenya va per parametre, no concatenada al text de la comanda:
    # aixi no acaba mai a cap pla d'execucio ni a cap traca de SQL Server.
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = @"
DECLARE @s nvarchar(max);
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    SET @s = N'CREATE LOGIN ' + QUOTENAME(@login)
        + N' WITH PASSWORD = ' + QUOTENAME(@pwd, '''')
        + N', CHECK_POLICY = ON, DEFAULT_DATABASE = IntercanviSAP;';
    EXEC sp_executesql @s;
    SELECT 'creat' AS resultat;
END
ELSE
BEGIN
    SET @s = N'ALTER LOGIN ' + QUOTENAME(@login)
        + N' WITH PASSWORD = ' + QUOTENAME(@pwd, '''')
        + N', CHECK_POLICY = ON, DEFAULT_DATABASE = IntercanviSAP;';
    EXEC sp_executesql @s;
    SELECT 'ja existia: contrasenya i base de dades per defecte reaplicades' AS resultat;
END
"@
    [void]$cmd.Parameters.AddWithValue('@login', $Login)
    [void]$cmd.Parameters.AddWithValue('@pwd', $newPwd)
    $r = $cmd.ExecuteScalar()
    Write-Host "  Login: $r" -ForegroundColor Green

    Exec 'IntercanviSAP' @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$Login')
    CREATE USER [$Login] FOR LOGIN [$Login];
GRANT SELECT, INSERT, UPDATE, DELETE, ALTER ON SCHEMA::sap_raw TO [$Login];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo     TO [$Login];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::staging TO [$Login];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[audit] TO [$Login];
"@
    Write-Host "  Permisos a IntercanviSAP: escriptura nomes a sap_raw" -ForegroundColor Green

    # DENY CONNECT nomes a les bases de dades de SAP, que es el que mana la
    # Regla 01. A 'master' NO: alli el DENY no protegeix res -- no hi tenim
    # dades i qualsevol login hi arriba per 'public'-- i en canvi impedeix que
    # el login s'autentiqui, encara que la cadena demani IntercanviSAP. Error
    # 916, "not able to access the database master". Si una versio anterior
    # d'aquest script ja l'hi va posar, aixo l'esborra.
    Exec 'master' @"
IF USER_ID('$Login') IS NOT NULL DROP USER [$Login];
"@
    Write-Host "  master: sense usuari ni DENY (si n'hi havia, esborrat)" -ForegroundColor Green

    foreach ($db in $SapDatabases) {
        try {
            Exec $db @"
IF USER_ID('$Login') IS NULL CREATE USER [$Login] FOR LOGIN [$Login];
DENY CONNECT TO [$Login];
"@
            Write-Host "  DENY CONNECT a $db" -ForegroundColor Green
        } catch {
            # Una BD de la llista que ja no hi sigui -- o que sigui OFFLINE,
            # com DB_FARINERA_TEST des del 22/09/2026 -- no ha d'aturar
            # l'script: sense aixo peta aqui i els permisos queden mig
            # aplicats.
            Write-Host "  $db : no s'ha pogut ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    # Comprovacio CONNECTANT-S'HI de debo, no impersonant.
    #
    # Abans aixo era un EXECUTE AS LOGIN dins de la sessio de l'administrador.
    # Impersonar no passa pel control de CONNECT, aixi que informava que tot
    # anava be d'un compte que no s'havia pogut connectar mai: el 27/08/2026 va
    # donar verd i el 16/09/2026 el Worker va petar amb un error 916 al
    # desplegar-lo. Una credencial que no s'ha provat obrint una connexio no
    # esta provada.
    #
    # Els SELECT de dins dels TRY assignen a una variable (SELECT TOP 1 @x = 1)
    # en comptes de retornar files. Si retornessin files, cadascun seria un
    # conjunt de resultats propi i el lector es quedaria amb el primer en
    # comptes del SELECT final: era l'altre bug del 27/08/2026.
    Write-Host ""
    try {
        $test = New-SqlConn $Server 'IntercanviSAP' $Login $newPwd
        $test.Open()
        Write-Host ("  Es connecta com a {0} : si (a {1})" -f $Login, $test.Database) -ForegroundColor Green

        $chk = $test.CreateCommand()
        $chk.CommandText = @"
DECLARE @ok_sapraw bit = 0, @ok_dbo_denegat bit = 1, @x int;
BEGIN TRY  SELECT TOP 1 @x = 1 FROM sap_raw.OCRD;   SET @ok_sapraw = 1;       END TRY BEGIN CATCH END CATCH
BEGIN TRY  SELECT TOP 1 @x = 1 FROM dbo.est_clients; SET @ok_dbo_denegat = 0; END TRY BEGIN CATCH END CATCH
SELECT CAST(@ok_sapraw AS int) AS pot_llegir_sap_raw, CAST(@ok_dbo_denegat AS int) AS te_dbo_denegat;
"@
        $rd = $chk.ExecuteReader()
        if ($rd.Read()) {
            $a = $rd.GetInt32(0); $b = $rd.GetInt32(1)
            Write-Host ("  Pot llegir sap_raw : {0}" -f $(if($a){'si'}else{'NO -- malament'}))
            Write-Host ("  dbo li es denegat  : {0}" -f $(if($b){'si'}else{'NO -- malament'}))
        }
        $rd.Close()
        $test.Close()

        foreach ($db in $SapDatabases) {
            try {
                $sap = New-SqlConn $Server $db $Login $newPwd
                $sap.Open(); $sap.Close()
                Write-Host ("  Entra a {0} : SI -- malament, revisa el DENY CONNECT" -f $db) -ForegroundColor Red
            } catch {
                Write-Host ("  Entra a {0} : no (correcte)" -f $db)
            }
        }
    }
    catch {
        $e = $_.Exception
        Write-Host ("  Es connecta com a {0} : NO -- error {1}" -f $Login, $e.Number) -ForegroundColor Red
        Write-Host ("  {0}" -f $e.Message.Split([Environment]::NewLine)[0]) -ForegroundColor Red
        if ($e.Number -eq 916) {
            Write-Host ""
            Write-Host "  916 vol dir que l'autenticacio ha passat i el context de BD no." -ForegroundColor Yellow
            Write-Host "  Mira DEFAULT_DATABASE del login i si te DENY CONNECT a master." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "Fet. Apunta la contrasenya al gestor: la necessitaras per a" -ForegroundColor Yellow
    Write-Host "l'appsettings.json de AE02SAPRDP i no es pot recuperar." -ForegroundColor Yellow
}
finally {
    $conn.Close()
    $adminPwd = $null; $newPwd = $null; $confirm = $null
    [GC]::Collect()
}
