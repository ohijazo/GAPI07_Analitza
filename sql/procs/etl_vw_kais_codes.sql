/* =========================================================================
   etl.vw_client_code / etl.vw_salesman_code
   Origen : sap_raw.OCRD, sap_raw.OSLP
   Destino: les fan servir sp_load_clients, sp_load_client_attributes,
            sp_load_invoice_lines, sp_load_receivables i sp_load_salesmen.

   PER QUE EXISTEIXEN
   ------------------
   Analitza construeix el seu historic sobre els identificadors que li arribaven
   de KAIS. Al cutover del 2 de novembre de 2026 l'origen passa a ser SAP i, on
   el codi no coincideixi, l'historic deixa de lligar: Analitza no veu un error,
   veu un client que ha deixat de comprar i un altre que acaba de neixer
   (Regla 04).

   La regla acordada amb Analitza (correu de l'Adria, 27/08/2026) es:

       id = COALESCE(U_FCCodiKais, <codi de SAP>)

   Qui ve de KAIS conserva el seu codi; qui es dona d'alta a SAP despres del
   tall porta el de SAP i el conserva. Els dos formats no es poden trepitjar:
   els de KAIS son 8 digits i els CardCode son 'C' + 6.

   PER QUE UNA VISTA I NO LA FORMULA REPETIDA
   ------------------------------------------
   El tros "CardCode + '-' + LineNum" apareix a VUIT llocs repartits per quatre
   SPs. La Regla 04 ja avisa que si es toca la formula d'un s'ha de tocar la de
   l'altre; amb el COALESCE a sobre, la probabilitat que dues copies divergeixin
   i que est_clients i est_atributs_client deixin de lligar seria alta. Aqui la
   definicio viu en un sol lloc.

   No es una columna calculada a sap_raw a proposit: sap_raw guarda la forma
   NATIVA de SAP i no ha de saber res del contracte amb Analitza (Regla 01).

   IDEMPOTENT: CREATE OR ALTER.
   ========================================================================= */
USE IntercanviSAP;
GO

/* Codi de client que s'emet cap a Analitza.
   LEFT(...,9) perque id_client_location es varchar(13) i se li afegeix
   '-' + 3 digits de ship-to: 9 + 1 + 3 = 13. Els codis reals fan 8 (KAIS) o
   7 ('C' + 6), aixi que el LEFT no talla res; hi es perque si algun dia
   apareix un codi mes llarg falli el check de longitud i no la clau primaria.
   NULLIF sobre la cadena buida: un UDF "informat" amb espais no val com a codi. */
CREATE OR ALTER VIEW etl.vw_client_code
AS
SELECT  c.CardCode,
        client_code = LEFT(
            COALESCE(NULLIF(LTRIM(RTRIM(c.U_FCCodiKais)), ''), RTRIM(c.CardCode)), 9)
FROM    sap_raw.OCRD AS c;
GO

/* Numero de ship-to que forma la meitat dreta de id_client_location.
   =========================================================================
   NO es CRD1.LineNum. KAIS numerava les adreces de cada client
   SEQUENCIALMENT des de 000; el LineNum de SAP es un numero de fila intern i
   comenca on li toca (000, 006, 014...). Mesurat el 28/08/2026 contra
   l'exportacio d'Analitza, sobre 4.689 clients:

       amb CRD1.LineNum      ->   283 clients quadren  (6%)
       renumerant 0,1,2...   -> 4.647 clients quadren  (99,1%)

   Per que no es va veure abans: la sonda de Fase 0 va donar 534/534
   coincidencies, pero contra baseline.est_clients, que a l'entorn de test es
   sortida del pipeline antic ja apuntat a SAP. Comparava SAP amb SAP i el que
   demostrava es que BPAddress.RowNum == CRD1.LineNum, no que cap dels dos fos
   el numero que KAIS va donar a Analitza.

   EL NUMERO JA NO ES CALCULA, ES LLEGEIX (01/09/2026)
   ---------------------------------------------------
   Calcular-lo al vol amb ROW_NUMBER() feia que esborrar una adreça renumeres
   totes les posteriors del mateix client. L'Adria va explicar que aixo, al seu
   costat, no deixa un forat sino que **enganxa l'historic d'una adreça a una
   altra**: quan deixa d'arribar-los un client_location l'esborren de
   l'aplicacio pero mantenen l'historic d'albarans, i si mes endavant neix una
   adreça amb aquell numero, se l'emporta tot.

   Ara el numero viu a cfg.client_ship_no, que l'assigna una sola vegada i no
   el torna a tocar (etl.sp_assign_client_ship_no).

   INNER JOIN a proposit: una adreça sense numero congelat NO ha de sortir amb
   un numero inventat. Que desaparegui es visible -el check ship_no_missing la
   caça i vanished_ids tambe-, mentre que inventar-lo seria silencios i
   trencaria justament el que aixo protegeix.
   ========================================================================= */
