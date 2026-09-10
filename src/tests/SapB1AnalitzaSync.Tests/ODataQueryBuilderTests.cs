using SapB1AnalitzaSync.Shared.ServiceLayer;

namespace SapB1AnalitzaSync.Tests;

public class ODataQueryBuilderTests
{
    /// <summary>
    /// REGRESSIÓ. A GAPI03_CRM, un $top=500 en una consulta de cens sobre 857
    /// clients actius va fer que 357 clients es desactivessin en silenci cada
    /// dia: $top limita el TOTAL sumant totes les pàgines, no la mida de
    /// pàgina. Aquí no s'emet mai; la paginació va per Prefer: odata.maxpagesize
    /// i odata.nextLink. Si algú el reintrodueix, aquest test ha de petar.
    /// </summary>
    /// NOTA: s'assereix sobre "$top" i no sobre "%24top". QueryStringBuilder
    /// escapa NOMES el valor, no la clau, aixi que les claus surten literals a
    /// la URL. Fins al 26/08/2026 aquests tres guardians buscaven "%24..." i
    /// per tant no podien fallar mai: donaven per bo qualsevol query.
    [Fact]
    public void Cap_consulta_emet_top()
    {
        foreach (var url in AllQueries())
            Assert.DoesNotContain("$top", url, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Un $filter buit fa que Service Layer retorni HTTP 400.</summary>
    [Fact]
    public void Sense_cursor_no_semet_filter()
    {
        var url = ODataQueryBuilder.BuildSalesDocuments("DeliveryNotes", null);
        Assert.DoesNotContain("$filter", url, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Amb_cursor_semet_filter_per_updatedate()
    {
        var url = ODataQueryBuilder.BuildSalesDocuments("DeliveryNotes", new DateTime(2026, 3, 14));
        var decoded = Uri.UnescapeDataString(url);
        Assert.Contains("UpdateDate ge datetime'2026-03-14T00:00:00'", decoded);
    }

    /// <summary>
    /// SL 10.0 FP 2602 rebutja el literal time'...' a $filter: el cursor només
    /// pot filtrar per UpdateDate. UpdateTime sí que val a $orderby.
    /// </summary>
    [Fact]
    public void El_filtre_no_usa_updatetime()
    {
        var decoded = Uri.UnescapeDataString(ODataQueryBuilder.BuildSalesDocuments("Returns", new DateTime(2026, 1, 1)));
        var filter = decoded.Split("$filter=")[1].Split('&')[0];
        Assert.DoesNotContain("UpdateTime", filter);
        Assert.Contains("UpdateTime", decoded.Split("$orderby=")[1]);
    }

    [Fact]
    public void Els_clients_demanen_les_adreces_al_select()
    {
        var decoded = Uri.UnescapeDataString(ODataQueryBuilder.BuildCustomersWithAddresses());
        Assert.Contains("BPAddresses", decoded);
        Assert.Contains("CardType eq 'cCustomer'", decoded);
    }

    /// <summary>
    /// REGRESSIO. A SL v1, BPAddresses i DocumentLines son col.leccions de tipus
    /// COMPLEX, no propietats de navegacio. Expandir-les respon
    /// 400 "Cannot expand invalid navigation property". Venen incloses amb
    /// l'entitat i n'hi ha prou de nomenar-les al $select.
    /// </summary>
    [Fact]
    public void Cap_consulta_emet_expand()
    {
        foreach (var url in AllQueries())
            Assert.DoesNotContain("$expand", url, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Els UDFs han d'anar al $select o SL no els retorna.</summary>
    [Fact]
    public void Els_udfs_van_al_select()
    {
        var partners = Uri.UnescapeDataString(ODataQueryBuilder.BuildCustomersWithAddresses());
        Assert.Contains("U_SEIPOSBC", partners);
        Assert.Contains("U_SEISEGH1", partners);
        Assert.Contains("U_SEISEGH2", partners);

        Assert.Contains("U_SEISubFamCialCat", Uri.UnescapeDataString(ODataQueryBuilder.BuildItems()));

        // Continuitat amb KAIS (Regla 04): sense aquests dos, id_client_location
        // cau al CardCode de SAP i el new_code queda buit.
        Assert.Contains("U_FCCodiKais", partners);
        Assert.Contains("U_SEICodienllac", partners);

        // U_FCNewCardCode es va crear el 26/08/2026 duplicant U_SEICodienllac i
        // s'ha borrat de SAP. Tornar a demanar-lo no dona un camp buit: SL manté
        // les metadades cacheades i la consulta acaba arribant a SQL amb una
        // columna que ja no existeix. El fallback del client nomes salta amb un
        // HTTP 400, i aquest error no ve de les metadades sino de sota (lliçó L7
        // de preparacioComandesVendaSAP), o sigui que la baixada de clients peta.
        foreach (var url in AllQueries())
            Assert.DoesNotContain("U_FCNewCardCode", Uri.UnescapeDataString(url));

        // U_SEIZONAC viu a BPAddress i no es demana camp a camp: arriba sencera
        // dins de BPAddresses, perque SL v1 no accepta $select imbricat.
        Assert.Contains("BPAddresses", partners);
    }

    [Fact]
    public void Les_cometes_simples_sescapen()
    {
        Assert.Equal("O''Brien", ODataQueryBuilder.Escape("O'Brien"));
    }

    /// <summary>OPYM no es diu PaymentMethods a Service Layer.</summary>
    [Fact]
    public void Opym_es_wizardpaymentmethods()
    {
        Assert.StartsWith("WizardPaymentMethods?", ODataQueryBuilder.BuildPaymentMethods());
    }

    private static IEnumerable<string> AllQueries() => new[]
    {
        ODataQueryBuilder.BuildCustomersWithAddresses(),
        ODataQueryBuilder.BuildCustomersWithAddressesFallback(),
        ODataQueryBuilder.BuildItems(),
        ODataQueryBuilder.BuildItemGroups(),
        ODataQueryBuilder.BuildSalesPersons(),
        ODataQueryBuilder.BuildPaymentMethods(),
        ODataQueryBuilder.BuildSalesDocuments("DeliveryNotes", null),
        ODataQueryBuilder.BuildSalesDocuments("Returns", new DateTime(2026, 1, 1)),
        ODataQueryBuilder.BuildSalesDocumentsFallback("CreditNotes", new DateTime(2026, 1, 1)),
        ODataQueryBuilder.BuildInvoices(null),
        ODataQueryBuilder.BuildInvoices(new DateTime(2026, 1, 1)),
    };
}
