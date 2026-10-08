using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace EinfachNetzwerk
{
    internal sealed class ResetNetworkPlan
    {
        private readonly string inventoryJson, checksJson, failureJson;
        internal bool CanExecute { get; private set; }
        internal bool RestoreClient { get; private set; }
        internal bool RestoreServices { get; private set; }
        internal string AuditPath { get; private set; }
        internal string Message { get; private set; }
        internal string ErrorCode { get; private set; }
        internal string ComputerName { get; private set; }
        internal string ClientBackupPath { get; private set; }
        internal string ServiceBackupPath { get; private set; }
        internal string OwnerSid { get; private set; }
        internal bool InventoryConfirmed { get { return ResetNetworkWorkflow.HasConfirmedInventory(Inventory); } }
        internal WorkerResult Inventory { get { return JsonData.Parse<WorkerResult>(inventoryJson); } }
        internal ShareItem[] Shares { get { return ResetNetworkWorkflow.Ordinary(Inventory.Shares); } }
        internal CheckItem[] Checks { get { return JsonData.Parse<CheckItem[]>(checksJson); } }
        internal WorkerResult DiagnosticResult
        {
            get
            {
                WorkerResult result = Inventory;
                WorkerResult failure = JsonData.Parse<WorkerResult>(failureJson);
                result.Success = CanExecute; result.Message = Message; result.ErrorCode = ErrorCode; result.Checks = Checks;
                result.ClientBackupPath = ClientBackupPath; result.ClientRepairAvailable = RestoreClient;
                result.ServiceBackupPath = ServiceBackupPath; result.ServiceRepairAvailable = RestoreServices;
                if (!CanExecute && failure != null) { result.ErrorType = failure.ErrorType; result.ErrorStackTrace = failure.ErrorStackTrace; }
                result.ConnectionVerified = result.NativeConnectionVerified = result.NamedConnectionVerified = result.RemoteComputerEnumerationVerified = false;
                return result;
            }
        }
        internal ResetNetworkPlan(WorkerResult inventory, CheckItem[] checks, WorkerResult client, WorkerResult services, bool ready, string audit, string code, string message)
            : this(inventory, checks, client, services, ready, audit, code, message, inventory) { }
        internal ResetNetworkPlan(WorkerResult inventory, CheckItem[] checks, WorkerResult client, WorkerResult services, bool ready, string audit, string code, string message, WorkerResult failure)
        {
            inventoryJson = JsonData.Serialize(inventory ?? new WorkerResult()); checksJson = JsonData.Serialize(checks ?? new CheckItem[0]); failureJson = JsonData.Serialize(failure);
            CanExecute = ready; AuditPath = audit ?? String.Empty; ErrorCode = code ?? String.Empty; Message = message ?? String.Empty;
            ComputerName = Environment.MachineName; OwnerSid = WindowsIdentity.GetCurrent().User.Value;
            RestoreClient = client != null && client.ClientRepairAvailable; ClientBackupPath = client == null ? String.Empty : client.ClientBackupPath ?? String.Empty;
            RestoreServices = services != null && services.ServiceRepairAvailable; ServiceBackupPath = services == null ? String.Empty : services.ServiceBackupPath ?? String.Empty;
        }
    }

    internal static class ResetNetworkWorkflow
    {
        private const string Next = "Klicke auf „Automatisch prüfen und beheben“. Bereits ausgeführte Schritte und der ursprüngliche Fehler bleiben im Fehlerbericht erhalten.";
        internal static async Task<ResetNetworkPlan> PrepareAsync(Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> run,
            string auditDirectory, Action<string> phase, Action<WorkProgress> counted)
        {
            WorkerResult source = await Run(run, Request("InspectResetShares"), phase, counted);
            WorkerResult client = await Run(run, Request("InspectClient"), phase, counted);
            WorkerResult services = await Run(run, Request("InspectServices"), phase, counted);
            List<CheckItem> checks = new List<CheckItem>();
            WorkerResult failure = null;
            string invalid = ValidateInventory(source);
            if (invalid != null)
            {
                failure = source;
                AddInspectionFailure(checks, source, "Freigaben für die Rücksetzung", invalid, "RESET_INVENTORY_UNCONFIRMED");
                checks.Add(Check("Freigaben für die Rücksetzung", "info", "Die Freigabenliste ist ungeprüft. Eine leere Anzeige bedeutet hier nicht, dass keine Freigaben vorhanden sind.", "RESET_INVENTORY_UNCONFIRMED"));
            }
            foreach (WorkerResult unavailable in new[] { client, services }.Where(TransportFailure))
            {
                if (failure == null) failure = unavailable;
                AddInspectionFailure(checks, unavailable, "Gesicherte Windows-Einstellungen", "Die gespeicherten Client- oder Dienstereinstellungen konnten nicht vollständig geprüft werden.", "RESET_SETTINGS_UNCONFIRMED");
            }
            CheckItem stoppedServer = (services.Checks ?? new CheckItem[0]).FirstOrDefault(c => c != null && c.Name == "LanmanServer" && c.State == "error" && c.Fixable &&
                (c.Code == "SERVICE_STOPPED" || c.Code == "Win32: 2114" || c.Code == "Win32: 1058"));
            if (stoppedServer != null)
            {
                if (failure == null) failure = services;
                foreach (CheckItem serviceCheck in (services.Checks ?? new CheckItem[0]).Where(c => c != null))
                    if (!checks.Any(c => JsonData.Serialize(c) == JsonData.Serialize(serviceCheck))) checks.Add(serviceCheck);
                checks.Add(new CheckItem { Name = "Serverdienst für die Sicherung", State = "error", Code = "RESET_BACKUP_SERVICE_REQUIRED", Fixable = true,
                    Detail = "Die vollständige Sicherung benötigt den laufenden Serverdienst. „Automatisch prüfen und beheben“ kann den bestätigten Dienstfehler zuerst reparieren. Dabei werden keine Freigaben entfernt.", NextStep = Next });
            }
            if (client.ClientRepairAvailable && (String.IsNullOrWhiteSpace(client.ClientBackupPath) || client.ErrorCode == "CLIENT_MANAGED_POLICY" || client.ErrorCode == "CLIENT_POLICY_STATE_UNKNOWN"))
            {
                if (failure == null) failure = client;
                AddInspectionFailure(checks, client, "Client-Rücknahme", "Die gesicherte Client-Rücknahme ist vorhanden, aber Windows hat ihren Verwaltungsstatus nicht bestätigt.", "RESET_CLIENT_SCOPE_BLOCKED");
            }
            if (services.ServiceRepairAvailable && String.IsNullOrWhiteSpace(services.ServiceBackupPath)) checks.Add(Check("Dienstereparatur-Rücknahme", "error", "Der gesicherte Rücknahmepfad für die Dienste fehlt.", "RESET_SERVICE_SCOPE_BLOCKED"));
            checks.Add(Check("Freigaben", "info", "Alle aufgeführten Datenfreigaben werden entfernt. Dateien bleiben erhalten; Windows-Systemfreigaben bleiben bestehen.", "RESET_DATA_SHARES_SCOPE"));
            checks.Add(Check("Gesicherte Freigabeeinstellungen", "info", "Für verwaltete Freigaben werden die gespeicherten eigenen Ordnerrechte, Firewall-Regeln und Windows-Netzwerkeinstellungen zurückgenommen. Fremde spätere Änderungen werden erhalten.", "RESET_MANAGED_SCOPE"));
            checks.Add(Check("Client-Einstellungen", "info", client.ClientRepairAvailable ? "Die gesicherten eigenen Client-Einstellungen werden zurückgenommen." : "Für den Windows-Client wurde keine eigene gespeicherte Rücknahme gemeldet.", "RESET_CLIENT_SCOPE"));
            checks.Add(Check("Dienstereinstellungen", "info", services.ServiceRepairAvailable ? "Die gesicherten eigenen Dienstereinstellungen werden zurückgenommen." : "Für die Dienstereparatur wurde keine eigene gespeicherte Rücknahme gemeldet.", "RESET_SERVICE_SCOPE"));
            checks.Add(Check("Grenzen der Rücksetzung", "info", "Es werden bekannte gesicherte Originalzustände verwendet. Unbekannte frühere Windows-, Adapter-, Router- oder VPN-Einstellungen werden nicht durch vermutete Standardwerte ersetzt.", "RESET_KNOWN_ORIGINALS_ONLY"));
            string audit = String.Empty;
            if (checks.All(c => c.State != "error"))
            {
                try { audit = WriteAudit(auditDirectory, new { Kind = "EinfachNetzwerkResetPlan", Version = 1, CreatedUtc = DateTime.UtcNow.ToString("o"), Computer = Environment.MachineName, Inventory = source, ClientRestore = client.ClientRepairAvailable, ClientBackup = client.ClientBackupPath, ServicesRestore = services.ServiceRepairAvailable, ServicesBackup = services.ServiceBackupPath, Checks = checks.ToArray() }, true); }
                catch (Exception error) { checks.Add(Check("Rücksetzungsplan sichern", "error", DiagnosticReports.Current.Redact(error.Message), "RESET_AUDIT_FAILED")); }
            }
            bool ready = checks.All(c => c.State != "error") && !String.IsNullOrWhiteSpace(audit);
            return new ResetNetworkPlan(source, checks.ToArray(), client, services, ready, audit,
                ready ? String.Empty : failure != null && !String.IsNullOrWhiteSpace(failure.ErrorCode) ? failure.ErrorCode : checks.First(c => c.State == "error").Code,
                ready ? "Der Rücksetzungsplan ist bereit. Erst nach deiner Bestätigung werden Freigaben oder Einstellungen geändert." : "Der Rücksetzungsplan ist noch nicht vollständig bestätigt. Es wurde nichts zurückgesetzt.", failure);
        }

        internal static async Task<WorkerResult> ExecuteAsync(ResetNetworkPlan plan, Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> run,
            Action<string> phase, Action<WorkProgress> counted)
        {
            if (plan == null || !plan.CanExecute) return Failure("RESET_PLAN_REQUIRED", "Erstelle zuerst einen bestätigten Rücksetzungsplan.");
            if (plan.ComputerName != Environment.MachineName || plan.OwnerSid != WindowsIdentity.GetCurrent().User.Value) return Failure("RESET_PLAN_IDENTITY_CHANGED", "Dieser Rücksetzungsplan gehört zu einem anderen Computer oder Windows-Benutzer.");
            WorkerResult source = await Run(run, Request("InspectResetShares"), phase, counted);
            WorkerResult client = await Run(run, Request("InspectClient"), phase, counted);
            WorkerResult services = await Run(run, Request("InspectServices"), phase, counted);
            string invalid = ValidateInventory(source);
            if (invalid != null)
                return Stop(source, "RESET_PLAN_STALE", "Die Freigaben oder Rücknahmedaten haben sich seit dem Plan geändert. Bitte die Übersicht neu erstellen.",
                    new[] { Check("Freigaben für die Rücksetzung", "info", "Die Freigabenliste ist ungeprüft. Eine leere Anzeige bedeutet hier nicht, dass keine Freigaben vorhanden sind.", "RESET_INVENTORY_UNCONFIRMED") }, null);
            if (TransportFailure(client) || TransportFailure(services))
                return Stop(TransportFailure(client) ? client : services, "RESET_PLAN_STALE", "Die gespeicherten Client- oder Dienstereinstellungen konnten nicht vollständig geprüft werden.", new CheckItem[0], null);
            if (!SameShares(plan.Shares, source.Shares) ||
                client.ClientRepairAvailable != plan.RestoreClient || services.ServiceRepairAvailable != plan.RestoreServices ||
                !String.Equals(client.ClientBackupPath ?? String.Empty, plan.ClientBackupPath, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(services.ServiceBackupPath ?? String.Empty, plan.ServiceBackupPath, StringComparison.OrdinalIgnoreCase))
                return Failure("RESET_PLAN_STALE", "Die Freigaben oder Rücknahmedaten haben sich seit dem Plan geändert. Bitte die Übersicht neu erstellen.");
            if (plan.RestoreClient && (client.ErrorCode == "CLIENT_MANAGED_POLICY" || client.ErrorCode == "CLIENT_POLICY_STATE_UNKNOWN"))
                return Failure("RESET_CLIENT_SCOPE_BLOCKED", "Die gesicherte Client-Rücknahme ist vorhanden, aber Windows hat ihren Verwaltungsstatus nicht bestätigt.");

            WorkerResult backup = await Run(run, Request("BackupReset"), phase, counted);
            if (!backup.Success || String.IsNullOrWhiteSpace(backup.BackupPath)) return Stop(backup, "RESET_BACKUP_UNCONFIRMED", "Die vollständige Sicherung wurde nicht bestätigt. Es wurde keine Freigabe entfernt.", new CheckItem[0], null);
            try { WriteAudit(Path.GetDirectoryName(plan.AuditPath), new { Kind = "EinfachNetzwerkResetExecution", Version = 1, CreatedUtc = DateTime.UtcNow.ToString("o"), PlanAudit = plan.AuditPath, Backup = backup.BackupPath, Inventory = source }, false); }
            catch (Exception error) { return Stop(Failure("RESET_AUDIT_FAILED", DiagnosticReports.Current.Redact(error.Message)), "RESET_AUDIT_FAILED", "Die Ausführungssicherung konnte nicht geschrieben werden. Es wurde keine Freigabe entfernt.", new CheckItem[0], backup.BackupPath); }

            List<CheckItem> completed = new List<CheckItem>();
            completed.Add(Check("Vollständige Sicherung", "ok", backup.BackupPath, "RESET_BACKUP_CREATED"));
            // Remove independent shares first; the last managed share can restore
            // a formerly stopped SMB service or the original network profile.
            foreach (ShareItem share in plan.Shares.Where(s => !s.Managed).Concat(plan.Shares.Where(s => s.Managed)))
            {
                ShareRequest removal = Request(share.Managed ? "Remove" : "RemoveListedShare");
                removal.ShareName = share.Name; removal.FolderPath = share.Path;
                WorkerResult result = await Run(run, removal, phase, counted);
                if (!result.Success) return Stop(result, "RESET_SHARE_FAILED", "Die Rücksetzung ist nur teilweise abgeschlossen. Eine Freigabe konnte nicht zurückgenommen werden.", completed, backup.BackupPath);
                completed.AddRange(result.Checks ?? new CheckItem[0]);
            }
            foreach (string action in (plan.RestoreClient ? new[] { "RestoreClient" } : new string[0]).Concat(plan.RestoreServices ? new[] { "RestoreServices" } : new string[0]))
            {
                ShareRequest request = Request(action); request.BackupPath = action == "RestoreClient" ? plan.ClientBackupPath : plan.ServiceBackupPath;
                WorkerResult result = await Run(run, request, phase, counted);
                if (!result.Success) return Stop(result, "RESET_SETTING_FAILED", "Die Datenfreigaben wurden bearbeitet. Mindestens eine gespeicherte Windows-Einstellung braucht noch einen Schritt.", completed, backup.BackupPath);
                completed.AddRange(result.Checks ?? new CheckItem[0]);
            }
            WorkerResult final = await Run(run, Request("InspectResetShares"), phase, counted);
            invalid = ValidateInventory(final);
            if (invalid != null) return Stop(final, "RESET_FINAL_INVENTORY_UNCONFIRMED", "Die Rücknahmeschritte wurden ausgeführt. Die abschließende Freigabenliste konnte noch nicht bestätigt werden.", completed, backup.BackupPath);
            if (Ordinary(final.Shares).Length != 0) return Stop(final, "RESET_SHARES_REMAIN", "Windows meldet noch Datenfreigaben. Diese werden nicht außerhalb des bestätigten Plans entfernt.", completed, backup.BackupPath);
            WorkerResult success = JsonData.Parse<WorkerResult>(JsonData.Serialize(final));
            success.Success = true; success.BackupPath = backup.BackupPath; success.Message = "Die bestätigten Datenfreigaben sind entfernt. Bekannte eigene Windows-Einstellungen wurden zurückgenommen. Dateien und Windows-Systemfreigaben bleiben erhalten.";
            success.ConnectionVerified = success.NativeConnectionVerified = success.NamedConnectionVerified = success.RemoteComputerEnumerationVerified = false;
            completed.Add(Check("Datenfreigaben nach der Rücksetzung", "ok", "Windows hat die leere Datenfreigabenliste frisch bestätigt.", "RESET_NO_DATA_SHARES"));
            success.Checks = completed.Concat(final.Checks ?? new CheckItem[0]).ToArray();
            return success;
        }

        private static ShareRequest Request(string action) { return new ShareRequest { Action = action, AdapterId = -1 }; }
        private static bool TransportFailure(WorkerResult result)
        {
            return result == null || result.Checks == null || result.Checks.Length == 0 ||
                (result.ErrorCode ?? String.Empty).StartsWith("RESET_", StringComparison.Ordinal) ||
                (result.ErrorCode ?? String.Empty).StartsWith("BACKEND_FAILURE", StringComparison.Ordinal) ||
                result.Checks.Any(c => c == null || (c.Name == "Aktion" && c.State == "error") || c.Code == "SERVICE_JOURNAL_INVALID" || c.Code == "CLIENT_JOURNAL_INVALID" ||
                    (c.Name == "Journal" && (c.State == "error" || c.State == "warning")));
        }
        internal static ShareItem[] Ordinary(ShareItem[] shares)
        {
            return (shares ?? new ShareItem[0]).Where(s => s != null && !Regex.IsMatch(s.Name ?? String.Empty, @"^(?:ADMIN\$|IPC\$|[A-Z]\$)$", RegexOptions.IgnoreCase)).ToArray();
        }
        internal static bool HasConfirmedInventory(WorkerResult source) { return ValidateInventory(source) == null; }
        private static void AddInspectionFailure(List<CheckItem> checks, WorkerResult actual, string scope, string fallbackDetail, string fallbackCode)
        {
            if (actual != null)
                foreach (CheckItem originalCheck in (actual.Checks ?? new CheckItem[0]).Where(c => c != null))
                    if (!checks.Any(c => JsonData.Serialize(c) == JsonData.Serialize(originalCheck))) checks.Add(originalCheck);
            // Add scope without replacing original native code, message or next step.
            // Even an error-free-looking partial list cannot authorize removal.
            string code = actual != null && !String.IsNullOrWhiteSpace(actual.ErrorCode) ? actual.ErrorCode : fallbackCode;
            string detail = actual != null && !String.IsNullOrWhiteSpace(actual.Message) ? actual.Message : fallbackDetail;
            CheckItem item = Check(scope, "error", detail, code);
            CheckItem original = actual == null ? null : (actual.Checks ?? new CheckItem[0]).FirstOrDefault(c => c != null && !String.IsNullOrWhiteSpace(c.NextStep) && c.State == "error");
            if (original != null) item.NextStep = original.NextStep;
            checks.Add(item);
        }
        private static string ValidateInventory(WorkerResult source)
        {
            if (source == null || !source.Success || source.Shares == null || source.Checks == null || source.Checks.Length == 0 ||
                source.Checks.Any(c => c == null || c.State == "error" || (c.Name == "Journal" && c.State == "warning")) ||
                !source.Checks.Any(c => c != null && c.Name == "Freigaben" && c.State == "ok" && c.Code == "RESET_SHARE_INVENTORY_CONFIRMED"))
                return "Die aktuelle Datenfreigabenliste wurde nicht vollständig von Windows bestätigt.";
            ShareItem[] ordinary = Ordinary(source.Shares);
            if (source.Shares.Any(s => s == null) || ordinary.GroupBy(s => s.Name ?? String.Empty, StringComparer.OrdinalIgnoreCase).Any(g => g.Count() != 1)) return "Die Freigabenliste enthält fehlende oder mehrdeutige Einträge.";
            foreach (ShareItem share in ordinary)
            {
                ShareRequest check = Request(share.Managed ? "Remove" : "RemoveListedShare"); check.ShareName = share.Name; check.FolderPath = share.Path;
                if (RequestRules.Validate(check) != null || String.IsNullOrWhiteSpace(share.Path) || !Regex.IsMatch(share.Path, @"^[A-Za-z]:[\\/]")) return "Eine Datenfreigabe hat keinen gültigen lokalen Namen oder Ordnerpfad.";
                try { Path.GetFullPath(share.Path); } catch (Exception) { return "Ein Datenfreigabepfad ist ungültig."; }
                if (!share.Available && !share.Managed) return "Ein nicht verwalteter Freigabeeintrag wurde nicht als vorhanden bestätigt.";
            }
            return null;
        }
        private static bool SameShares(ShareItem[] planned, ShareItem[] current)
        {
            Func<ShareItem, string> identity = s => JsonData.Serialize(new { Name = (s.Name ?? String.Empty).ToUpperInvariant(), Path = Path.GetFullPath(s.Path).TrimEnd('\\', '/').ToUpperInvariant(), s.Managed, s.Available, s.Mode, s.UserName, s.AllowWrite, s.AdapterId });
            string[] before = Ordinary(planned).Select(identity).OrderBy(s => s, StringComparer.Ordinal).ToArray();
            string[] after = Ordinary(current).Select(identity).OrderBy(s => s, StringComparer.Ordinal).ToArray();
            return before.SequenceEqual(after, StringComparer.Ordinal);
        }
        private static CheckItem Check(string name, string state, string detail, string code) { return new CheckItem { Name = name, State = state, Detail = detail, Code = code, NextStep = state == "error" ? Next : String.Empty }; }
        private static WorkerResult Failure(string code, string detail) { return new WorkerResult { Success = false, Message = detail, ErrorCode = code, ErrorType = "ResetNetworkWorkflow", Checks = new[] { Check("Netzwerkeinrichtung zurücksetzen", "error", detail, code) } }; }
        private static WorkerResult Stop(WorkerResult actual, string fallback, string message, IEnumerable<CheckItem> prior, string backup)
        {
            WorkerResult result = actual == null ? Failure(fallback, message) : JsonData.Parse<WorkerResult>(JsonData.Serialize(actual));
            result.Success = false; result.Message = message;
            if (String.IsNullOrWhiteSpace(result.ErrorCode)) result.ErrorCode = fallback;
            result.BackupPath = backup ?? result.BackupPath;
            List<CheckItem> checks = prior.Concat(actual == null ? new CheckItem[0] : actual.Checks ?? new CheckItem[0]).Where(c => c != null).ToList();
            if (actual != null && !String.IsNullOrWhiteSpace(actual.Message) && !checks.Any(c => c.Detail == actual.Message))
            {
                CheckItem cause = Check("Ursprünglicher Windows-Fehler", "error", actual.Message, result.ErrorCode);
                CheckItem original = checks.FirstOrDefault(c => c.State == "error" && !String.IsNullOrWhiteSpace(c.NextStep));
                if (original != null) cause.NextStep = original.NextStep;
                checks.Add(cause);
            }
            checks.Add(Check("Netzwerkeinrichtung zurücksetzen", "error", message, result.ErrorCode));
            result.Checks = checks.ToArray();
            result.ConnectionVerified = result.NativeConnectionVerified = result.NamedConnectionVerified = result.RemoteComputerEnumerationVerified = false;
            return result;
        }
        private static async Task<WorkerResult> Run(Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> run, ShareRequest request, Action<string> phase, Action<WorkProgress> counted)
        {
            if (run == null) return Failure("RESET_RUNNER_MISSING", "Die Windows-Prüfung konnte nicht gestartet werden.");
            bool first = true;
            try
            {
                WorkerResult result = await run(request, phase, delegate(WorkProgress value) {
                    if (counted == null || value == null || value.Total <= 0 || value.Completed < 0 || value.Completed > value.Total || value.Percent != (int)((long)value.Completed * 100 / value.Total)) return;
                    WorkProgress copy = new WorkProgress { Text = value.Text, Total = value.Total, Completed = value.Completed, Percent = value.Percent, PhaseStart = first, ResultAccepted = value.ResultAccepted }; first = false; counted(copy);
                });
                return result ?? Failure("RESET_RESULT_MISSING", "Windows hat für die Rücksetzung kein Ergebnis zurückgegeben.");
            }
            catch (Exception error) { WorkerResult result = Failure("RESET_RUN_EXCEPTION", DiagnosticReports.Current.Redact(error.Message)); result.ErrorType = error.GetType().FullName; result.ErrorStackTrace = DiagnosticReports.Current.Redact(error.ToString()); return result; }
        }
        private static string WriteAudit(string directory, object record, bool newSession)
        {
            if (String.IsNullOrWhiteSpace(directory) || !Path.IsPathRooted(directory)) throw new InvalidOperationException("Der lokale Sicherungsordner für den Rücksetzungsplan fehlt.");
            directory = Path.GetFullPath(directory);
            for (DirectoryInfo parent = new DirectoryInfo(directory); parent != null; parent = parent.Parent)
                if (parent.Exists && (parent.Attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("Der Sicherungsordner darf keine Ordnerumleitung enthalten.");
            if (newSession) directory = Path.Combine(directory, "reset-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            if (newSession)
            {
                DirectorySecurity security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
                foreach (SecurityIdentifier sid in new[] { WindowsIdentity.GetCurrent().User, new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                    security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                new DirectoryInfo(directory).SetAccessControl(security);
            }
            string path = Path.Combine(directory, (newSession ? "plan-" : "execution-") + Guid.NewGuid().ToString("N") + ".json");
            byte[] bytes = new UTF8Encoding(false).GetBytes(JsonData.Serialize(record));
            using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { output.Write(bytes, 0, bytes.Length); output.Flush(true); }
            if (File.ReadAllText(path, Encoding.UTF8) != Encoding.UTF8.GetString(bytes)) throw new IOException("Der Rücksetzungsplan wurde nicht vollständig gespeichert.");
            return path;
        }
    }
}
