using SapB1AnalitzaSync.Shared.Logging;

namespace SapB1AnalitzaSync.Tests;

public class FileLogPolicyTests
{
    [Fact]
    public void FileName_porta_la_data_en_AAAAMMDD()
        => Assert.Equal("worker-20261006.log", FileLogPolicy.FileName(new DateOnly(2026, 10, 6)));

    [Theory]
    [InlineData("worker-20261006.log", true)]
    [InlineData("logs/worker-20261006.log", true)]
    [InlineData("worker-2026-10-06.log", false)]
    [InlineData("worker-20261332.log", false)]   // mes 13, dia 32
    [InlineData("etl-20261006.log", false)]
    [InlineData("worker-20261006.txt", false)]
    public void TryParseDay_nomes_accepta_el_patro(string name, bool expected)
        => Assert.Equal(expected, FileLogPolicy.TryParseDay(name, out _));

    [Fact]
    public void FilesToPurge_conserva_els_dies_de_retencio_comptant_avui()
    {
        var today = new DateOnly(2026, 10, 6);
        var files = new[]
        {
            "worker-20261006.log",   // avui
            "worker-20261004.log",
            "worker-20260930.log",   // fa 6 dies, l'ultim que es conserva amb retencio 7
            "worker-20260929.log",   // fa 7 dies
            "worker-20260901.log",
        };

        var purge = FileLogPolicy.FilesToPurge(files, today, retentionDays: 7);

        Assert.Equal(new[] { "worker-20260929.log", "worker-20260901.log" }, purge);
    }

    [Fact]
    public void FilesToPurge_no_toca_el_que_no_hem_escrit_nosaltres()
    {
        var purge = FileLogPolicy.FilesToPurge(
            new[] { "notes.txt", "etl-20260101.log", "worker-vell.log", "worker-20260101.log" },
            new DateOnly(2026, 10, 6), retentionDays: 30);

        Assert.Equal(new[] { "worker-20260101.log" }, purge);
    }

    // Un zero per badada a la configuracio no ha de buidar la carpeta.
    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public void FilesToPurge_amb_retencio_no_positiva_no_esborra_res(int retentionDays)
        => Assert.Empty(FileLogPolicy.FilesToPurge(
            new[] { "worker-20200101.log" }, new DateOnly(2026, 10, 6), retentionDays));

    // Rellotge tocat: un fitxer amb data futura es deixa estar.
    [Fact]
    public void FilesToPurge_no_esborra_fitxers_amb_data_futura()
        => Assert.Empty(FileLogPolicy.FilesToPurge(
            new[] { "worker-20271006.log" }, new DateOnly(2026, 10, 6), retentionDays: 30));

    [Fact]
    public void FormatLine_segella_en_UTC_i_escurca_la_categoria()
    {
        var line = FileLogPolicy.FormatLine(
            new DateTime(2026, 10, 6, 0, 45, 19, DateTimeKind.Utc),
            "INF", "SapB1AnalitzaSync.Worker.Services.ServiceLayerClient", "Login a Service Layer");

        Assert.Equal("2026-10-06 00:45:19Z INF ServiceLayerClient Login a Service Layer", line);
    }

    [Theory]
    [InlineData("SapB1AnalitzaSync.Worker.Services.MirrorSyncService", "MirrorSyncService")]
    [InlineData("Program", "Program")]
    [InlineData("", "-")]
    [InlineData("acaba.amb.punt.", "acaba.amb.punt.")]
    public void ShortCategory(string category, string expected)
        => Assert.Equal(expected, FileLogPolicy.ShortCategory(category));
}
