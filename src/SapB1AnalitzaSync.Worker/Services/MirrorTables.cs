using System.Data;
using SapB1AnalitzaSync.Shared.Configuration;
using SapB1AnalitzaSync.Shared.ServiceLayer;

namespace SapB1AnalitzaSync.Worker.Services;

/// <summary>
/// Converteix les files de Service Layer en <see cref="DataTable"/> amb la
/// forma exacta de les taules de <c>sap_raw</c>.
///
/// Els noms de columna han de coincidir literalment amb el DDL de
/// <c>sql/schema/02_create_sap_raw.sql</c>: SqlBulkCopy els mapeja per nom i,
/// si no quadren, falla en temps d'execució i no de compilació.
///
/// <c>_synced_at</c> no s'hi posa a propòsit: no ve mapejada i SQL Server hi
/// aplica el DEFAULT.
/// </summary>
internal static class MirrorTables
{
    // ---------------- Mestres ----------------

    public static DataTable NewOcrd()
    {
        var dt = new DataTable();
        dt.Columns.Add("CardCode", typeof(string));
        dt.Columns.Add("CardName", typeof(string));
        dt.Columns.Add("CardType", typeof(string));
        dt.Columns.Add("validFor", typeof(string));
        dt.Columns.Add("frozenFor", typeof(string));
        dt.Columns.Add("Address", typeof(string));
        dt.Columns.Add("City", typeof(string));
        dt.Columns.Add("ZipCode", typeof(string));
        dt.Columns.Add("Country", typeof(string));
        dt.Columns.Add("SlpCode", typeof(short));
        dt.Columns.Add("PymCode", typeof(string));
        dt.Columns.Add("Phone1", typeof(string));
        dt.Columns.Add("E_Mail", typeof(string));
        dt.Columns.Add("U_SEIPOSBC", typeof(string));
        dt.Columns.Add("U_SEISEGH1", typeof(string));
        dt.Columns.Add("U_SEISEGH2", typeof(string));
        dt.Columns.Add("UpdateDate", typeof(DateTime));
        return dt;
    }

    public static void AddOcrd(DataTable dt, PartnerRow r) => dt.Rows.Add(
        r.CardCode,
        Val(r.CardName),
        Val(SapEnums.CardType(r.CardType)),
        Val(SapEnums.YesNo(r.Valid)),
        Val(SapEnums.YesNo(r.Frozen)),
        Val(r.Address),
        Val(r.City),
        Val(r.ZipCode),
        Val(r.Country),
        r.SalesPersonCode is null ? DBNull.Value : (short)r.SalesPersonCode.Value,
        Val(r.PeymentMethodCode),
        Val(r.Phone1),
        Val(r.EmailAddress),
        Val(r.U_SEIPOSBC),
        Val(r.U_SEISEGH1),
        Val(r.U_SEISEGH2),
        Val(r.UpdateDate));

    public static DataTable NewCrd1()
    {
        var dt = new DataTable();
        dt.Columns.Add("CardCode", typeof(string));
        dt.Columns.Add("LineNum", typeof(int));
        dt.Columns.Add("Address", typeof(string));
        dt.Columns.Add("Street", typeof(string));
        dt.Columns.Add("StreetNo", typeof(string));
        dt.Columns.Add("Building", typeof(string));
        dt.Columns.Add("City", typeof(string));
        dt.Columns.Add("ZipCode", typeof(string));
        dt.Columns.Add("Country", typeof(string));
        dt.Columns.Add("AdresType", typeof(string));
        dt.Columns.Add("U_SEIZONAC", typeof(string));
        return dt;
    }

    public static void AddCrd1(DataTable dt, string cardCode, BPAddressRow a) => dt.Rows.Add(
        cardCode,
        a.RowNum ?? 0,
        Val(a.AddressName),
        Val(a.Street),
        Val(a.StreetNo),
        Val(a.BuildingFloorRoom),
        Val(a.City),
        Val(a.ZipCode),
        Val(a.Country),
        Val(SapEnums.AddressType(a.AddressType)),
        Val(a.U_SEIZONAC));

