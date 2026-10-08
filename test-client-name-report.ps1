param([string]$OutputFolder)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Only compile and exercise in-memory records in a marked isolated QA folder.
# This test never connects SMB, changes Windows settings or exports user data.
if (-not $OutputFolder) { $OutputFolder=Join-Path $PSScriptRoot ('ui-qa\client-name-report-isolated-'+[guid]::NewGuid().ToString('N')) }
$OutputFolder=[IO.Path]::GetFullPath($OutputFolder)
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $OutputFolder 'isolated-qa.marker'),'Einfach Netzwerk: isolated client-name report tests', (New-Object Text.UTF8Encoding($true)))
$qaSource=Join-Path $OutputFolder 'ClientNameReportQa.cs'
$qaCode=@'
using System;
using System.Globalization;
using System.Web.Script.Serialization;
using EinfachNetzwerk;

internal static class ClientNameReportQa
{
    private static int count;
    private static readonly string[] NameLabels = {
        "Namensverbindung gewünscht", "Windows-Namenszugriff geprüft", "Bestätigter Computername",
        "Namens-Freigabepfad", "Namenszugriff-Code", "Namenszugriff-Details"
    };
    private static void Check(bool valid, string text)
    {
        if (!valid) throw new InvalidOperationException(text);
        count++;
    }
    private static ShareRequest Request()
    {
        return new ShareRequest { Action="ConnectRemote", Mode="Guest", RemoteHost="192.168.44.21",
            RemoteShareName="Desktop", RemoteUserName=@"NOTEBOOK-QA\Gast", AllowNameConnection=true };
    }
    private static WorkerResult Partial(string code)
    {
        return new WorkerResult { Success=true, ConnectionVerified=true, NativeConnectionVerified=true,
            NamedConnectionVerified=false, Message="Pinned IP works; named access needs attention.",
            ComputerName="CLIENT-QA", Address="192.168.44.13", RemoteComputerName="NOTEBOOK-QA",
            RemoteAddress="192.168.44.21", RemoteShareName="Desktop", RemoteName="NOTEBOOK-QA",
            SharePath=@"\\192.168.44.21\Desktop", NamedSharePath=@"\\NOTEBOOK-QA\Desktop",
            NamedAccessCode=code, NamedAccessMessage="Original name failure at WNetAddConnection2; 0x80070035.",
            LoginUserName=@"NOTEBOOK-QA\Gast", ErrorCode="", ClientBackupPath="PRIVATE_CLIENT_JOURNAL_SENTINEL",
            ServiceBackupPath="PRIVATE_SERVICE_JOURNAL_SENTINEL", BackupPath="PRIVATE_SHARE_JOURNAL_SENTINEL",
            Checks=new[] { new CheckItem { Name="Windows-Zugriff über den Computernamen", State="warning",
                Code=code, Detail="Name listing failed; original HRESULT 0x80070035.",
                NextStep="Keep the independently verified IP path." } } };
    }
    private static string Line(string label, string value) { return I18n.T(label)+": "+value; }
    public static int Main()
    {
        try
        {
            I18n.Language="de";
            var json=new JavaScriptSerializer();
            ShareRequest request=Request();
            ShareRequest requestCopy=json.Deserialize<ShareRequest>(json.Serialize(request));
            Check(requestCopy.AllowNameConnection, "Named request option did not survive JSON transport.");
            Check(requestCopy.RemoteHost==request.RemoteHost && requestCopy.RemoteUserName==request.RemoteUserName,
                "Named request transport changed selected endpoint or account.");
            WorkerResult result=Partial("Win32: 53");
            WorkerResult resultCopy=json.Deserialize<WorkerResult>(json.Serialize(result));
            Check(resultCopy.Success && resultCopy.ConnectionVerified && resultCopy.NativeConnectionVerified && !resultCopy.NamedConnectionVerified,
                "Result DTO merged named failure with verified IP success.");
            Check(resultCopy.RemoteName==result.RemoteName && resultCopy.NamedSharePath==result.NamedSharePath,
                "Result DTO lost the confirmed name or separate path.");
            Check(resultCopy.NamedAccessCode==result.NamedAccessCode && resultCopy.NamedAccessMessage==result.NamedAccessMessage,
                "Result DTO changed original named error details.");

            const string plain="NAMED_PLAINTEXT_SECRET_SENTINEL_741";
            const string cipher="NAMED_DPAPI_SECRET_SENTINEL_982";
            request.ProtectedPassword=cipher;
            result.NamedAccessMessage += " "+plain+" "+cipher;
            result.Checks[0].Detail += " "+plain+" "+cipher;
            var session=new DiagnosticSession();
            using(session.ProtectSecrets(plain)) session.RecordOperation("ConnectRemote", request, result);
            string report=session.BuildReport();
            foreach(string value in new[] {
                Line("Windows-Zugriff geprüft","True"), Line("SMB-Verbindung geprüft","True"),
                Line("Windows-Namenszugriff geprüft","False"), Line("Namensverbindung gewünscht","True"),
                Line("Bestätigter Computername","NOTEBOOK-QA"), Line("Namens-Freigabepfad",@"\\NOTEBOOK-QA\Desktop"),
                Line("Namenszugriff-Code","Win32: 53"), @"\\192.168.44.21\Desktop", "0x80070035"
            }) Check(report.Contains(value), "Partial report omitted original context: "+value);
            foreach(string value in new[] { plain, cipher, "PRIVATE_CLIENT_JOURNAL_SENTINEL", "PRIVATE_SERVICE_JOURNAL_SENTINEL",
                "PRIVATE_SHARE_JOURNAL_SENTINEL", "ProtectedPassword:" })
                Check(!report.Contains(value), "Report leaked a secret or unlisted internal field: "+value);
            Check(session.HistoryCount==1, "A named warning with successful IP result was not retained.");

            request.RemoteHost="MUTATED_REQUEST_SENTINEL";
            request.RemoteUserName="MUTATED_ACCOUNT_SENTINEL";
            result.NamedAccessCode="MUTATED_NAMED_CODE_SENTINEL";
            result.NamedAccessMessage="MUTATED_NAMED_DETAIL_SENTINEL";
            result.NamedSharePath=@"\\MUTATED_PATH_SENTINEL\Other";
            result.Checks[0].Code="MUTATED_CHECK_CODE_SENTINEL";
            result.Checks[0].Detail="MUTATED_CHECK_DETAIL_SENTINEL";
            report=session.BuildReport();
            foreach(string value in new[] { "MUTATED_REQUEST_SENTINEL", "MUTATED_ACCOUNT_SENTINEL", "MUTATED_NAMED_CODE_SENTINEL",
                "MUTATED_NAMED_DETAIL_SENTINEL", "MUTATED_PATH_SENTINEL", "MUTATED_CHECK_CODE_SENTINEL", "MUTATED_CHECK_DETAIL_SENTINEL" })
                Check(!report.Contains(value), "Session record was not immutable: "+value);
            Check(report.Contains("Win32: 53") && report.Contains("0x80070035"), "Original code was lost after source DTO edits.");

            WorkerResult success=Partial("WINDOWS_NATIVE_NAME_ACCESS_VERIFIED");
            success.NamedConnectionVerified=true;
            success.NamedAccessMessage="Windows verified the named share and complete share list.";
            success.Checks=new CheckItem[0];
            session.RecordOperation("ConnectRemote", Request(), success);
            report=session.BuildReport();
            Check(report.Contains(Line("Windows-Namenszugriff geprüft","True")), "Latest named success was omitted.");
            Check(report.Contains(Line("Windows-Namenszugriff geprüft","False")), "A later success erased the original separate named failure.");
            Check(report.Contains("Win32: 53") && report.Contains("WINDOWS_NATIVE_NAME_ACCESS_VERIFIED"), "Latest success replaced original native failure code.");
            Check(session.HistoryCount==1, "Success fabricated a new warning history record.");
            Check(!report.Contains(plain) && !report.Contains(cipher), "Released secret scope restored credentials in old records.");

            int languageCount=0;
            foreach(LanguageItem language in I18n.Languages)
            {
                languageCount++; I18n.Language=language.Code; report=session.BuildReport();
                foreach(string label in NameLabels)
                {
                    string translated=I18n.T(label);
                    Check(!String.IsNullOrWhiteSpace(translated) && (language.Code=="de" || translated!=label),
                        "Missing name report translation: "+language.Code+" / "+label);
                    Check(report.Contains(translated+":"), "Translated report label missing: "+language.Code+" / "+label);
                }
                Check(report.Contains(Line("Windows-Zugriff geprüft","True")) && report.Contains(Line("Windows-Namenszugriff geprüft","True"))
                    && report.Contains(Line("Windows-Namenszugriff geprüft","False")), "Language merged IP/name/latest/history statuses: "+language.Code);
                Check(report.Contains("Win32: 53") && report.Contains("0x80070035") && report.Contains(@"\\192.168.44.21\Desktop")
                    && report.Contains(@"\\NOTEBOOK-QA\Desktop"), "Language corrupted original codes or paths: "+language.Code);
                Check(!report.Contains(plain) && !report.Contains(cipher) && !report.Contains("ProtectedPassword:"),
                    "Language restored sensitive material: "+language.Code);
                Check(session.HistoryCount==1 && !report.Contains("MUTATED_NAMED_CODE_SENTINEL"),
                    "Language changed retained immutable history: "+language.Code);
            }
            Check(languageCount==7, "The report QA did not cover seven languages.");

            foreach(string code in new[] { "Win32: 53", "Win32: 1219", "APP: CLIENT_NAME_NATIVE_TIMEOUT", "HRESULT: 0x80070035" })
            {
                I18n.Language="de"; var originalSession=new DiagnosticSession();
                originalSession.RecordOperation("ConnectRemote",Request(),Partial(code));
                Check(originalSession.BuildReport().Contains(Line("Namenszugriff-Code",code)), "Original name code was reformatted or replaced: "+code);
                Check(originalSession.BuildReport().Contains(Line("Windows-Zugriff geprüft","True"))
                    && originalSession.BuildReport().Contains(Line("Windows-Namenszugriff geprüft","False")),
                    "Original code changed independent verification flags: "+code);
            }

            ShareRequest password=Request(); password.Mode="Password"; password.ProtectedPassword=cipher;
            WorkerResult passwordResult=Partial("CLIENT_NAME_PASSWORD_MODE_SKIPPED");
            passwordResult.NamedAccessMessage="A provider says password=UNKNOWN_PROVIDER_PASSWORD_SENTINEL; pinned IP remains available.";
            passwordResult.Checks[0].Detail="Provider passwd not given. ProtectedPassword="+cipher+"; original Win32: 53";
            var passwordSession=new DiagnosticSession(); passwordSession.RecordOperation("ConnectRemote",password,passwordResult);
            report=passwordSession.BuildReport();
            Check(!report.Contains(cipher) && !report.Contains("UNKNOWN_PROVIDER_PASSWORD_SENTINEL"), "Password/provider-labelled credentials leaked without a plaintext scope.");
            Check(report.Contains("CLIENT_NAME_PASSWORD_MODE_SKIPPED") && report.Contains("Win32: 53"), "Credential removal destroyed unrelated original codes.");
            Console.WriteLine("Client name report: "+count.ToString(CultureInfo.InvariantCulture)+" isolated checks passed; seven languages, no real SMB or Windows changes.");
            return 0;
        }
        catch(Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
'@
[IO.File]::WriteAllText($qaSource,$qaCode,(New-Object Text.UTF8Encoding($true)))
$qaCompiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $qaCompiler)) { $qaCompiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$qaExecutable=Join-Path $OutputFolder 'ClientNameReportQa.exe'
$qaSources=@('Models.cs','DiagnosticReport.cs','I18n.cs') | ForEach-Object {Join-Path $PSScriptRoot $_}
$qaSources+=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'LocalizationResources*.cs' -File | ForEach-Object {$_.FullName})
$qaSources+=$qaSource
& $qaCompiler /nologo /target:exe /langversion:5 /optimize+ ('/out:'+$qaExecutable) /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll @qaSources
if ($LASTEXITCODE -ne 0) {throw 'Client name report QA did not compile.'}
& $qaExecutable
if ($LASTEXITCODE -ne 0) {throw 'Client name report QA failed.'}
