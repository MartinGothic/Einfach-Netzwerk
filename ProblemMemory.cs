using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace EinfachNetzwerk
{
    internal sealed class RememberedProblem
    {
        internal string Scope, Operation;
        internal CheckItem Check;
        internal bool Resolved;
        internal RememberedProblem Copy()
        {
            return new RememberedProblem { Scope = Scope, Operation = Operation, Resolved = Resolved,
                Check = JsonData.Parse<CheckItem>(JsonData.Serialize(Check)) };
        }
    }

    // Session-only, redacted causes. A successful unrelated operation never
    // erases an error. Resolution requires the same check and connection scope.
    internal static class ProblemMemory
    {
        private static readonly object gate = new object();
        private static readonly List<RememberedProblem> entries = new List<RememberedProblem>();
        internal static event EventHandler Changed;
        internal static RememberedProblem[] Snapshot()
        {
            lock (gate) return entries.Select(e => e.Copy()).ToArray();
        }
        internal static void Observe(string operation, ShareRequest context, WorkerResult result, Exception error, Func<string, string> redact)
        {
            if (result == null && error == null) return;
            if (result == null) result = BackendClient.Failure(error.Message, error);
            CheckItem[] checks = (result.Checks ?? new CheckItem[0]).Where(c => c != null).ToArray();
            List<CheckItem> problems = checks.Where(c => c.State == "error" || c.State == "warning").ToList();
            if (!result.Success && problems.Count == 0 && !result.AnonymousShareListDenied)
                problems.Add(new CheckItem { Name = "Aktion", State = "error", Detail = result.Message, Code = result.ErrorCode });
            bool changed = false;
            bool clientReady = VerifiedClientPreparation(context, result, checks);
            lock (gate)
            {
                foreach (CheckItem check in checks.Where(c => c.State == "ok" && VerifiedObservation(c, result)))
                {
                    string scope = ScopeKey(operation, context, result, check);
                    foreach (RememberedProblem entry in entries.Where(e => !e.Resolved && e.Scope == scope &&
                        (IsClientSummary(e.Check) ? clientReady && check.Code == "CLIENT_PREPARATION_READY" :
                        (String.Equals(e.Check.Name, check.Name, StringComparison.OrdinalIgnoreCase) ||
                        (e.Check.Code == "RESET_BACKUP_SERVICE_REQUIRED" && check.Name == "LanmanServer" && check.Code == "SERVICE_RUNNING") ||
                        (e.Check.Name == "Windows-Zugriff über den Computernamen" && check.Name == "Freigabenliste über Computernamen geöffnet" && check.Code == "WINDOWS_NATIVE_NAME_ACCESS_VERIFIED")))))
                    { entry.Resolved = true; changed = true; }
                }
                foreach (CheckItem check in problems)
                {
                    string scope = ScopeKey(operation, context, result, check);
                    RememberedProblem entry = entries.LastOrDefault(e => e.Scope == scope && e.Check.Name == check.Name && e.Check.Code == check.Code);
                    CheckItem clean = new CheckItem { Name = redact(check.Name), State = check.State, Code = redact(check.Code),
                        Detail = redact(check.Detail), NextStep = redact(check.NextStep), Fixable = check.Fixable,
                        TargetShare = redact(check.TargetShare), RemoteHost = redact(check.RemoteHost) };
                    if (String.IsNullOrEmpty(clean.RemoteHost) && ((check.Code ?? "").StartsWith("REMOTE_", StringComparison.Ordinal) ||
                        check.Name == "Echter Windows-Client-Zugriff" || check.Name == "Windows-Freigabenliste des Computers" || check.Name == "Windows-Zugriff über den Computernamen"))
                        clean.RemoteHost = redact(context == null ? result.RemoteAddress : context.RemoteHost);
                    if (entry == null) { entry = new RememberedProblem { Scope = scope }; entries.Add(entry); }
                    entry.Check = clean; entry.Operation = redact(operation);
                    entry.Resolved = !result.InspectionIncomplete && check.Name == "Windows-Zugriff vor der Reparatur" && result.NativeConnectionVerified && result.ConnectionVerified;
                    changed = true;
                }
                while (entries.Count > 32) entries.RemoveAt(0);
            }
            if (changed) { EventHandler handler = Changed; if (handler != null) handler(null, EventArgs.Empty); }
        }
        private static bool IsClientSummary(CheckItem check)
        {
            string name = I18n.SourceOf(check.Name);
            return check.Code == "CLIENT_GUEST_COMPATIBILITY_REQUIRED" && (name == "Prüfung" || name == "Aktion");
        }
        private static bool VerifiedClientPreparation(ShareRequest request, WorkerResult result, CheckItem[] checks)
        {
            if (request == null || request.Action != "InspectClient" || !result.Success || result.InspectionIncomplete) return false;
            Func<string, bool> ready = code => checks.Any(check => check.State == "ok" && check.Code == code);
            Func<string, bool> setting = name => checks.Any(check => check.State == "ok" && check.Code == "CLIENT_EFFECTIVE_SETTING" && check.Name == "Windows-Client: " + name);
            return ready("CLIENT_PREPARATION_READY") && ready("SERVICE_WORKSTATION_READY") && ready("CLIENT_PRIVATE_LAN_READY") &&
                setting("EnableInsecureGuestLogons") && setting("RequireSecuritySignature") &&
                (setting("RequireEncryption") || checks.Any(check => check.Name == "Windows-Client: RequireEncryption" && check.State == "info" && check.Code == "CLIENT_PROPERTY_UNAVAILABLE"));
        }
        private static string Scope(string operation, ShareRequest request, WorkerResult result, CheckItem check)
        {
            string code = check.Code ?? "", name = check.Name ?? "";
            if (name == "LanmanServer" || name == "LanmanWorkstation" || name == "FDResPub" || name == "fdPHost" || code.StartsWith("SERVICE_", StringComparison.Ordinal) || code == "RESET_BACKUP_SERVICE_REQUIRED") return "services/" + Environment.MachineName;
            if (code.StartsWith("CLIENT_", StringComparison.Ordinal) && !code.StartsWith("CLIENT_NAME_", StringComparison.Ordinal)) return "client/" + Environment.MachineName;
            if (code.StartsWith("REMOTE_", StringComparison.Ordinal) || request != null && !String.IsNullOrEmpty(request.RemoteHost))
                return "remote/" + ((request == null ? check.RemoteHost ?? result.RemoteAddress : request.RemoteHost) ?? "").ToUpperInvariant() + "/" + ((request == null ? result.RemoteShareName : request.RemoteShareName) ?? "").ToUpperInvariant() +
                    "/" + (request == null ? String.Empty : (request.Mode ?? String.Empty).ToUpperInvariant()) + "/" + (request == null ? String.Empty : (request.RemoteUserName ?? String.Empty).ToUpperInvariant());
            string share = check.TargetShare;
            if (String.IsNullOrEmpty(share) && request != null) share = request.ShareName;
            if (!String.IsNullOrEmpty(share)) return "share/" + Environment.MachineName + "/" + share.ToUpperInvariant();
            string action = request == null ? operation : request.Action;
            if ((action ?? "").IndexOf("Reset", StringComparison.OrdinalIgnoreCase) >= 0 || (operation ?? "").IndexOf("Rücksetz", StringComparison.OrdinalIgnoreCase) >= 0) return "reset/" + Environment.MachineName;
            return "operation/" + (action ?? "");
        }
        private static string ScopeKey(string operation, ShareRequest request, WorkerResult result, CheckItem check)
        {
            byte[] value = Encoding.UTF8.GetBytes(Scope(operation, request, result, check));
            try { using (SHA256 hash = SHA256.Create()) return BitConverter.ToString(hash.ComputeHash(value)); }
            finally { Array.Clear(value, 0, value.Length); }
        }
        private static bool VerifiedObservation(CheckItem check, WorkerResult result)
        {
            if (result.InspectionIncomplete) return false;
            if (check.Name == "Konfiguration des Serverdiensts") return check.Code == "SERVICE_SERVER_METADATA_PRESENT";
            if ((check.Name ?? String.Empty).StartsWith("Windows-Client: ", StringComparison.Ordinal)) return check.Code == "CLIENT_EFFECTIVE_SETTING";
            if (check.Name == "Echter Windows-Client-Zugriff") return result.NativeConnectionVerified && result.ConnectionVerified && check.Code == "WINDOWS_NATIVE_ACCESS_VERIFIED";
            if (check.Name == "Windows-Freigabenliste des Computers") return result.RemoteComputerEnumerationVerified && check.Code == "REMOTE_COMPUTER_ENUMERATION_VERIFIED";
            if (check.Name == "Windows-Zugriff über den Computernamen" || check.Name == "Freigabenliste über Computernamen geöffnet")
                return result.NamedConnectionVerified && result.NamedAccessCode == "WINDOWS_NATIVE_NAME_ACCESS_VERIFIED" && check.Code == "WINDOWS_NATIVE_NAME_ACCESS_VERIFIED";
            if (check.Name == "LanmanServer" || check.Name == "LanmanWorkstation" || check.Name == "FDResPub" || check.Name == "fdPHost") return check.Code == "SERVICE_RUNNING";
            return true;
        }
        internal static WorkerResult AsResult()
        {
            RememberedProblem[] all = Snapshot();
            return new WorkerResult { Success = all.All(e => e.Resolved || e.Check.State != "error"), Message = "Erkannte Probleme bleiben mit ihrer ursprünglichen Ursache sichtbar.",
                Checks = all.Select(e => { CheckItem c = e.Check; if (e.Resolved) { c.State = "ok"; c.Detail = I18n.T("Erneut geprüft und behoben. Ursprüngliche Ursache:") + " " + c.Detail; } return c; }).ToArray() };
        }
    }
}
