/* =========================================================================
   configure_database_mail.sql
   -------------------------------------------------------------------------
   Configura Database Mail amb M365 (smtp.office365.com:587 TLS) i deixa el
   SQL Agent enviant notificacions al operador AnalitzaOps quan el job falla.

   ANTES d'executar:
     1) Substituir <APP_PASSWORD_O_CONTRASENYA> per la contrasenya real
        (idealment App Password si tens MFA).
     2) Assegurar que SMTP AUTH esta habilitat al mailbox d'M365.

   DESPRES d'executar:
     - El script reinicia SQL Agent (necessari per llegir nous registres).
     - El test de mail (paso 8) ha d'arribar a la bustia en 30s.
   =========================================================================*/

/* ---------- 1. Activar Database Mail XPs ---------- */
USE master;
GO

EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;    RECONFIGURE;
GO

/* ---------- 2. Reinstaurar profile i compte (idempotent) ---------- */
USE msdb;
GO

/* Elimina profile/compte existents amb el nom (per re-executar net) */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = 'AnalitzaSQLMail')
BEGIN
    DECLARE @prof_id int = (SELECT profile_id FROM msdb.dbo.sysmail_profile WHERE name = 'AnalitzaSQLMail');
    EXEC msdb.dbo.sysmail_delete_profileaccount_sp @profile_id = @prof_id, @account_name = N'AnalitzaSQL_M365';
    EXEC msdb.dbo.sysmail_delete_principalprofile_sp @profile_id = @prof_id;
    EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = N'AnalitzaSQLMail';
END
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = 'AnalitzaSQL_M365')
    EXEC msdb.dbo.sysmail_delete_account_sp @account_name = N'AnalitzaSQL_M365';
GO

/* ---------- 3. Crear compte SMTP ---------- */
EXEC msdb.dbo.sysmail_add_account_sp
    @account_name        = N'AnalitzaSQL_M365',
    @description         = N'Compte M365 SMTP per a notificacions del SQL Agent',
    @email_address       = N'ohijazo@agrienergia.com',     -- From address
    @display_name        = N'SQL Server AE01SAPSQL',
    @replyto_address     = N'ohijazo@agrienergia.com',
    @mailserver_name     = N'smtp.office365.com',
    @mailserver_type     = N'SMTP',
    @port                = 587,
    @enable_ssl          = 1,                              -- STARTTLS
    @username            = N'ohijazo@agrienergia.com',
    @password            = N'<APP_PASSWORD_O_CONTRASENYA>'; -- !! substituir !!
GO

/* ---------- 4. Crear profile i lligar-lo al compte ---------- */
EXEC msdb.dbo.sysmail_add_profile_sp
    @profile_name = N'AnalitzaSQLMail',
    @description  = N'Profile per al job Analitza_ETL_Daily';

EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name   = N'AnalitzaSQLMail',
    @account_name   = N'AnalitzaSQL_M365',
    @sequence_number = 1;

EXEC msdb.dbo.sysmail_add_principalprofile_sp
    @profile_name  = N'AnalitzaSQLMail',
    @principal_name = N'public',
    @is_default    = 1;
GO

/* ---------- 5. Configurar SQL Agent per usar Database Mail ---------- */
EXEC master.dbo.xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
    N'UseDatabaseMail', N'REG_DWORD', 1;

EXEC master.dbo.xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
    N'DatabaseMailProfile', N'REG_SZ', N'AnalitzaSQLMail';
GO

/* ---------- 6. Actualitzar operador AnalitzaOps ---------- */
EXEC msdb.dbo.sp_update_operator
    @name = N'AnalitzaOps',
    @email_address = N'ohijazo@agrienergia.com';
GO

/* ---------- 7. Reiniciar SQL Agent perque agafi els nous registres ----------
   No es pot reiniciar el SQL Agent des d'una connexio que no sigui local;
   recomanem fer-ho manualment a SSMS: right-click sobre SQL Server Agent ->
   Restart, o via Services.msc.
   Alternativament des d'aquest mateix script (necessita xp_cmdshell habilitat
   i privilegi sysadmin):
       EXEC xp_cmdshell 'net stop "SQLSERVERAGENT" && net start "SQLSERVERAGENT"';
*/

/* ---------- 8. Test de mail ---------- */
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = N'AnalitzaSQLMail',
    @recipients   = N'ohijazo@agrienergia.com',
    @subject      = N'Test Database Mail des de AE01SAPSQL / IntercanviSAP',
    @body         = N'Si reps aquest correu, Database Mail esta configurat correctament.';
GO

/* ---------- 9. Comprovar estat del test ---------- */
WAITFOR DELAY '00:00:05';

SELECT TOP 3
    sent_status, sent_date, recipients, subject,
    LEFT(last_mod_date_text, 30) AS last_mod
FROM   (SELECT sent_status, sent_date, recipients, subject,
               CAST(last_mod_date AS varchar(30)) AS last_mod_date_text,
               mailitem_id
        FROM msdb.dbo.sysmail_allitems) x
ORDER BY mailitem_id DESC;

/* Si veus alguna fila amb sent_status='failed', mira: */
SELECT TOP 3 send_request_date, log_date, [description]
FROM   msdb.dbo.sysmail_event_log
WHERE  event_type IN ('error','warning')
ORDER BY log_id DESC;
GO
