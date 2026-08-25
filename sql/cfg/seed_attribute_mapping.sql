/* =========================================================================
   Seeds per a cfg.attribute_mapping   (obsolet al format KAIS-WIDE)
   -------------------------------------------------------------------------
   Els atributs (est_atributs_client i est_atributs_producte) ara són WIDE:
   les columnes són fixes i el mapping SAP → columna KAIS està hardcoded
   als SPs sp_load_client_attributes i sp_load_product_attributes.

   Aquesta taula (cfg.attribute_mapping) es manté per si en el futur cal
   afegir atributs opcionals addicionals que Analitza pugui llegir sota
   demanda, però ARA MATEIX no s'utilitza. Netegem qualsevol contingut
   que hi hagués del disseny anterior (LONG).
   ========================================================================= */
USE IntercanviSAP;
GO

DELETE FROM cfg.attribute_mapping;
GO