    public static DataTable NewOitm()
    {
        var dt = new DataTable();
        dt.Columns.Add("ItemCode", typeof(string));
        dt.Columns.Add("ItemName", typeof(string));
        dt.Columns.Add("ItmsGrpCod", typeof(short));
        dt.Columns.Add("validFor", typeof(string));
        dt.Columns.Add("frozenFor", typeof(string));
        dt.Columns.Add("SalUnitMsr", typeof(string));
        dt.Columns.Add("U_SEISubFamCialCat", typeof(string));
        dt.Columns.Add("UpdateDate", typeof(DateTime));
        return dt;
    }

    public static void AddOitm(DataTable dt, ItemRow r) => dt.Rows.Add(
        r.ItemCode,
        Val(r.ItemName),
        r.ItemsGroupCode is null ? DBNull.Value : (short)r.ItemsGroupCode.Value,
        Val(SapEnums.YesNo(r.Valid)),
        Val(SapEnums.YesNo(r.Frozen)),
        Val(r.SalesUnit),
        Val(r.U_SEISubFamCialCat),
        Val(r.UpdateDate));

    public static DataTable NewOitb()
    {
        var dt = new DataTable();
        dt.Columns.Add("ItmsGrpCod", typeof(short));
        dt.Columns.Add("ItmsGrpNam", typeof(string));
        return dt;
    }

    public static void AddOitb(DataTable dt, ItemGroupRow r) => dt.Rows.Add(
        (short)(r.Number ?? 0), Val(r.GroupName));

    public static DataTable NewOslp()
    {
        var dt = new DataTable();
        dt.Columns.Add("SlpCode", typeof(short));
        dt.Columns.Add("SlpName", typeof(string));
        return dt;
    }

    public static void AddOslp(DataTable dt, SalesPersonRow r) => dt.Rows.Add(
        (short)(r.SalesEmployeeCode ?? 0), Val(r.SalesEmployeeName));

    public static DataTable NewOpym()
    {
        var dt = new DataTable();
        dt.Columns.Add("PayMethCod", typeof(string));
        dt.Columns.Add("Descript", typeof(string));
        return dt;
    }

    public static void AddOpym(DataTable dt, PaymentMethodRow r) => dt.Rows.Add(
        r.PaymentMethodCode, Val(r.Description));

    // ---------------- Documents de venda ----------------

    public static DataTable NewSalesHeader()
    {
        var dt = new DataTable();
        dt.Columns.Add("DocEntry", typeof(int));
        dt.Columns.Add("DocNum", typeof(int));
        dt.Columns.Add("DocDate", typeof(DateTime));
        dt.Columns.Add("CardCode", typeof(string));
        dt.Columns.Add("ShipToCode", typeof(string));
        dt.Columns.Add("DiscPrcnt", typeof(decimal));
        dt.Columns.Add("DiscSum", typeof(decimal));
        dt.Columns.Add("DocTotal", typeof(decimal));
        dt.Columns.Add("VatSum", typeof(decimal));
        dt.Columns.Add("Series", typeof(int));
        dt.Columns.Add("Comments", typeof(string));
        dt.Columns.Add("CancelStatus", typeof(string));
        dt.Columns.Add("UpdateDate", typeof(DateTime));
        dt.Columns.Add("UpdateTime", typeof(TimeSpan));
        return dt;
    }

    public static void AddSalesHeader(DataTable dt, DocumentRow r) => dt.Rows.Add(
        r.DocEntry ?? 0,
        Val(r.DocNum),
        Val(r.DocDate),
        Val(r.CardCode),
        Val(r.ShipToCode),
        Dec(r.DiscountPercent),
        Dec(r.TotalDiscount),
        Dec(r.DocTotal),
        Dec(r.VatSum),
        Val(r.Series),
        Val(r.Comments),
        Val(r.CancelStatus),
        Val(r.UpdateDate),
        r.UpdateTime is null ? DBNull.Value : SapEnums.ParseTime(r.UpdateTime));

