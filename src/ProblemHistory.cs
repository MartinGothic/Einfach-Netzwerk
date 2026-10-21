using System;
using System.Collections.Generic;
using System.Text;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    // A successful operation is not proof that an earlier finding was fixed.
    // Only a fresh check of the same subject, or a scoped native proof, resolves it.
    internal sealed class ProblemHistory
    {
        private sealed class Finding
        {
            internal CheckItem Check;
            internal string Context;
            internal bool Resolved;
        }
        private readonly List<Finding> findings = new List<Finding>();
        internal bool HasProblems { get { return findings.Count != 0; } }
        internal bool HasUnresolved { get { return Latest(false) != null; } }

        internal void Observe(WorkerResult result, string context, bool allowConfirmation = true)
        {
            if (result == null) return;
            foreach (CheckItem check in result.Checks ?? new CheckItem[0])
            {
                if (check == null) continue;
                foreach (Finding old in findings)
                    if (allowConfirmation && !result.InspectionIncomplete && SameSubject(old, check, context) && Is(check.State, "ok") && ConfirmedCheck(result, check)) old.Resolved = true;
                if (!Is(check.State, "error") && !Is(check.State, "warning")) continue;
                bool duplicate = false;
                foreach (Finding old in findings)
                    if (SameSubject(old, check, context) && Is(old.Check.Code, check.Code) && String.Equals(old.Check.Detail, check.Detail, StringComparison.Ordinal))
                    { old.Resolved = false; duplicate = true; break; }
                if (!duplicate) Remember(check, context);
            }
            if (!result.Success && !result.AnonymousShareListDenied && !HasCurrentProblem(result))
                RememberFailure(result.Message, result.ErrorCode, context);
        }
        internal void RememberFailure(string message, string code, string context)
        {
            CheckItem check = new CheckItem { Name = "Vorgang nicht abgeschlossen", State = "error", Detail = message, Code = code };
            foreach (Finding old in findings)
                if (SameSubject(old, check, context) && Is(old.Check.Code, code) && String.Equals(old.Check.Detail, message, StringComparison.Ordinal))
                { old.Resolved = false; return; }
            Remember(check, context);
        }
        private void Remember(CheckItem check, string context)
        {
            if (findings.Count >= 32) findings.RemoveAt(0);
            findings.Add(new Finding { Context = context ?? String.Empty, Check = new CheckItem {
                Name = DiagnosticReports.Current.Redact(check.Name), State = check.State, Detail = DiagnosticReports.Current.Redact(check.Detail), Code = DiagnosticReports.Current.Redact(check.Code),
                NextStep = DiagnosticReports.Current.Redact(check.NextStep), TargetShare = DiagnosticReports.Current.Redact(check.TargetShare), RemoteHost = DiagnosticReports.Current.Redact(check.RemoteHost), Fixable = check.Fixable } });
        }
        internal void Confirm(string context, Predicate<CheckItem> proofApplies)
        {
            if (proofApplies == null) return;
            foreach (Finding old in findings)
                if (Is(old.Context, context) && proofApplies(old.Check)) old.Resolved = true;
        }
        internal string Notice()
        {
            Finding value = Latest(false) ?? Latest(true);
            if (value == null) return String.Empty;
            string title = I18n.T(value.Resolved ? "Vorheriger Befund – durch erneute Prüfung behoben" : "Problem erkannt");
            string detail = I18n.TranslatePhase(value.Check.Detail ?? String.Empty);
            int newline = detail.IndexOfAny(new[] { '\r', '\n' });
            if (newline >= 0) detail = detail.Substring(0, newline);
            string text = title + ": " + I18n.T(value.Check.Name ?? String.Empty);
            if (!String.IsNullOrWhiteSpace(detail)) text += "\r\n" + detail;
            if (!String.IsNullOrWhiteSpace(value.Check.Code)) text += "  (" + I18n.T("Fehlercode") + ": " + value.Check.Code + ")";
            if (!value.Resolved && !String.IsNullOrWhiteSpace(value.Check.NextStep)) text += "\r\n" + I18n.TranslatePhase(value.Check.NextStep);
            return text;
        }
        internal string AppendDetails(string current)
        {
            if (!HasProblems) return current ?? String.Empty;
            StringBuilder text = new StringBuilder(current ?? String.Empty);
            foreach (Finding value in findings)
            {
                text.AppendLine().AppendLine().Append(I18n.T(value.Resolved ? "Vorheriger Befund – durch erneute Prüfung behoben" : "Vorheriger Befund – noch nicht erneut bestätigt"));
                text.AppendLine().Append(I18n.T(value.Check.Name ?? String.Empty)).Append(": ").Append(I18n.TranslatePhase(value.Check.Detail ?? String.Empty));
                if (!String.IsNullOrWhiteSpace(value.Check.Code)) text.AppendLine().Append(I18n.T("Fehlercode")).Append(": ").Append(value.Check.Code);
                if (!String.IsNullOrWhiteSpace(value.Check.NextStep)) text.AppendLine().Append(I18n.T("Nächster Schritt")).Append(": ").Append(I18n.TranslatePhase(value.Check.NextStep));
            }
            return text.ToString();
        }
        private Finding Latest(bool resolved)
        {
            for (int i = findings.Count - 1; i >= 0; i--) if (findings[i].Resolved == resolved) return findings[i];
            return null;
        }
        private static bool SameSubject(Finding old, CheckItem check, string context)
        {
            return Is(old.Context, context) && Is(old.Check.Name, check.Name) && Is(old.Check.TargetShare, check.TargetShare) && Is(old.Check.RemoteHost, check.RemoteHost);
        }
        private static bool ConfirmedCheck(WorkerResult result, CheckItem check)
        {
            if (Is(check.Name, "Echter Windows-Client-Zugriff"))
                return result.ConnectionVerified && result.NativeConnectionVerified && Is(check.Code, "WINDOWS_NATIVE_ACCESS_VERIFIED");
            if (Is(check.Name, "Windows-Freigabenliste des Computers"))
                return result.RemoteComputerEnumerationVerified && Is(check.Code, "REMOTE_COMPUTER_ENUMERATION_VERIFIED");
            if (Is(check.Name, "Windows-Zugriff über den Computernamen") || Is(check.Name, "Freigabe über Computernamen geöffnet") || Is(check.Name, "Freigabenliste über Computernamen geöffnet"))
                return result.ConnectionVerified && result.NativeConnectionVerified && result.NamedConnectionVerified &&
                    Is(result.NamedAccessCode, "WINDOWS_NATIVE_NAME_ACCESS_VERIFIED") &&
                    (Is(check.Code, "WINDOWS_NATIVE_NAME_ACCESS_VERIFIED") || Is(check.Code, "WINDOWS_NATIVE_NAMED_SHARE_VERIFIED"));
            if (Is(check.Name, "LanmanServer") || Is(check.Name, "LanmanWorkstation") || Is(check.Name, "FDResPub") || Is(check.Name, "fdPHost"))
                return Is(check.Code, "SERVICE_RUNNING");
            return true;
        }
        private static bool Is(string left, string right) { return String.Equals(left ?? String.Empty, right ?? String.Empty, StringComparison.OrdinalIgnoreCase); }
        internal static bool HasCurrentProblem(WorkerResult result)
        {
            foreach (CheckItem check in result == null ? new CheckItem[0] : result.Checks ?? new CheckItem[0])
                if (check != null && (Is(check.State, "error") || Is(check.State, "warning"))) return true;
            return false;
        }
        internal static void SelectFirstProblem(ListView checks)
        {
            foreach (string state in new[] { "error", "warning" })
                foreach (ListViewItem row in checks.Items)
                {
                    CheckItem check = row.Tag as CheckItem;
                    if (check == null || !Is(check.State, state)) continue;
                    row.Selected = row.Focused = true; row.EnsureVisible(); return;
                }
        }
        internal static bool CanRepairService(CheckItem check)
        {
            if (check == null || !check.Fixable || (!Is(check.State, "error") && !Is(check.State, "warning"))) return false;
            if (Is(check.Code, "SERVICE_SERVER_METADATA_INVALID")) return true;
            bool service = Is(check.Name, "LanmanServer") || Is(check.Name, "LanmanWorkstation") || Is(check.Name, "FDResPub") || Is(check.Name, "fdPHost");
            if (!service) return false;
            if (Is(check.Code, "SERVICE_STOPPED") || Is(check.Code, "Win32: 2114") || Is(check.Code, "Win32: 1058")) return true;
            return Is(check.Code, "Win32: 1060") && (Is(check.Name, "FDResPub") || Is(check.Name, "fdPHost"));
        }
    }
}
