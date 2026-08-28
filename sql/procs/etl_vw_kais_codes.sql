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

   ATENCIO — el que aixo compra i el que costa:
   Si algu ESBORRA una adreca de ship-to a SAP, totes les posteriors del mateix
   client es renumeren, i per a Analitza aixo son ubicacions que desapareixen i
   ubicacions noves que neixen amb l'historic buit. El check vanished_ids ho
   detecta l'endema, pero ho detecta, no ho evita. La solucio estable seria
   congelar el numero per (client, adreca) en una taula al tall i fer servir la
   seqüencia nomes per a les adreces noves; queda pendent de decidir amb
   Analitza. Mentrestant aixo es correcte per al 99,1% dels clients i el que hi
   havia ho era per al 6%.
   ========================================================================= */
CREATE OR ALTER VIEW etl.vw_client_ship
AS
SELECT  a.CardCode,
        a.LineNum,
        a.[Address],
        /* -1 perque la primera adreca ha de ser 000, com a KAIS. ORDER BY
           LineNum es determinista: (CardCode, LineNum) es la clau primaria. */
        ship_no = ROW_NUMBER() OVER (PARTITION BY a.CardCode ORDER BY a.LineNum) - 1
FROM    sap_raw.CRD1 AS a
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
