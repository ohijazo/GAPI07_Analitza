/* =========================================================================
   Seeds per a cfg.zone_code_mapping
   -------------------------------------------------------------------------
   Mapping zone_name (valor real de CRD1.U_SEIZONAC a SAP) → zone_id numèric
   estable + zone_description que consumeix Analitza.

   Codis inicials 0001..0047 assignats per ordre alfabètic com a valor
   temporal. Un cop Adrià ens passi els codis KAIS antics per preservar
   continuïtat (0011=Girona Poblacions, 0025=Barcelona Poblacions, etc.),
   substituïm els codis via aquest mateix seed (MERGE idempotent).

   Font: SELECT DISTINCT LTRIM(RTRIM(U_SEIZONAC)) FROM CRD1 WHERE AdresType='S';
   Cobertura al test: 47 zones úniques.
   ========================================================================= */
USE IntercanviSAP;
GO

;MERGE cfg.zone_code_mapping AS T
 USING (VALUES
    ('ALEMANIA',                '0001', N'ALEMANIA'),
    ('ALICANTE',                '0002', N'ALICANTE'),
    ('ALMERIA',                 '0003', N'ALMERIA'),
    ('ANDORRA',                 '0004', N'ANDORRA'),
    ('ANGLATERRA',              '0005', N'ANGLATERRA'),
    ('ARAGON',                  '0006', N'ARAGON'),
    ('ASTURIAS',                '0007', N'ASTURIAS'),
    ('BADAJOZ',                 '0008', N'BADAJOZ'),
    ('BARCELONA CIUTAT',        '0009', N'BARCELONA CIUTAT'),
    ('BARCELONA POBLACIONS',    '0010', N'BARCELONA POBLACIONS'),
    ('CADIZ',                   '0011', N'CADIZ'),
    ('CANTABRIA',               '0012', N'CANTABRIA'),
    ('CASTELLO',                '0013', N'CASTELLO'),
    ('CASTILLA - LA MANCHA',    '0014', N'CASTILLA - LA MANCHA'),
    ('CASTILLA - LEON',         '0015', N'CASTILLA - LEON'),
    ('CORDOBA',                 '0016', N'CORDOBA'),
    ('EIVISSA',                 '0017', N'EIVISSA'),
    ('FORMENTERA',              '0018', N'FORMENTERA'),
    (N'FRANÇA',                 '0019', N'FRANÇA'),
    ('FUERTEVENTURA',           '0020', N'FUERTEVENTURA'),
    ('GALICIA',                 '0021', N'GALICIA'),
    ('GIRONA CIUTAT',           '0022', N'GIRONA CIUTAT'),
    ('GIRONA POBLACIONS',       '0023', N'GIRONA POBLACIONS'),
    ('GRAN CANARIA',            '0024', N'GRAN CANARIA'),
    ('GRANADA',                 '0025', N'GRANADA'),
    ('GUINEA ECUATORIAL',       '0026', N'GUINEA ECUATORIAL'),
    ('HUELVA',                  '0027', N'HUELVA'),
    ('ITALIA',                  '0028', N'ITALIA'),
    ('JAEN',                    '0029', N'JAEN'),
    ('LA RIOJA',                '0030', N'LA RIOJA'),
    ('LLEIDA CIUTAT',           '0031', N'LLEIDA CIUTAT'),
    ('LLEIDA POBLACIONS',       '0032', N'LLEIDA POBLACIONS'),
    ('MADRID',                  '0033', N'MADRID'),
    ('MALAGA',                  '0034', N'MALAGA'),
    ('MALLORCA',                '0035', N'MALLORCA'),
    ('MENORCA',                 '0036', N'MENORCA'),
    ('MURCIA',                  '0037', N'MURCIA'),
    ('NAVARRA',                 '0038', N'NAVARRA'),
    ('PAIS BASC',               '0039', N'PAIS BASC'),
    ('PORTUGAL',                '0040', N'PORTUGAL'),
    ('QATAR',                   '0041', N'QATAR'),
    ('SENSE ZONA',              '0000', N'SENSE ZONA'),
    ('SEVILLA',                 '0042', N'SEVILLA'),
    ('TARRAGONA',               '0043', N'TARRAGONA'),
    ('TENERIFE',                '0044', N'TENERIFE'),
    ('VALENCIA',                '0045', N'VALENCIA'),
    ('VENEZUELA',               '0046', N'VENEZUELA')
   ) AS S(zone_name, zone_id, zone_description)
   ON T.zone_name = S.zone_name
 WHEN MATCHED THEN
    UPDATE SET zone_id = S.zone_id, zone_description = S.zone_description
 WHEN NOT MATCHED THEN
    INSERT (zone_name, zone_id, zone_description)
    VALUES (S.zone_name, S.zone_id, S.zone_description);
GO
