/* =========================================================================
   SQL Agent Job: Analitza_ETL_Daily
   Schedule: cada dia a les 03:00 (lluny dels backups SAP, marge fins 05:00,
             que es quan Analitza es connecta a estirar les dades).
   Step 1 : EXEC IntercanviSAP.etl.sp_run_all (transforma sap_raw -> est_*)

   El mirall sap_raw el refresca SapB1AnalitzaSync.Worker, que corre com a
   tasca programada a AE02SAPRDP a les 02:45. NO es un pas d'aquest job: SQL
   Agent no pot llancar un proces en una altra maquina.
   On fail : sp_send_dbmail a l'operador "AnalitzaOps".

   Que l'ETL no transformi un mirall vell no ho garanteix l'ordre dels passos,
   sino la guarda de frescor de sp_run_all (cfg.settings.MIRROR_MAX_AGE_HOURS).

   Pre-requisits:
     - La tasca del Worker corrent a AE02SAPRDP i acabada abans de les 03:00.
     - Database Mail configurat amb un profile (es passa en @notify_email_operator_name).
     - Operator "AnalitzaOps" creat amb una addreca d'email valida (vegeu seccio
       opcional al final). Si no es vol notificacio per email, comentar la linia
       @notify_email_operator_name de sp_add_job.
   =========================================================================*/
USE msdb;
GO

/* ---------------------------------------------------------------------------
   1. Operador (cal que existeixi abans de referenciar-lo al job).
      Si no es vol email, es pot deixar i el job nomes loga errors.
   ---------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM dbo.sysoperators WHERE name = N'AnalitzaOps')
    EXEC dbo.sp_add_operator
        @name = N'AnalitzaOps',
        @enabled = 1,
        @email_address = N'oscarhijazomasso@gmail.com';
GO

/* ---------------------------------------------------------------------------
   2. Job - es recrea per garantir idempotencia.
   ---------------------------------------------------------------------------*/
DECLARE @JobName sysname = N'Analitza_ETL_Daily';


IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @JobName)
    EXEC dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

EXEC dbo.sp_add_job
    @job_name = @JobName,
    @description = N'Carga diaria de Analitza: transforma sap_raw a est_*. El mirall el refresca el Worker a AE02SAPRDP a les 02:45.',
    @enabled = 1,
    @notify_level_eventlog = 0,
    @notify_level_email    = 2,                  -- 2 = on failure
    @notify_email_operator_name = N'AnalitzaOps',
    @category_name = N'[Uncategorized (Local)]';

EXEC dbo.sp_add_jobserver
    @job_name = @JobName,
    @server_name = N'(local)';

/* Un sol pas: el Worker ja no s'executa des d'aqui.

   Corre com a tasca programada a AE02SAPRDP (servidor d'aplicacions) a les
   02:45. Son dos planificadors que no es parlen, aixi que la garantia de no
   transformar un mirall vell no la dona l'ordre dels passos sino la guarda de
   frescor de sp_run_all: si sap_raw.sync_state te mes de
   cfg.settings.MIRROR_MAX_AGE_HOURS hores, avorta amb ABORTED_STALE_MIRROR i
   dbo.est_* es queda com estava.

   @database_user_name = gapi07_etl
   ---------------------------------
   El job es propietat de `sa`. Sense aquesta linia el pas corre com a
   **sysadmin**, i llavors el que impedeix que l'ETL torni a llegir taules de
   SAP no es cap permis, es nomes que el codi ja no ho fa (Regla 01). Era el
   que quedava obert de la Fase 5, mesurat el 31/08/2026.

   gapi07_etl es un usuari SENSE LOGIN (sql/security/create_etl_user.sql): no
   serveix per connectar-se de fora i no te ambit fora d'IntercanviSAP. Cap
   base de dades de SAP li es accessible, i aixo no depen de cap DENY que algu
   pugui desfer.

   Si aquest usuari no existeix, el pas falla amb "The database user name
   'gapi07_etl' is not valid" i el job no publica res. Es preferible a
   arrencar en silenci amb sysadmin. */
EXEC dbo.sp_add_jobstep
    @job_name   = @JobName,
    @step_name  = N'Run ETL',
    @step_id    = 1,
    @subsystem  = N'TSQL',
    @database_name = N'IntercanviSAP',
    @database_user_name = N'gapi07_etl',
    @command    = N'EXEC etl.sp_run_all;',
    @on_success_action = 1,    -- 1 = quit success
    @on_fail_action    = 2,    -- 2 = quit failure
    @retry_attempts    = 0;

EXEC dbo.sp_add_jobschedule
    @job_name   = @JobName,
    @name       = N'Daily 03:00',
    @freq_type  = 4,           -- 4 = daily
    @freq_interval = 1,        -- every 1 day
    @active_start_time = 030000;

PRINT 'Job Analitza_ETL_Daily creat (1 pas: ETL, com a gapi07_etl).';
PRINT 'El mirall el refresca el Worker a AE02SAPRDP, com a tasca programada a les 02:45.';
PRINT 'Si no ha corregut, sp_run_all avorta amb ABORTED_STALE_MIRROR.';
GO
