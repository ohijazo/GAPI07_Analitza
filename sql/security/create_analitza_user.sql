/* =========================================================================
   create_analitza_user.sql
   -------------------------------------------------------------------------
   Crea el login + user amb que Analitza CM es connecta a IntercanviSAP.
     - Login: analitza_ro  (SQL auth)
     - Nomes SELECT sobre dbo.est_*, que es el contracte (Regla 04)
     - Denegat: sap_raw, staging, audit, cfg, etl, i les BD de SAP

   PER QUE NO db_datareader
   ------------------------
   Fins al 31/08/2026 aquest compte era db_datareader de tota la BD, i per
   tant podia llegir sap_raw.OCRD, sap_raw.DLN1 i la resta del mirall: una
   copia fidel de les taules internes de SAP. Tambe staging, audit i
   cfg.settings.

   Tres motius per tancar-ho:

     1. La Regla 01 diu que Analitza "no veu SAP mai". Amb db_datareader
        veia una copia literal de les seves taules.
     2. La Regla 04 diu que el contracte son les 8 dbo.est_*. Tot el que
        quedi visible mes enlla del contracte s'acaba fent servir, i llavors
        ja no es pot canviar.
     3. Llicenciament indirecte. La pregunta oberta amb el partner de SAP no
        va del compte tecnic, va de qui consumeix les dades. Donar acces a
        una copia d'OCRD es materialment pitjor que donar les 8 taules
        derivades. Veure memoria_projecte.md §9.

   dbo nomes conte les vuit est_*, aixi que GRANT SELECT sobre l'esquema es
   exactament el contracte i cobreix les taules que s'hi afegeixin.

   ABANS D'EXECUTAR: canvia la contrasenya de sota. Per rotar-la sense
   tocar aquest fitxer hi ha sql/security/Rotate-AnalitzaPassword.ps1, que
   la demana interactivament i no l'escriu enlloc.

   IDEMPOTENT: es pot executar tantes vegades com calgui.
   =========================================================================*/
USE master;
GO

/* 1. Login -------------------------------------------------------------- */
DECLARE @pwd nvarchar(128) = N'<POSA-HI-UNA-CONTRASENYA-LLARGA>';

IF SUSER_ID('analitza_ro') IS NULL
BEGIN
    IF @pwd LIKE N'%POSA-HI%'
        THROW 50001, 'Canvia la contrasenya abans de crear analitza_ro.', 1;

    DECLARE @sql nvarchar(max) = N'CREATE LOGIN analitza_ro WITH PASSWORD = ' + QUOTENAME(@pwd, '''')
        + N', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF, DEFAULT_DATABASE = IntercanviSAP;';
    EXEC sp_executesql @sql;
    PRINT 'Login analitza_ro creat.';
END
ELSE
    PRINT 'El login analitza_ro ja existia; no es toca la contrasenya.';
GO

/* 2. User i permisos a IntercanviSAP ------------------------------------ */
USE IntercanviSAP;
GO

IF USER_ID('analitza_ro') IS NULL
    CREATE USER analitza_ro FOR LOGIN analitza_ro;
GO

/* db_datareader donava tota la base de dades. Veure el capcal. */
IF EXISTS (SELECT 1 FROM sys.database_role_members rm
           JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
           JOIN sys.database_principals u ON u.principal_id = rm.member_principal_id
           WHERE r.name = N'db_datareader' AND u.name = N'analitza_ro')
BEGIN
    ALTER ROLE db_datareader DROP MEMBER analitza_ro;
    PRINT 'analitza_ro tret de db_datareader.';
END
GO

/* El contracte: les vuit dbo.est_*, nomes lectura. */
GRANT SELECT ON SCHEMA::dbo TO analitza_ro;
GO

/* Denegacions explicites. Amb el GRANT acotat no caldrien, pero deixen
   constancia de la intencio i aguanten si algun dia algu torna a afegir el
   compte a un rol ampli. Mateix criteri que a create_worker_user.sql. */
DENY SELECT ON SCHEMA::sap_raw TO analitza_ro;   /* el mirall de SAP */
DENY SELECT ON SCHEMA::staging TO analitza_ro;   /* dades a mig carregar */
DENY SELECT ON SCHEMA::[audit] TO analitza_ro;
DENY SELECT ON SCHEMA::cfg     TO analitza_ro;
DENY SELECT ON SCHEMA::etl     TO analitza_ro;   /* les vistes de codis KAIS */
GO

/* 3. Cap acces a les BD de SAP ------------------------------------------ */
USE [SBO-COMMON];
GO
IF USER_ID('analitza_ro') IS NULL
    CREATE USER analitza_ro FOR LOGIN analitza_ro;
DENY CONNECT TO analitza_ro;
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
IF USER_ID(''analitza_ro'') IS NULL
    CREATE USER analitza_ro FOR LOGIN analitza_ro;
DENY CONNECT TO analitza_ro;';
    EXEC sp_executesql @sql;
    PRINT 'CONNECT denegat a analitza_ro sobre ' + @db + '.';
END
GO

/* 4. Verificacio -------------------------------------------------------- */
USE IntercanviSAP;
GO

PRINT '--- Permisos d''analitza_ro a IntercanviSAP ---';
SELECT  pe.state_desc,
        pe.permission_name,
        ISNULL(SCHEMA_NAME(pe.major_id), '') AS esquema
FROM    sys.database_permissions pe
JOIN    sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
WHERE   pr.name = N'analitza_ro' AND pe.class = 3
ORDER BY pe.state_desc, esquema;

PRINT '--- Que pot llegir de veritat ---';
EXECUTE AS USER = N'analitza_ro';
SELECT 'dbo.est_clients'     AS objecte, HAS_PERMS_BY_NAME('dbo.est_clients','OBJECT','SELECT')     AS pot_llegir
UNION ALL SELECT 'dbo.est_linies_albara', HAS_PERMS_BY_NAME('dbo.est_linies_albara','OBJECT','SELECT')
UNION ALL SELECT 'sap_raw.OCRD',          HAS_PERMS_BY_NAME('sap_raw.OCRD','OBJECT','SELECT')
UNION ALL SELECT 'sap_raw.DLN1',          HAS_PERMS_BY_NAME('sap_raw.DLN1','OBJECT','SELECT')
UNION ALL SELECT 'staging.est_clients',   HAS_PERMS_BY_NAME('staging.est_clients','OBJECT','SELECT')
UNION ALL SELECT 'cfg.settings',          HAS_PERMS_BY_NAME('cfg.settings','OBJECT','SELECT')
UNION ALL SELECT 'audit.etl_runs',        HAS_PERMS_BY_NAME('audit.etl_runs','OBJECT','SELECT');
REVERT;
GO
