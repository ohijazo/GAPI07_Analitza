using System.Text;

namespace SapB1AnalitzaSync.Shared.ServiceLayer;

/// <summary>
/// Construeix les consultes OData contra SAP B1 Service Layer.
///
/// REGLA QUE NO ES POT TRENCAR (Regla 02): aquí NO s'emet mai <c>$top</c>.
/// A OData, <c>$top=N</c> limita els registres retornats sumant TOTES les
/// pàgines del <c>odata.nextLink</c>, no per pàgina. A GAPI03_CRM això va fer
/// que una reconciliació amb <c>$top=500</c> sobre 857 clients desactivés 357
/// clients cada dia en silenci. La mida de pàgina es controla exclusivament
/// amb la capçalera <c>Prefer: odata.maxpagesize</c>, i es pagina seguint el
/// <c>odata.nextLink</c> fins a esgotar-lo.
///
/// El filtre incremental és només per <c>UpdateDate</c> (Edm.DateTime): SL
/// 10.0 FP 2602 rebutja el literal <c>time'...'</c> a <c>$filter</c>. Es
/// compensa amb un overlap de dies al cursor; l'escriptura al mirall és un
/// MERGE idempotent, així que rellegir de més no fa cap mal.
///
/// I aquí NO s'emet mai <c>$expand</c>. A Service Layer v1, <c>BPAddresses</c> i
/// <c>DocumentLines</c> són col·leccions de tipus COMPLEX, no propietats de
/// navegació: expandir-les respon
/// <c>400 — Cannot expand invalid navigation property</c>. Vénen incloses en el
/// cos de l'entitat, i n'hi ha prou de nomenar-les al <c>$select</c>.
/// </summary>
public static class ODataQueryBuilder
{
    // ---- Mestres: cens complet, sense filtre de data ------------------------

    public static readonly string[] PartnerFields =
    {
        "CardCode", "CardName", "CardType", "Valid", "Frozen",
        "Address", "City", "ZipCode", "Country",
        "SalesPersonCode", "PeymentMethodCode", "Phone1", "EmailAddress",
        "U_SEIPOSBC", "U_SEISEGH1", "U_SEISEGH2", "UpdateDate",
        // Continuitat amb KAIS (Regla 04): el codi antic mana sobre el CardCode
        // a l'hora d'emetre id_client_location, i U_FCNewCardCode porta el
        // successor quan un client canvia de rao social.
        "U_FCCodiKais", "U_FCNewCardCode",
    };

    public static readonly string[] ItemFields =
    {
        "ItemCode", "ItemName", "ItemsGroupCode", "Valid", "Frozen",
        "SalesUnit", "U_SEIFamCialCat", "U_SEISubFamCialCat", "UpdateDate",
    };

