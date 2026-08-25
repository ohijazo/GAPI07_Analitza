namespace SapB1AnalitzaSync.Shared.ServiceLayer;

/// <summary>
/// Tradueix els enums de Service Layer a la forma nativa de les taules de SAP.
///
/// El mirall <c>sap_raw</c> guarda 'Y'/'N', 'C', 'S', 'O', 'T'... i no
/// "tYES"/"cCustomer"/"bo_ShipTo", perquè els stored procedures de l'ETL ja
/// estaven escrits i validats contra la forma nativa. Concentrar aquí la
/// traducció fa que els SPs no s'hagin d'assabentar que l'origen ha canviat.
///
/// Tot el que no reconeixem retorna null en comptes d'endevinar: val més una
/// columna buida que un valor inventat que passi els checks de qualitat.
/// </summary>
public static class SapEnums
{
    /// <summary>BoYesNoEnum ("tYES"/"tNO") → 'Y'/'N', com validFor i frozenFor.</summary>
    public static string? YesNo(string? slValue) => slValue switch
    {
        "tYES" => "Y",
        "tNO"  => "N",
        _      => null,
    };

    /// <summary>BoCardTypes → OCRD.CardType.</summary>
    public static string? CardType(string? slValue) => slValue switch
    {
        "cCustomer" => "C",
        "cSupplier" => "S",
        "cLid"      => "L",   // lead
        _           => null,
    };

    /// <summary>BoAddressType → CRD1.AdresType.</summary>
    public static string? AddressType(string? slValue) => slValue switch
    {
        "bo_ShipTo" => "S",
        "bo_BillTo" => "B",
        _           => null,
    };

    /// <summary>BoStatus → OINV.DocStatus. 'O' = oberta, 'C' = tancada.</summary>
    public static string? DocumentStatus(string? slValue) => slValue switch
    {
        "bost_Open"  => "O",
        "bost_Close" => "C",
        "bost_Paid"  => "C",
        "bost_Delivered" => "C",
        _            => null,
    };

    /// <summary>
    /// BoDocLineType → DLN1.LineType. Els SPs filtren amb <c>LineType &lt;&gt; 'T'</c>.
    ///
    /// ATENCIÓ, aquí NO val la regla de "si no ho reconec, retorno null" que
    /// segueix la resta d'aquest fitxer. A SAP una línia normal té cadena
    /// buida, no NULL, i <c>NULL &lt;&gt; 'T'</c> no és cert sinó desconegut: si
    /// retornéssim null, el filtre descartaria TOTES les línies i
    /// est_linies_albara quedaria buida. I quedaria buida en silenci, perquè
    /// amb la taula buida no hi ha orfes i el check de volum tampoc salta.
    /// Va passar el 25/08/2026.
    ///
    /// Regla general: un camp que s'utilitza dins d'un predicat no pot tenir
    /// NULL com a valor per defecte.
    /// </summary>
    public static string LineType(string? slValue) => slValue switch
    {
        "dlt_Comment" => "T",
        "dlt_Text"    => "T",
        _             => "",   // línia normal: a SAP és cadena buida
    };

    /// <summary>
    /// SL serialitza Edm.Time com a durada ISO 8601 ("PT10H23M45S") o com a
    /// "HH:mm:ss" segons la versio; acceptem les dues i no petem amb res mes.
    /// </summary>
    public static TimeSpan ParseTime(string? s)
    {
        if (string.IsNullOrEmpty(s)) return TimeSpan.Zero;
        if (s.StartsWith("PT", StringComparison.Ordinal))
        {
            try { return System.Xml.XmlConvert.ToTimeSpan(s); }
            catch (FormatException) { return TimeSpan.Zero; }
        }
        return TimeSpan.TryParse(s, out var t) ? t : TimeSpan.Zero;
    }
}
