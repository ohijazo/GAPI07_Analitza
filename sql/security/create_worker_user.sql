/* =========================================================================
   create_worker_user.sql  —  Login de SQL Server per al Worker

   PER QUE
   -------
   El Worker escriu al mirall sap_raw. Fins ara ho feia amb `sa`, que es
   excessiu: nomes ha de poder escriure a un esquema d'una base de dades.

   Aquest login viura en un fitxer de configuracio a AE01SAPRDP, una maquina
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

/* Cap acces a la resta de bases de dades del servidor, incloent-hi SAP. */
USE [DB_FARINERA_TEST];
GO
IF USER_ID('gapi07_worker') IS NULL
    CREATE USER gapi07_worker FOR LOGIN gapi07_worker;
DENY CONNECT TO gapi07_worker;
GO

USE master;
GO
IF USER_ID('gapi07_worker') IS NULL
    CREATE USER gapi07_worker FOR LOGIN gapi07_worker;
DENY CONNECT TO gapi07_worker;
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
