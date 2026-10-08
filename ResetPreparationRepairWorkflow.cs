using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Threading.Tasks;

namespace EinfachNetzwerk
{
    // Repairs prerequisites only. Share removal and undo belong exclusively to
    // the separate reviewed ResetNetworkWorkflow.ExecuteAsync transaction.
    internal static class ResetPreparationRepairWorkflow
    {
        private const string Scope = "Voraussetzungen automatisch beheben";
        private const string Unsupported = "Diese Ursache kann hier nicht automatisch geändert werden. Der ursprüngliche Fehler und sein nächster Schritt bleiben erhalten. Es wurde keine Freigabe entfernt.";

        internal static async Task<ResetNetworkPlan> PrepareAsync(
            Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> run,
            string auditDirectory, Action<string> phase, Action<WorkProgress> counted)
        {
            Observed before = new Observed(run);
            ResetNetworkPlan initial = await ResetNetworkWorkflow.PrepareAsync(before.Invoke, auditDirectory, phase, counted);
            CheckItem[] serviceChecks = before.Services == null ? new CheckItem[0] : before.Services.Checks ?? new CheckItem[0];
            bool supported = serviceChecks.Any(SupportedService);
            if (!supported)
            {
                CheckItem unknownServer = serviceChecks.FirstOrDefault(c => c != null && c.Name == "LanmanServer" && c.State == "error");
                if (unknownServer != null)
                    return Add(initial, serviceChecks.Concat(new[] { Note("info", Unsupported, "RESET_PREPARATION_UNSUPPORTED") }), false,
                        String.IsNullOrWhiteSpace(initial.ErrorCode) ? Code(before.Services, unknownServer.Code) : initial.ErrorCode, Unsupported, before.Services);
                return initial.CanExecute ? initial : Add(initial, new[] { Note("info", Unsupported, "RESET_PREPARATION_UNSUPPORTED") }, false, initial.ErrorCode, initial.Message, null);
            }

            // Starting all four supported services must not run alongside an
            // unreadable journal, managed policy, missing service or query error.
            if (!initial.InventoryConfirmed || HasUnsafeEvidence(before) ||
                initial.Checks.Any(c => c != null && c.State == "error" && !ServicePrerequisite(c)))
                return Add(initial, new[] { before.Source, before.Client, before.Services }.Where(r => r != null)
                    .SelectMany(r => r.Checks ?? new CheckItem[0]).Where(c => c != null && UnsafeCheck(c) && !initial.Checks.Any(old => JsonData.Serialize(old) == JsonData.Serialize(c)))
                    .Concat(new[] { Note("info", Unsupported, "RESET_PREPARATION_UNSUPPORTED") }), false, initial.ErrorCode,
                    initial.CanExecute ? Unsupported : initial.Message, null);

            NetworkItem[] networks = (before.Services.Networks ?? new NetworkItem[0]).Where(PrivateNetwork).ToArray();
            if (networks.Length != 1)
                return Add(initial, new[] { Note("error", "Für die Dienstereparatur muss genau eine aktive private LAN/WLAN-Verbindung bestätigt sein. Es wird kein Netzwerk geraten.", "SERVICE_PRIVATE_NETWORK_REQUIRED") },
                    false, "SERVICE_PRIVATE_NETWORK_REQUIRED", Unsupported, null);

            // The backend validates identity, policy, current service state and
            // preserves the first saved Before values. No advanced repair here.
            ShareRequest request = new ShareRequest { Action = "RepairServices", AdapterId = networks[0].Id, AllowAdvancedRepair = false };
            WorkerResult repair = await Repair(run, request, phase, counted);
            Observed after = new Observed(run);
            ResetNetworkPlan fresh = await ResetNetworkWorkflow.PrepareAsync(after.Invoke, auditDirectory, phase, counted);
            List<CheckItem> notes = new List<CheckItem>();
            foreach (CheckItem old in serviceChecks.Where(SupportedService))
            {
                CheckItem history = JsonData.Parse<CheckItem>(JsonData.Serialize(old));
                history.State = "info"; history.Fixable = false;
                history.Detail = "Vor dem Reparaturversuch: " + (old.Detail ?? String.Empty);
                notes.Add(history);
            }
            foreach (CheckItem observed in (repair.Checks ?? new CheckItem[0]).Where(c => c != null))
            {
                CheckItem step = JsonData.Parse<CheckItem>(JsonData.Serialize(observed));
                if (repair.Success && step.State == "error") { step.State = "info"; step.Detail = "Vor dem Reparaturversuch: " + (step.Detail ?? String.Empty); }
                notes.Add(step);
            }
            if (after.Services != null)
                notes.AddRange((after.Services.Checks ?? new CheckItem[0]).Where(c => c != null && !fresh.Checks.Concat(notes).Any(old => JsonData.Serialize(old) == JsonData.Serialize(c))));
            if (!String.IsNullOrWhiteSpace(repair.ServiceBackupPath))
                notes.Add(Note("info", repair.ServiceBackupPath, "RESET_PREPARATION_SERVICE_BACKUP"));

            if (!repair.Success)
            {
                if (!String.IsNullOrWhiteSpace(repair.Message) && !notes.Any(c => c.Detail == repair.Message))
                    notes.Add(Note("error", repair.Message, Code(repair, "RESET_PREPARATION_REPAIR_FAILED")));
                return Add(fresh, notes, false, Code(repair, "RESET_PREPARATION_REPAIR_FAILED"),
                    "Der Dienstereparaturversuch wurde nicht bestätigt. Die Voraussetzungen wurden danach frisch geprüft; Freigaben wurden nicht entfernt.", repair,
                    before.Services != null && before.Services.ServiceRepairAvailable ? before.Services : repair.ServiceRepairAvailable ? repair : null);
            }

            WorkerResult saved = before.Services != null && before.Services.ServiceRepairAvailable ? before.Services : repair;
            if (saved.ServiceRepairAvailable && (String.IsNullOrWhiteSpace(saved.ServiceBackupPath) ||
                !fresh.RestoreServices || !String.Equals(saved.ServiceBackupPath, fresh.ServiceBackupPath, StringComparison.OrdinalIgnoreCase)))
            {
                if (!String.IsNullOrWhiteSpace(saved.ServiceBackupPath)) notes.Add(Note("info", saved.ServiceBackupPath, "RESET_PREPARATION_ORIGINAL_SERVICE_BACKUP"));
                notes.Add(Note("error", "Die ursprüngliche Dienstesicherung wurde nach der Reparatur nicht unverändert bestätigt. Der Bericht bewahrt ihren Pfad; es wird nichts zurückgesetzt.", "RESET_PREPARATION_BACKUP_UNCONFIRMED"));
                return Add(fresh, notes, false, "RESET_PREPARATION_BACKUP_UNCONFIRMED", Unsupported, repair, saved);
            }
            if (after.Services == null || !(after.Services.Checks ?? new CheckItem[0]).Any(c => c != null && c.Name == "LanmanServer" && c.State == "ok" && c.Code == "SERVICE_RUNNING"))
            {
                notes.Add(Note("error", "Windows hat nach dem Reparaturversuch noch keinen laufenden Serverdienst bestätigt. Es wird kein weiterer Reparaturversuch automatisch gestartet.", "RESET_PREPARATION_SERVICE_UNCONFIRMED"));
                return Add(fresh, notes, false, String.IsNullOrWhiteSpace(fresh.ErrorCode) ? "RESET_PREPARATION_SERVICE_UNCONFIRMED" : fresh.ErrorCode, Unsupported, after.Services);
            }
            notes.Add(Note("ok", "Die unterstützten Dienstvoraussetzungen wurden repariert und frisch geprüft. Freigaben wurden dabei nicht entfernt. Die Rücksetzung benötigt weiterhin deine eigene Bestätigung.", "RESET_PREPARATION_REPAIRED"));
            return Add(fresh, notes, fresh.CanExecute, fresh.ErrorCode, fresh.Message, null);
        }

