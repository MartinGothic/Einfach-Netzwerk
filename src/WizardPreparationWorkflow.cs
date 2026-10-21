using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace EinfachNetzwerk
{
    internal static class WizardPreparationWorkflow
    {
        private const string ReceiverReady = "Dieser PC ist auch für andere Gastfreigaben vorbereitet. Der tatsächliche Zugriff wird nach der Auswahl des anderen Computers geprüft.";
        private const string ReceiverIncomplete = "Die lokale Freigabe ist eingerichtet. Die Vorbereitung für andere Gastfreigaben braucht noch einen Schritt. Das Prüfergebnis zeigt die Ursache und die passende Reparatur.";

        internal static async Task<WorkerResult> PrepareReceiverAsync(WizardSelection selection, WorkerResult server,
            Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> runReceiver,
            Action<string> phase, Action<WorkProgress> counted)
        {
            if (server == null) return Failure("WIZARD_SERVER_RESULT_MISSING", "Die Einrichtung wurde nicht abgeschlossen. Bitte beachte das Prüfergebnis im Hauptfenster.");
            if (!server.Success || selection == null || !selection.Guest || !selection.PrepareReceiver) return server;

            // Keep all server facts, its undo location, share list and local access
            // proof separate from the client settings checked by this extra step.
            WorkerResult merged = JsonData.Parse<WorkerResult>(JsonData.Serialize(server));
            merged.WizardReceiverRequested = true;
            merged.WizardReceiverReady = false;
            List<WorkerResult> observed = new List<WorkerResult>();
            WorkerResult terminal;
            if (selection.Network == null || selection.Network.Id < 0)
                terminal = Failure("WIZARD_RECEIVER_NETWORK_REQUIRED", "Die gewählte Heimnetzverbindung fehlt. Die lokale Freigabe bleibt eingerichtet.");
            else if (runReceiver == null)
                terminal = Failure("WIZARD_RECEIVER_RUNNER_MISSING", "Windows hat für die Empfängerprüfung kein Ergebnis zurückgegeben.");
            else
            {
                terminal = await Run(runReceiver, Request("InspectClient", selection.Network.Id), phase, counted);
                observed.Add(terminal);
                if (!terminal.Success && String.Equals(terminal.ErrorCode, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", StringComparison.Ordinal) &&
                    (terminal.Checks ?? new CheckItem[0]).Any(c => c != null && c.Fixable && String.Equals(c.Code, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", StringComparison.Ordinal)))
                {
                    WorkerResult preparation = await Run(runReceiver, Request("PrepareClient", selection.Network.Id), phase, counted);
                    observed.Add(preparation);
                    terminal = preparation;
                    if (preparation.Success)
                    {
                        terminal = await Run(runReceiver, Request("InspectClient", selection.Network.Id), phase, counted);
                        observed.Add(terminal);
                    }
                }
            }

            List<CheckItem> checks = new List<CheckItem>(merged.Checks ?? new CheckItem[0]);
            // Old failed compatibility checks remain in the diagnostic history.
            // Only fresh state and successful repair notes appear as current state.
            foreach (WorkerResult prior in observed.Where(r => r != terminal && r.Success))
                checks.AddRange((prior.Checks ?? new CheckItem[0]).Where(c => c != null && String.Equals(c.State, "info", StringComparison.OrdinalIgnoreCase)));
            checks.AddRange((terminal.Checks ?? new CheckItem[0]).Where(c => c != null));
            merged.Checks = checks.ToArray();
            foreach (WorkerResult result in observed)
            {
                if (result.ClientRepairAvailable) merged.ClientRepairAvailable = true;
                if (!String.IsNullOrWhiteSpace(result.ClientBackupPath)) merged.ClientBackupPath = result.ClientBackupPath;
            }
            merged.WizardReceiverReady = terminal.Success;
            merged.Success = server.Success && terminal.Success;
            merged.Message = terminal.Success ? ReceiverReady : ReceiverIncomplete;
            if (!terminal.Success)
            {
                merged.ErrorCode = terminal.ErrorCode;
                merged.ErrorType = terminal.ErrorType;
                merged.ErrorStackTrace = terminal.ErrorStackTrace;
                if (!checks.Any(c => c != null && String.Equals(c.State, "error", StringComparison.OrdinalIgnoreCase)))
                {
                    checks.Add(new CheckItem { Name = "Windows-Client für andere Gastfreigaben", State = "error", Detail = terminal.Message,
                        Code = String.IsNullOrWhiteSpace(terminal.ErrorCode) ? "WIZARD_RECEIVER_NOT_READY" : terminal.ErrorCode,
                        NextStep = "Öffne den Fehler-Fixer und wähle den passenden Eintrag. Der Fehlerbericht enthält die Details." });
                    merged.Checks = checks.ToArray();
                }
            }
            return merged;
        }

        private static ShareRequest Request(string action, int adapter)
        {
            return new ShareRequest { Action = action, Mode = "Guest", AdapterId = adapter, AllowGuestSettings = action == "PrepareClient" };
        }

        private static async Task<WorkerResult> Run(Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> run,
            ShareRequest request, Action<string> phase, Action<WorkProgress> counted)
        {
            bool firstCount = true;
            Action<WorkProgress> progress = delegate(WorkProgress value)
            {
                if (counted == null || value == null || value.Total <= 0 || value.Completed < 0 || value.Completed > value.Total ||
                    value.Percent != (int)((long)value.Completed * 100 / value.Total)) return;
                WorkProgress snapshot = new WorkProgress { Text = value.Text, Total = value.Total, Completed = value.Completed,
                    Percent = value.Percent, PhaseStart = firstCount, ResultAccepted = value.ResultAccepted };
                firstCount = false;
                counted(snapshot);
            };
            try
            {
                WorkerResult result = await run(request, phase, progress);
                return result ?? Failure("WIZARD_RECEIVER_RESULT_MISSING", "Windows hat für die Empfängerprüfung kein Ergebnis zurückgegeben.");
            }
            catch (Exception error)
            {
                // The backend records its original operation. Retain the concrete
                // exception if a caller fails before it can deliver a result.
                WorkerResult result = Failure("WIZARD_RECEIVER_EXCEPTION", DiagnosticReports.Current.Redact(error.Message));
                result.ErrorType = error.GetType().FullName;
                result.ErrorStackTrace = DiagnosticReports.Current.Redact(error.ToString());
                return result;
            }
        }

        private static WorkerResult Failure(string code, string detail)
        {
            return new WorkerResult { Success = false, Message = detail, ErrorCode = code, ErrorType = "WizardReceiverPreparation",
                Checks = new[] { new CheckItem { Name = "Windows-Client für andere Gastfreigaben", State = "error", Detail = detail, Code = code,
                    NextStep = "Öffne den Fehler-Fixer und wähle den passenden Eintrag. Der Fehlerbericht enthält die Details." } } };
        }
    }
}
