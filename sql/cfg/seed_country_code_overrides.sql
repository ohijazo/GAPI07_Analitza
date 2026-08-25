/* =========================================================================
   Seeds per a cfg.country_code_overrides
   -------------------------------------------------------------------------
   El mapping de SAP a ISO-2 es necessari nomes per a codis no estandard.
   La majoria de codis a SAP B1 ja son ISO-2 (ES, FR, PT, ...) i sp_load_clients
   els converteix a minuscules directament. Aqui nomes afegim casos especials.
   Comentaris al voltant de cada exemple per saber per que hi son.
   =========================================================================*/
USE IntercanviSAP;
GO

;MERGE cfg.country_code_overrides AS T
 USING (VALUES
        -- exemple: si algun client te 'UK' en lloc de 'GB'
        ('UK', 'gb'),
        -- alguns dataset antics utilitzen el nom complet
        ('ESPAÑA', 'es'),
        ('FRANCIA', 'fr'),
        ('PORTUGAL', 'pt')
       ) AS S(sap_country_code, iso2_code)
   ON T.sap_country_code = S.sap_country_code
 WHEN MATCHED THEN UPDATE SET iso2_code = S.iso2_code
 WHEN NOT MATCHED THEN INSERT (sap_country_code, iso2_code) VALUES (S.sap_country_code, S.iso2_code);
GO
