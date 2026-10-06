namespace SapB1AnalitzaSync.Shared.Configuration;

public sealed class FileLogOptions
{
    public const string SectionName = "FileLog";

    public bool Enabled { get; set; } = true;

    /// <summary>Relatiu a la carpeta de l'executable, o absolut.</summary>
    public string Directory { get; set; } = "logs";

    /// <summary>Dies que es conserven, comptant el d'avui. 0 o menys = no esborrar res.</summary>
    public int RetentionDays { get; set; } = 30;
}