    /// <summary>
    /// Clients amb les seves adreces. A SAP les adreces són CRD1, i el seu
    /// RowNum és el que forma id_client_location (Regla 04).
    /// </summary>
    public static string BuildCustomersWithAddresses()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", string.Join(",", PartnerFields) + ",BPAddresses");
        q.Append("$filter", "CardType eq 'cCustomer'");
        q.Append("$orderby", "CardCode");
        return "BusinessPartners?" + q;
    }

    /// <summary>
    /// Variant sense <c>$select</c>, per si alguna build de SL no accepta
    /// nomenar la col·lecció complexa al select. Retorna moltes més columnes de
    /// les que necessitem, però funciona sempre. El client hi cau
    /// automàticament davant d'un HTTP 400.
    /// </summary>
    public static string BuildCustomersWithAddressesFallback()
    {
        var q = new QueryStringBuilder();
        q.Append("$filter", "CardType eq 'cCustomer'");
        q.Append("$orderby", "CardCode");
        return "BusinessPartners?" + q;
    }

    public static string BuildItems()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", string.Join(",", ItemFields));
        q.Append("$orderby", "ItemCode");
        return "Items?" + q;
    }

    public static string BuildItemGroups()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", "Number,GroupName,U_FCCodiKais");
        q.Append("$orderby", "Number");
        return "ItemGroups?" + q;
    }

    public static string BuildSalesPersons()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", "SalesEmployeeCode,SalesEmployeeName,U_FCCodiKais");
        q.Append("$orderby", "SalesEmployeeCode");
        return "SalesPersons?" + q;
    }

    /// <summary>OPYM. A Service Layer l'entitat es diu WizardPaymentMethods.</summary>
    public static string BuildPaymentMethods()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", "PaymentMethodCode,Description");
        q.Append("$orderby", "PaymentMethodCode");
        return "WizardPaymentMethods?" + q;
    }

    // ---- Sonda de codis heretats de KAIS ------------------------------------
    //
    // Analitza construeix el seu historic sobre els IDs que li arribaven de KAIS.
    // Al cutover, els IDs passen a ser els de SAP. Aquestes consultes serveixen
    // per respondre amb dades si els codis es van preservar o no.

    public static string BuildSalesPersonsWithKaisCode()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", "SalesEmployeeCode,SalesEmployeeName,U_FCCodiKais");
        q.Append("$orderby", "SalesEmployeeCode");
        return "SalesPersons?" + q;
    }

    public static string BuildCustomersWithLinkCode()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", "CardCode,CardName,Valid,U_SEICodienllac,U_FCCodiKais,U_FCNewCardCode");
        q.Append("$filter", "CardType eq 'cCustomer'");
        q.Append("$orderby", "CardCode");
        return "BusinessPartners?" + q;
    }

    /// <summary>
    /// Sense els UDFs creats el 26/08/2026. Service Layer es cacheja les
    /// metadades: fins que no se li reinicia el servei, demanar un UDF acabat
    /// de crear respon 400 "Property ... is invalid".
    /// </summary>
    public static string BuildCustomersWithLinkCodeFallback()
    {
        var q = new QueryStringBuilder();
        q.Append("$select", "CardCode,CardName,Valid,U_SEICodienllac");
        q.Append("$filter", "CardType eq 'cCustomer'");
        q.Append("$orderby", "CardCode");
        return "BusinessPartners?" + q;
    }

    // ---- Documents: incremental per UpdateDate ------------------------------

    public static readonly string[] SalesDocHeaderFields =
    {
        "DocEntry", "DocNum", "DocDate", "CardCode", "ShipToCode",
        "DiscountPercent", "TotalDiscount", "DocTotal", "VatSum",
        "Series", "Comments", "CancelStatus", "UpdateDate", "UpdateTime",
    };

    public static readonly string[] InvoiceHeaderFields =
    {
        "DocEntry", "DocNum", "DocDate", "DocDueDate", "CardCode", "ShipToCode",
        "DocTotal", "PaidToDate", "DocumentStatus", "PaymentMethod",
        "CancelStatus", "UpdateDate", "UpdateTime",
    };

    /// <summary>
    /// Albarans / devolucions / abonaments amb les seves línies.
    /// <paramref name="entitySet"/> és DeliveryNotes, Returns o CreditNotes:
    /// les tres són el mateix EntityType (SAPB1.Document) a Service Layer.
    /// </summary>
    public static string BuildSalesDocuments(string entitySet, DateTime? updatedSince)
    {
        var q = new QueryStringBuilder();
        q.Append("$select", string.Join(",", SalesDocHeaderFields) + ",DocumentLines");
        AppendUpdatedSince(q, updatedSince);
        q.Append("$orderby", "UpdateDate,UpdateTime,DocEntry");
        return entitySet + "?" + q;
    }

    public static string BuildSalesDocumentsFallback(string entitySet, DateTime? updatedSince)
    {
        var q = new QueryStringBuilder();
        AppendUpdatedSince(q, updatedSince);
        q.Append("$orderby", "UpdateDate,UpdateTime,DocEntry");
        return entitySet + "?" + q;
    }

    /// <summary>
    /// Factures de client, per als efectes pendents. No calen les línies: només
    /// el saldo i el venciment.
    /// </summary>
    public static string BuildInvoices(DateTime? updatedSince)
    {
        var q = new QueryStringBuilder();
        q.Append("$select", string.Join(",", InvoiceHeaderFields));
        AppendUpdatedSince(q, updatedSince);
        q.Append("$orderby", "UpdateDate,UpdateTime,DocEntry");
        return "Invoices?" + q;
    }

    // ---- internals ---------------------------------------------------------

    private static void AppendUpdatedSince(QueryStringBuilder q, DateTime? updatedSince)
    {
        // $filter buit retorna HTTP 400: si no hi ha cursor, no s'emet la clau.
        if (updatedSince is null) return;
        q.Append("$filter", $"UpdateDate ge {FormatDateTimeLiteral(updatedSince.Value)}");
    }

    /// <summary>OData v3: datetime'yyyy-MM-ddTHH:mm:ss'. SL accepta aquest literal.</summary>
    public static string FormatDateTimeLiteral(DateTime value) =>
        $"datetime'{value:yyyy-MM-dd}T00:00:00'";

    /// <summary>Literal de cadena OData: les cometes simples es dupliquen.</summary>
    public static string Escape(string s) => s.Replace("'", "''");

    private sealed class QueryStringBuilder
    {
        private readonly StringBuilder _sb = new();

        public void Append(string key, string value)
        {
            if (_sb.Length > 0) _sb.Append('&');
            _sb.Append(key).Append('=').Append(Uri.EscapeDataString(value));
        }

        public override string ToString() => _sb.ToString();
    }
}
