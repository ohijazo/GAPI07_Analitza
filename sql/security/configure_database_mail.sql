/* =========================================================================
   configure_database_mail.sql
   -------------------------------------------------------------------------
   Configura Database Mail amb el mailbox de servei d'M365
   (smtp.office365.com:587 STARTTLS) i deixa el SQL Agent notificant
   l'operador AnalitzaOps quan el job Analitza_ETL_Daily falla.

   NO S'EXECUTA A MA. El llança Configure-DatabaseMail.ps1, que demana la
   contrasenya interactivament i substitueix els marcadors en memoria. Aqui no
   hi ha d'haver mai una credencial: Regla 03.

   Marcadors que substitueix el llancador:
     {{FROM_ADDRESS}}  adreca remitent      p.ex. sql-alerts@agrienergia.com
     {{SMTP_USER}}     usuari d'autenticacio -- OJO: a M365 sovint NO coincideix
                       amb l'adreca (pot ser ...@<tenant>.onmicrosoft.com)
     {{SMTP_PASSWORD}} contrasenya, nomes en memoria
     {{ALERT_TO}}      qui rep les alertes

   ABANS d'executar cal que SMTP AUTH estigui habilitat al mailbox: al tenant
   esta desactivat per defecte. Si no ho esta, el test del pas 8 falla amb un
   error d'autenticacio i no es un problema d'aquest script.

   DESPRES: cal reiniciar el SQL Agent (pas 7) perque llegeixi els registres
   nous, i el test del pas 8 ha d'arribar en menys d'un minut.
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

/* ---------- 3. Crear compte SMTP ----------
   @email_address i @username son coses diferents i a M365 sovint no
   coincideixen: el primer es l'adreca que veura qui rebi el correu, el segon
   es la credencial amb que s'autentica. Posar-hi el mateix valor "perque sembla
   logic" es la manera mes rapida de passar una tarda depurant un 535. */
EXEC msdb.dbo.sysmail_add_account_sp
    @account_name        = N'AnalitzaSQL_M365',
    @description         = N'Mailbox de servei M365 per a notificacions del SQL Agent',
    @email_address       = N'{{FROM_ADDRESS}}',
    @display_name        = N'SQL Server AE01SAPSQL',
    @replyto_address     = N'{{FROM_ADDRESS}}',
    @mailserver_name     = N'smtp.office365.com',
    @mailserver_type     = N'SMTP',
    @port                = 587,
    @enable_ssl          = 1,                      -- STARTTLS
    @username            = N'{{SMTP_USER}}',
    @password            = N'{{SMTP_PASSWORD}}';
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

/* ---------- 6. Actualitzar l'operador AnalitzaOps ----------
   Qui rep les alertes hauria de ser una adreca institucional, no personal: el
   dia que qui la llegeix no hi sigui, les alertes s'han de seguir veient. */
EXEC msdb.dbo.sp_update_operator
    @name = N'AnalitzaOps',
    @email_address = N'{{ALERT_TO}}';
GO

/* ---------- 7. Reiniciar el SQL Agent ----------
   Cal perque llegeixi els registres nous del pas 5. No es pot fer des d'una
   connexio remota: a SSMS, boto dret sobre SQL Server Agent -> Restart, o des
   de services.msc a la maquina. */

/* ---------- 8. Test ---------- */
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = N'AnalitzaSQLMail',
    @recipients   = N'{{ALERT_TO}}',
    @subject      = N'Test Database Mail des de AE01SAPSQL / IntercanviSAP',
    @body         = N'Si reps aquest correu, Database Mail esta configurat correctament.';
GO

/* ---------- 9. Comprovar l'estat del test ---------- */
WAITFOR DELAY '00:00:10';

SELECT TOP 3 sent_status, sent_date, recipients, subject
FROM   msdb.dbo.sysmail_allitems
ORDER  BY mailitem_id DESC;

/* Si hi ha cap fila amb sent_status='failed', el motiu es aqui. Un error 535
   vol dir credencial rebutjada: mirar si SMTP AUTH esta habilitat al mailbox
   abans de sospitar de la contrasenya. */
SELECT TOP 5 log_date, event_type, [description]
FROM   msdb.dbo.sysmail_event_log
WHERE  event_type IN ('error','warning')
ORDER  BY log_id DESC;
GO
