using System;
using System.Drawing;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    public sealed partial class MainForm
    {
        private TableLayoutPanel problemNotice;
        private Label problemState, problemCause;
        private Button problemFix, problemList;
        private RememberedProblem shownProblem;
        private Control BuildProblemNotice()
        {
            problemNotice = Card("Erkannte Probleme", "Das Programm zeigt Ursache und passende Hilfe automatisch nach einer Prüfung.");
            problemNotice.Visible = false;
            problemState = Paragraph(String.Empty, problemNotice); problemState.Font = new Font("Segoe UI", 10f, FontStyle.Bold);
            problemCause = Paragraph(String.Empty, problemNotice);
            problemNotice.Controls.Add(problemState); problemNotice.Controls.Add(problemCause);
            TableLayoutPanel actions = ActionGrid(2); actions.Height = 38;
            problemFix = ActionButton("Dieses Problem beheben", 300, true); problemList = ActionButton("Probleme und Lösungen", 300, false);
            actions.Controls.Add(problemFix, 0, 0); actions.Controls.Add(problemList, 1, 0); problemNotice.Controls.Add(actions);
            problemFix.Click += async delegate { await FixRememberedProblem(); };
            problemList.Click += async delegate { await OpenErrorFixWindow(true); };
            return problemNotice;
        }
        private void ProblemMemoryChanged(object sender, EventArgs args)
        {
            if (IsDisposed || !IsHandleCreated) return;
            if (InvokeRequired) { BeginInvoke(new Action(RefreshProblemNotice)); return; }
            RefreshProblemNotice();
            if (problemNotice.Visible && homeScroll != null) homeScroll.ScrollControlIntoView(problemNotice);
        }
        private void RefreshProblemNotice()
        {
            if (problemNotice == null || IsDisposed) return;
            RememberedProblem[] all = ProblemMemory.Snapshot();
            shownProblem = all.LastOrDefault(e => !e.Resolved && e.Check.State == "error") ??
                all.LastOrDefault(e => !e.Resolved && e.Check.Fixable && ErrorFixDialog.ActionFor(e.Check) != ErrorFixAction.None) ??
                all.LastOrDefault(e => !e.Resolved) ?? all.LastOrDefault();
            problemNotice.Visible = shownProblem != null;
            if (shownProblem == null) return;
            CheckItem check = shownProblem.Check;
            problemState.Text = I18n.T(shownProblem.Resolved ? "Erneut geprüft und behoben" : "Problem erkannt") + ": " + I18n.T(check.Name ?? "Prüfung");
            problemState.ForeColor = shownProblem.Resolved ? Accent : StateColor(check.State);
            string text = I18n.TranslatePhase(check.Detail ?? String.Empty).Replace("\r\n", " ").Replace("\n", " ");
            problemCause.Text = text.Length > 240 ? text.Substring(0, 237) + "…" : text;
            homeHints.SetToolTip(problemCause, I18n.TranslatePhase(check.Detail ?? String.Empty) + "\n" + (check.Code ?? String.Empty));
            ErrorFixAction action = shownProblem.Resolved ? ErrorFixAction.None : ErrorFixDialog.ActionFor(check);
            problemFix.Text = I18n.T(action == ErrorFixAction.None ? "Fehlerbericht exportieren" : check.Fixable ? "Dieses Problem beheben" : "Passende Hilfe öffnen");
            problemFix.Enabled = problemList.Enabled = !busy;
            problemList.Text = I18n.T("Probleme und Lösungen");
            problemNotice.AccessibleDescription = problemState.Text + ". " + I18n.TranslatePhase(check.Detail ?? String.Empty);
        }
        private async Task FixRememberedProblem()
        {
            if (busy || shownProblem == null) return;
            CheckItem check = shownProblem.Check;
            ErrorFixAction action = shownProblem.Resolved ? ErrorFixAction.None : ErrorFixDialog.ActionFor(check);
            if (action == ErrorFixAction.None) { DiagnosticReports.Current.SaveReport(this); return; }
            await RouteErrorFix(action, check);
        }
    }
}
