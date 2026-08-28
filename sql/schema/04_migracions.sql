/* =========================================================================
   04_migracions.sql  —  Canvis d'esquema sobre una BD ja desplegada

   PER QUE EXISTEIX AQUEST FITXER
   ------------------------------
   01_create_database.sql fa DROP TABLE de les est_*, o sigui que NO es pot
   tornar a executar sobre la productiva: s'enduria les dades que Analitza
   consulta. Aquí hi van els canvis d'esquema equivalents, en forma d'ALTER
   guardat, perquè una BD existent convergeixi amb el DDL sense perdre res.

   Cada bloc ha de ser IDEMPOTENT i ha de deixar la taula igual que la deixaria
   01_create_database.sql en una instal.lació nova. Si un dia divergeixen, la
   productiva i la de test deixen de ser la mateixa cosa i les validacions no
   volen dir res.

   L'executa deploy.sql just després del schema.
   ========================================================================= */
USE IntercanviSAP;
GO

/* -------------------------------------------------------------------------
   2026-08-28 — discount: decimal(5,2) -> decimal(9,6)

   discount es un multiplicador (1.00 = sense descompte, 0.90 = 10%), i el
   net_amount es calcula a precisio completa. Amb nomes 2 decimals, un
   descompte del 3,33% queda 0,9667 -> 0,97 i la formula
   net_amount = price * qty * discount deixa de quadrar: el check
   formula_break saltaria cada nit. Amb les 62 linies de la BD de test cap
   linia porta descompte i el problema no es veia.

   Ampliar es compatible cap enrere per a qui llegeix: Analitza fa
   "1-discount" i el que rep son mes decimals, no un valor diferent.
   Acordat amb l'Adria el 27/08/2026.
   ------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.est_linies_albara')
             AND name = 'discount' AND (precision <> 9 OR scale <> 6))
    ALTER TABLE dbo.est_linies_albara ALTER COLUMN discount decimal(9,6) NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('staging.est_linies_albara')
             AND name = 'discount' AND (precision <> 9 OR scale <> 6))
    ALTER TABLE staging.est_linies_albara ALTER COLUMN discount decimal(9,6) NULL;
GO

IF OBJECT_ID('baseline.est_linies_albara') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('baseline.est_linies_albara')
                 AND name = 'discount' AND (precision <> 9 OR scale <> 6))
    /* La fotografia tambe, o comparar-la amb staging donaria diferencies que
       nomes son d'escala. */
    ALTER TABLE baseline.est_linies_albara ALTER COLUMN discount decimal(9,6) NULL;
GO