    public static DataTable NewSalesLine()
    {
        var dt = new DataTable();
        dt.Columns.Add("DocEntry", typeof(int));
        dt.Columns.Add("LineNum", typeof(int));
        dt.Columns.Add("ItemCode", typeof(string));
        dt.Columns.Add("Quantity", typeof(decimal));
        dt.Columns.Add("PriceBefDi", typeof(decimal));
        dt.Columns.Add("StockPrice", typeof(decimal));
        dt.Columns.Add("DiscPrcnt", typeof(decimal));
        dt.Columns.Add("LineType", typeof(string));
        return dt;
    }

    public static void AddSalesLine(DataTable dt, int docEntry, DocumentLineRow l, SyncOptions sync) => dt.Rows.Add(
        docEntry,
        l.LineNum ?? 0,
        Val(l.ItemCode),
        Dec(l.Quantity),
        Dec(SelectPrice(l, sync.PriceField)),
        Dec(SelectCost(l, sync.CostField)),
        Dec(l.DiscountPercent),
        Val(SapEnums.LineType(l.LineType)));

    /// <summary>Quina propietat de SL fa de PriceBefDi. Ho fixa la Fase 0.</summary>
    public static double? SelectPrice(DocumentLineRow l, string field) => field switch
    {
        "Price" => l.Price,
        _       => l.UnitPrice,
    };

    /// <summary>Quina propietat de SL fa de StockPrice, o cap. Ho fixa la Fase 0.</summary>
    public static double? SelectCost(DocumentLineRow l, string field) => field switch
    {
        "GrossBuyPrice" => l.GrossBuyPrice,
        "none"          => null,
        _               => l.StockInmPrice,
    };

    // ---------------- Factures ----------------

    public static DataTable NewInvoiceHeader()
    {
        var dt = new DataTable();
        dt.Columns.Add("DocEntry", typeof(int));
        dt.Columns.Add("DocNum", typeof(int));
        dt.Columns.Add("DocDate", typeof(DateTime));
        dt.Columns.Add("DocDueDate", typeof(DateTime));
        dt.Columns.Add("CardCode", typeof(string));
        dt.Columns.Add("ShipToCode", typeof(string));
        dt.Columns.Add("DocTotal", typeof(decimal));
        dt.Columns.Add("PaidToDate", typeof(decimal));
        dt.Columns.Add("DocStatus", typeof(string));
        dt.Columns.Add("PeyMethod", typeof(string));
        dt.Columns.Add("CancelStatus", typeof(string));
        dt.Columns.Add("UpdateDate", typeof(DateTime));
        dt.Columns.Add("UpdateTime", typeof(TimeSpan));
        return dt;
    }

    public static void AddInvoiceHeader(DataTable dt, DocumentRow r) => dt.Rows.Add(
        r.DocEntry ?? 0,
        Val(r.DocNum),
        Val(r.DocDate),
        Val(r.DocDueDate),
        Val(r.CardCode),
        Val(r.ShipToCode),
        Dec(r.DocTotal),
        Dec(r.PaidToDate),
        Val(SapEnums.DocumentStatus(r.DocumentStatus)),
        Val(r.PaymentMethod),
        Val(r.CancelStatus),
        Val(r.UpdateDate),
        r.UpdateTime is null ? DBNull.Value : SapEnums.ParseTime(r.UpdateTime));

    // ---------------- helpers ----------------

    private static object Val(string? s) => string.IsNullOrEmpty(s) ? DBNull.Value : s;
    private static object Val(int? v) => v is null ? DBNull.Value : v.Value;
    private static object Val(DateTime? v) => v is null ? DBNull.Value : v.Value;

    /// <summary>
    /// SL serialitza els imports com a Edm.Double. Es passen a decimal per no
    /// arrossegar error binari fins a les columnes numeric(19,6) del mirall.
    /// </summary>
    private static object Dec(double? v) => v is null ? DBNull.Value : (decimal)Math.Round(v.Value, 6, MidpointRounding.AwayFromZero);
}
