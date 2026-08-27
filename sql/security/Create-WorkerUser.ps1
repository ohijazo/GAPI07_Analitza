# Crea el login gapi07_worker a AE01SAPSQL.
#
# Demana les contrasenyes interactivament i no les escriu enlloc: ni a
# l'historial de la consola, ni en cap fitxer, ni en cap paràmetre.
# Compatible amb PowerShell 5.1.
#
#   .\Create-WorkerUser.ps1
#
# Despres d'executar-lo, apunta la contrasenya del worker al gestor de
# contrasenyes: la necessitaras per a l'appsettings.json de AE01SAPRDP i no hi
# ha manera de recuperar-la.

param(
    [string]$Server   = 'AE01SAPSQL',
    [string]$Login    = 'gapi07_worker',
    [string]$AdminUser = 'sa'
)

$ErrorActionPreference = 'Stop'

function Read-Plain([string]$prompt) {
    $sec = Read-Host $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

Write-Host ""
Write-Host "Crear el login '$Login' a $Server" -ForegroundColor Cyan
Write-Host ""

$adminPwd = Read-Plain "Contrasenya de $AdminUser (per connectar)"
$newPwd   = Read-Plain "Contrasenya NOVA per a $Login"
$confirm  = Read-Plain "Repeteix-la"

if ($newPwd -ne $confirm) { Write-Host "No coincideixen." -ForegroundColor Red; exit 1 }
if ($newPwd.Length -lt 16) {
    Write-Host "Massa curta: minim 16 caracters. Viura en un fitxer de configuracio d'una maquina compartida." -ForegroundColor Red
    exit 1
}

$conn = New-Object System.Data.SqlClient.SqlConnection `
    "Server=$Server;Database=master;User Id=$AdminUser;Password=$adminPwd;Encrypt=False;TrustServerCertificate=True;Connection Timeout=15"
$conn.Open()

function Exec([string]$db, [string]$sql, [hashtable]$params = @{}) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "USE [$db];" + $sql
    foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $params[$k]) }
    $cmd.CommandTimeout = 120
    [void]$cmd.ExecuteNonQuery()
}

try {
    # La contrasenya va per parametre, no concatenada al text de la comanda:
    # aixi no acaba mai a cap pla d'execucio ni a cap traça de SQL Server.
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
    SELECT 'ja existia' AS resultat;
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

    foreach ($db in @('DB_FARINERA_TEST', 'master')) {
        Exec $db @"
IF USER_ID('$Login') IS NULL CREATE USER [$Login] FOR LOGIN [$Login];
DENY CONNECT TO [$Login];
"@
        Write-Host "  DENY CONNECT a $db" -ForegroundColor Green
    }

    # Comprovacio real, no nomes mirar els GRANT.
    #
    # Els SELECT de dins dels TRY assignen a una variable (SELECT TOP 1 @x = 1)
    # en comptes de retornar files. Si retornessin files, cadascun seria un
    # conjunt de resultats propi i el lector es quedaria amb el primer en
    # comptes del SELECT final: era el bug del 27/08/2026.
    $chk = $conn.CreateCommand()
    $chk.CommandText = @"
USE IntercanviSAP;
DECLARE @ok_sapraw bit = 0, @ok_dbo_denegat bit = 0, @x int;
EXECUTE AS LOGIN = '$Login';
BEGIN TRY  SELECT TOP 1 @x = 1 FROM sap_raw.OCRD;      SET @ok_sapraw = 1;      END TRY BEGIN CATCH END CATCH
BEGIN TRY  SELECT TOP 1 @x = 1 FROM dbo.est_clients;                            END TRY BEGIN CATCH SET @ok_dbo_denegat = 1; END CATCH
REVERT;
SELECT CAST(@ok_sapraw AS int) AS pot_llegir_sap_raw, CAST(@ok_dbo_denegat AS int) AS te_dbo_denegat;
"@
    $rd = $chk.ExecuteReader()
    if ($rd.Read()) {
        $a = $rd.GetInt32(0); $b = $rd.GetInt32(1)
        Write-Host ""
        Write-Host ("  Pot llegir sap_raw : {0}" -f $(if($a){'si'}else{'NO -- malament'}))
        Write-Host ("  dbo li es denegat  : {0}" -f $(if($b){'si'}else{'NO -- malament'}))
    }
    $rd.Close()

    Write-Host ""
    Write-Host "Fet. Apunta la contrasenya al gestor: la necessitaras per a" -ForegroundColor Yellow
    Write-Host "l'appsettings.json de AE01SAPRDP i no es pot recuperar." -ForegroundColor Yellow
}
finally {
    $conn.Close()
    $adminPwd = $null; $newPwd = $null; $confirm = $null
    [GC]::Collect()
}
