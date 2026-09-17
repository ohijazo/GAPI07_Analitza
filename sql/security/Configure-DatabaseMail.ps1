# Configura Database Mail a AE01SAPSQL amb el mailbox de servei d'M365.
#
# Llegeix configure_database_mail.sql, hi substitueix els marcadors EN MEMORIA
# i l'executa. La contrasenya del mailbox es demana interactivament i no
# s'escriu enlloc: ni al fitxer, ni a l'historial, ni a cap parametre (Regla 03).
#
# Cal un compte sysadmin: crear comptes de Database Mail i escriure al registre
# del SQL Agent son operacions de servidor.
#
# Compatible amb PowerShell 5.1.
#
#   .\Configure-DatabaseMail.ps1
#
# DESPRES cal reiniciar el SQL Agent perque llegeixi els registres nous.

param(
    [string]$Server      = 'AE01SAPSQL',
    [string]$AdminUser   = 'sa',
    [string]$FromAddress = 'sql-alerts@agrienergia.com',
    [string]$SmtpUser    = 'sql-alerts@grupagrienergia.onmicrosoft.com',
    [string]$AlertTo     = 'ohijazo@agrienergia.com'
)

$ErrorActionPreference = 'Stop'

$sqlPath = Join-Path $PSScriptRoot 'configure_database_mail.sql'
if (-not (Test-Path $sqlPath)) { Write-Host "No trobo $sqlPath" -ForegroundColor Red; exit 1 }

function Read-Plain([string]$prompt) {
    $sec = Read-Host $prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# La contrasenya no va interpolada dins de la cadena de connexio: amb ';', '='
# o cometes el client la trenca i el que veus es un "Login failed" que sembla
# una credencial dolenta. Veure gapi07-comptes-sql.
function New-SqlConn([string]$server, [string]$db, [string]$user, [string]$plainPwd) {
    $sec = ConvertTo-SecureString $plainPwd -AsPlainText -Force
    $sec.MakeReadOnly()
    $cred = New-Object System.Data.SqlClient.SqlCredential($user, $sec)
    return New-Object System.Data.SqlClient.SqlConnection(
        "Server=$server;Database=master;Encrypt=False;TrustServerCertificate=True;Connection Timeout=15", $cred)
}

Write-Host ""
Write-Host "Database Mail a $Server" -ForegroundColor Cyan
Write-Host "  remitent : $FromAddress"
Write-Host "  usuari   : $SmtpUser"
Write-Host "  alertes a: $AlertTo"
Write-Host ""

$adminPwd = Read-Plain "Contrasenya de $AdminUser (per connectar al SQL)"
$smtpPwd  = Read-Plain "Contrasenya del mailbox $SmtpUser"
if ($smtpPwd.Length -lt 8) { Write-Host "Massa curta, no sembla la bona." -ForegroundColor Red; exit 1 }

$sql = Get-Content $sqlPath -Raw
$sql = $sql.Replace('{{FROM_ADDRESS}}',  $FromAddress.Replace("'","''"))
$sql = $sql.Replace('{{SMTP_USER}}',     $SmtpUser.Replace("'","''"))
$sql = $sql.Replace('{{SMTP_PASSWORD}}', $smtpPwd.Replace("'","''"))
$sql = $sql.Replace('{{ALERT_TO}}',      $AlertTo.Replace("'","''"))

$cn = New-SqlConn $Server 'master' $AdminUser $adminPwd
$cn.Open()

try {
    $lots = [regex]::Split($sql, '(?im)^\s*GO\s*$')
    $n = 0
    foreach ($lot in $lots) {
        if ([string]::IsNullOrWhiteSpace($lot)) { continue }
        $cmd = $cn.CreateCommand(); $cmd.CommandText = $lot; $cmd.CommandTimeout = 120
        $rd = $cmd.ExecuteReader()
        do {
            if ($rd.FieldCount -gt 0) {
                while ($rd.Read()) {
                    $vals = @()
                    for ($i = 0; $i -lt $rd.FieldCount; $i++) { $vals += "$($rd.GetName($i))=$($rd.GetValue($i))" }
                    Write-Host ("  " + ($vals -join '  '))
                }
            }
        } while ($rd.NextResult())
        $rd.Close()
        $n++
    }
    Write-Host ""
    Write-Host "Executats $n lots." -ForegroundColor Green
}
finally {
    $cn.Close()
    $adminPwd = $null; $smtpPwd = $null; $sql = $null
    [GC]::Collect()
}

Write-Host ""
Write-Host "COM LLEGIR EL QUE ACABES DE VEURE:" -ForegroundColor Yellow
Write-Host "  Les consultes finals nomes miren l'ultima hora. Si hi surt una" -ForegroundColor Yellow
Write-Host "  linia amb sent_status=sent, ha anat be; qualsevol cosa mes vella" -ForegroundColor Yellow
Write-Host "  no te res a veure amb aquesta execucio." -ForegroundColor Yellow
Write-Host ""
Write-Host "QUE FALTA:" -ForegroundColor Yellow
Write-Host "  1. Reiniciar el SQL Agent a la maquina perque llegeixi els" -ForegroundColor Yellow
Write-Host "     registres nous. Sense aixo, el job no enviara res encara que" -ForegroundColor Yellow
Write-Host "     el test hagi arribat: es la confusio mes facil d'aquest pas." -ForegroundColor Yellow
Write-Host "  2. Mirar la bustia: el test ha d'arribar en menys d'un minut." -ForegroundColor Yellow
Write-Host "  3. Si surt sent_status=failed amb un 535, el problema es que SMTP" -ForegroundColor Yellow
Write-Host "     AUTH no esta habilitat al mailbox, no la contrasenya." -ForegroundColor Yellow
