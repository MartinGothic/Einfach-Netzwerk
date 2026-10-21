using System;
using System.Collections.Generic;
using System.Drawing;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal enum ErrorFixAction { None, Services, Receiver, Share, ShareList, NameAccess, Discovery, Permissions, Reset, ClientPreparation }

    // This is a task chooser and an explicitly requested read-only inspection.
    // Repairs stay in the existing, scoped workflows with their own consent.
    internal sealed class ErrorFixDialog : AeroGlassForm
    {
        private const string ResetExplanation = "Normale Ordner- und Laufwerksfreigaben entfernen und gesicherte Netzwerkänderungen dieses Programms zurücknehmen. Zuerst wird eine Übersicht vorbereitet; Dateien bleiben erhalten.";
        private readonly bool preview;
        private readonly Func<Action<string>, Action<WorkProgress>, Task<WorkerResult>> inspectAll;
        private readonly Func<IWin32Window, Task> resetNetwork;
        private readonly List<Button> actions = new List<Button>();
        private readonly Panel scroll;
        private readonly TableLayoutPanel stack;
        private readonly CollapsibleSection resultsSection, detailSection;
        private readonly ListView checks;
        private readonly TextBox details;
        private readonly Label status, summary, percentage, readableCause;
        private readonly Button search, selectedAction, export, close, resetShortcut;
        private readonly CountedProgressPresenter presenter;
        private readonly Timer resultReveal = new Timer { Interval = 320 };
        private bool busy;
        private WorkerResult lastResult;

        internal ErrorFixAction RequestedAction { get; private set; }
        internal CheckItem RequestedCheck { get; private set; }

        internal ErrorFixDialog(bool preview, Func<Action<string>, Action<WorkProgress>, Task<WorkerResult>> inspectAll)
            : this(preview, inspectAll, null) { }

        internal ErrorFixDialog(bool preview, Func<Action<string>, Action<WorkProgress>, Task<WorkerResult>> inspectAll, Func<IWin32Window, Task> resetNetwork)
        {
            this.preview = preview; this.inspectAll = inspectAll; this.resetNetwork = resetNetwork;
            Text = I18n.T("Fehler-Fixer"); AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 9.5f); ForeColor = AeroTheme.Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(227, 243, 253);
            AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
            ClientSize = new Size(1010, 780); MinimumSize = new Size(900, 660);
            StartPosition = FormStartPosition.CenterParent; ShowInTaskbar = false; MinimizeBox = false;
            TableLayoutPanel shell = Grid(1, 3); shell.Padding = new Padding(12, 0, 12, 12);
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 164)); Controls.Add(shell);
            shell.Controls.Add(new AeroHeader { Heading = "Fehler-Fixer", Subtitle = "Wähle dein Problem. Wir führen dich zur passenden Reparatur.", Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 8) }, 0, 0);
            scroll = new BufferedScroll { Dock = DockStyle.Fill, AutoScroll = true, Margin = Padding.Empty, Padding = new Padding(3, 0, 3, 8) };
            shell.Controls.Add(scroll, 0, 1);
            stack = Grid(1, 0); stack.Dock = DockStyle.Top; stack.AutoSize = true; stack.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); scroll.Controls.Add(stack);
            Add(stack, Wrapped("Kein Scan beim Öffnen. Wähle ein Problem oder starte unten die Gesamtprüfung."));

            TableLayoutPanel cards = Grid(2, 0); cards.Dock = DockStyle.Top; cards.AutoSize = true; cards.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            AddCard(cards, ErrorFixAction.Receiver, "Anderer Computer lässt sich nicht öffnen", "„Konnte nicht zugegriffen werden“ oder 0x80070035: Prüfe Zielcomputer, Port 445 und die Anmeldung auf diesem PC.", "Netzwerkzugriff beheben");
            AddCard(cards, ErrorFixAction.Services, "Ein Netzwerkdienst fehlt oder ist gestoppt", "„Der Serverdienst wurde nicht gestartet“: Benötigte Windows-Dienste auf diesem PC prüfen und gezielt reparieren.", "Dienste reparieren");
            AddCard(cards, ErrorFixAction.Receiver, "Zugriff ohne Passwort wird blockiert", "Gastanmeldung, SMB-Signatur oder Verschlüsselung können den Zugriff blockieren. Die passende Einrichtung wird vorher erklärt.", "Anmeldung und SMB prüfen");
            AddCard(cards, ErrorFixAction.Permissions, "Ordner meldet „Zugriff verweigert“", "Auf dem freigebenden PC: Eine gespeicherte Freigabe auswählen und ihre Ordner- und Freigaberechte prüfen.", "Freigaberechte reparieren");
            AddCard(cards, ErrorFixAction.NameAccess, "IP funktioniert, Computername nicht", "Den Zugriff über IP und Computernamen getrennt testen. Das Programm prüft, welcher Verbindungsweg funktioniert.", "Computername prüfen");
            AddCard(cards, ErrorFixAction.ShareList, "Freigabenliste zeigt Win32: 5", "Eine anonyme Liste kann verweigert werden, obwohl ein Ordner erreichbar ist. Mit einem bekannten Netzwerk-Konto erneut prüfen.", "Freigabenliste prüfen");
            AddCard(cards, ErrorFixAction.Discovery, "Computer oder Freigabe wird nicht gefunden", "Die Erkennung für eine gespeicherte Freigabe im gewählten Heimnetz prüfen. Der andere Computer muss eingeschaltet und wach sein.", "Sichtbarkeit einrichten");
            AddCard(cards, ErrorFixAction.Share, "Eigene Freigabe funktioniert nicht", "Eine gespeicherte Freigabe prüfen und reparieren: Freigabe, Dienste, Heimnetz und Dateirechte werden zusammen geprüft.", "Eigene Freigabe reparieren");
            Add(stack, cards);
            GlassCard resetCard = new GlassCard { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, RowCount = 0, Padding = new Padding(13, 10, 13, 10), Margin = new Padding(0, 0, 0, 10) };
            resetCard.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            Add(resetCard, Wrapped(ResetExplanation));
            Button reset = ActionButton("Alles auf Standard zurücksetzen", false); reset.Dock = DockStyle.Top; reset.Height = 34; reset.Margin = Padding.Empty; reset.Tag = ErrorFixAction.Reset;
            reset.Click += async delegate { await OpenReset(); }; actions.Add(reset); Add(resetCard, reset); Add(stack, resetCard);

            resultsSection = new CollapsibleSection("Ergebnis der Gesamtprüfung") { Expanded = false, Margin = new Padding(0, 4, 0, 0) };
            summary = Wrapped("Noch nicht geprüft. Die Gesamtprüfung startet nur auf deinen Klick."); Add(resultsSection.Content, summary);
            checks = new BufferedChecks { Dock = DockStyle.Top, Height = 196, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false, Margin = new Padding(0, 6, 0, 6), AccessibleName = I18n.T("Ergebnis der Gesamtprüfung") };
            checks.Columns.Add(I18n.T("Prüfung"), 260); checks.Columns.Add(I18n.T("Status"), 120); checks.Columns.Add(I18n.T("Ursache / Details"), 530);
            checks.SelectedIndexChanged += delegate { ShowSelected(); }; Add(resultsSection.Content, checks);
            readableCause = Wrapped(String.Empty); Add(resultsSection.Content, readableCause);
            selectedAction = ActionButton("Passende Hilfe öffnen", false); selectedAction.Enabled = false; selectedAction.Height = 34; selectedAction.Dock = DockStyle.Top;
            selectedAction.Click += delegate { CheckItem item = SelectedCheck; if (item != null) Request(ActionFor(item), item); }; Add(resultsSection.Content, selectedAction);
            detailSection = new CollapsibleSection("Fehlercodes und technische Details") { Expanded = false, Margin = new Padding(0, 4, 0, 0) };
            details = new TextBox { Dock = DockStyle.Top, Height = 145, Multiline = true, ReadOnly = true, WordWrap = false, ScrollBars = ScrollBars.Both, BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(250, 253, 255), AccessibleName = I18n.T("Fehlercodes und technische Details") };
            Add(detailSection.Content, details); Add(resultsSection.Content, detailSection); Add(stack, resultsSection);

            TableLayoutPanel footer = Grid(2, 4); footer.Padding = new Padding(3, 9, 3, 0);
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 68));
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 43)); footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 47)); footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
            Label scope = Wrapped("Gesamtprüfung: Einstellungen und Dienste dieses PCs. Andere Computer werden gesucht; ihr Ordnerzugriff wird separat geprüft."); scope.Margin = Padding.Empty;
            footer.Controls.Add(scope, 0, 0); footer.SetColumnSpan(scope, 2);
            TableLayoutPanel buttons = Grid(4, 1); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 29)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 29)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 29)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 13)); buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            search = ActionButton("Alle Fehler suchen", true); export = ActionButton("Fehlerbericht exportieren", false); close = ActionButton("Schließen", false);
            resetShortcut = ActionButton("Alles zurücksetzen", false); resetShortcut.Tag = ErrorFixAction.Reset; resetShortcut.AccessibleDescription = I18n.T(ResetExplanation);
            resetShortcut.Click += async delegate { await OpenReset(); };
            buttons.Controls.Add(search, 0, 0); buttons.Controls.Add(export, 1, 0); buttons.Controls.Add(resetShortcut, 2, 0); buttons.Controls.Add(close, 3, 0); footer.Controls.Add(buttons, 0, 1); footer.SetColumnSpan(buttons, 2);
            status = new Label { Dock = DockStyle.Fill, UseMnemonic = false, AutoSize = false, Text = I18n.T("Bereit. Es wurden keine Prüfungen oder Änderungen ausgeführt."), Margin = new Padding(0, 5, 0, 3), ForeColor = MutedColor };
            footer.Controls.Add(status, 0, 2); footer.SetColumnSpan(status, 2);
            AeroProgressBar progress = new AeroProgressBar { Dock = DockStyle.Fill, Visible = false, Margin = Padding.Empty }; percentage = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleRight, Text = "0 %", Visible = false, Margin = Padding.Empty };
            footer.Controls.Add(progress, 0, 3); footer.Controls.Add(percentage, 1, 3); shell.Controls.Add(footer, 0, 2); presenter = new CountedProgressPresenter(progress, percentage);
            search.Click += async delegate { await Inspect(); };
            resultReveal.Tick += delegate
            {
                if (IsDisposed || !resultsSection.Expanded) { resultReveal.Stop(); return; }
                // Native content becomes visible only after the cached reveal ends.
                // The AutoSize stack's old scroll range can otherwise survive that motion.
                if (!resultsSection.Content.Visible) return;
                resultReveal.Stop(); scroll.AutoScrollMinSize = new Size(0, stack.Height + scroll.Padding.Vertical);
                scroll.PerformLayout(); scroll.AutoScrollPosition = new Point(0, Math.Max(0, resultsSection.Top));
            };
            stack.SizeChanged += delegate { if (resultsSection.Content.Visible) scroll.AutoScrollMinSize = new Size(0, stack.Height + scroll.Padding.Vertical); };
            export.Click += delegate { DiagnosticReports.Current.SaveReport(this); };
            close.Click += delegate { if (!busy) Close(); };
            FormClosing += delegate(object sender, FormClosingEventArgs args) { if (busy) args.Cancel = true; };
            Shown += delegate { AeroTheme.GlassFrame(this); };
            I18n.Changed += LanguageChanged; CancelButton = close; I18n.Apply(this); AeroTheme.StyleGlassChildren(this);
        }

        private static TableLayoutPanel Grid(int columns, int rows) { return new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = columns, RowCount = rows, Margin = Padding.Empty, Padding = Padding.Empty }; }
        private static Button ActionButton(string text, bool primary) { return new AeroButton { Text = I18n.T(text), Primary = primary, Dock = DockStyle.Fill, Margin = new Padding(0, 4, 8, 4), UseMnemonic = false }; }
        private static Color MutedColor { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(80, 103, 120); } }
        private static Label Wrapped(string text) { return new Label { Text = I18n.T(text), Dock = DockStyle.Top, AutoSize = true, UseMnemonic = false, Margin = new Padding(0, 3, 0, 9), ForeColor = MutedColor }; }
        private static void Add(TableLayoutPanel parent, Control child)
        {
            int row = parent.RowCount++; parent.RowStyles.Add(new RowStyle(SizeType.AutoSize)); parent.Controls.Add(child, 0, row);
            Label label = child as Label; if (label == null) return;
            EventHandler measure = delegate { int width = Math.Max(100, parent.ClientSize.Width - parent.Padding.Horizontal - label.Margin.Horizontal); label.MaximumSize = new Size(width, 0); };
            parent.SizeChanged += measure; label.TextChanged += measure; label.FontChanged += measure;
        }
        private void AddCard(TableLayoutPanel cards, ErrorFixAction action, string title, string description, string buttonText)
        {
            int index = cards.Controls.Count; int row = index / 2;
            if (row >= cards.RowCount) { cards.RowCount++; cards.RowStyles.Add(new RowStyle(SizeType.AutoSize)); }
            GlassCard card = new GlassCard { Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, RowCount = 0, Padding = new Padding(13, 10, 13, 10), Margin = new Padding(index % 2 == 0 ? 0 : 5, 0, index % 2 == 0 ? 5 : 0, 10) };
            card.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            Label heading = Wrapped(title); heading.ForeColor = AeroTheme.Ink; heading.Font = new Font("Segoe UI", 10f, FontStyle.Bold); heading.Margin = new Padding(0, 0, 0, 5); Add(card, heading);
            Add(card, Wrapped(description));
            Button button = ActionButton(buttonText, false); button.Dock = DockStyle.Top; button.Height = 34; button.Margin = Padding.Empty; button.Tag = action; button.AccessibleDescription = I18n.T(description);
            button.Click += delegate { Request(action, null); }; actions.Add(button); Add(card, button); cards.Controls.Add(card, index % 2, row);
        }
        private void Request(ErrorFixAction action, CheckItem item)
        {
            if (busy || action == ErrorFixAction.None) return;
            RequestedAction = action; RequestedCheck = item; DialogResult = DialogResult.OK; Close();
        }
        private async Task OpenReset()
        {
            if (busy) return;
            if (resetNetwork == null) { Request(ErrorFixAction.Reset, null); return; }
            bool failed = false;
            try { SetBusy(true); await resetNetwork(this); }
            catch (Exception error) { failed = true; DiagnosticReports.Current.RecordException("ResetWindow", error); status.Text = I18n.Format("Nicht abgeschlossen: {0}", error.Message); status.ForeColor = ErrorColor; }
            finally
            {
                if (!IsDisposed)
                {
                    lastResult = null; checks.Items.Clear(); details.Clear(); summary.Text = I18n.T("Noch nicht geprüft. Die Gesamtprüfung startet nur auf deinen Klick.");
                    resultReveal.Stop(); resultsSection.Expanded = false; selectedAction.Enabled = false; ((AeroButton)export).Primary = failed;
                    if (!failed) { status.Text = I18n.T("Zurücksetzen-Fenster geschlossen. Die Gesamtprüfung kann bei Bedarf neu gestartet werden."); status.ForeColor = MutedColor; }
                    SetBusy(false);
                }
            }
        }
        private async Task Inspect()
        {
            if (busy) return;
            if (preview) { status.Text = I18n.T("Vorschau: Es werden keine Verbindungen oder Windows-Änderungen ausgeführt."); return; }
            try
            {
                if (inspectAll == null) throw new InvalidOperationException(I18n.T("Die Netzwerkaktion ist derzeit nicht verfügbar."));
                SetBusy(true); presenter.Begin(); status.ForeColor = AeroTheme.Ink;
                WorkerResult result = await inspectAll(delegate(string text) { if (!IsDisposed) status.Text = I18n.TranslatePhase(text); }, delegate(WorkProgress value) { if (!IsDisposed) { if (value != null && value.PhaseStart) presenter.Begin(); presenter.Report(value); } });
                if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Prüfergebnis geliefert."));
                ShowResult(result, true);
                if (result.InspectionIncomplete) await presenter.FinishAsync(false); else await presenter.FinishInspectionAsync();
            }
            catch (Exception error)
            {
                presenter.Stop(); DiagnosticReports.Current.RecordException("Inspect", error, new ShareRequest { Action = "Inspect" });
                status.Text = I18n.Format("Nicht abgeschlossen: {0}", error.Message); status.ForeColor = ErrorColor; ((AeroButton)export).Primary = true;
            }
            finally { SetBusy(false); }
        }
        private void SetBusy(bool value)
        {
            busy = value; search.Enabled = export.Enabled = close.Enabled = resetShortcut.Enabled = !value;
            foreach (Button button in actions) button.Enabled = !value;
            selectedAction.Enabled = !value && SelectedCheck != null && ActionFor(SelectedCheck) != ErrorFixAction.None;
        }
        private static Color ErrorColor { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(174, 49, 40); } }
        private CheckItem SelectedCheck { get { return checks.SelectedItems.Count == 0 ? null : checks.SelectedItems[0].Tag as CheckItem; } }
        internal void ShowKnownProblems(WorkerResult result)
        {
            if (result == null) return;
            ShowResult(result, true); resultsSection.Expanded = true; SetBusy(false);
        }
        private void ShowResult(WorkerResult result, bool reveal)
        {
            lastResult = result; checks.BeginUpdate(); checks.Items.Clear(); int errors = 0, notices = 0;
            foreach (CheckItem item in result.Checks ?? new CheckItem[0])
            {
                if (item == null) continue;
                bool error = String.Equals(item.State, "error", StringComparison.OrdinalIgnoreCase), warning = String.Equals(item.State, "warning", StringComparison.OrdinalIgnoreCase);
                if (error) errors++; else if (warning || item.Code == "REMOTE_ANONYMOUS_SHARE_LIST_DENIED") notices++;
                ListViewItem row = new ListViewItem(I18n.T(item.Name ?? String.Empty)) { Tag = item };
                row.SubItems.Add(I18n.T(error ? "Fehlt / Fehler" : warning ? "Hinweis" : item.State == "ok" ? "OK" : "Info")); row.SubItems.Add(I18n.TranslatePhase(item.Detail ?? String.Empty));
                if (error) row.ForeColor = ErrorColor; checks.Items.Add(row);
            }
            checks.EndUpdate();
            summary.Text = result.Checks != null && result.Checks.Length > 0 ? I18n.Format("{0} Fehler · {1} Hinweise. Wähle eine Zeile für Details und passende Hilfe.", errors, notices) : I18n.T("Die Prüfung hat keine Einzelprüfungen geliefert. Bitte den Fehlerbericht öffnen.");
            status.Text = result.InspectionIncomplete ? I18n.T("Die Gesamtprüfung ist unvollständig. Bereits bestätigte Ergebnisse stehen in der Liste.") : errors > 0 ? I18n.T("Prüfung beendet. Die gefundenen Probleme stehen in der Liste.") : !result.Success ? I18n.TranslatePhase(result.Message ?? I18n.T("Die Prüfung hat keine Einzelprüfungen geliefert. Bitte den Fehlerbericht öffnen.")) : notices > 0 ? I18n.T("Prüfung beendet. Hinweise stehen in der Liste; der Zugriff auf andere Computer bleibt separat zu prüfen.") : I18n.T("Lokale Prüfung beendet. Den Zugriff auf einen anderen Computer prüfst du im Netzwerkzugriff.");
            status.ForeColor = errors > 0 ? ErrorColor : MutedColor;
            ((AeroButton)export).Primary = errors > 0 || !result.Success;
            details.Text = I18n.TranslatePhase(result.Message ?? String.Empty) + (String.IsNullOrWhiteSpace(result.ErrorCode) ? String.Empty : "\r\n" + I18n.T("Fehlercode") + ": " + result.ErrorCode);
            selectedAction.Enabled = false;
            ListViewItem[] rows = checks.Items.Cast<ListViewItem>().ToArray();
            ListViewItem selected = rows.FirstOrDefault(row => ((CheckItem)row.Tag).State == "error") ??
                rows.FirstOrDefault(row => ((CheckItem)row.Tag).State == "warning" && ((CheckItem)row.Tag).Fixable && ActionFor((CheckItem)row.Tag) != ErrorFixAction.None) ??
                rows.FirstOrDefault(row => ((CheckItem)row.Tag).State == "warning");
            if (selected != null) { selected.Selected = true; ShowSelected(); }
            if (reveal) { resultsSection.Expanded = true; resultsSection.ToggleButton.Focus(); resultReveal.Stop(); resultReveal.Start(); }
        }
        private void ShowSelected()
        {
            CheckItem item = SelectedCheck; selectedAction.Enabled = !busy && item != null && ActionFor(item) != ErrorFixAction.None;
            if (item == null) return;
            readableCause.Text = I18n.TranslatePhase(item.Detail ?? String.Empty);
            selectedAction.Text = I18n.T(item.Fixable && ActionFor(item) != ErrorFixAction.None ? "Dieses Problem beheben" : "Passende Hilfe öffnen");
            ((AeroButton)selectedAction).Primary = (item.State == "error" || item.Fixable) && ActionFor(item) != ErrorFixAction.None;
            StringBuilder text = new StringBuilder(I18n.TranslatePhase(item.Detail ?? String.Empty));
            if (!String.IsNullOrWhiteSpace(item.Code)) text.AppendLine().Append(I18n.T("Fehlercode")).Append(": ").Append(item.Code);
            if (!String.IsNullOrWhiteSpace(item.NextStep)) text.AppendLine().Append(I18n.T("Nächster Schritt")).Append(": ").Append(I18n.TranslatePhase(item.NextStep));
            details.Text = text.ToString();
        }
        internal static ErrorFixAction ActionFor(CheckItem item)
        {
            if (item == null || String.Equals(item.State, "ok", StringComparison.OrdinalIgnoreCase)) return ErrorFixAction.None;
            string code = (item.Code ?? String.Empty).ToUpperInvariant(), name = item.Name ?? String.Empty;
            if (code == "DISCOVERY_COMPLETE" || code == "DISCOVERY_INCOMPLETE" || code == "REMOTE_ACCESS_NOT_CHECKED") return ErrorFixAction.None;
            if (code == "REMOTE_ANONYMOUS_SHARE_LIST_DENIED") return ErrorFixAction.ShareList;
            if (code == "RESET_BACKUP_SERVICE_REQUIRED") return ErrorFixAction.Services;
            if (code == "CLIENT_GUEST_COMPATIBILITY_REQUIRED" && item.Fixable) return ErrorFixAction.ClientPreparation;
            if (code.StartsWith("RESET_", StringComparison.Ordinal)) return ErrorFixAction.Reset;
            if (name == "Windows-Freigabenliste des Computers") return ErrorFixAction.ShareList;
            if (name == "Windows-Zugriff über den Computernamen") return ErrorFixAction.NameAccess;
            if (code.StartsWith("SERVICE_", StringComparison.Ordinal) || name == "LanmanServer" || name == "LanmanWorkstation" || name == "FDResPub" || name == "fdPHost") return ErrorFixAction.Services;
            if (name == "Echter Windows-Client-Zugriff" || !String.IsNullOrWhiteSpace(item.RemoteHost)) return ErrorFixAction.Receiver;
            if (code.StartsWith("CLIENT_", StringComparison.Ordinal) || code.StartsWith("REMOTE_", StringComparison.Ordinal)) return ErrorFixAction.Receiver;
            if (code == "DISCOVERY_SETUP_REQUIRED" && item.Fixable) return ErrorFixAction.Discovery;
            if (!String.IsNullOrEmpty(item.TargetShare)) return ErrorFixAction.Permissions;
            return ErrorFixAction.None;
        }
        private void LanguageChanged(object sender, EventArgs args)
        {
            if (IsDisposed) return; I18n.Apply(this); resetShortcut.AccessibleDescription = I18n.T(ResetExplanation);
            if (lastResult != null) { ShowResult(lastResult, false); SetBusy(busy); }
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { I18n.Changed -= LanguageChanged; resultReveal.Stop(); resultReveal.Dispose(); if (presenter != null) presenter.Dispose(); } base.Dispose(disposing);
        }
        private sealed class BufferedScroll : Panel { internal BufferedScroll() { DoubleBuffered = true; } }
        private sealed class BufferedChecks : ListView { internal BufferedChecks() { DoubleBuffered = true; } }
    }
}