CREATE OR ALTER VIEW etl.vw_client_ship
AS
SELECT  a.CardCode,
        a.LineNum,
        a.[Address],
        f.ship_no
FROM    sap_raw.CRD1 AS a
INNER JOIN cfg.client_ship_no AS f
        ON f.CardCode = a.CardCode AND f.LineNum = a.LineNum
WHERE   a.AdresType = 'S';
GO

/* Codi de comercial. El fallback replica el que feia sp_load_salesmen abans
   d'existir el UDF: LPAD a 3 digits, i els SlpCode negatius (-1 = "sense
   agent", que SAP fa servir de fallback) a '000'. */
CREATE OR ALTER VIEW etl.vw_salesman_code
AS
SELECT  s.SlpCode,
        id_salesman = LEFT(
            COALESCE(
                NULLIF(LTRIM(RTRIM(s.U_FCCodiKais)), ''),
                CASE WHEN s.SlpCode < 0 THEN '000'
                     ELSE RIGHT('000' + CAST(s.SlpCode AS varchar(10)), 3) END), 3)
FROM    sap_raw.OSLP AS s;
GO

/* -------------------------------------------------------------------------
   etl.vw_client_successor - el new_code: qui substitueix un client

   D'ON SURT
   ---------
   De sap_raw.OCRD.U_SEICodienllac, un camp de la implantacio (Seidor). El
   projecte havia creat OCRD.U_FCNewCardCode per a aixo mateix sense saber que
   ja existia; s'ha borrat de SAP i aquesta vista el substitueix.

   EL CAMP APUNTA ENRERE
   ---------------------
   Mesurat amb --probe el 10/09/2026 sobre DB_FARINERA_TEST, 160 clients de
   4.691 el porten informat, i la direccio es inequivoca:

       de client viu a client de baixa : 108
       de client de baixa a client viu :   2

   O sigui que U_SEICodienllac guarda el PREDECESSOR: el codi del client que
   aquest ve a substituir. I new_code demana el contrari, el codi NOU. Per aixo
   la vista INVERTEIX la relacio: el new_code d'un client es el codi de qui
   l'apunta a ell. Emetre el camp tal qual lligaria l'historic al reves i
   Analitza acumularia les vendes al registre mort.

   EL VALOR NO VE TAL COM ESTA A L'ALTRA BANDA
   -------------------------------------------
   Hi falten els zeros de l'esquerra ('201011' pel client amb U_FCCodiKais
   '00201011') i la 'C' del CardCode ('211433' per C211433). De les quatre
   normalitzacions provades a la sonda, la de 8 digits resol 160 de 160 i la de
   la 'C' 159 de 160; hi son les dues perque despres del tall els clients nous
   no tindran codi de KAIS i nomes els valdra la segona.

   NOMES POT SORTIR UN SUCCESSOR PER CLIENT
   ----------------------------------------
   La inversio no es 1:1: a test hi ha un predecessor amb dos successors
   (C211608 <- C211534, C301563). Sense el TOP 1 es multiplicarien files a
   staging.est_clients i hi hauria id_client_location duplicats. Es tria el
   successor viu, i entre dos de vius el CardCode mes alt (el mes recent). El
   check new_code_ambiguous de sp_data_quality_checks avisa de cada cas.

   Les cadenes (A substitueix B, que substituia C) s'emeten a un sol salt: el
   new_code de C es B, no A. A test n'hi ha 20.
   ------------------------------------------------------------------------- */
CREATE OR ALTER VIEW etl.vw_client_successor
AS
SELECT  pred.CardCode,
        new_code = LEFT(scc.client_code, 8)
FROM    sap_raw.OCRD AS pred
INNER JOIN etl.vw_client_code AS pcc
        ON pcc.CardCode = pred.CardCode
CROSS APPLY (
        SELECT TOP (1) s.CardCode
        FROM   sap_raw.OCRD AS s
        WHERE  NULLIF(LTRIM(RTRIM(s.U_SEICodienllac)), '') IS NOT NULL
          AND  s.CardCode <> pred.CardCode
          AND  (
                 /* Nomes s'omplen els zeros si hi caben: amb RIGHT() pelat, un
                    valor mes llarg de 8 es truncaria i lligaria amb qui no toca. */
                 CASE WHEN LEN(LTRIM(RTRIM(s.U_SEICodienllac))) <= 8
                      THEN RIGHT('00000000' + LTRIM(RTRIM(s.U_SEICodienllac)), 8)
                      ELSE LTRIM(RTRIM(s.U_SEICodienllac)) END = pcc.client_code
                 OR 'C' + LTRIM(RTRIM(s.U_SEICodienllac)) = RTRIM(pred.CardCode)
               )
        ORDER BY CASE WHEN s.validFor = 'Y' THEN 0 ELSE 1 END, s.CardCode DESC
) AS pick
INNER JOIN etl.vw_client_code AS scc
        ON scc.CardCode = pick.CardCode;
GO
