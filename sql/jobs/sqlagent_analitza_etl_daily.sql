/* =========================================================================
   SQL Agent Job: Analitza_ETL_Daily
   Schedule: cada dia a les 03:00 (lluny dels backups SAP, marge fins 05:00,
             que es quan Analitza es connecta a estirar les dades).
   Step 1 : SapB1AnalitzaSync.Worker --once   (refresca el mirall sap_raw des
            de SAP per Service Layer)
   Step 2 : EXEC IntercanviSAP.etl.sp_run_all (transforma sap_raw -> est_*)
   On fail : sp_send_dbmail a l'operador "AnalitzaOps".

   L'ordre no es negociable: si el pas 1 falla, el pas 2 NO s'ha d'executar, o
   l'ETL carregaria el mirall del dia anterior sense adonar-se'n. Per aixo el
   pas 1 te @on_fail_action = 2 (quit with failure).

   Pre-requisits:
     - El Worker publicat a @WorkerExe (veure la variable mes avall) i amb la
       seva configuracio d'entorn: ServiceLayer:* i Database:ConnectionString
       com a variables d'entorn de maquina del compte que executa SQL Agent
       (Regla 03: mai secrets al repo ni a la comanda del job).
     - El compte de servei de SQL Agent ha de poder executar l'exe i sortir a
       la xarxa cap al Service Layer de SAP (HTTPS, port 50000 per defecte).
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

/* Ruta de l'executable del Worker. Ajustar si es publica en un altre lloc. */
DECLARE @WorkerExe nvarchar(400) = N'P:\GAPI07_Analitza\src\SapB1AnalitzaSync.Worker\bin\Release\net8.0\SapB1AnalitzaSync.Worker.exe';

IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = @JobName)
    EXEC dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

EXEC dbo.sp_add_job
    @job_name = @JobName,
    @description = N'Carga diaria de Analitza des de SAP B1 a IntercanviSAP. Pas 1: refresca sap_raw via Service Layer. Pas 2: etl.sp_run_all.',
    @enabled = 1,
    @notify_level_eventlog = 0,
    @notify_level_email    = 2,                  -- 2 = on failure
    @notify_email_operator_name = N'AnalitzaOps',
    @category_name = N'[Uncategorized (Local)]';

EXEC dbo.sp_add_jobserver
    @job_name = @JobName,
    @server_name = N'(local)';

/* Pas 1 - mirall. Si falla, el job para aqui i dbo.est_* es queda amb les
   dades d'ahir, que es exactament el comportament que volem: Analitza prefereix
   dades velles a dades a mitges. */
EXEC dbo.sp_add_jobstep
    @job_name   = @JobName,
    @step_name  = N'Refresca sap_raw (Service Layer)',
    @step_id    = 1,
    @subsystem  = N'CmdExec',
    @command    = @WorkerExe,           -- sense arguments: el mode per defecte es --once
    @on_success_action = 3,             -- 3 = go to next step
    @on_fail_action    = 2,             -- 2 = quit with failure
    @retry_attempts    = 1,
    @retry_interval    = 5;             -- minuts; cobreix un tall de xarxa puntual

/* Pas 2 - ETL. Llegeix nomes sap_raw i cfg; no toca SAP. */
EXEC dbo.sp_add_jobstep
    @job_name   = @JobName,
    @step_name  = N'Run ETL',
    @step_id    = 2,
    @subsystem  = N'TSQL',
    @database_name = N'IntercanviSAP',
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

PRINT 'Job Analitza_ETL_Daily creat amb 2 passos (mirall + ETL).';
PRINT 'Comprova que el compte de SQL Agent pot executar:';
PRINT @WorkerExe;
GO
