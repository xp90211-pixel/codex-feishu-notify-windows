using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexFeishuNotify.Installer
{
    internal static class Program
    {
        private const string PayloadResourceName = "CodexFeishuNotify.Payload.zip";
        private const string ProductDirectoryName = "CodexFeishuNotify";

        [STAThread]
        public static int Main(string[] args)
        {
            InstallerOptions options;
            try
            {
                options = InstallerOptions.Parse(args);
            }
            catch (Exception exception)
            {
                ShowError("Invalid installer options", exception.Message, false);
                return 2;
            }

            try
            {
                string version = GetProductVersion();
                string installDirectory = GetInstallDirectory(options.InstallRoot, version);
                InstallPayload(installDirectory);

                string shortcutWarning = null;
                if (options.CreateShortcut)
                {
                    try
                    {
                        CreateStartMenuShortcut(installDirectory);
                    }
                    catch (Exception exception)
                    {
                        shortcutWarning = "The application was installed, but the Start menu shortcut could not be created.\r\n\r\n" + exception.Message;
                    }
                }

                if (options.LaunchSettings)
                {
                    LaunchSettings(installDirectory);
                }

                if (!options.Quiet && shortcutWarning != null)
                {
                    MessageBox.Show(shortcutWarning, "Codex Feishu Notify", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }

                return 0;
            }
            catch (Exception exception)
            {
                ShowError("Installation failed", exception.Message, options.Quiet);
                return 1;
            }
        }

        private static string GetProductVersion()
        {
            Assembly assembly = typeof(Program).Assembly;
            object[] attributes = assembly.GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute), false);
            string version = attributes.Length > 0
                ? ((AssemblyInformationalVersionAttribute)attributes[0]).InformationalVersion
                : assembly.GetName().Version.ToString(3);

            int metadataIndex = version.IndexOf('+');
            if (metadataIndex >= 0)
            {
                version = version.Substring(0, metadataIndex);
            }

            char[] invalid = Path.GetInvalidFileNameChars();
            char[] sanitized = version.ToCharArray();
            for (int index = 0; index < sanitized.Length; index++)
            {
                if (Array.IndexOf(invalid, sanitized[index]) >= 0 || sanitized[index] == '/' || sanitized[index] == '\\')
                {
                    sanitized[index] = '_';
                }
            }

            string result = new string(sanitized).Trim();
            if (result.Length == 0)
            {
                throw new InvalidOperationException("The installer version is empty.");
            }

            return result;
        }

        private static string GetInstallDirectory(string requestedRoot, string version)
        {
            string installRoot = requestedRoot;
            if (String.IsNullOrWhiteSpace(installRoot))
            {
                string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (String.IsNullOrWhiteSpace(localAppData))
                {
                    throw new InvalidOperationException("LOCALAPPDATA could not be resolved.");
                }

                installRoot = Path.Combine(localAppData, "Programs");
            }

            installRoot = Path.GetFullPath(Environment.ExpandEnvironmentVariables(installRoot.Trim().Trim('"')));
            string productRoot = Path.GetFullPath(Path.Combine(installRoot, ProductDirectoryName));
            string installDirectory = Path.GetFullPath(Path.Combine(productRoot, "v" + version));
            if (!IsChildPath(installDirectory, productRoot))
            {
                throw new InvalidOperationException("The resolved installation directory is outside the product directory.");
            }

            return installDirectory;
        }

        private static void InstallPayload(string installDirectory)
        {
            string productRoot = Directory.GetParent(installDirectory).FullName;
            Directory.CreateDirectory(productRoot);

            string stagingDirectory = Path.Combine(productRoot, ".installing-" + Guid.NewGuid().ToString("N"));
            string backupDirectory = null;
            bool payloadPromoted = false;

            try
            {
                Directory.CreateDirectory(stagingDirectory);
                ExtractPayload(stagingDirectory);
                ValidatePayload(stagingDirectory);

                if (Directory.Exists(installDirectory))
                {
                    backupDirectory = Path.Combine(productRoot, ".previous-" + Path.GetFileName(installDirectory) + "-" + Guid.NewGuid().ToString("N"));
                    Directory.Move(installDirectory, backupDirectory);
                }

                try
                {
                    Directory.Move(stagingDirectory, installDirectory);
                    payloadPromoted = true;
                }
                catch
                {
                    if (backupDirectory != null && Directory.Exists(backupDirectory) && !Directory.Exists(installDirectory))
                    {
                        Directory.Move(backupDirectory, installDirectory);
                        backupDirectory = null;
                    }

                    throw;
                }

                TryDeleteDirectory(backupDirectory);
                backupDirectory = null;
            }
            finally
            {
                if (!payloadPromoted)
                {
                    TryDeleteDirectory(stagingDirectory);
                }
            }
        }

        private static void ExtractPayload(string stagingDirectory)
        {
            Assembly assembly = typeof(Program).Assembly;
            using (Stream payload = assembly.GetManifestResourceStream(PayloadResourceName))
            {
                if (payload == null)
                {
                    throw new InvalidOperationException("The embedded release payload is missing.");
                }

                using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read, false))
                {
                    string packageRoot = null;
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string archivePath = entry.FullName.Replace('\\', '/');
                        if (archivePath.StartsWith("/", StringComparison.Ordinal) || archivePath.IndexOf('\0') >= 0)
                        {
                            throw new InvalidDataException("The release payload contains an invalid path.");
                        }

                        int firstSeparator = archivePath.IndexOf('/');
                        if (firstSeparator <= 0)
                        {
                            throw new InvalidDataException("The release payload must have one top-level directory.");
                        }

                        string currentRoot = archivePath.Substring(0, firstSeparator);
                        if (packageRoot == null)
                        {
                            packageRoot = currentRoot;
                        }
                        else if (!String.Equals(packageRoot, currentRoot, StringComparison.Ordinal))
                        {
                            throw new InvalidDataException("The release payload contains multiple top-level directories.");
                        }

                        string relativePath = archivePath.Substring(firstSeparator + 1);
                        if (relativePath.Length == 0)
                        {
                            continue;
                        }
                        if (relativePath.IndexOf(':') >= 0)
                        {
                            throw new InvalidDataException("The release payload contains an invalid path segment.");
                        }

                        string destination = Path.GetFullPath(Path.Combine(stagingDirectory, relativePath.Replace('/', Path.DirectorySeparatorChar)));
                        if (!IsChildPath(destination, stagingDirectory))
                        {
                            throw new InvalidDataException("The release payload attempted to write outside the staging directory.");
                        }

                        if (String.IsNullOrEmpty(entry.Name))
                        {
                            Directory.CreateDirectory(destination);
                            continue;
                        }

                        string parent = Path.GetDirectoryName(destination);
                        if (!String.IsNullOrEmpty(parent))
                        {
                            Directory.CreateDirectory(parent);
                        }

                        using (Stream input = entry.Open())
                        using (FileStream output = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
                        {
                            input.CopyTo(output);
                        }
                    }
                }
            }
        }

        private static void ValidatePayload(string stagingDirectory)
        {
            string launcher = Path.Combine(stagingDirectory, "Open-Settings.cmd");
            string settingsScript = Path.Combine(stagingDirectory, "scripts", "Settings-Gui.ps1");
            string installerScript = Path.Combine(stagingDirectory, "scripts", "Install.ps1");
            if (!File.Exists(launcher) || !File.Exists(settingsScript) || !File.Exists(installerScript))
            {
                throw new InvalidDataException("The embedded release payload is incomplete.");
            }
        }

        private static void CreateStartMenuShortcut(string installDirectory)
        {
            string programsDirectory = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
            if (String.IsNullOrWhiteSpace(programsDirectory))
            {
                throw new InvalidOperationException("The Start menu Programs directory could not be resolved.");
            }

            string shortcutDirectory = Path.Combine(programsDirectory, "Codex Feishu Notify");
            Directory.CreateDirectory(shortcutDirectory);
            string shortcutPath = Path.Combine(shortcutDirectory, "Codex Feishu Notify Settings.lnk");
            string powerShellPath = GetWindowsPowerShellPath();
            string settingsScript = Path.Combine(installDirectory, "scripts", "Settings-Gui.ps1");

            Type shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null)
            {
                throw new InvalidOperationException("Windows Script Host is unavailable.");
            }

            object shellObject = Activator.CreateInstance(shellType);
            object shortcutObject = null;
            try
            {
                dynamic shell = shellObject;
                dynamic shortcut = shell.CreateShortcut(shortcutPath);
                shortcutObject = shortcut;
                shortcut.TargetPath = powerShellPath;
                shortcut.Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(settingsScript);
                shortcut.WorkingDirectory = installDirectory;
                shortcut.Description = "Configure Codex Feishu notifications";
                shortcut.IconLocation = powerShellPath + ",0";
                shortcut.Save();
            }
            finally
            {
                ReleaseComObject(shortcutObject);
                ReleaseComObject(shellObject);
            }
        }

        private static void LaunchSettings(string installDirectory)
        {
            string settingsScript = Path.Combine(installDirectory, "scripts", "Settings-Gui.ps1");
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = GetWindowsPowerShellPath();
            startInfo.Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(settingsScript);
            startInfo.WorkingDirectory = installDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            Process process = Process.Start(startInfo);
            if (process == null)
            {
                throw new InvalidOperationException("The graphical settings tool could not be started.");
            }
        }

        private static string GetWindowsPowerShellPath()
        {
            string powerShellPath = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(powerShellPath))
            {
                throw new FileNotFoundException("Windows PowerShell was not found.", powerShellPath);
            }

            return powerShellPath;
        }

        private static bool IsChildPath(string candidate, string parent)
        {
            string normalizedCandidate = Path.GetFullPath(candidate);
            string normalizedParent = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            return normalizedCandidate.StartsWith(normalizedParent, StringComparison.OrdinalIgnoreCase);
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static void ReleaseComObject(object value)
        {
            if (value != null && Marshal.IsComObject(value))
            {
                Marshal.FinalReleaseComObject(value);
            }
        }

        private static void TryDeleteDirectory(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
            {
                return;
            }

            try
            {
                Directory.Delete(path, true);
            }
            catch
            {
                // A stale version backup is safer than failing an otherwise successful install.
            }
        }

        private static void ShowError(string title, string message, bool quiet)
        {
            if (!quiet)
            {
                MessageBox.Show(message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private sealed class InstallerOptions
        {
            public string InstallRoot { get; private set; }
            public bool LaunchSettings { get; private set; }
            public bool CreateShortcut { get; private set; }
            public bool Quiet { get; private set; }

            private InstallerOptions()
            {
                LaunchSettings = true;
                CreateShortcut = true;
            }

            public static InstallerOptions Parse(string[] args)
            {
                InstallerOptions options = new InstallerOptions();
                for (int index = 0; index < args.Length; index++)
                {
                    string argument = args[index];
                    if (String.Equals(argument, "--install-root", StringComparison.OrdinalIgnoreCase))
                    {
                        if (index + 1 >= args.Length || String.IsNullOrWhiteSpace(args[index + 1]))
                        {
                            throw new ArgumentException("--install-root requires a directory path.");
                        }

                        options.InstallRoot = args[++index];
                    }
                    else if (String.Equals(argument, "--no-launch", StringComparison.OrdinalIgnoreCase))
                    {
                        options.LaunchSettings = false;
                    }
                    else if (String.Equals(argument, "--no-shortcut", StringComparison.OrdinalIgnoreCase))
                    {
                        options.CreateShortcut = false;
                    }
                    else if (String.Equals(argument, "--quiet", StringComparison.OrdinalIgnoreCase))
                    {
                        options.Quiet = true;
                    }
                    else
                    {
                        throw new ArgumentException("Unknown option: " + argument);
                    }
                }

                return options;
            }
        }
    }
}
