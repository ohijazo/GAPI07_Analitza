# Draft resposta a Sistemes — Integració Analitza CM ↔ SAP B1

**Assumpte:** RE: Integració Analitza CM ↔ SAP B1 — confirmacions i punt SMTP

---

Hola,

Perfecte, gràcies per les respostes ràpides. Confirmo els punts i us aclareixo el 6:

## Punt 1 — VPN per Analitza
Rebut. Us donaré la IP concreta d'Analitza tan bon punt em contesti el seu CTO (Adrià Arnau, ja l'he escrit avui). Un cop la tingui, us envio un correu curt amb la petició formal:

- **Origen:** IP d'Analitza (pendent)
- **Destinació:** `AE01SAPSQL` (192.168.254.x segons vosaltres)
- **Port:** 1433/TCP
- **Login:** `analitza_ro` (SQL auth, ja creat a `IntercanviSAP` amb `db_datareader` i `DENY CONNECT` a la resta de BD del servidor)

## Punt 2 — Firewall / port 1433
OK amb la IP de la subxarxa `192.168.254.x` per VPN.

## Punt 3 — Backup
Amb el backup complet de la VM ja n'hi ha prou. **No cal activar backup intern addicional** a `IntercanviSAP`: la BD es regenera cada nit des de SAP (recovery model SIMPLE), i el backup de la VM ens permet restauració granular si mai cal. Ho deixem així.

## Punt 6 — Database Mail / SMTP

Aquí cal aclarir una cosa tècnica: **Database Mail del SQL Server només suporta SMTP AUTH bàsica** (usuari + contrasenya). No suporta autenticació moderna via *client secret* / OAuth2 (que és el que jo entenc per "secret id"), perquè és una funcionalitat que Microsoft mai va afegir al motor SMTP intern del SQL Server.

Per tant, les opcions realistes són:

1. **(Preferida) Un mailbox de servei M365 tipus `sql-alerts@agrienergia.com`** (o el nom que preferiu) amb:
   - **SMTP AUTH habilitat** al mailbox (per defecte està desactivat al tenant per política)
   - **App Password** generada des del propi mailbox (si té MFA)
   - Ús exclusiu per notificacions automàtiques de SQL Server (i altres serveis interns que puguin necessitar-ho en el futur)
   - Avantatge: les alertes surten d'una adreça institucional, no del meu compte personal
   
2. **Relay SMTP intern anònim** (si en tenim algun servidor SMTP local que accepti relay des de la subnet de servidors). No requereix credencials. Si teniu això muntat, seria encara més net que l'opció 1.

3. **(Fallback provisional)** Fer-ho amb el meu compte + App Password fins que decidiu 1 o 2. Ho puc canviar més endavant sense downtime.

Si podeu prioritzar l'opció 1 (crear el mailbox de servei), millor. Digueu-me si necessiteu aprovació de nivell superior per crear-lo, o si preferiu que faci servir provisionalment el meu compte.

## Punts 4, 5, 7
OK, no cal cap acció per la vostra banda.

Gràcies,
Oscar
