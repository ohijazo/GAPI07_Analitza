using System.Text.Json.Serialization;

namespace SapB1AnalitzaSync.Shared.ServiceLayer;

/// <summary>
/// Pàgina d'una col·lecció OData. El nom de la propietat del següent enllaç
/// canvia entre versions de Service Layer: v1 (OData v3) l'escriu
/// "odata.nextLink" i algunes builds "@odata.nextLink". Mirem les dues.
/// </summary>
public sealed class ODataPage<T>
{
    [JsonPropertyName("value")]           public List<T>? Value { get; set; }
    [JsonPropertyName("odata.nextLink")]  public string? NextLink { get; set; }
    [JsonPropertyName("@odata.nextLink")] public string? NextLinkV4 { get; set; }

    public string? ResolveNextLink() => NextLink ?? NextLinkV4;
}

public sealed class PartnerRow
{
    public string? CardCode { get; set; }
    public string? CardName { get; set; }
    public string? CardType { get; set; }
    public string? Valid { get; set; }
    public string? Frozen { get; set; }
    public string? Address { get; set; }
    public string? City { get; set; }
    public string? ZipCode { get; set; }
    public string? Country { get; set; }
    public int? SalesPersonCode { get; set; }
    public string? PeymentMethodCode { get; set; }
    public string? Phone1 { get; set; }
    public string? EmailAddress { get; set; }
    public string? U_SEIPOSBC { get; set; }
    public string? U_SEISEGH1 { get; set; }
    public string? U_SEISEGH2 { get; set; }
    public DateTime? UpdateDate { get; set; }
    public List<BPAddressRow>? BPAddresses { get; set; }

    /// <summary>"Codi enllac": candidat descartat a portar el codi de client de KAIS (nomes 10 de 500).</summary>
    public string? U_SEICodienllac { get; set; }

    /// <summary>Codi del client a KAIS. Creat el 26/08/2026; s'omple abans de l'1 de novembre.</summary>
    public string? U_FCCodiKais { get; set; }

    /// <summary>CardCode del successor per canvi de rao social. Creat el 26/08/2026.</summary>
    public string? U_FCNewCardCode { get; set; }
}

/// <summary>
/// Una adreça del client. <see cref="RowNum"/> és el candidat a CRD1.LineNum,
/// i per tant a la meitat de id_client_location: la Fase 0 ho verifica contra
/// baseline.est_clients abans de donar-ho per bo (Regla 04).
/// </summary>
public sealed class BPAddressRow
{
    public int? RowNum { get; set; }
    public string? AddressName { get; set; }
    public string? Street { get; set; }
    public string? StreetNo { get; set; }
    public string? BuildingFloorRoom { get; set; }
    public string? City { get; set; }
    public string? ZipCode { get; set; }
    public string? Country { get; set; }
    public string? AddressType { get; set; }
    public string? U_SEIZONAC { get; set; }
}

public sealed class ItemRow
{
    public string? ItemCode { get; set; }
    public string? ItemName { get; set; }
    public int? ItemsGroupCode { get; set; }
    public string? Valid { get; set; }
    public string? Frozen { get; set; }
    public string? SalesUnit { get; set; }
    public string? U_SEISubFamCialCat { get; set; }
    public DateTime? UpdateDate { get; set; }
}

public sealed class ItemGroupRow
{
    public int? Number { get; set; }
    public string? GroupName { get; set; }
}

public sealed class SalesPersonRow
{
    public int? SalesEmployeeCode { get; set; }
    public string? SalesEmployeeName { get; set; }

    /// <summary>Codi del comercial a KAIS. Existeix al $metadata; la sonda mira si esta poblat.</summary>
    public string? U_FCCodiKais { get; set; }
}

public sealed class PaymentMethodRow
{
    public string? PaymentMethodCode { get; set; }
    public string? Description { get; set; }
}

/// <summary>
/// Capçalera de document de venda. DeliveryNotes, Returns, CreditNotes i
/// Invoices comparteixen EntityType (SAPB1.Document), per això un sol DTO
/// cobreix els quatre; cada consulta demana només els camps que li calen i
/// la resta arriben null.
/// </summary>
public sealed class DocumentRow
{
    public int? DocEntry { get; set; }
    public int? DocNum { get; set; }
    public DateTime? DocDate { get; set; }
    public DateTime? DocDueDate { get; set; }
    public string? CardCode { get; set; }
    public string? ShipToCode { get; set; }
    public double? DiscountPercent { get; set; }
    public double? TotalDiscount { get; set; }
    public double? DocTotal { get; set; }
    public double? VatSum { get; set; }
    public double? PaidToDate { get; set; }
    public string? DocumentStatus { get; set; }
    public string? PaymentMethod { get; set; }
    public int? Series { get; set; }
    public string? Comments { get; set; }
    public string? CancelStatus { get; set; }
    public DateTime? UpdateDate { get; set; }
    public string? UpdateTime { get; set; }
    public List<DocumentLineRow>? DocumentLines { get; set; }
}

public sealed class DocumentLineRow
{
    public int? LineNum { get; set; }
    public string? ItemCode { get; set; }
    public double? Quantity { get; set; }

    /// <summary>Candidat a DLN1.PriceBefDi (preu abans de descompte). Ho confirma la Fase 0.</summary>
    public double? UnitPrice { get; set; }

    /// <summary>Preu ja descomptat. Es baixa només per poder comparar-lo amb UnitPrice a la sonda.</summary>
    public double? Price { get; set; }

    /// <summary>Candidat a DLN1.StockPrice (cost de la línia). Veure Fase 0, forat B2.</summary>
    public double? StockInmPrice { get; set; }

    /// <summary>L'altre candidat a cost de línia.</summary>
    public double? GrossBuyPrice { get; set; }

    public double? DiscountPercent { get; set; }
    public string? LineType { get; set; }
}
