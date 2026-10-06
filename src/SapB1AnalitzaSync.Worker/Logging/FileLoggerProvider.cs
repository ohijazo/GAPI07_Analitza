using SapB1AnalitzaSync.Shared.Configuration;
using SapB1AnalitzaSync.Shared.Logging;

namespace SapB1AnalitzaSync.Worker.Logging;

// Escriu el log a <carpeta>/worker-AAAAMMDD.log, al costat de l'executable.
//
// PER QUE EXISTEIX. La tasca de les 02:45 llança l'exe sense redirigir la
// sortida, així que la consola se'n va a terra. El 06/10/2026, primer cicle
// nocturn amb l'usuari `proceso`, es va poder dir que havia anat bé per
// audit.etl_runs i sap_raw.sync_state, però de QUIN USUARI havia fet servir no
// en quedava cap rastre: l'única evidència era que el fitxer de configuració el
// nomenava. Redirigir la sortida voldria tocar la definició de la tasca, que és
// d'un administrador d'una màquina que no és nostra; això no depèn de ningú.
//
// MAI HA DE FER PETAR EL WORKER. Si la carpeta no és escrivible pel compte de la
// tasca, el cicle ha de seguir refrescant el mirall igualment: un log que trenca
// la feina és pitjor que no tenir-ne cap. Per això tot va dins d'un try i, quan
// falla, es diu UNA vegada per consola i es calla.
//
// Un fitxer per dia i retenció per dies, perquè això corre en una màquina
// compartida: un log que creix sense final és un problema que li deixem a algú
// altre.
internal sealed class FileLoggerProvider : ILoggerProvider
{
    private readonly FileLogWriter _writer;

    public FileLoggerProvider(FileLogOptions options, string baseDirectory)
    {
        var directory = Path.IsPathRooted(options.Directory)
            ? options.Directory
            : Path.Combine(baseDirectory, options.Directory);

        _writer = new FileLogWriter(directory, options.RetentionDays);
    }

    public ILogger CreateLogger(string categoryName) => new FileLogger(categoryName, _writer);

    public void Dispose() { }
}

internal sealed class FileLogWriter
{
    // UTF-8 AMB BOM a propòsit. Sense ell, PowerShell 5.1 i el Notepad del
    // servidor llegeixen el fitxer com a ANSI i "reemplaçament" surt
    // "reemplaÃ§ament" (la mateixa mossegada que la Regla 05 als scripts .ps1).
    // Aquest log existeix per ser llegit en aquella màquina, així que el BOM és
    // part de la feina.
    private static readonly System.Text.UTF8Encoding Utf8WithBom = new(encoderShouldEmitUTF8Identifier: true);

    private readonly object _gate = new();
    private readonly string _directory;
    private bool _broken;

    public FileLogWriter(string directory, int retentionDays)
    {
        _directory = directory;
        Prepare(retentionDays);
    }

    public void Write(string line)
    {
        if (_broken) return;

        lock (_gate)
        {
            if (_broken) return;
            try
            {
                // Obrir i tancar a cada línia: el volum és d'unes centenes de
                // línies per execució i, a canvi, si el procés mor a mitges no es
                // perd el tros que explica per què ha mort.
                File.AppendAllText(Path.Combine(_directory, FileLogPolicy.FileName(Today())),
                                   line + Environment.NewLine, Utf8WithBom);
            }
            catch (Exception ex)
            {
                Break(ex);
            }
        }
    }

    private void Prepare(int retentionDays)
    {
        try
        {
            System.IO.Directory.CreateDirectory(_directory);

            var existing = System.IO.Directory.GetFiles(_directory, FileLogPolicy.Prefix + "*" + FileLogPolicy.Extension);
            foreach (var path in FileLogPolicy.FilesToPurge(existing, Today(), retentionDays))
                File.Delete(path);
        }
        catch (Exception ex)
        {
            Break(ex);
        }
    }

    private void Break(Exception ex)
    {
        _broken = true;
        Console.Error.WriteLine($"[FileLog] desactivat: no es pot escriure a {_directory} ({ex.GetType().Name}: {ex.Message}). " +
                                "El cicle continua; el log nomes anira a la consola.");
    }

    private static DateOnly Today() => DateOnly.FromDateTime(DateTime.UtcNow);
}

internal sealed class FileLogger(string category, FileLogWriter writer) : ILogger
{
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) => logLevel != LogLevel.None;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
                            Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;

        var message = formatter(state, exception);
        if (exception is not null) message = message + Environment.NewLine + exception;

        writer.Write(FileLogPolicy.FormatLine(DateTime.UtcNow, Abbreviate(logLevel), category, message));
    }

    private static string Abbreviate(LogLevel level) => level switch
    {
        LogLevel.Trace => "TRC",
        LogLevel.Debug => "DBG",
        LogLevel.Information => "INF",
        LogLevel.Warning => "WRN",
        LogLevel.Error => "ERR",
        LogLevel.Critical => "CRT",
        _ => "---",
    };
}
