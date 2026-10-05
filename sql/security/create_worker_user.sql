/* =========================================================================
   create_worker_user.sql  —  Login de SQL Server per al Worker

   PER QUE
   -------
   El Worker escriu al mirall sap_raw. Fins ara ho feia amb `sa`, que es
   excessiu: nomes ha de poder escriure a un esquema d'una base de dades.

   Aquest login viura en un fitxer de configuracio a AE02SAPRDP, una maquina
   compartida amb webservices de tercers. Com menys pugui fer, millor.

   QUE POT FER
   -----------
   Nomes sobre IntercanviSAP, i nomes sobre l'esquema sap_raw:
     SELECT, INSERT, UPDATE, DELETE  - omplir el mirall
     ALTER                            - TRUNCATE TABLE ho requereix

   No pot llegir dbo.est_* (el que consumeix Analitza), ni staging, ni audit,
   ni cfg. Si algun dia el Worker ha de llegir cfg.settings, s'afegeix
   explicitament aqui i es documenta per que.

   ABANS D'EXECUTAR
   ----------------
   Canvia la contrasenya de sota. No la deixis com esta.
   ========================================================================= */
USE master;
GO

DECLARE @pwd nvarchar(128) = N'<POSA-HI-UNA-CONTRASENYA-LLARGA>';

IF @pwd LIKE N'%POSA-HI%'
    THROW 50001, 'Canvia la contrasenya abans d executar aquest script.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'gapi07_worker')
BEGIN
    DECLARE @sql nvarchar(max) = N'CREATE LOGIN gapi07_worker WITH PASSWORD = ' + QUOTENAME(@pwd, '''')
        + N', CHECK_POLICY = ON, DEFAULT_DATABASE = IntercanviSAP;';
    EXEC sp_executesql @sql;
    PRINT 'Login gapi07_worker creat.';
END
ELSE
    PRINT 'El login gapi07_worker ja existia; no es toca la contrasenya.';
GO

USE IntercanviSAP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'gapi07_worker')
    CREATE USER gapi07_worker FOR LOGIN gapi07_worker;
GO

/* Escriptura nomes sobre el mirall. ALTER hi es perque TRUNCATE TABLE el
   requereix: el Worker fa TRUNCATE + BULK INSERT als mestres. */
GRANT SELECT, INSERT, UPDATE, DELETE, ALTER ON SCHEMA::sap_raw TO gapi07_worker;
GO

/* Les taules temporals que fa servir SqlBulkCopy van a tempdb i no calen
   permisos explicits. */

/* -------------------------------------------------------------------------
   Denegacions explicites. No caldrien —sense GRANT no hi ha acces— pero
   deixen constancia de la intencio i aguanten si algun dia algu afegeix el
   compte a un rol ampli per error.
   ------------------------------------------------------------------------- */
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo     TO gapi07_worker;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::staging TO gapi07_worker;
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[audit] TO gapi07_worker;
GO

/* Cap acces a la resta de bases de dades del servidor, incloent-hi SAP.

   Va per sp_executesql perque USE no es pot posar dins d'un IF, i sense la
   guarda de DB_ID el dia que donin de baixa una d'aquestes bases de dades el
   script peta aqui i deixa els permisos a mig aplicar. Tot script de sql/ ha
   de ser idempotent (Regla 05).

   El QUOTENAME d'aqui NO es la regressio que prohibeix la Regla 01: alla es
   tracta de SPs que consulten taules de SAP amb el nom de la companyia
   interpolat. Aixo es DDL de seguretat, i el que fa es justament tancar
   l'acces a aquelles bases de dades. */
DECLARE @sapdb TABLE (name sysname PRIMARY KEY);
INSERT @sapdb (name) VALUES (N'DB_FARIN_TEST'), (N'DB_FARINERA'), (N'DB_FARINERA_TEST');
/* DB_FARIN_TEST es la companyia de test des del 22/09/2026. DB_FARINERA_TEST
   es la d'abans: el 22/09/2026 ja estava OFFLINE, i es queda a la llista fins
   que la treguin del servidor.

   DB_FARINERA (sense sufix) es una BD de SAP d'aquest mateix servidor, ONLINE
   des del 13/03/2026. Hi va el DENY pel mateix motiu que a les altres. OJO: la
   documentacio del projecte dona per fet que la companyia productiva es dira
   DB_FARINERA_PROD, i aqui no hi ha cap BD amb aquest nom -- s'ha de confirmar
   quina es abans del cutover, i afegir-la aqui si resulta ser una altra. */

DECLARE @db sysname, @sql nvarchar(max);
WHILE EXISTS (SELECT 1 FROM @sapdb)
BEGIN
    SELECT TOP 1 @db = name FROM @sapdb ORDER BY name;
    DELETE FROM @sapdb WHERE name = @db;

    /* Ha de ser ONLINE, no nomes existir: DB_ID() retorna un id per a una BD
       OFFLINE i el USE de sota peta igualment. DB_FARINERA_TEST ja estava
       OFFLINE el 22/09/2026, aixi que aquest cas no es hipotetic. */
    IF NOT EXISTS (SELECT 1 FROM sys.databases
                   WHERE name = @db AND state_desc = 'ONLINE')
    BEGIN
        PRINT @db + ': no hi es o no esta ONLINE, res a denegar.';
        CONTINUE;
    END

    SET @sql = N'USE ' + QUOTENAME(@db) + N';
IF USER_ID(''gapi07_worker'') IS NULL
    CREATE USER gapi07_worker FOR LOGIN gapi07_worker;
DENY CONNECT TO gapi07_worker;';
    EXEC sp_executesql @sql;
    PRINT 'CONNECT denegat a gapi07_worker sobre ' + @db + '.';
END
GO

/* A 'master' NO hi va cap DENY CONNECT, i si una versio anterior d'aquest
   script l'hi va posar, aixo el desfa.

   Alli el DENY no protegeix res —no hi tenim dades i qualsevol login hi arriba
   per 'public'— i en canvi impedeix que el login s'autentiqui, encara que la
   cadena de connexio demani IntercanviSAP: error 916, "not able to access the
   database master". Va estar vint dies latent i el 16/09/2026 va costar una
   tarda de depuracio al desplegar el Worker a AE01SAPRDP.

   Create-WorkerUser.ps1 ja ho fa aixi des de llavors; aquest fitxer s'hi havia
   quedat enrere i tornava a obrir el parany a qui executes el .sql en comptes
   del .ps1. */
USE master;
GO
IF USER_ID('gapi07_worker') IS NOT NULL
    DROP USER gapi07_worker;
GO

/* -------------------------------------------------------------------------
   Verificacio
   ------------------------------------------------------------------------- */
USE IntercanviSAP;
GO

PRINT '--- Permisos de gapi07_worker a IntercanviSAP ---';
SELECT  pe.class_desc,
        ISNULL(SCHEMA_NAME(pe.major_id), '') AS esquema,
        pe.permission_name,
        pe.state_desc
FROM    sys.database_permissions pe
JOIN    sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
WHERE   pr.name = N'gapi07_worker'
ORDER BY pe.state_desc, esquema, pe.permission_name;
GO

/* Comprovacio real: aixo ha de funcionar...
       EXECUTE AS LOGIN = N'gapi07_worker';
       SELECT TOP 1 CardCode FROM sap_raw.OCRD;
       REVERT;

   ...i aixo ha de fallar amb error de permisos:
       EXECUTE AS LOGIN = N'gapi07_worker';
       SELECT TOP 1 id_client_location FROM dbo.est_clients;
       REVERT;
   ------------------------------------------------------------------------- */