        private static bool SupportedService(CheckItem check)
        {
            return check != null && check.State == "error" && check.Fixable &&
                new[] { "LanmanServer", "LanmanWorkstation", "FDResPub", "fdPHost" }.Contains(check.Name) &&
                new[] { "SERVICE_STOPPED", "Win32: 2114", "Win32: 1058" }.Contains(check.Code);
        }
        private static bool ServicePrerequisite(CheckItem check)
        {
            return SupportedService(check) || check.Code == "RESET_BACKUP_SERVICE_REQUIRED" ||
                (check.Name == "Lokaler SMB-Port 445" && check.Code == "SERVICE_LOCAL_PORT_CLOSED");
        }
        private static bool HasUnsafeEvidence(Observed data)
        {
            return new[] { data.Source, data.Client, data.Services }.Where(r => r != null).Any(r =>
                new[] { "CLIENT_MANAGED_POLICY", "CLIENT_POLICY_STATE_UNKNOWN", "POLICY_BLOCK" }.Contains(r.ErrorCode) ||
                (r.Checks ?? new CheckItem[0]).Any(UnsafeCheck));
        }
        private static bool UnsafeCheck(CheckItem c)
        {
            return c == null ||
                    new[] { "CLIENT_MANAGED_POLICY", "CLIENT_POLICY_STATE_UNKNOWN", "POLICY_BLOCK" }.Contains(c.Code) ||
                    ((c.Code ?? String.Empty).Contains("JOURNAL") && (c.State == "warning" || c.State == "error")) ||
                    (c.Name == "Journal" && (c.State == "warning" || c.State == "error")) ||
                    c.Code == "SERVICE_SERVER_METADATA_INVALID" || c.Code == "SERVICE_SERVER_METADATA_QUERY_FAILED" ||
                    (new[] { "LanmanServer", "LanmanWorkstation", "FDResPub", "fdPHost" }.Contains(c.Name) && c.State == "error" && !SupportedService(c));
        }
        private static bool PrivateNetwork(NetworkItem network)
        {
            IPAddress address;
            if (network == null || network.Id <= 0 || network.Category != "Private" || !IPAddress.TryParse(network.Address, out address) ||
                address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return false;
            byte[] bytes = address.GetAddressBytes();
            return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168);
        }
        private static string Code(WorkerResult result, string fallback) { return result != null && !String.IsNullOrWhiteSpace(result.ErrorCode) ? result.ErrorCode : fallback; }
        private static CheckItem Note(string state, string detail, string code) { return new CheckItem { Name = Scope, State = state, Detail = detail, Code = code }; }
        private static ResetNetworkPlan Add(ResetNetworkPlan plan, IEnumerable<CheckItem> notes, bool ready, string code, string message, WorkerResult failure, WorkerResult serviceScope = null)
        {
            WorkerResult diagnostic = plan.DiagnosticResult;
            WorkerResult client = new WorkerResult { ClientRepairAvailable = plan.RestoreClient, ClientBackupPath = plan.ClientBackupPath };
            WorkerResult services = serviceScope ?? new WorkerResult { ServiceRepairAvailable = plan.RestoreServices, ServiceBackupPath = plan.ServiceBackupPath };
            return new ResetNetworkPlan(plan.Inventory, plan.Checks.Concat(notes).ToArray(), client, services,
                ready, plan.AuditPath, code, message, failure ?? diagnostic);
        }
        private static async Task<WorkerResult> Repair(Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> run,
            ShareRequest request, Action<string> phase, Action<WorkProgress> counted)
        {
            bool first = true;
            try
            {
                WorkerResult result = await run(request, phase, delegate(WorkProgress value) {
                    if (counted == null || value == null || value.Total <= 0 || value.Completed < 0 || value.Completed > value.Total ||
                        value.Percent != (int)((long)value.Completed * 100 / value.Total)) return;
                    counted(new WorkProgress { Text = value.Text, Total = value.Total, Completed = value.Completed, Percent = value.Percent, PhaseStart = first, ResultAccepted = value.ResultAccepted }); first = false;
                });
                if (result != null) return result;
                return new WorkerResult { Success = false, ErrorCode = "RESET_PREPARATION_RESULT_MISSING", Message = "Windows hat für die Dienstereparatur kein Ergebnis geliefert." };
            }
            catch (Exception error)
            {
                return new WorkerResult { Success = false, ErrorCode = "RESET_PREPARATION_EXCEPTION", ErrorType = error.GetType().FullName,
                    Message = DiagnosticReports.Current.Redact(error.Message), ErrorStackTrace = DiagnosticReports.Current.Redact(error.ToString()) };
            }
        }
        private sealed class Observed
        {
            private readonly Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> run;
            internal WorkerResult Source, Client, Services;
            internal Observed(Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> runner) { run = runner; }
            internal async Task<WorkerResult> Invoke(ShareRequest request, Action<string> phase, Action<WorkProgress> counted)
            {
                WorkerResult actual = run == null ? null : await run(request, phase, counted);
                WorkerResult copy = actual == null ? null : JsonData.Parse<WorkerResult>(JsonData.Serialize(actual));
                if (request.Action == "InspectResetShares") Source = copy;
                else if (request.Action == "InspectClient") Client = copy;
                else if (request.Action == "InspectServices") Services = copy;
                else throw new InvalidOperationException("RESET_PREPARATION_UNEXPECTED_INSPECTION");
                return actual;
            }
        }
    }
}
