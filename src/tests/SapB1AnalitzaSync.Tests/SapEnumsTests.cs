using SapB1AnalitzaSync.Shared.ServiceLayer;

namespace SapB1AnalitzaSync.Tests;

/// <summary>
/// La traducció d'enums és l'única cosa que separa el que diu Service Layer del
/// que esperen els stored procedures de l'ETL. Si aquí es cola un valor
/// equivocat, els SPs no peten: simplement deixen de trobar files (per exemple,
/// cap client amb CardType='C') i l'ETL carrega una taula buida.
/// </summary>
public class SapEnumsTests
{
    [Theory]
    [InlineData("tYES", "Y")]
    [InlineData("tNO", "N")]
    public void YesNo_tradueix_els_valors_coneguts(string sl, string expected) =>
        Assert.Equal(expected, SapEnums.YesNo(sl));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("tYes")]     // SL no escriu això, però si ho fes no volem endevinar
    public void YesNo_retorna_null_si_no_el_reconeix(string? sl) =>
        Assert.Null(SapEnums.YesNo(sl));

    [Fact]
    public void CardType_de_client_es_C()
    {
        Assert.Equal("C", SapEnums.CardType("cCustomer"));
        Assert.Equal("S", SapEnums.CardType("cSupplier"));
        Assert.Null(SapEnums.CardType("qualsevol"));
    }

    [Fact]
    public void AddressType_de_ship_to_es_S()
    {
        Assert.Equal("S", SapEnums.AddressType("bo_ShipTo"));
        Assert.Equal("B", SapEnums.AddressType("bo_BillTo"));
    }

    [Fact]
    public void DocumentStatus_obert_es_O()
    {
        Assert.Equal("O", SapEnums.DocumentStatus("bost_Open"));
        Assert.Equal("C", SapEnums.DocumentStatus("bost_Close"));
    }

    /// <summary>
    /// Els SPs filtren LineType &lt;&gt; 'T'. Només les línies de comentari són
    /// 'T'; una línia normal ha de donar null i no una lletra qualsevol, o el
    /// filtre deixaria passar comentaris o descartaria vendes.
    /// </summary>
    [Fact]
    public void LineType_nomes_marca_els_comentaris()
    {
        Assert.Equal("T", SapEnums.LineType("dlt_Comment"));
        Assert.Null(SapEnums.LineType("dlt_Regular"));
        Assert.Null(SapEnums.LineType(null));
    }

    [Theory]
    [InlineData("PT10H23M45S", 10, 23, 45)]
    [InlineData("10:23:45", 10, 23, 45)]
    public void ParseTime_accepta_les_dues_formes_dedm_time(string input, int h, int m, int s) =>
        Assert.Equal(new TimeSpan(h, m, s), SapEnums.ParseTime(input));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("no-es-una-hora")]
    public void ParseTime_no_peta_amb_brossa(string? input) =>
        Assert.Equal(TimeSpan.Zero, SapEnums.ParseTime(input));
}
