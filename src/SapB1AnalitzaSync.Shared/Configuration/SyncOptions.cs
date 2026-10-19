namespace SapB1AnalitzaSync.Shared.Configuration;

public sealed class DatabaseOptions
{
    public const string SectionName = "Database";

    /// <summary>Connexió a IntercanviSAP amb permís d'escriptura sobre sap_raw.</summary>
    public string ConnectionString { get; set; } = string.Empty;

    public int CommandTimeoutSeconds { get; set; } = 300;

    /// <summary>Files per lot de SqlBulkCopy cap a la taula temporal.</summary>
    public int BulkBatchSize { get; set; } = 5000;
}

public sealed class SyncOptions
{
    public const string SectionName = "Sync";

    /// <summary>
    /// Dies que es resta al cursor abans de demanar a SL. Compensa que el
    /// filtre incremental només pot ser per UpdateDate i no per UpdateTime
    /// (Regla 02): un document actualitzat el mateix dia que el cursor es
    /// tornaria a llegir. El MERGE és idempotent, així que rellegir no fa mal.
    /// </summary>
    public int OverlapDays { get; set; } = 1;

    /// <summary>
    /// Data des de la qual es fa el backfill inicial de documents quan no hi ha
    /// cursor. Null = tot l'històric.
    /// </summary>
    public DateTime? BackfillFrom { get; set; }

    /// <summary>
    /// El mode --backfill l'activa. Fa que <see cref="BackfillFrom"/> mani sobre
    /// el cursor desat: sense això, un cop hi ha cursor no es podria rellegir
    /// l'historic sense esborrar sap_raw.sync_state a ma.
    /// </summary>
    public bool ForceBackfill { get; set; }

    /// <summary>
    /// Documents per lot abans d'escriure al mirall. Un lot massa gran manté
    /// molta memòria ocupada amb les línies expandides; massa petit multiplica
    /// els viatges a SQL Server.
    /// </summary>
    public int DocumentFlushSize { get; set; } = 500;

    /// <summary>
    /// Propietat de Service Layer que alimenta DLN1.PriceBefDi (preu unitari
    /// ABANS de descompte). Valors: "UnitPrice" (per defecte) o "Price".
    /// Es configurable perque la Fase 0 ho ha de confirmar contra baseline: si
    /// s'inverteix, el net_amount surt malament i cap check de qualitat ho
    /// detecta, perque queda coherent amb ell mateix (Regla 04).
    /// </summary>
    public string PriceField { get; set; } = "UnitPrice";

    /// <summary>
    /// Propietat que alimenta DLN1.StockPrice (cost de la linia). Service Layer
    /// no exposa StockPrice; els candidats son "StockInmPrice" i "GrossBuyPrice".
    /// "none" deixa el cost a NULL: product_cost es opcional a la guia
    /// d'Analitza, i val mes buit que un valor que no es el que era.
    /// Ho decideix la Fase 0 amb xifres.
    /// </summary>
    /// Per defecte "none": a 25/08/2026 sabem que cap candidat es el que era, i
    /// deixar-ho buit a proposit es preferible a deixar-ho buit per casualitat
    /// (StockInmPrice tambe dona 0, pero perque esta buit a SAP, no perque ho
    /// haguem decidit). Ho ha de tancar l'Adria.
    public string CostField { get; set; } = "none";

    /// <summary>
    /// Exportacio de client_locations que ens passa Analitza. Es l'UNIC cens
    /// dels codis de KAIS que tenim: baseline.est_* a l'entorn de test ja es
    /// sortida del pipeline apuntat a SAP, i per tant ja porta CardCodes.
    /// La sonda la fa servir per dir quins clients d'Analitza es perdrien.
    /// Cal tornar-la a demanar just abans del tall: els clients donats d'alta
    /// entre l'exportacio i el 16 de novembre no hi son.
    /// </summary>
    public string KaisClientExportPath { get; set; } = string.Empty;
}
