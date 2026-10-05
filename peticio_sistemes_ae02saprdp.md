# Petició a Sistemes — netejar AE01SAPRDP (el Worker de GAPI07 ja corre bé a AE02SAPRDP)

**Canal: Teams.** Versió del 29/09/2026.

**Nota interna (no s'envia).** La versió del 25/09 demanava dues coses i preguntava dues més. **Les
dues preguntes s'han contestat soles el 28/09 sense Sistemes**: el `schtasks /query /s AE02SAPRDP`,
que el 25/09 responia `Acceso denegado`, ara contesta. La tasca hi era, **estava desactivada** i no
havia corregut mai (`267011` = mai executada) — es va demanar registrar-la desactivada i ningú la va
activar en acabar el desplegament. Activada i llançada des de l'equip local el 28/09; el cicle
nocturn del 29/09 va córrer sol (tasca a les 02:45:01 amb resultat `0`, run 157 `SUCCESS`). I això
contesta també la pregunta del *Log on as a batch job*: si faltés, hauria tornat `0x4`.

**O sigui que només queda el punt 3**, que és feina a la màquina vella. Detall a
`docs/memoria_projecte.md`, §9, *Resolt el 28/09/2026*.

---

Hola,

La integració de SAP cap a Analitza (GAPI07) ja torna a córrer sola a `AE02SAPRDP`: la tasca
`GAPI07 Refresca sap_raw` va executar-se ahir a la nit a les 02:45 i el procés de les 03:00 va
publicar les dades correctament. **No us cal fer res d'això**, i gràcies per deixar-ho tot preparat
—carpeta, permisos i sortida cap a la base de dades hi eren i funcionaven—.

El que havia passat, per si us serveix: la tasca la vau registrar **desactivada**, tal com us vam
demanar per no fer-la fallar abans que hi hagués els programes. Quan els vaig copiar, **no la vaig
tornar a activar**: era el pas que ens faltava als dos. Ja està activada.

**L'únic que us demano és netejar la màquina vella, `AE01SAPRDP`:**

1. **Desactivar o esborrar la tasca `GAPI07 Refresca sap_raw`.** Ja no ha de córrer allà, i si les
   dues màquines la corren es trepitgen.
2. **Esborrar `C:\Apps\SapB1AnalitzaSync\appsettings.Production.json`.** Té credencials a dins i ja
   no fa cap feina. Si preferiu, ho faig jo, que hi tinc accés — digueu-m'ho.

I un detall menor, per quan tingueu un moment i sense pressa: a `AE02SAPRDP`, els permisos de
`C:\Apps\SapB1AnalitzaSync` venen heretats de `C:\Apps` i `sapsistema` hi té control total. Amb
lectura i execució n'hi hauria prou, i així el compte que executa el programa no el pot modificar.
Ara mateix no és cap problema; només que si algun dia s'afegeix alguna cosa als permisos de
`C:\Apps`, baixarà aquí sola.

Gràcies,
Oscar Hijazo
ohijazo@agrienergia.com
