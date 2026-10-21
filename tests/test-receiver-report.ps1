param([string]$OutputFolder, [string]$AssemblyPath = (Join-Path $PSScriptRoot '..\dist\Einfach-Netzwerk.exe'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Only in-memory records and marked isolated test output; no network or Windows changes.
if(-not $OutputFolder){$OutputFolder=Join-Path $PSScriptRoot ('ui-qa\receiver-report-isolated-'+[Guid]::NewGuid().ToString('N'))}
$OutputFolder=[IO.Path]::GetFullPath($OutputFolder)
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $OutputFolder 'isolated-qa.marker'),'Einfach Netzwerk: isolated receiver report tests',(New-Object Text.UTF8Encoding($true)))
$taskSource=Join-Path $OutputFolder 'ReceiverReportQa.cs'
$taskCode=@'
using System;
using System.Globalization;
using System.Web.Script.Serialization;
using EinfachNetzwerk;
internal static class ReceiverReportQa {
    static int count;
    static void Check(bool value,string reason){if(!value)throw new InvalidOperationException(reason);count++;}
    static string Line(string label,string value){return I18n.T(label)+": "+value;}
    static WorkerResult Prepared(){return new WorkerResult {
        Success=true, ClientRepairAvailable=true,
        Message="Dieser Windows-Client ist für Freigaben ohne Passwort vorbereitet. Der Zugriff auf einen anderen Computer ist noch ungeprüft.",
        ClientBackupPath="PRIVATE_CLIENT_JOURNAL_SENTINEL",BackupPath="PRIVATE_SERVER_JOURNAL_SENTINEL",
        ServiceBackupPath="PRIVATE_SERVICE_JOURNAL_SENTINEL",ComputerName="RECEIVER-QA"};}
    static WorkerResult Listed(){return new WorkerResult {
        Success=true,RemoteComputerEnumerationVerified=true,RemoteComputerName="SOURCE-QA",RemoteAddress="192.168.44.21",
        ClientRepairAvailable=true,ClientBackupPath="PRIVATE_CLIENT_JOURNAL_SENTINEL",
        Message="Windows hat die vollständige Freigabenliste des anderen Computers gelesen. Wähle einen Ordner oder ein Laufwerk aus; dessen Zugriff wird anschließend getrennt geprüft.",
        RemoteShares=new[]{new RemoteShareItem{Name="Pictures",Remark="Public pictures",AccessMode="Guest",SuggestedUserName=@"SOURCE-QA\Gast",MetadataVerified=true},
            new RemoteShareItem{Name="Documents",Remark="External share",MetadataVerified=false}}};}
    static WorkerResult AnonymousDenied(){return new WorkerResult {
        Success=false,AnonymousShareListDenied=true,RemoteComputerName="SOURCE-QA",RemoteAddress="192.168.44.21",
        ErrorCode="Win32: 5",ErrorType="System.ComponentModel.Win32Exception",
        Message="Windows erlaubt die Freigabenliste nicht ohne Benutzername. Einzelne freigegebene Ordner können trotzdem erreichbar sein. Der Ordnerzugriff ist hier noch ungeprüft.",
        Checks=new[]{new CheckItem{Name="Windows-Freigabenliste des Computers",State="info",Code="Win32: 5",Fixable=false,
            Detail="Original NetShareEnum: Zugriff verweigert (Win32: 5); HRESULT 0x80070005.",
            NextStep="Freigabenliste mit Netzwerk-Konto prüfen. Verwende ein vom anderen Computer gemeldetes oder selbst eingegebenes Konto. Alternativ einen bekannten Freigabenamen direkt prüfen."}}};}
    public static int Main(){try{
        I18n.Language="de";
        var serializer=new JavaScriptSerializer();
        foreach(string action in new[]{"InspectClient","PrepareClient","RestoreClient"}){
            var request=new ShareRequest{Action=action,Mode="Guest",AllowGuestSettings=action=="PrepareClient"};
            var result=Prepared();var session=new DiagnosticSession();session.RecordOperation(action,request,result);
            string report=session.BuildReport();
            Check(report.Contains(Line("Gespeicherte Client-Reparatur vorhanden","True")),action+" omitted journal state without target.");
            Check(report.Contains(Line("Gastkompatibilität ausdrücklich bestätigt",request.AllowGuestSettings.ToString())),action+" omitted explicit consent without target.");
            Check(report.Contains(Line("Windows-Zugriff geprüft","False")),action+" hid unverified remote access.");
            Check(report.Contains(Line("SMB-Verbindung geprüft","False")),action+" confused ready configuration with SMB connection.");
            Check(report.Contains(Line("Freigabenliste des Zielcomputers geprüft","False")),action+" fabricated enumeration verification.");
            Check(!report.Contains("Ziel-IP-Adresse:")&&!report.Contains("Zielfreigabe:"),action+" invented target details.");
            Check(report.Contains(Line("Sicherung der Client-Einstellungen","PRIVATE_CLIENT_JOURNAL_SENTINEL"))&&report.Contains(Line("Sicherung der Aktion","PRIVATE_SERVER_JOURNAL_SENTINEL"))&&report.Contains(Line("Sicherung der Dienst-Einstellungen","PRIVATE_SERVICE_JOURNAL_SENTINEL")),action+" lost the documented backup paths.");
            Check(session.HistoryCount==0,action+" fabricated an error for successful preparation.");
        }
        WorkerResult enumerated=Listed();
        WorkerResult copy=serializer.Deserialize<WorkerResult>(serializer.Serialize(enumerated));
        Check(copy.RemoteComputerEnumerationVerified&&!copy.ConnectionVerified&&!copy.NativeConnectionVerified&&!copy.NamedConnectionVerified,"JSON transport merged list proof with folder proof.");
        Check(copy.RemoteShares.Length==2&&copy.RemoteShares[0].SuggestedUserName==@"SOURCE-QA\Gast"&&copy.RemoteShares[0].MetadataVerified&&!copy.RemoteShares[1].MetadataVerified,"JSON lost public share data or structural metadata flags.");
        var enumRequest=new ShareRequest{Action="EnumerateComputer",RemoteHost="192.168.44.21",Mode="Guest"};
        Check(RequestRules.Validate(enumRequest)==null,"Explicit anonymous computer listing requires unknown share/account.");
        var listedSession=new DiagnosticSession();listedSession.RecordOperation("EnumerateComputer",enumRequest,enumerated);
        string listReport=listedSession.BuildReport();
        Check(listReport.Contains(Line("Freigabenliste des Zielcomputers geprüft","True")),"Confirmed computer list omitted.");
        Check(listReport.Contains(Line("Windows-Zugriff geprüft","False"))&&listReport.Contains(Line("SMB-Verbindung geprüft","False")),"Confirmed list falsely verified a folder.");
        Check(listReport.Contains(I18n.Format("Gefundene entfernte Freigabe {0}",1))&&listReport.Contains(I18n.Format("Gefundene entfernte Freigabe {0}",2)),"Public remote shares omitted from report.");
        Check(listReport.Contains(Line("Freigabe","Pictures"))&&listReport.Contains(Line("Gemeldeter Netzwerk-Benutzer",@"SOURCE-QA\Gast"))&&listReport.Contains(Line("Verbindungsdaten formal geprüft","True")),"Confirmed list lost public suggestion.");
        Check(listReport.Contains(Line("Verbindungsdaten formal geprüft","False")),"Unknown share became a valid account preset.");
        Check(!listReport.Contains("Ausgewählter Ordner / Datenträger:")&&!listReport.Contains("Namens-Freigabepfad:"),"Enumeration invented local data paths.");
        enumerated.RemoteShares[0].Name="MUTATED_REMOTE_NAME_SENTINEL";enumerated.RemoteShares[0].Remark="MUTATED_REMOTE_REMARK_SENTINEL";
        enumerated.RemoteShares[0].SuggestedUserName="MUTATED_REMOTE_ACCOUNT_SENTINEL";enumerated.RemoteComputerEnumerationVerified=false;
        enumRequest.RemoteHost="MUTATED_REMOTE_HOST_SENTINEL";
        listReport=listedSession.BuildReport();
        Check(!listReport.Contains("MUTATED_REMOTE_"),"Stored public report changed after DTO mutation.");
        Check(listReport.Contains(Line("Freigabenliste des Zielcomputers geprüft","True"))&&listReport.Contains("Pictures"),"Original verified enumeration evidence was lost.");
        const string plain="RECEIVER_PLAIN_SECRET_SENTINEL_882";const string cipher="RECEIVER_CIPHER_SECRET_SENTINEL_399";
        var failed=Listed();failed.Success=false;failed.RemoteComputerEnumerationVerified=false;failed.ErrorCode="Win32: 53";
        failed.ErrorType="System.ComponentModel.Win32Exception";failed.Message="original HRESULT 0x80070035; "+plain+"; "+cipher;
        failed.RemoteShares[0].Remark="password=PROVIDER_REMOTE_SECRET_SENTINEL; "+plain+"; "+cipher;
        failed.RemoteShares[1].SuggestedUserName="account-"+plain;
        var credentialRequest=new ShareRequest{Action="EnumerateComputer",Mode="Password",RemoteHost="192.168.44.21",RemoteUserName=@"SOURCE-QA\Network",ProtectedPassword=cipher};
        var errorSession=new DiagnosticSession();using(errorSession.ProtectSecrets(plain)){errorSession.RecordOperation("EnumerateComputer",credentialRequest,failed);}
        string errorReport=errorSession.BuildReport();
        Check(errorReport.Contains(Line("Sicherung der Client-Einstellungen","PRIVATE_CLIENT_JOURNAL_SENTINEL")),"Failure lost the documented client backup path.");
        foreach(string secret in new[]{plain,cipher,"PROVIDER_REMOTE_SECRET_SENTINEL","ProtectedPassword:"})Check(!errorReport.Contains(secret),"Remote report leaked "+secret);
        Check(errorReport.Contains("Win32: 53")&&errorReport.Contains("0x80070035"),"Redaction destroyed original Windows errors.");
        Check(errorSession.HistoryCount==1,"Failed enumeration was not retained.");
        errorSession.RecordOperation("PrepareClient",new ShareRequest{Action="PrepareClient",Mode="Guest",AllowGuestSettings=true},Prepared());
        errorReport=errorSession.BuildReport();
        Check(errorReport.Contains("Win32: 53")&&errorSession.HistoryCount==1,"Preparation erased previous original enumeration failure.");
        Check(!errorReport.Contains(plain)&&!errorReport.Contains(cipher),"Later action restored released passwords.");
        var folder=new WorkerResult{Success=true,ConnectionVerified=true,NativeConnectionVerified=true,RemoteComputerName="SOURCE-QA",RemoteAddress="192.168.44.21",RemoteShareName="Pictures",SharePath=@"\\192.168.44.21\Pictures"};
        var folderSession=new DiagnosticSession();folderSession.RecordOperation("ConnectRemote",new ShareRequest{Action="ConnectRemote",RemoteHost="192.168.44.21",RemoteShareName="Pictures",RemoteUserName=@"SOURCE-QA\Gast",Mode="Guest"},folder);
        string folderReport=folderSession.BuildReport();
        Check(folderReport.Contains(Line("Windows-Zugriff geprüft","True"))&&folderReport.Contains(Line("Freigabenliste des Zielcomputers geprüft","False")),"Folder-only proof invented complete computer-list proof.");
        var anonymous=AnonymousDenied();var anonymousRequest=new ShareRequest{Action="EnumerateComputer",Mode="Guest",RemoteHost="192.168.44.21"};
        var anonymousCopy=serializer.Deserialize<WorkerResult>(serializer.Serialize(anonymous));
        Check(anonymousCopy.AnonymousShareListDenied&&!anonymousCopy.Success&&!anonymousCopy.RemoteComputerEnumerationVerified&&!anonymousCopy.NativeConnectionVerified&&!anonymousCopy.ConnectionVerified,"Transport changed narrow anonymous failure into access success.");
        Check(anonymousCopy.ErrorCode=="Win32: 5"&&anonymousCopy.Checks[0].Code=="Win32: 5"&&anonymousCopy.Checks[0].State=="info"&&!anonymousCopy.Checks[0].Fixable,"Transport lost original anonymous-list code or invented global repair.");
        var anonymousSession=new DiagnosticSession();anonymousSession.RecordOperation("EnumerateComputer",anonymousRequest,anonymous);
        string anonymousReport=anonymousSession.BuildReport();
        Check(anonymousReport.Contains(Line("Anonyme Freigabenliste verweigert","True")),"Specific anonymous-list scope omitted.");
        Check(anonymousReport.Contains(Line("Ergebnis","Hinweis"))&&!anonymousReport.Contains(Line("Ergebnis","Erfolgreich"))&&anonymousReport.Contains("Win32: 5")&&anonymousReport.Contains("NetShareEnum")&&anonymousReport.Contains("0x80070005"),"Neutral list limitation lost scoped notice or original native failure.");
        Check(anonymousReport.Contains(Line("Freigabenliste des Zielcomputers geprüft","False"))&&anonymousReport.Contains(Line("Windows-Zugriff geprüft","False"))&&anonymousReport.Contains(Line("SMB-Verbindung geprüft","False")),"Anonymous refusal fabricated list or folder proof.");
        Check(anonymousSession.HistoryCount==1,"Informational anonymous limitation lost failed native call from history.");
        anonymous.AnonymousShareListDenied=false;anonymous.ErrorCode="MUTATED_ANONYMOUS_CODE_SENTINEL";anonymous.Checks[0].Detail="MUTATED_ANONYMOUS_DETAIL_SENTINEL";
        anonymousReport=anonymousSession.BuildReport();
        Check(anonymousReport.Contains(Line("Anonyme Freigabenliste verweigert","True"))&&!anonymousReport.Contains("MUTATED_ANONYMOUS_"),"Anonymous failure record was not immutable.");
        anonymousSession.RecordOperation("EnumerateComputer",new ShareRequest{Action="EnumerateComputer",Mode="Guest",RemoteHost="192.168.44.21",RemoteUserName=@"SOURCE-QA\Gast"},Listed());
        anonymousReport=anonymousSession.BuildReport();
        Check(anonymousReport.Contains(Line("Anonyme Freigabenliste verweigert","True"))&&anonymousReport.Contains(Line("Anonyme Freigabenliste verweigert","False"))&&anonymousReport.Contains("Win32: 5"),"Authenticated list success erased original anonymous limitation.");
        Check(anonymousSession.HistoryCount==1,"Authenticated retry duplicated successful action in warning history.");
        foreach(string invalidScope in new[]{"Password","NamedGuest","SecretGuest","DifferentAction","DifferentCode","ListProof","NativeProof","NamedProof","ConnectionProof","MissingFlag"}){
            var scopedRequest=new ShareRequest{Action="EnumerateComputer",Mode="Guest",RemoteHost="192.168.44.21"};
            var scopedResult=AnonymousDenied();string scopedAction="EnumerateComputer";
            if(invalidScope=="Password")scopedRequest.Mode="Password";
            if(invalidScope=="NamedGuest")scopedRequest.RemoteUserName=@"SOURCE-QA\Gast";
            if(invalidScope=="SecretGuest"){scopedRequest.ProtectedPassword="SCOPED_GUEST_DPAPI_SECRET_SENTINEL";scopedResult.Message+=" "+scopedRequest.ProtectedPassword;}
            if(invalidScope=="DifferentAction")scopedAction="ConnectRemote";
            if(invalidScope=="DifferentCode")scopedResult.ErrorCode="Win32: 53";
            if(invalidScope=="ListProof")scopedResult.RemoteComputerEnumerationVerified=true;
            if(invalidScope=="NativeProof")scopedResult.NativeConnectionVerified=true;
            if(invalidScope=="NamedProof")scopedResult.NamedConnectionVerified=true;
            if(invalidScope=="ConnectionProof")scopedResult.ConnectionVerified=true;
            if(invalidScope=="MissingFlag")scopedResult.AnonymousShareListDenied=false;
            var scopedSession=new DiagnosticSession();scopedSession.RecordOperation(scopedAction,scopedRequest,scopedResult);string scopedReport=scopedSession.BuildReport();
            Check(scopedReport.Contains(Line("Ergebnis","Fehlgeschlagen"))&&!scopedReport.Contains(Line("Ergebnis","Hinweis")),"Out-of-scope native failure was presented as an anonymous notice: "+invalidScope);
            Check(scopedReport.Contains(scopedResult.ErrorCode)&&scopedSession.HistoryCount==1,"Presentation changed native error/history: "+invalidScope);
            if(invalidScope=="SecretGuest")Check(!scopedReport.Contains("SCOPED_GUEST_DPAPI_SECRET_SENTINEL"),"Rejected secret-bearing guest request leaked protected password.");
        }
        foreach(string action in new[]{"ConnectRemote","EnumerateComputer","InspectClient"}){
            var ordinary=new WorkerResult{Success=false,ErrorCode="Win32: 5",RemoteComputerName=action=="InspectClient"?null:"SOURCE-QA",Checks=new[]{new CheckItem{Code="Win32: 5",State="error",Detail="Original Windows access denied."}}};
            var ordinarySession=new DiagnosticSession();ordinarySession.RecordOperation(action,new ShareRequest{Action=action,Mode="Password",RemoteUserName=@"SOURCE-QA\Network"},ordinary);
            string ordinaryReport=ordinarySession.BuildReport();
            Check(ordinaryReport.Contains(Line("Anonyme Freigabenliste verweigert","False"))&&!ordinaryReport.Contains(Line("Anonyme Freigabenliste verweigert","True")),"Generic access denied was labelled anonymous: "+action);
            Check(ordinaryReport.Contains("Win32: 5")&&ordinarySession.HistoryCount==1,"Ordinary access failure lost original code/history: "+action);
        }
        var sourceSession=new DiagnosticSession();sourceSession.RecordOperation("Inspect",new ShareRequest{Action="Inspect"},new WorkerResult{Success=false,ErrorCode="Win32: 5"});
        Check(!sourceSession.BuildReport().Contains(I18n.T("Anonyme Freigabenliste verweigert")+":"),"Local server inspection acquired unrelated anonymous-list scope.");
        int languages=0;foreach(LanguageItem language in I18n.Languages){languages++;I18n.Language=language.Code;listReport=listedSession.BuildReport();errorReport=errorSession.BuildReport();
            foreach(string label in new[]{"Freigabenliste des Zielcomputers geprüft","Gefundene entfernte Freigabe {0}","Öffentliche Freigabebeschreibung","Gemeldeter Netzwerk-Benutzer","Gemeldete Zugangsart","Verbindungsdaten formal geprüft"}){
                string translated=I18n.T(label);Check(!String.IsNullOrWhiteSpace(translated)&&(language.Code=="de"||translated!=label),"Missing report translation "+language.Code+" / "+label);
                Check(listReport.Contains(label.Contains("{0}")?I18n.Format(label,1):translated+":"),"Missing translated public report label "+language.Code+" / "+label);
            }
            Check(listReport.Contains(Line("Freigabenliste des Zielcomputers geprüft","True"))&&listReport.Contains(Line("Windows-Zugriff geprüft","False")),"Language merged list and folder proof: "+language.Code);
            Check(errorReport.Contains("Win32: 53")&&errorReport.Contains("0x80070035")&&!errorReport.Contains(plain)&&!errorReport.Contains(cipher),"Language lost original codes or restored secret: "+language.Code);
            string anonymousLabel=I18n.T("Anonyme Freigabenliste verweigert");anonymousReport=anonymousSession.BuildReport();
            Check(language.Code=="de"||anonymousLabel!="Anonyme Freigabenliste verweigert","Missing anonymous scope translation: "+language.Code);
            Check(anonymousReport.Contains(anonymousLabel+": True")&&anonymousReport.Contains(anonymousLabel+": False")&&anonymousReport.Contains("Win32: 5")&&anonymousReport.Contains("0x80070005"),"Translated retry lost scoped original anonymous failure: "+language.Code);
            Check(anonymousReport.Contains(Line("Ergebnis",I18n.T("Hinweis"))),"Translated history omitted anonymous query notice: "+language.Code);
            Check(anonymousReport.Contains(Line("Windows-Zugriff geprüft","False"))&&!anonymousReport.Contains(Line("Windows-Zugriff geprüft","True")),"Language converted list retry into folder proof: "+language.Code);
            Check(anonymousSession.HistoryCount==1&&!anonymousReport.Contains("MUTATED_ANONYMOUS_"),"Language changed immutable anonymous history: "+language.Code);
            foreach(string action in new[]{"InspectClient","PrepareClient","EnumerateComputer"})Check(!String.IsNullOrWhiteSpace(I18n.T(action)),"Missing new action translation "+language.Code+" / "+action);
        }
        Check(languages==7,"Seven languages not covered.");
        Console.WriteLine("Receiver report: "+count.ToString(CultureInfo.InvariantCulture)+" isolated checks passed; distinct configuration/list/folder proof, seven languages and credential redaction; no network or Windows changes.");return 0;
    }catch(Exception error){Console.Error.WriteLine(error);return 1;}}
}
'@
[IO.File]::WriteAllText($taskSource,$taskCode,(New-Object Text.UTF8Encoding($true)))
$taskCompiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $taskCompiler)){$taskCompiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
$taskExe=Join-Path $OutputFolder 'ReceiverReportQa.exe'
$AssemblyPath = (Resolve-Path -LiteralPath $AssemblyPath).Path
Copy-Item -LiteralPath $AssemblyPath -Destination (Join-Path $OutputFolder ([IO.Path]::GetFileName($AssemblyPath))) -Force
& $taskCompiler /nologo /target:exe /langversion:5 /optimize+ ('/out:'+$taskExe) /reference:System.dll /reference:System.Core.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll ('/reference:'+$AssemblyPath) $taskSource
if($LASTEXITCODE -ne 0){throw 'Receiver report QA did not compile.'}
& $taskExe
if($LASTEXITCODE -ne 0){throw 'Receiver report QA failed.'}
