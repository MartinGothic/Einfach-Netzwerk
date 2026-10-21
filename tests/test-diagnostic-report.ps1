param([string]$OutputFolder, [string]$AssemblyPath = (Join-Path $PSScriptRoot '..\dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference = 'Stop'
if (-not $OutputFolder) { $OutputFolder = Join-Path $PSScriptRoot ('ui-qa\diagnostic-report-isolated-' + [guid]::NewGuid().ToString('N')) }
$OutputFolder = [IO.Path]::GetFullPath($OutputFolder)
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$diagnosticCompiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $diagnosticCompiler)) { $diagnosticCompiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$diagnosticExecutable = Join-Path $OutputFolder 'DiagnosticReportQa.exe'
$diagnosticQaSource = @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using EinfachNetzwerk;

internal static class DiagnosticReportQa
{
    private static int assertions;
    private static void Require(bool test, string message) { if (!test) throw new InvalidOperationException(message); assertions++; }
    private static void Contains(string text, string value) { Require(text.Contains(value), "Report omitted expected value: " + value); }
    private static void Excludes(string text, string value) { Require(!text.Contains(value), "A sensitive value survived redaction."); }

    private static Exception Nested(string secret)
    {
        try { throw new Win32Exception(5, "Native access denied: " + secret); }
        catch (Exception inner) { return new InvalidOperationException("Outer failure: " + secret, inner); }
    }
    private static void OptionalResult(WorkerResult result, string key, string value)
    {
        PropertyInfo property = typeof(WorkerResult).GetProperty(key);
        if (property != null) property.SetValue(result, value, null);
    }
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string destination = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(destination);
            I18n.Language = "de";
            DiagnosticSession empty = new DiagnosticSession();
            string emptyReport = empty.BuildReport();
            Contains(emptyReport, "Es wurde noch keine Aktion erfasst.");
            Contains(emptyReport, "In dieser Sitzung wurden keine Fehler oder Warnungen erfasst.");
            Require(empty.HistoryCount == 0, "Empty report invented a failure.");
            Require(Directory.GetFiles(destination).Length == 0, "Building a report wrote an automatic file.");

            const string plain = "PASSWORD_SENTINEL_Ä_29xy";
            const string cipher = "DPAPI_SENTINEL_63744";
            DiagnosticSession session = new DiagnosticSession();
            ShareRequest context = new ShareRequest { Action = "Apply", FolderPath = @"D:\Prüfen\" + plain, ShareName = "Desktop-Ä", Mode = "password", UserName = "Prüfen", AdapterId = 17, ProtectedPassword = cipher };
            WorkerResult failure = new WorkerResult { Success = false, Message = "SMB denied " + plain + " " + cipher, ComputerName = "HOME-PC", Address = "192.168.178.24", SharePath = @"\\192.168.178.24\Desktop-Ä", LoginUserName = @"HOME-PC\Prüfen", ConnectionText = "smb://Visitor:URI_UNKNOWN_SECRET@192.168.178.24/Desktop-Ä\r\npassword=KEY_UNKNOWN_SECRET; next field", RetryCount = 2,
                Checks = new[] { new CheckItem { Name = "ACL", State = "Error", Code = "WIN32_ACCESS_DENIED_5", Detail = "Zugriff verweigert: " + plain + " " + cipher, Fixable = true, NextStep = "Prüfen – " + plain }, new CheckItem { Name = "Network", State = "Warning", Code = null, Detail = "Gateway: 192.168.178.1", NextStep = "Anderes Gerät prüfen" }, new CheckItem { Name = "SMB", State = "OK", Code = "SMB_OK_445", Detail = "Listener aktiv" } },
                Networks = new[] { new NetworkItem { Id = 17, Name = "Ethernet-Ä", Address = "192.168.178.24", Subnet = "192.168.178.0/24", Category = "Private" } },
                Shares = new[] { new ShareItem { Name = "Desktop-Ä", Path = @"D:\Inventory\" + plain, Available = true, Managed = true, Mode = "password", UserName = "Prüfen", AllowWrite = true, AdapterId = 17 } } };
            OptionalResult(failure, "ErrorCode", "0x80070005"); OptionalResult(failure, "ErrorType", "System.UnauthorizedAccessException"); OptionalResult(failure, "ErrorStackTrace", "backend stack " + plain);
            using (session.ProtectSecrets(plain)) session.RecordOperation("Apply", context, failure, Nested(plain));
            string report = session.BuildReport();
            Excludes(report, plain); Excludes(report, cipher); Excludes(report, "URI_UNKNOWN_SECRET"); Excludes(report, "KEY_UNKNOWN_SECRET");
            Contains(report, "WIN32_ACCESS_DENIED_5"); Contains(report, "SMB_OK_445"); Contains(report, "Win32-Fehlercode: 5"); Contains(report, "HRESULT: 0x80004005");
            Contains(report, "nicht bereitgestellt"); Contains(report, "Prüfung 3"); Contains(report, "Ethernet-Ä"); Contains(report, "192.168.178.0/24"); Contains(report, "Netzwerkadapter-ID: 17");
            Contains(report, "SMB-Port (TCP): 445"); Contains(report, "Ausgewählter Benutzer: Prüfen"); Contains(report, "Aufrufliste:");
            Contains(report, "Erfasste Freigabe 1"); Contains(report, "Im Netzwerk eingerichtet: True"); Contains(report, "Vom Programm verwaltet: True");
            Excludes(report, "ProtectedPassword:"); Excludes(report, "BackupPath:");
            Require(session.HistoryCount == 1, "A captured failure was not retained.");

            // Prove retained data is an immutable sanitized snapshot, not a live request/result.
            failure.Message = "MUTATION_AFTER_CAPTURE"; context.FolderPath = "MUTATION_CONTEXT";
            Excludes(session.BuildReport(), "MUTATION_AFTER_CAPTURE"); Excludes(session.BuildReport(), "MUTATION_CONTEXT");
            FieldInfo latestField = typeof(DiagnosticSession).GetField("latest", BindingFlags.Instance | BindingFlags.NonPublic);
            object latest = latestField.GetValue(session);
            object lines = latest.GetType().GetField("Lines", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(latest);
            foreach (object line in (System.Collections.IEnumerable)lines)
            {
                string retained = line.GetType().GetField("Value", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(line) as string;
                if (retained != null) { Excludes(retained, plain); Excludes(retained, cipher); }
            }
            FieldInfo secretField = typeof(DiagnosticSession).GetField("secrets", BindingFlags.Instance | BindingFlags.NonPublic);
            Require(((System.Collections.IDictionary)secretField.GetValue(session)).Count == 0, "Operation secret survived scope disposal.");

            session.RecordOperation("Inspect", null, new WorkerResult { Success = true, Message = "SUCCESSFUL_INSPECTION_AFTER_FAILURE", Checks = new[] { new CheckItem { Name = "SMB", State = "OK", Code = "LISTENER_OK" } } });
            string afterSuccess = session.BuildReport();
            Contains(afterSuccess, "SUCCESSFUL_INSPECTION_AFTER_FAILURE"); Contains(afterSuccess, "WIN32_ACCESS_DENIED_5");
            Require(session.HistoryCount == 1, "Success removed an older error or invented a new one.");
            session.RecordOperation("Inspect-warning", null, new WorkerResult { Success = true, Checks = new[] { new CheckItem { Name = "Connectivity", State = "Warning", Code = "DEVICE_CONFIRMATION_REQUIRED" } } });
            Require(session.HistoryCount == 2, "Warning in a successful result was not retained.");

            DiagnosticSession bounded = new DiagnosticSession();
            for (int index = 0; index < 30; index++) bounded.RecordMessage("General-" + index, "HISTORY_ENTRY_" + index.ToString("D2", CultureInfo.InvariantCulture), index == 0 ? "FIRST_MUST_EXPIRE" : "CODE_" + index);
            Require(bounded.HistoryCount == DiagnosticSession.MaximumHistory, "Error history is unbounded.");
            string boundedText = bounded.BuildReport();
            Excludes(boundedText, "FIRST_MUST_EXPIRE"); Excludes(boundedText, "HISTORY_ENTRY_00"); Contains(boundedText, "HISTORY_ENTRY_10"); Contains(boundedText, "HISTORY_ENTRY_29"); Contains(boundedText, "10 ältere Einträge");
            DiagnosticSession noCode = new DiagnosticSession(); noCode.RecordMessage("Clipboard", "No numeric provider code.");
            Contains(noCode.BuildReport(), "Fehlercode: nicht bereitgestellt"); Excludes(noCode.BuildReport(), "Win32-Fehlercode: 5");

            DiagnosticSession labels = new DiagnosticSession();
            labels.RecordMessage("Sanitize", "password=UNKNOWN_PLAIN; Password=\"UNKNOWN_QUOTED\"; ProtectedPassword='UNKNOWN_ENCRYPTED'; smb://a:UNKNOWN_URL@host/path");
            string labelled = labels.BuildReport();
            Excludes(labelled, "UNKNOWN_PLAIN"); Excludes(labelled, "UNKNOWN_QUOTED"); Excludes(labelled, "UNKNOWN_ENCRYPTED"); Excludes(labelled, "UNKNOWN_URL");
            const string longSecret = "VERY_LONG_PASSWORD_PREFIX_7";
            using (labels.ProtectSecrets(longSecret)) labels.RecordMessage("Long-field", new string('x', 19990) + longSecret + new string('y', 30000));
            Excludes(labels.BuildReport(), longSecret); Excludes(labels.BuildReport(), "VERY_LONG_PASSW"); Contains(labels.BuildReport(), "Langer Eintrag gekürzt");
            IDisposable first = labels.ProtectSecrets("OVERLAP_SECRET");
            using (labels.ProtectSecrets("OVERLAP_SECRET")) { first.Dispose(); Excludes(labels.Redact("OVERLAP_SECRET"), "OVERLAP_SECRET"); }
            first.Dispose(); Require(((System.Collections.IDictionary)secretField.GetValue(labels)).Count == 0, "Nested secret scopes did not release correctly.");

            string savedLanguage = I18n.Language;
            foreach (LanguageItem language in I18n.Languages)
            {
                I18n.Language = language.Code;
                string localized = session.BuildReport();
                Contains(localized, "WIN32_ACCESS_DENIED_5"); Contains(localized, "Prüfen"); Contains(localized, "192.168.178.24");
                Require(!String.IsNullOrWhiteSpace(I18n.T("Fehlerbericht exportieren")), "Empty export translation.");
                if (language.Code != "de") Require(I18n.T("Fehlerbericht exportieren") != "Fehlerbericht exportieren", "Missing export translation: " + language.Code);
                Excludes(localized, plain); Excludes(localized, cipher);
            }
            I18n.Language = savedLanguage;

            string output = Path.Combine(destination, "Fehlerbericht-Ä.txt");
            string unrelated = Path.Combine(destination, "unrelated-content.txt"); File.WriteAllText(unrelated, "Unrelated file remains untouched.", Encoding.UTF8);
            session.WriteReport(output);
            byte[] bytes = File.ReadAllBytes(output);
            Require(bytes.Length > 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF, "TXT is not UTF-8 with a Windows-readable BOM.");
            string exported = File.ReadAllText(output, Encoding.UTF8); Contains(exported, "Desktop-Ä"); Contains(exported, "WIN32_ACCESS_DENIED_5"); Excludes(exported, plain); Excludes(exported, cipher);
            noCode.WriteReport(output); Contains(File.ReadAllText(output, Encoding.UTF8), "No numeric provider code.");
            Require(Directory.GetFiles(destination, "*.tmp").Length == 0, "Atomic export left a temporary file.");
            Contains(File.ReadAllText(unrelated), "Unrelated file remains untouched.");
            bool failedWrite = false;
            try { session.WriteReport(Path.Combine(destination, "missing-directory", "report.txt")); } catch (DirectoryNotFoundException) { failedWrite = true; }
            Require(failedWrite, "Invalid export path was silently accepted.");
            Console.WriteLine("Diagnostic report checks passed: " + assertions);
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
'@
$diagnosticQaSourcePath = Join-Path $OutputFolder 'DiagnosticReportQa.cs'
[IO.File]::WriteAllText($diagnosticQaSourcePath, $diagnosticQaSource, (New-Object Text.UTF8Encoding($true)))
$AssemblyPath = (Resolve-Path -LiteralPath $AssemblyPath).Path
Copy-Item -LiteralPath $AssemblyPath -Destination (Join-Path $OutputFolder ([IO.Path]::GetFileName($AssemblyPath))) -Force
& $diagnosticCompiler /nologo /target:exe /langversion:5 /optimize+ ('/out:' + $diagnosticExecutable) /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll ('/reference:'+$AssemblyPath) $diagnosticQaSourcePath
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic report QA did not compile.' }
$diagnosticFixtureFolder = Join-Path $OutputFolder 'fixtures'
& $diagnosticExecutable $diagnosticFixtureFolder
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic report QA failed.' }
Get-Item -LiteralPath $diagnosticExecutable | Select-Object FullName,Length
