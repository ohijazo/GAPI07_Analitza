/* =========================================================================
   revoke_sap_direct_access.sql   —  Fase 5 de la migracio a Service Layer

   PER QUE
   -------
   Un cop l'ETL ja no llegeix taules internes de SAP, la prohibicio de la
   Regla 01 nomes es de debo si, a mes, deixa de ser tecnicament possible.
   Mentre el login que executa l'ETL pugui fer SELECT sobre la BD de SAP, el
   patro antic pot tornar a entrar per la porta del darrere en qualsevol
   moment i ningu se n'assabentara.

   QUAN EXECUTAR-LO
   ----------------
   NOMES despres que sql\verify_migration.sql doni 0 files de diferencia.
   Abans d'aixo, revocar l'acces et deixa sense la fotografia de referencia
   si has de tornar a prendre-la.

   NO va a deploy.sql a proposit: es una accio d'una sola vegada i s'ha de
   fer conscientment.

   COM EXECUTAR-LO
   ---------------
   Primer la seccio 1 (nomes llegeix i informa). Mira la llista, decideix
   quin login es el de l'ETL, i despres executa la seccio 2 posant-hi el nom.
   ========================================================================= */

/* -------------------------------------------------------------------------
   1. QUI POT LLEGIR AVUI LA BD DE SAP
      Executa-ho i mira la sortida abans de tocar res. El compte de servei de
      SQL Agent i el teu usuari nominal hi sortiran; el que ens interessa es
      si hi ha algun login creat expressament per a l'ETL.
   ------------------------------------------------------------------------- */
USE [DB_FARIN_TEST];
GO

PRINT '--- Usuaris de DB_FARIN_TEST i els seus rols ---';

SELECT  dp.name              AS usuari,
        dp.type_desc         AS tipus,
        USER_NAME(rm.role_principal_id) AS rol
FROM    sys.database_principals dp
LEFT JOIN sys.database_role_members rm ON rm.member_principal_id = dp.principal_id
WHERE   dp.type IN ('S', 'U', 'G')
    AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
ORDER BY dp.name;

PRINT '--- Permisos explicits d objecte i de BD ---';

SELECT  pr.name         AS usuari,
        pe.permission_name,
        pe.state_desc,
        pe.class_desc,
        OBJECT_NAME(pe.major_id) AS objecte
FROM    sys.database_permissions pe
JOIN    sys.database_principals pr ON pr.principal_id = pe.grantee_principal_id
WHERE   pr.name NOT IN ('public', 'dbo', 'guest')
ORDER BY pr.name, pe.permission_name;
GO

/* -------------------------------------------------------------------------
   2. REVOCACIO
      Descomenta i posa-hi el login real. DENY i no REVOKE: DENY guanya sobre
      qualsevol permis heretat d'un rol, i aixo es justament el que volem
      (que no hi hagi manera de tornar-hi sense passar per aqui).

      Si el login de l'ETL resulta ser 'sa' o el compte de servei de SQL
      Agent, NO el toquis: son comptes d'administracio i denegar-los l'acces
      trencaria altres coses. En aquest cas, la feina pendent es una altra:
      crear un login dedicat per a l'ETL amb permisos nomes sobre
      IntercanviSAP, i deixar constancia escrita de la decisio.
   ------------------------------------------------------------------------- */

/*
USE [DB_FARIN_TEST];
GO

DECLARE @login sysname = N'<posa-hi-el-login-de-l-ETL>';

IF USER_ID(@login) IS NOT NULL
BEGIN
    DECLARE @sql nvarchar(max) = N'DENY CONNECT TO ' + QUOTENAME(@login) + N';';
    EXEC sp_executesql @sql;
    PRINT 'CONNECT denegat a ' + @login + ' sobre DB_FARIN_TEST.';
END
ELSE
    PRINT @login + ' no es usuari de DB_FARIN_TEST: no hi ha res a revocar.';
GO
*/

/* -------------------------------------------------------------------------
   3. COMPROVACIO
      Despres de revocar, aixo ha de fallar amb un error de permisos. Si
      retorna files, la revocacio no ha fet efecte i la Fase 5 no esta tancada.
   ------------------------------------------------------------------------- */

/*
EXECUTE AS LOGIN = N'<posa-hi-el-login-de-l-ETL>';
SELECT TOP 1 CardCode FROM [DB_FARIN_TEST].dbo.OCRD;   -- ha de petar
REVERT;
*/
