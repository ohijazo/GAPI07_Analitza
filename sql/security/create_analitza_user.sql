/* =========================================================================
   create_analitza_user.sql
   -------------------------------------------------------------------------
   Crea el login + user per a la connexio d'Analitza CM.
     - Login: analitza_ro  (SQL auth)
     - Rols: db_datareader nomes a IntercanviSAP
     - Denegat explicitament: access a SBO-COMMON i a la BD productiva SAP

   ABANS d'executar: canvia '<contrasenya_segura>' per una contrasenya forta
   (minim 12 chars, mixt majus/minus/numeros/simbols).

   Notes:
     - L'usuari NO ha de tenir cap acces a DB_FARINERA_TEST (o a la BD SAP
       productiva quan toqui) ni a SBO-COMMON.
     - Si voleu, addicionalment es pot restringir per IP creant un firewall
       rule, pero MSSQL no ho fa natiu.
   =========================================================================*/
USE master;
GO

/* 1. Login */
IF SUSER_ID('analitza_ro') IS NULL
    CREATE LOGIN analitza_ro
        WITH PASSWORD = '<contrasenya_segura>',
             CHECK_POLICY = ON,
             CHECK_EXPIRATION = OFF,
             DEFAULT_DATABASE = IntercanviSAP;
GO

/* 2. User i rol a IntercanviSAP */
USE IntercanviSAP;
GO

IF USER_ID('analitza_ro') IS NULL
    CREATE USER analitza_ro FOR LOGIN analitza_ro;
GO

ALTER ROLE db_datareader ADD MEMBER analitza_ro;
GO

/* 3. Denegacio explicita d'acces a altres BD rellevants */
USE [SBO-COMMON];
GO
IF USER_ID('analitza_ro') IS NULL
    CREATE USER analitza_ro FOR LOGIN analitza_ro;
DENY CONNECT TO analitza_ro;
GO

USE [DB_FARINERA_TEST];
GO
IF USER_ID('analitza_ro') IS NULL
    CREATE USER analitza_ro FOR LOGIN analitza_ro;
DENY CONNECT TO analitza_ro;
GO

/* 4. Verificacio */
USE IntercanviSAP;
GO

PRINT '--- Permisos d''analitza_ro a IntercanviSAP: ---';
SELECT  dp.permission_name, dp.state_desc, OBJECT_NAME(dp.major_id) AS [object]
FROM    sys.database_permissions dp
JOIN    sys.database_principals  p ON p.principal_id = dp.grantee_principal_id
WHERE   p.name = 'analitza_ro';

PRINT '--- Rols d''analitza_ro: ---';
SELECT r.name AS role_name
FROM   sys.database_role_members rm
JOIN   sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN   sys.database_principals u ON u.principal_id = rm.member_principal_id
WHERE  u.name = 'analitza_ro';
GO
