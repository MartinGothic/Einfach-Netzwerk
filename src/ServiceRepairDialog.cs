using System;
using System.Drawing;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    // Service health belongs to this Windows PC. It does not certify access
    // from another device, and never creates a share or changes credentials.
    internal sealed class ServiceRepairDialog : AeroGlassForm
    {
        private readonly bool preview;
        private readonly Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> execute;
        private readonly Label computer, status, percentage;
        private readonly CheckBox advanced;
        private readonly ComboBox network;
        private readonly Label networkLabel;
        private readonly ListView checks;
        private readonly TextBox details;
        private readonly Panel scroll;
        private readonly GroupBox resultGroup;
        private readonly Button inspect, repair, restore, export, close;
        private readonly CountedProgressPresenter presenter;
        private readonly string computerName;
        private bool busy, repairAvailable, inspected;
        private WorkerResult lastResult;
        private string lastAction;
        private readonly ProblemHistory problemHistory = new ProblemHistory();
        private readonly Label problemNotice;

        internal ServiceRepairDialog(WorkerResult localInventory, bool preview,
            Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> execute)
        {
            this.preview = preview; this.execute = execute;
            computerName = localInventory == null || String.IsNullOrWhiteSpace(localInventory.ComputerName) ? Environment.MachineName : localInventory.ComputerName;
            repairAvailable = localInventory != null && localInventory.ServiceRepairAvailable;
            Text = I18n.T("Windows-Dienste reparieren");
            AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 9.5f); ForeColor = AeroTheme.Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(227, 243, 253);
            AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
            ClientSize = new Size(940, 725); MinimumSize = new Size(860, 650);
            StartPosition = FormStartPosition.CenterParent; ShowInTaskbar = false; MinimizeBox = false;

            TableLayoutPanel shell = Grid(1, 5); shell.Padding = new Padding(12, 0, 12, 12);
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 73));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 96)); Controls.Add(shell);
            shell.Controls.Add(new AeroHeader { Heading = "Windows-Dienste reparieren", Subtitle = "Gestoppte Netzwerkdienste auf diesem PC erkennen und starten.", Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 8) }, 0, 0);
            computer = new Label { Dock = DockStyle.Fill, AutoSize = false, UseMnemonic = false, Font = new Font("Segoe UI", 10, FontStyle.Bold), Margin = new Padding(3, 0, 3, 4) };
            shell.Controls.Add(computer, 0, 1);
            scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Margin = Padding.Empty, Padding = new Padding(3, 0, 3, 5) };
            shell.Controls.Add(scroll, 0, 2);
            TableLayoutPanel stack = Grid(1, 0); stack.Dock = DockStyle.Top; stack.AutoSize = true; stack.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); scroll.Controls.Add(stack);
            networkLabel = Wrapped("Heimnetzverbindung für die Dienstprüfung"); Add(stack, networkLabel);
            network = new ComboBox { Dock = DockStyle.Top, DropDownStyle = ComboBoxStyle.DropDownList, Margin = new Padding(3, 0, 3, 8), AccessibleName = I18n.T("Heimnetzverbindung für die Dienstprüfung") };
            Add(stack, network); UpdateNetworks(localInventory == null ? null : localInventory.Networks);
            Add(stack, Wrapped("„Der Serverdienst wurde nicht gestartet“ bedeutet: Ein benötigter Windows-Netzwerkdienst läuft nicht. Die Prüfung zeigt, welcher Dienst auf diesem PC betroffen ist."));
            Add(stack, Wrapped("Server (LanmanServer): Dieser PC bietet Ordner an. Arbeitsstation (LanmanWorkstation): Dieser PC öffnet Freigaben anderer Computer. Die Erkennungsdienste machen den PC im Heimnetz sichtbar."));
            Add(stack, Wrapped("„Automatisch reparieren“ startet benötigte Dienste und korrigiert ihren Starttyp, wenn nötig. Änderungen werden vorher gesichert. Ordner, Freigaben und Passwörter bleiben erhalten."));
            Add(stack, Wrapped("Fehlende Windows-Dienstkonfigurationen werden nur aus geprüften Windows-Originalen dieses PCs wiederhergestellt. Änderungen werden vorher gesichert."));
            advanced = new CheckBox { Text = I18n.T("Fehlende Windows-Dienstkonfiguration reparieren"), Checked = true, AutoSize = true, Dock = DockStyle.Top, UseMnemonic = false, Margin = new Padding(3, 0, 3, 8) };
            Add(stack, advanced);
            problemNotice = Wrapped(String.Empty); problemNotice.Visible = false; Add(stack, problemNotice);

            resultGroup = new GroupBox { Text = I18n.T("Netzwerkdienste auf diesem PC"), Dock = DockStyle.Top, Height = 266, Margin = new Padding(0, 3, 0, 5), Padding = new Padding(9, 20, 9, 8) };
            TableLayoutPanel results = Grid(1, 2); results.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            results.RowStyles.Add(new RowStyle(SizeType.Percent, 58)); results.RowStyles.Add(new RowStyle(SizeType.Percent, 42));
            checks = new ServiceChecks { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false, Margin = new Padding(0, 0, 0, 7), AccessibleName = I18n.T("Netzwerkdienste auf diesem PC") };
            checks.Columns.Add(I18n.T("Prüfung"), 215); checks.Columns.Add(I18n.T("Status"), 105); checks.Columns.Add(I18n.T("Fehlercode"), 130); checks.Columns.Add(I18n.T("Ursache / Details"), 395);
            details = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Dock = DockStyle.Fill, BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(250, 253, 255), AccessibleName = I18n.T("Ursache / Details") };
            checks.SelectedIndexChanged += delegate { ShowSelectedCheck(); };
            results.Controls.Add(checks, 0, 0); results.Controls.Add(details, 0, 1); resultGroup.Controls.Add(results); Add(stack, resultGroup);

            TableLayoutPanel work = Grid(2, 2); work.Padding = new Padding(3, 3, 3, 3);
            work.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); work.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 65));
            work.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); work.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
            status = new Label { Dock = DockStyle.Fill, AutoSize = false, UseMnemonic = false, Text = I18n.T(preview ? "Vorschau: Es werden keine Verbindungen oder Windows-Änderungen ausgeführt." : "Die Dienste werden beim Öffnen geprüft. Für Änderungen benötigt Windows Administratorrechte.") };
            percentage = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomRight, Text = "0 %", Visible = false };
            AeroProgressBar progress = new AeroProgressBar { Dock = DockStyle.Fill, Visible = false, Margin = Padding.Empty };
            work.Controls.Add(status, 0, 0); work.SetColumnSpan(status, 2); work.Controls.Add(progress, 0, 1); work.Controls.Add(percentage, 1, 1); shell.Controls.Add(work, 0, 3);
            presenter = new CountedProgressPresenter(progress, percentage);

            TableLayoutPanel buttons = Grid(3, 2);
            buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 34)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33));
            buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 50)); buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 50));
            inspect = ActionButton("Dienste erneut prüfen", false); repair = ActionButton("Automatisch reparieren", true); export = ActionButton("Fehlerbericht exportieren", false);
            restore = ActionButton("Dienstereparatur zurücknehmen", false); close = ActionButton("Schließen", false);
            buttons.Controls.Add(inspect, 0, 0); buttons.Controls.Add(repair, 1, 0); buttons.Controls.Add(export, 2, 0);
            buttons.Controls.Add(restore, 0, 1); buttons.SetColumnSpan(restore, 2); buttons.Controls.Add(close, 2, 1); shell.Controls.Add(buttons, 0, 4);
            inspect.Click += async delegate { await Operate("InspectServices"); };
            repair.Click += async delegate { await Operate("RepairServices"); };
            restore.Click += async delegate { await Operate("RestoreServices"); };
            export.Click += delegate { DiagnosticReports.Current.SaveReport(this); };
            close.Click += delegate { if (!busy) Close(); };
            FormClosing += delegate(object sender, FormClosingEventArgs args) { if (busy) args.Cancel = true; };
            Shown += async delegate { AeroTheme.GlassFrame(this); if (!preview && !inspected) { inspected = true; await Operate("InspectServices"); } };
            I18n.Changed += LanguageChanged; CancelButton = close; AcceptButton = repair;
            UpdateComputer(); SetBusy(false); I18n.Apply(this); AeroTheme.StyleGlassChildren(this);
        }

        private static TableLayoutPanel Grid(int columns, int rows) { return new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = columns, RowCount = rows, Margin = Padding.Empty, Padding = Padding.Empty }; }
        private static Label Wrapped(string text) { return new Label { Text = I18n.T(text), Dock = DockStyle.Top, AutoSize = true, UseMnemonic = false, MaximumSize = new Size(900, 0), Margin = new Padding(3, 3, 3, 8), ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(80, 103, 120) }; }
        private static Button ActionButton(string text, bool primary) { return new AeroButton { Text = I18n.T(text), Primary = primary, Dock = DockStyle.Fill, Margin = new Padding(3, 5, 3, 5) }; }
        private static void Add(TableLayoutPanel parent, Control child)
        {
            int row = parent.RowCount++; parent.RowStyles.Add(new RowStyle(SizeType.AutoSize)); parent.Controls.Add(child, 0, row);
            Label label = child as Label;
            if (label == null) return;
            EventHandler measure = delegate
            {
                int width = Math.Max(100, parent.ClientSize.Width - label.Margin.Horizontal);
                label.MaximumSize = new Size(width, 0);
                Size text = TextRenderer.MeasureText(label.Text, label.Font, new Size(width, 10000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                label.MinimumSize = new Size(0, text.Height + 2);
            };
            parent.SizeChanged += measure; label.TextChanged += measure; label.FontChanged += measure;
        }
        private void UpdateComputer() { computer.Text = I18n.Format("Dienstprüfung auf diesem PC: {0}", computerName); }
        private async Task Operate(string action)
        {
            if (busy) return;
            if (preview) { status.Text = I18n.T("Vorschau: Es werden keine Verbindungen oder Windows-Änderungen ausgeführt."); return; }
            NetworkItem selected = network.SelectedItem as NetworkItem;
            ShareRequest request = new ShareRequest { Action = action, AllowAdvancedRepair = advanced.Checked, AdapterId = selected == null ? 0 : selected.Id };
            try
            {
                if (execute == null) throw new InvalidOperationException(I18n.T("Die Netzwerkaktion ist derzeit nicht verfügbar."));
                SetBusy(true);
                WorkerResult result = await execute(request, Phase, delegate(WorkProgress value) { if (!IsDisposed) presenter.Report(value); });
                if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Prüfergebnis geliefert."));
                await presenter.FinishAsync(result.Success);
                repairAvailable = result.ServiceRepairAvailable;
                UpdateNetworks(result.Networks);
                ShowResult(result, action);
            }
            catch (Exception error)
            {
                presenter.Stop(); DiagnosticReports.Current.RecordException(action, error, request);
                ShowResult(BackendClient.Failure(error.Message, error), action);
                status.ForeColor = ErrorColor;
            }
            finally { SetBusy(false); }
        }
        private static Color ErrorColor { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(174, 49, 40); } }
        private void Phase(string text) { if (!IsDisposed) status.Text = I18n.TranslatePhase(text); }
        private void SetBusy(bool value)
        {
            busy = value; inspect.Enabled = repair.Enabled = advanced.Enabled = network.Enabled = close.Enabled = export.Enabled = !value;
            restore.Enabled = !value && repairAvailable;
            if (value) { status.ForeColor = AeroTheme.Ink; presenter.Begin(); }
        }
        private void ShowResult(WorkerResult result, string action)
        {
            problemHistory.Observe(result, computerName);
            lastResult = result; lastAction = action; checks.BeginUpdate(); checks.Items.Clear();
            foreach (CheckItem item in result.Checks ?? new CheckItem[0])
            {
                if (item == null) continue;
                ListViewItem row = new ListViewItem(I18n.T(item.Name ?? String.Empty)) { Tag = item };
                row.SubItems.Add(StateText(item.State)); row.SubItems.Add(item.Code ?? String.Empty); row.SubItems.Add(I18n.TranslatePhase(item.Detail ?? String.Empty));
                if (String.Equals(item.State, "error", StringComparison.OrdinalIgnoreCase)) row.ForeColor = ErrorColor;
                checks.Items.Add(row);
            }
            checks.EndUpdate();
            details.Text = problemHistory.AppendDetails(I18n.TranslatePhase(result.Message ?? String.Empty) + (String.IsNullOrWhiteSpace(result.ErrorCode) ? String.Empty : "\r\n" + I18n.T("Fehlercode") + ": " + result.ErrorCode));
            status.Text = result.ServiceHealthVerified && action != "RestoreServices"
                ? I18n.T("Die lokalen Netzwerkdienste laufen und Port 445 antwortet. Den Zugriff von einem anderen Gerät prüfst du dort separat.")
                : I18n.TranslatePhase(result.Message ?? String.Empty);
            status.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : result.Success && (result.ServiceHealthVerified || action == "RestoreServices") ? Color.FromArgb(32, 110, 60) : Color.FromArgb(153, 89, 29);
            bool supported = false;
            foreach (CheckItem item in result.Checks ?? new CheckItem[0]) if (ProblemHistory.CanRepairService(item)) supported = true;
            ((AeroButton)repair).Primary = supported;
            ((AeroButton)export).Primary = (!result.Success || ProblemHistory.HasCurrentProblem(result)) && !supported;
            problemNotice.Text = problemHistory.Notice();
            if (problemHistory.HasUnresolved && !supported) problemNotice.Text += "\r\n" + I18n.T("Für dieses Problem ist keine sichere automatische Reparatur bestätigt. Die Details bleiben sichtbar; exportiere den Fehlerbericht für die weitere Prüfung.");
            problemNotice.Visible = problemHistory.HasProblems;
            problemNotice.ForeColor = problemHistory.HasUnresolved ? ErrorColor : AeroTheme.Ink;
            ProblemHistory.SelectFirstProblem(checks);
            AcceptButton = supported ? repair : inspect;
            scroll.ScrollControlIntoView(resultGroup);
        }
        private void ShowSelectedCheck()
        {
            if (checks.SelectedItems.Count == 0) return;
            CheckItem item = checks.SelectedItems[0].Tag as CheckItem; if (item == null) return;
            StringBuilder value = new StringBuilder(I18n.TranslatePhase(item.Detail ?? String.Empty));
            if (!String.IsNullOrWhiteSpace(item.Code)) value.AppendLine().Append(I18n.T("Fehlercode")).Append(": ").Append(item.Code);
            if (!String.IsNullOrWhiteSpace(item.NextStep)) value.AppendLine().Append(I18n.T("Nächster Schritt")).Append(": ").Append(I18n.TranslatePhase(item.NextStep));
            details.Text = problemHistory.AppendDetails(value.ToString());
        }
        private static string StateText(string value) { return I18n.T(value == "ok" ? "OK" : value == "error" ? "Fehlt / Fehler" : value == "warning" ? "Hinweis" : "Info"); }
        private void UpdateNetworks(NetworkItem[] values)
        {
            if (values == null || values.Length == 0) { network.Visible = networkLabel.Visible = network.Items.Count > 1; return; }
            NetworkItem selected = network.SelectedItem as NetworkItem;
            int selectedId = selected == null ? 0 : selected.Id;
            network.BeginUpdate(); network.Items.Clear();
            foreach (NetworkItem item in values)
                if (item != null && String.Equals(item.Category, "Private", StringComparison.OrdinalIgnoreCase)) network.Items.Add(item);
            for (int i = 0; i < network.Items.Count; i++) if (((NetworkItem)network.Items[i]).Id == selectedId) network.SelectedIndex = i;
            if (network.SelectedIndex < 0 && network.Items.Count == 1) network.SelectedIndex = 0;
            network.EndUpdate(); network.Visible = networkLabel.Visible = network.Items.Count > 1;
        }
        private void LanguageChanged(object sender, EventArgs args)
        {
            I18n.Apply(this); UpdateComputer(); checks.Columns[0].Text = I18n.T("Prüfung"); checks.Columns[1].Text = I18n.T("Status"); checks.Columns[2].Text = I18n.T("Fehlercode"); checks.Columns[3].Text = I18n.T("Ursache / Details");
            if (lastResult != null) ShowResult(lastResult, lastAction);
        }
        private sealed class ServiceChecks : ListView { internal ServiceChecks() { DoubleBuffered = true; } }
        protected override void Dispose(bool disposing) { if (disposing) { I18n.Changed -= LanguageChanged; if (presenter != null) presenter.Dispose(); } base.Dispose(disposing); }
    }
}
