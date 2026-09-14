// Compile as /target:winexe: the host itself must never allocate a console.
// Only the fixed notification entry points can be launched.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

internal static class NotificationHost
{
    private static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;

    private static string QuoteArgument(string value)
    {
        // Windows argv quoting, not shell quoting. Preserve JSON quotes,
        // Unicode, metacharacters and backslashes (including a trailing slash).
        var result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { backslashes++; continue; }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
            }
            else
            {
                result.Append('\\', backslashes);
                result.Append(character);
            }
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2);
        return result.Append('"').ToString();
    }

    private static string FindPowerShell()
    {
        string[] candidates = {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                @".cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                @"PowerShell\7\pwsh.exe")
        };
        foreach (string candidate in candidates)
            if (File.Exists(candidate)) return candidate;
        string windowsPowerShell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        if (File.Exists(windowsPowerShell)) return windowsPowerShell;
        throw new FileNotFoundException("PowerShell was not found.");
    }

    private static void ReportError(string message)
    {
        // Never show a message box or create a console, even on failure.
        try
        {
            string logDirectory = Path.Combine(Root, "logs");
            Directory.CreateDirectory(logDirectory);
            File.AppendAllText(Path.Combine(logDirectory, "notification-host.log"),
                DateTimeOffset.Now.ToString("o") + " " + message + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch { }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0) return 64;
            string mode = args[0];
            if (mode == "notify" || mode == "dispatch")
            {
                if (args.Length != 2) return 64;
            }
            else if (mode == "drain")
            {
                if (args.Length > 2 || (args.Length == 2 && args[1] != "-DryRun")) return 64;
            }
            else return 64;

            string script = Path.Combine(Root, mode + ".ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("Notification script is missing.", script);
            var childArgs = new List<string> {
                "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", script
            };
            for (int index = 1; index < args.Length; index++) childArgs.Add(args[index]);
            var quoted = new List<string>();
            foreach (string argument in childArgs) quoted.Add(QuoteArgument(argument));
            var start = new ProcessStartInfo {
                FileName = FindPowerShell(),
                Arguments = string.Join(" ", quoted),
                WorkingDirectory = Root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false)
            };
            using (var child = new Process { StartInfo = start })
            {
                child.Start();
                child.StandardInput.Close();
                Task<string> output = child.StandardOutput.ReadToEndAsync();
                Task<string> error = child.StandardError.ReadToEndAsync();
                child.WaitForExit();
                Task.WaitAll(output, error);
                if (child.ExitCode != 0)
                    ReportError(mode + " exit=" + child.ExitCode);
                return child.ExitCode;
            }
        }
        catch (Exception exception)
        {
            ReportError(exception.GetType().Name);
            return 1;
        }
    }
}
