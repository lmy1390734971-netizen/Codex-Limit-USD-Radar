using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("Token Rader")]
[assembly: AssemblyDescription("Local Codex token usage dashboard launcher")]
[assembly: AssemblyProduct("Token Rader")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class TokenRaderLauncher
{
    private static string FindOnPath(string executable)
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string rawDirectory in path.Split(Path.PathSeparator))
        {
            string directory = rawDirectory.Trim().Trim('"');
            if (directory.Length == 0) continue;
            string candidate = Path.Combine(directory, executable);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    [STAThread]
    private static void Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "TokenRader.ps1");
        if (!File.Exists(script))
        {
            System.Windows.Forms.MessageBox.Show(
                "TokenRader.ps1 was not found next to TokenRader.exe.",
                "Token Rader",
                System.Windows.Forms.MessageBoxButtons.OK,
                System.Windows.Forms.MessageBoxIcon.Error);
            return;
        }

        string powerShell = FindOnPath("powershell.exe") ?? FindOnPath("pwsh.exe");
        if (powerShell == null)
        {
            System.Windows.Forms.MessageBox.Show(
                "Windows PowerShell or PowerShell 7 was not found in PATH.",
                "Token Rader",
                System.Windows.Forms.MessageBoxButtons.OK,
                System.Windows.Forms.MessageBoxIcon.Error);
            return;
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = powerShell,
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script.Replace("\"", "\\\"") + "\"",
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        Process.Start(startInfo);
    }
}
