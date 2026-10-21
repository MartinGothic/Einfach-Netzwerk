using System;
using System.Collections.Generic;
using System.Drawing;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    // Preparing is read-only. Execution receives exactly the reviewed immutable
    // plan; the controller validates it again before the first Windows change.
    internal sealed class ResetNetworkDialog : AeroGlassForm
    {
        private readonly bool preview;
        private readonly Func<Action<string>, Action<WorkProgress>, Task<ResetNetworkPlan>> preparePlan;
        private readonly Func<Action<string>, Action<WorkProgress>, Task<ResetNetworkPlan>> prepareAndRepair;
        private readonly Func<ResetNetworkPlan, Action<string>, Action<WorkProgress>, Task<WorkerResult>> executePlan;
        private readonly Func<string, string, bool> consent;
        private readonly Label summary, status, percentage, sharesTitle, explanationTitle, explanation;
        private readonly GlassCard explanationCard;
        private readonly TableLayoutPanel shell, footer;
        private readonly Panel scroll;
        private readonly TableLayoutPanel stack;
        private readonly ListView shares, checks;
        private readonly ListView originalChecks;
        private readonly Label originalExplanation;
        private readonly GlassCard originalSection;
        private readonly List<CheckItem> originalProblems = new List<CheckItem>();
        private readonly Dictionary<string, string> originalStates = new Dictionary<string, string>();
        private readonly TextBox details;
        private readonly Button prepare, repair, execute, export, close;
        private readonly CollapsibleSection detailSection;
        private readonly CountedProgressPresenter presenter;
        private readonly Timer explanationReveal = new Timer { Interval = 25 };
        private ResetNetworkPlan plan;
        private CheckItem[] lastChecks = new CheckItem[0];
        private bool busy;
        private bool revealOriginal;
        private bool positioningExplanation;

        internal ResetNetworkDialog(bool preview,
            Func<Action<string>, Action<WorkProgress>, Task<ResetNetworkPlan>> preparePlan,
            Func<ResetNetworkPlan, Action<string>, Action<WorkProgress>, Task<WorkerResult>> executePlan)
            : this(preview, preparePlan, executePlan, null) { }

        internal ResetNetworkDialog(bool preview,
            Func<Action<string>, Action<WorkProgress>, Task<ResetNetworkPlan>> preparePlan,
            Func<ResetNetworkPlan, Action<string>, Action<WorkProgress>, Task<WorkerResult>> executePlan,
            Func<string, string, bool> consent)
            : this(preview, preparePlan, executePlan, consent, null) { }

        internal ResetNetworkDialog(bool preview,
            Func<Action<string>, Action<WorkProgress>, Task<ResetNetworkPlan>> preparePlan,
            Func<ResetNetworkPlan, Action<string>, Action<WorkProgress>, Task<WorkerResult>> executePlan,
            Func<string, string, bool> consent,
            Func<Action<string>, Action<WorkProgress>, Task<ResetNetworkPlan>> prepareAndRepair)
        {
            this.preview = preview; this.preparePlan = preparePlan; this.executePlan = executePlan; this.consent = consent; this.prepareAndRepair = prepareAndRepair;
            Text = I18n.T("Netzwerk zurücksetzen"); AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 9.5f); ForeColor = AeroTheme.Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(227, 243, 253);
            AutoScaleMode = AutoScaleMode.Dpi; AutoScaleDimensions = new SizeF(96, 96);
            ClientSize = new Size(980, 775); MinimumSize = new Size(870, 670);
            StartPosition = FormStartPosition.CenterParent; ShowInTaskbar = false; MinimizeBox = false;
            shell = Grid(1, 3); shell.Padding = new Padding(12, 0, 12, 12);
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 134)); Controls.Add(shell);
            shell.Controls.Add(new AeroHeader { Heading = "Netzwerk zurücksetzen", Subtitle = "Erst prüfen, dann zurücksetzen.", Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 8) }, 0, 0);
            scroll = new BufferedScroll { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(3, 0, 3, 8), Margin = Padding.Empty }; shell.Controls.Add(scroll, 0, 1);
            stack = Grid(1, 0); stack.Dock = DockStyle.Top; stack.AutoSize = true; stack.AutoSizeMode = AutoSizeMode.GrowAndShrink; stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); scroll.Controls.Add(stack);
            Add(stack, Wrapped("Zuerst vorbereiten und die Übersicht lesen. Das Öffnen dieses Fensters führt keine Suche oder Änderungen aus."));
            Add(stack, Wrapped("Normale Datenfreigaben werden entfernt; Dateien und Windows-Systemfreigaben bleiben erhalten. Nur gesicherte Änderungen dieses Programms werden zurückgenommen."));
            summary = Wrapped("Noch keine Übersicht vorbereitet. Prüfe zuerst, was auf diesem PC zurückgenommen werden kann."); summary.Font = new Font("Segoe UI", 10f, FontStyle.Bold); summary.ForeColor = AeroTheme.Ink; Add(stack, summary);
            sharesTitle = Heading("Diese Datenfreigaben werden entfernt"); Add(stack, sharesTitle);
            shares = new BufferedChecks { Dock = DockStyle.Top, Height = 116, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false, ShowItemToolTips = true, Margin = new Padding(0, 5, 0, 10), AccessibleName = I18n.T("Diese Datenfreigaben werden entfernt") };
            shares.Columns.Add(I18n.T("Freigabe"), 205); shares.Columns.Add(I18n.T("Lokaler Pfad"), 670); Add(stack, shares);
            Add(stack, Heading("Sicherungen, Rücknahme und Grenzen"));
            checks = new BufferedChecks { Dock = DockStyle.Top, Height = 156, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false, ShowItemToolTips = true, Margin = new Padding(0, 5, 0, 8), AccessibleName = I18n.T("Sicherungen, Rücknahme und Grenzen") };
            checks.Columns.Add(I18n.T("Prüfung"), 240); checks.Columns.Add(I18n.T("Status"), 115); checks.Columns.Add(I18n.T("Kurz erklärt"), 515); checks.SelectedIndexChanged += delegate { ShowSelected(); }; Add(stack, checks);
            checks.MouseDown += delegate { revealOriginal = false; QueueExplanationReveal(); }; checks.KeyDown += delegate { revealOriginal = false; QueueExplanationReveal(); };
            explanationCard = new GlassCard { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, RowCount = 0, Padding = new Padding(13, 9, 13, 9), Margin = new Padding(0, 0, 0, 8) };
            explanationCard.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); explanationTitle = Heading("Vollständige Erklärung zum gewählten Punkt"); explanation = Wrapped("Wähle eine Zeile. Hier steht die vollständige Erklärung und der nächste Schritt.");
            Add(explanationCard, explanationTitle); Add(explanationCard, explanation); Add(stack, explanationCard);
            originalSection = new GlassCard { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, RowCount = 0, Visible = false, Padding = new Padding(13, 9, 13, 9), Margin = new Padding(0, 0, 0, 8) };
            originalSection.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); Add(originalSection, Heading("Erkannte Probleme – ursprüngliche Ursachen"));
            originalChecks = new BufferedChecks { Dock = DockStyle.Top, Height = 92, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false, ShowItemToolTips = true, Margin = new Padding(0, 4, 0, 5), AccessibleName = I18n.T("Erkannte Probleme – ursprüngliche Ursachen") };
            originalChecks.Columns.Add(I18n.T("Prüfung"), 310); originalChecks.Columns.Add(I18n.T("Status nach Prüfung"), 210); originalChecks.Columns.Add(I18n.T("Ursprünglicher Fehlercode"), 310); Add(originalSection, originalChecks);
            originalExplanation = Wrapped("Die ursprüngliche Ursache bleibt nach einem Reparaturversuch hier sichtbar."); Add(originalSection, originalExplanation); Add(stack, originalSection);
            originalChecks.SelectedIndexChanged += delegate { ShowOriginalSelected(); };
            originalChecks.MouseDown += delegate { revealOriginal = true; QueueExplanationReveal(); }; originalChecks.KeyDown += delegate { revealOriginal = true; QueueExplanationReveal(); };
            detailSection = new CollapsibleSection("Fehlercodes und technische Details") { Expanded = false, Margin = new Padding(0, 0, 0, 5) };
            details = new TextBox { Dock = DockStyle.Top, Height = 140, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(250, 253, 255), AccessibleName = I18n.T("Fehlercodes und technische Details") }; Add(detailSection.Content, details); Add(stack, detailSection);
            footer = Grid(2, 3); footer.Padding = new Padding(3, 9, 3, 0); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 68));
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 112)); footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
            TableLayoutPanel buttons = Grid(3, 3); for (int column = 0; column < 3; column++) buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / 3)); buttons.RowStyles.Add(new RowStyle(SizeType.Absolute, 36)); buttons.RowStyles.Add(new RowStyle(SizeType.Absolute, 38)); buttons.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
            Label repairHint = Wrapped("Prüfen und beheben repariert unterstützte Dienstfehler. Dabei werden keine Freigaben entfernt oder Einstellungen zurückgesetzt."); repairHint.Dock = DockStyle.Fill; repairHint.AutoSize = false; repairHint.Margin = new Padding(0, 0, 0, 3); buttons.Controls.Add(repairHint, 0, 0); buttons.SetColumnSpan(repairHint, 3);
            prepare = ActionButton("Zurücksetzen vorbereiten", true); repair = ActionButton("Automatisch prüfen und beheben", false); execute = ActionButton("Alles zurücksetzen", false); export = ActionButton("Fehlerbericht exportieren", false); close = ActionButton("Schließen", false);
            repair.AccessibleDescription = repairHint.Text;
            buttons.Controls.Add(prepare, 0, 1); buttons.Controls.Add(repair, 1, 1); buttons.Controls.Add(execute, 2, 1); buttons.Controls.Add(export, 0, 2); buttons.SetColumnSpan(export, 2); buttons.Controls.Add(close, 2, 2); footer.Controls.Add(buttons, 0, 0); footer.SetColumnSpan(buttons, 2);
            status = new Label { Dock = DockStyle.Fill, AutoSize = false, UseMnemonic = false, ForeColor = MutedColor, Margin = new Padding(0, 3, 0, 3), Text = I18n.T("Bereit. Noch keine Windows-Änderungen ausgeführt.") }; footer.Controls.Add(status, 0, 1); footer.SetColumnSpan(status, 2);
            AeroProgressBar progress = new AeroProgressBar { Dock = DockStyle.Fill, Visible = false, Margin = Padding.Empty }; percentage = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleRight, Text = "0 %", Visible = false, Margin = Padding.Empty };
            footer.Controls.Add(progress, 0, 2); footer.Controls.Add(percentage, 1, 2); shell.Controls.Add(footer, 0, 2); presenter = new CountedProgressPresenter(progress, percentage);
            checks.SizeChanged += delegate { ResizeColumns(); }; shares.SizeChanged += delegate { ResizeColumns(); }; originalChecks.SizeChanged += delegate { ResizeColumns(); };
            status.TextChanged += delegate { MeasureStatus(); }; status.FontChanged += delegate { MeasureStatus(); }; footer.SizeChanged += delegate { MeasureStatus(); };
            scroll.SizeChanged += delegate { QueueExplanationReveal(); }; explanationCard.SizeChanged += delegate { QueueExplanationReveal(); }; originalSection.SizeChanged += delegate { if (revealOriginal) QueueExplanationReveal(); };
            scroll.Layout += delegate { if (revealOriginal) QueueExplanationReveal(); }; stack.Layout += delegate { if (revealOriginal) QueueExplanationReveal(); };
            scroll.MouseWheel += delegate { revealOriginal = false; };
            explanationReveal.Tick += delegate { explanationReveal.Stop(); RevealExplanation(); };
            prepare.Click += async delegate { await Prepare(); }; repair.Click += async delegate { await PrepareAndRepair(); }; execute.Click += async delegate { await Execute(); }; export.Click += delegate { DiagnosticReports.Current.SaveReport(this); }; close.Click += delegate { if (!busy) Close(); };
            FormClosing += delegate(object sender, FormClosingEventArgs args) { if (busy) args.Cancel = true; }; Shown += delegate { AeroTheme.GlassFrame(this); };
            I18n.Changed += LanguageChanged; CancelButton = close; SetBusy(false); I18n.Apply(this); AeroTheme.StyleGlassChildren(this); ResizeColumns(); MeasureStatus();
        }
        private static TableLayoutPanel Grid(int columns, int rows) { return new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = columns, RowCount = rows, Margin = Padding.Empty, Padding = Padding.Empty }; }
        private static Color MutedColor { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(80, 103, 120); } }
        private static Color ErrorColor { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(174, 49, 40); } }
        private static Label Wrapped(string text) { return new Label { Text = I18n.T(text), Dock = DockStyle.Top, AutoSize = true, UseMnemonic = false, ForeColor = MutedColor, Margin = new Padding(0, 3, 0, 8) }; }
        private static Label Heading(string text) { Label label = Wrapped(text); label.Font = new Font("Segoe UI", 10f, FontStyle.Bold); label.ForeColor = AeroTheme.Ink; return label; }
        private static Button ActionButton(string text, bool primary) { return new AeroButton { Text = I18n.T(text), Dock = DockStyle.Fill, Margin = new Padding(0, 3, 8, 3), Primary = primary, UseMnemonic = false }; }
        private static void Add(TableLayoutPanel parent, Control child)
        {
            int row = parent.RowCount++; parent.RowStyles.Add(new RowStyle(SizeType.AutoSize)); parent.Controls.Add(child, 0, row); Label label = child as Label; if (label == null) return;
            EventHandler measure = delegate { label.MaximumSize = new Size(Math.Max(100, parent.ClientSize.Width - parent.Padding.Horizontal - label.Margin.Horizontal), 0); };
            parent.SizeChanged += measure; label.TextChanged += measure; label.FontChanged += measure;
        }
        private void ResizeColumns()
        {
            if (checks == null || shares == null || checks.Columns.Count < 3 || shares.Columns.Count < 2) return;
            int width = Math.Max(400, checks.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 5);
            int name = (int)(width * .38), state = Math.Max(108, (int)(width * .17));
            checks.Columns[0].Width = name; checks.Columns[1].Width = state; checks.Columns[2].Width = Math.Max(100, width - name - state);
            width = Math.Max(400, shares.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 5);
            shares.Columns[0].Width = (int)(width * .28); shares.Columns[1].Width = width - shares.Columns[0].Width;
            width = Math.Max(400, originalChecks.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 5);
            originalChecks.Columns[0].Width = (int)(width * .36); originalChecks.Columns[1].Width = (int)(width * .30); originalChecks.Columns[2].Width = width - originalChecks.Columns[0].Width - originalChecks.Columns[1].Width;
        }
        private void MeasureStatus()
        {
            if (status == null || footer == null || shell == null || footer.ClientSize.Width < 1) return;
            int width = Math.Max(100, footer.ClientSize.Width - footer.Padding.Horizontal - status.Margin.Horizontal);
            int height = TextRenderer.MeasureText(status.Text, status.Font, new Size(width, 10000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix).Height + status.Margin.Vertical + 3;
            int desired = footer.Padding.Vertical + 112 + Math.Max(25, height) + 18;
            if (Math.Abs(shell.RowStyles[2].Height - desired) > .5f) shell.RowStyles[2].Height = desired;
        }
        private void Phase(string value) { if (!IsDisposed) status.Text = I18n.TranslatePhase(value); }
        private void Counted(WorkProgress value) { if (!IsDisposed) { if (value != null && value.PhaseStart) presenter.Begin(); presenter.Report(value); } }
        private void SetBusy(bool value) { busy = value; prepare.Enabled = export.Enabled = close.Enabled = !value; repair.Enabled = !value && !preview && prepareAndRepair != null; execute.Enabled = !value && !preview && plan != null && plan.CanExecute; }
        private Task Prepare() { return PrepareCore(false); }
        private Task PrepareAndRepair() { return PrepareCore(true); }
        private async Task PrepareCore(bool repairPrerequisites)
        {
            if (busy) return;
            if (preview) { status.Text = I18n.T("Vorschau: Es werden keine Verbindungen oder Windows-Änderungen ausgeführt."); return; }
            if (repairPrerequisites && prepareAndRepair == null) return;
            revealOriginal = repairPrerequisites;
            if (repairPrerequisites) RememberOriginalProblems();
            plan = null; shares.Items.Clear(); checks.Items.Clear(); details.Clear(); lastChecks = new CheckItem[0]; explanationTitle.Text = I18n.T("Vollständige Erklärung zum gewählten Punkt"); explanation.Text = I18n.T("Wähle eine Zeile. Hier steht die vollständige Erklärung und der nächste Schritt.");
            try
            {
                Func<Action<string>, Action<WorkProgress>, Task<ResetNetworkPlan>> callback = repairPrerequisites ? prepareAndRepair : preparePlan;
                if (callback == null) throw new InvalidOperationException(I18n.T("Die Netzwerkaktion ist derzeit nicht verfügbar."));
                SetBusy(true); presenter.Begin(); status.ForeColor = MutedColor; summary.Text = I18n.T(repairPrerequisites ? "Voraussetzungen werden geprüft und unterstützte Dienstfehler behoben. Freigaben bleiben erhalten." : "Übersicht wird vorbereitet. Es werden noch keine Freigaben entfernt.");
                ResetNetworkPlan prepared = await callback(Phase, Counted);
                if (prepared == null) throw new InvalidOperationException(I18n.T("Windows hat kein Prüfergebnis geliefert."));
                plan = prepared; ShowPlan();
                if (originalProblems.Count > 0) { UpdateOriginalProblems(prepared); if (repairPrerequisites) { revealOriginal = true; QueueExplanationReveal(); } }
                if (!prepared.InventoryConfirmed || (prepared.Inventory != null && prepared.Inventory.InspectionIncomplete)) await presenter.FinishAsync(false); else await presenter.FinishInspectionAsync();
            }
            catch (Exception error) { presenter.Stop(); DiagnosticReports.Current.RecordException(repairPrerequisites ? "RepairResetPrerequisites" : "PrepareReset", error); status.Text = I18n.Format("Nicht abgeschlossen: {0}", error.Message); status.ForeColor = ErrorColor; SetPreparationEmphasis(true); }
            finally { SetBusy(false); if (repairPrerequisites && originalProblems.Count > 0) { revealOriginal = true; repair.Focus(); QueueExplanationReveal(); } }
        }
        private void ShowPlan()
        {
            if (plan == null) return;
            shares.BeginUpdate(); shares.Items.Clear();
            foreach (ShareItem item in plan.Shares) { ListViewItem row = new ListViewItem(item.Name ?? String.Empty) { ToolTipText = (item.Name ?? String.Empty) + "\r\n" + (item.Path ?? String.Empty) }; row.SubItems.Add(item.Path ?? String.Empty); shares.Items.Add(row); }
            shares.EndUpdate(); ShowChecks(plan.Checks);
            sharesTitle.Text = I18n.T(plan.InventoryConfirmed ? "Diese Datenfreigaben werden entfernt" : "Freigabenliste noch nicht bestätigt");
            summary.Text = plan.InventoryConfirmed ? I18n.Format("{0} Datenfreigaben auf {1}. Prüfe die Liste und die Rücknahme unten.", plan.Shares.Length, plan.ComputerName) : I18n.T("Die Freigabenliste ist noch nicht bestätigt. Der markierte Prüfpunkt erklärt, was fehlt.");
            status.Text = plan.CanExecute ? I18n.T("Übersicht bereit. Erst „Alles zurücksetzen“ und die anschließende Bestätigung führen Änderungen aus.") : I18n.T(prepareAndRepair != null ? "Zurücksetzen noch nicht möglich. Klicke auf „Automatisch prüfen und beheben“. Die Erklärung zeigt die Ursache." : "Zurücksetzen noch nicht möglich. Die Liste zeigt die fehlenden Voraussetzungen."); status.ForeColor = plan.CanExecute ? MutedColor : ErrorColor;
            details.Text = I18n.TranslatePhase(plan.Message ?? String.Empty) + (String.IsNullOrWhiteSpace(plan.ErrorCode) ? String.Empty : "\r\n" + I18n.T("Fehlercode") + ": " + plan.ErrorCode);
            SetPreparationEmphasis(!plan.CanExecute);
        }
        private static string ProblemKey(CheckItem item) { return (item.Name ?? String.Empty) + "\n" + (item.Code ?? String.Empty); }
        private void RememberOriginalProblems()
        {
            foreach (CheckItem item in lastChecks)
            {
                if (item == null || item.State != "error") continue; string key = ProblemKey(item);
                if (originalStates.ContainsKey(key)) continue;
                originalProblems.Add(new CheckItem { Name = item.Name, State = item.State, Code = item.Code, Detail = item.Detail, NextStep = item.NextStep, Fixable = item.Fixable }); originalStates[key] = "Noch nicht bestätigt";
            }
            ShowOriginalProblems();
        }
        private void UpdateOriginalProblems(ResetNetworkPlan current)
        {
            List<CheckItem> verified = new List<CheckItem>(current.Checks ?? new CheckItem[0]); verified.AddRange(current.Inventory.Checks ?? new CheckItem[0]);
            foreach (CheckItem original in originalProblems)
            {
                bool stillFailed = false, confirmed = false;
                foreach (CheckItem item in verified)
                {
                    if (item == null || item.Name != original.Name) continue;
                    if (item.State == "error" && (item.Code == original.Code || String.IsNullOrWhiteSpace(original.Code))) stillFailed = true;
                    if (item.State == "ok") confirmed = true;
                }
                if (original.Code == "RESET_INVENTORY_UNCONFIRMED" && current.InventoryConfirmed) confirmed = true;
                if (original.Code == "RESET_BACKUP_SERVICE_REQUIRED") foreach (CheckItem item in verified) if (item != null && item.Name == "LanmanServer" && item.State == "ok") confirmed = true;
                originalStates[ProblemKey(original)] = stillFailed ? "Noch nicht behoben" : current.CanExecute && current.InventoryConfirmed && confirmed ? "Behoben" : "Noch nicht bestätigt";
            }
            ShowOriginalProblems();
        }
        private void ShowOriginalProblems()
        {
            originalSection.Visible = originalProblems.Count > 0; if (!originalSection.Visible) return;
            originalChecks.BeginUpdate(); originalChecks.Items.Clear();
            foreach (CheckItem item in originalProblems)
            {
                ListViewItem row = new ListViewItem(ShortName(item.Name)) { Tag = item, ToolTipText = I18n.T(item.Name ?? String.Empty) + "\r\n" + I18n.TranslatePhase(item.Detail ?? String.Empty) };
                row.SubItems.Add(I18n.T(originalStates[ProblemKey(item)])); row.SubItems.Add(item.Code ?? String.Empty); originalChecks.Items.Add(row);
            }
            originalChecks.EndUpdate(); ResizeColumns(); if (originalChecks.Items.Count > 0) { originalChecks.Items[0].Selected = true; ShowOriginalSelected(); }
        }
        private void ShowOriginalSelected()
        {
            if (originalChecks.SelectedItems.Count == 0) return; CheckItem item = originalChecks.SelectedItems[0].Tag as CheckItem; if (item == null) return;
            StringBuilder text = new StringBuilder(I18n.T("Ursprüngliche Ursache")).Append(": ").Append(I18n.TranslatePhase(item.Detail ?? String.Empty));
            if (!String.IsNullOrWhiteSpace(item.Code)) text.AppendLine().Append(I18n.T("Ursprünglicher Fehlercode")).Append(": ").Append(item.Code);
            if (!String.IsNullOrWhiteSpace(item.NextStep)) text.AppendLine().Append(I18n.T("Ursprünglicher nächster Schritt")).Append(": ").Append(I18n.TranslatePhase(item.NextStep));
            text.AppendLine().AppendLine().Append(I18n.T("Status nach Prüfung")).Append(": ").Append(I18n.T(originalStates[ProblemKey(item)])); originalExplanation.Text = text.ToString();
        }
        private void SetPreparationEmphasis(bool blocked)
        {
            bool canRepair = blocked && !preview && prepareAndRepair != null;
            ((AeroButton)repair).Primary = canRepair; ((AeroButton)prepare).Primary = !blocked;
            ((AeroButton)export).Primary = blocked && !canRepair;
        }
        private async Task Execute()
        {
            if (busy || preview || plan == null || !plan.CanExecute) return;
            ResetNetworkPlan approved = plan;
            string explanation = I18n.Format("Auf {0} werden {1} Datenfreigaben entfernt. Ihre Dateien bleiben erhalten. Die in der Übersicht gezeigten, gesicherten Netzwerkänderungen werden zurückgenommen.\n\nDie aktuelle Übersicht wurde geprüft. Jetzt zurücksetzen?", approved.ComputerName, approved.Shares.Length);
            StringBuilder names = new StringBuilder(); ShareItem[] affected = approved.Shares;
            for (int i = 0; i < Math.Min(20, affected.Length); i++) names.AppendLine(affected[i].Name ?? String.Empty);
            if (affected.Length > 20) names.AppendLine(I18n.Format("Weitere {0} Freigaben stehen vollständig in der Übersicht.", affected.Length - 20));
            if (affected.Length > 0) explanation += "\n\n" + I18n.T("Betroffene Freigaben") + ":\n" + names.ToString();
            if (approved.RestoreClient) explanation += "\n" + I18n.T("Gesicherte SMB-Client-Einstellungen zurücknehmen.");
            if (approved.RestoreServices) explanation += "\n" + I18n.T("Gesicherte Windows-Dienständerungen zurücknehmen.");
            bool allowed = consent == null ? MessageBox.Show(this, explanation, I18n.T("Zurücksetzen bestätigen"), MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) == DialogResult.Yes : consent(explanation, I18n.T("Zurücksetzen bestätigen"));
            if (!allowed) { status.Text = I18n.T("Abgebrochen. Keine Freigaben oder Windows-Einstellungen geändert."); return; }
            try
            {
                if (executePlan == null) throw new InvalidOperationException(I18n.T("Die Netzwerkaktion ist derzeit nicht verfügbar."));
                SetBusy(true); presenter.Begin(); status.ForeColor = MutedColor;
                WorkerResult result = await executePlan(approved, Phase, Counted);
                if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Prüfergebnis geliefert."));
                ShowChecks(result.Checks); sharesTitle.Text = I18n.T("Vorbereitete Freigaben – ursprüngliche Übersicht"); details.Text = I18n.TranslatePhase(result.Message ?? String.Empty) + (String.IsNullOrWhiteSpace(result.ErrorCode) ? String.Empty : "\r\n" + I18n.T("Fehlercode") + ": " + result.ErrorCode) + (String.IsNullOrWhiteSpace(result.BackupPath) ? String.Empty : "\r\n" + I18n.T("Sicherung dieses Zurücksetzens") + ": " + result.BackupPath);
                status.Text = I18n.TranslatePhase(result.Message ?? String.Empty); status.ForeColor = result.Success ? MutedColor : ErrorColor; ((AeroButton)export).Primary = !result.Success;
                summary.Text = result.Success ? I18n.T("Zurücksetzen abgeschlossen. Für eine neue Freigabe den Assistenten verwenden.") : I18n.T("Zurücksetzen nicht vollständig abgeschlossen. Details und Fehlerbericht zeigen den aktuellen Stand.");
                await presenter.FinishAsync(result.Success);
            }
            catch (Exception error) { presenter.Stop(); DiagnosticReports.Current.RecordException("ExecuteReset", error); status.Text = I18n.Format("Nicht abgeschlossen: {0}", error.Message); status.ForeColor = ErrorColor; ((AeroButton)export).Primary = true; }
            finally { plan = null; SetBusy(false); }
        }
        private void ShowChecks(CheckItem[] values)
        {
            lastChecks = values ?? new CheckItem[0]; checks.BeginUpdate(); checks.Items.Clear(); int firstProblem = -1; foreach (CheckItem item in lastChecks)
            {
                if (item == null) continue; ListViewItem row = new ListViewItem(ShortName(item.Name)) { Tag = item, ToolTipText = I18n.T(item.Name ?? String.Empty) + "\r\n" + I18n.TranslatePhase(item.Detail ?? String.Empty) };
                row.SubItems.Add(I18n.T(item.State == "ok" ? "OK" : item.State == "error" ? "Fehlt / Fehler" : item.State == "warning" ? "Hinweis" : "Info")); row.SubItems.Add(I18n.T(item.State == "error" ? "Bitte Erklärung lesen" : item.State == "warning" ? "Hinweis beachten" : item.State == "ok" ? "Bestätigt" : "Geplanter Schritt"));
                if (item.State == "error") { row.ForeColor = ErrorColor; if (firstProblem < 0) firstProblem = checks.Items.Count; } checks.Items.Add(row);
            } checks.EndUpdate(); ResizeColumns();
            if (checks.Items.Count > 0) { checks.Items[firstProblem < 0 ? 0 : firstProblem].Selected = true; ShowSelected(); }
        }
        private static string ShortName(string original)
        {
            string key = original ?? String.Empty;
            if (key == "Freigaben für die Rücksetzung") key = "Freigabenliste";
            else if (key == "Gesicherte Windows-Einstellungen") key = "Windows-Sicherungen";
            else if (key == "Gesicherte Freigabeeinstellungen") key = "Freigabe-Einstellungen";
            else if (key == "Dienstereparatur-Rücknahme") key = "Dienste-Rücknahme";
            else if (key == "Datenfreigaben nach der Rücksetzung") key = "Abschlussprüfung";
            else if (key == "Netzwerkeinrichtung zurücksetzen") key = "Zurücksetzen";
            return I18n.T(key);
        }
        private void ShowSelected()
        {
            if (checks.SelectedItems.Count == 0) return; CheckItem item = checks.SelectedItems[0].Tag as CheckItem; if (item == null) return;
            explanationTitle.Text = I18n.T(item.Name ?? String.Empty); StringBuilder readable = new StringBuilder(I18n.TranslatePhase(item.Detail ?? String.Empty));
            if (!String.IsNullOrWhiteSpace(item.NextStep)) readable.AppendLine().AppendLine().Append(I18n.T("Nächster Schritt")).Append(": ").Append(I18n.TranslatePhase(item.NextStep));
            if (item.State == "error" && !preview && prepareAndRepair != null) readable.AppendLine().AppendLine().Append(I18n.T("Klicke unten auf „Automatisch prüfen und beheben“. Unterstützte Dienstfehler werden repariert und die Übersicht wird erneut geprüft."));
            explanation.Text = readable.Length == 0 ? I18n.T("Zu diesem Punkt liegt keine weitere Erklärung vor.") : readable.ToString();
            QueueExplanationReveal();
            StringBuilder text = new StringBuilder(I18n.TranslatePhase(item.Detail ?? String.Empty)); if (!String.IsNullOrWhiteSpace(item.Code)) text.AppendLine().Append(I18n.T("Fehlercode")).Append(": ").Append(item.Code); if (!String.IsNullOrWhiteSpace(item.NextStep)) text.AppendLine().Append(I18n.T("Nächster Schritt")).Append(": ").Append(I18n.TranslatePhase(item.NextStep)); details.Text = text.ToString();
        }
        private void QueueExplanationReveal()
        {
            if (IsDisposed || positioningExplanation || !IsHandleCreated || checks == null || (!revealOriginal && checks.SelectedItems.Count == 0)) return;
            // Repeated layout notifications must not keep postponing the tick.
            if (!explanationReveal.Enabled) explanationReveal.Start();
        }
        private void RevealExplanation()
        {
            if (IsDisposed || (!revealOriginal && checks.SelectedItems.Count == 0)) return;
            positioningExplanation = true;
            try
            {
                stack.PerformLayout(); scroll.AutoScrollMinSize = new Size(0, stack.Height + scroll.Padding.Vertical);
                Control target = revealOriginal && originalSection.Visible ? (Control)originalExplanation : explanationCard;
                if (!revealOriginal) checks.Focus();
                // The original explanation is nested inside a card. Convert its
                // bounds to the stack before deciding how far to scroll.
                Rectangle targetBounds = stack.RectangleToClient(target.RectangleToScreen(target.ClientRectangle));
                int desired = Math.Max(0, targetBounds.Bottom - scroll.ClientSize.Height + 8);
                // Prefer the whole explanation after a smaller window or a wrapped
                // translated message; a portion of the list remains above it.
                if (targetBounds.Height <= scroll.ClientSize.Height)
                    desired = Math.Max(0, Math.Min(targetBounds.Top, desired));
                else desired = Math.Max(0, targetBounds.Top);
                scroll.AutoScrollPosition = new Point(0, desired);
            }
            finally { positioningExplanation = false; }
        }
        private void LanguageChanged(object sender, EventArgs args) { if (IsDisposed) return; I18n.Apply(this); if (plan != null) ShowPlan(); else if (lastChecks.Length > 0) ShowChecks(lastChecks); ShowOriginalProblems(); ResizeColumns(); MeasureStatus(); }
        protected override void Dispose(bool disposing) { if (disposing) { I18n.Changed -= LanguageChanged; explanationReveal.Stop(); explanationReveal.Dispose(); if (presenter != null) presenter.Dispose(); } base.Dispose(disposing); }
        private sealed class BufferedScroll : Panel { internal BufferedScroll() { DoubleBuffered = true; } }
        private sealed class BufferedChecks : ListView { internal BufferedChecks() { DoubleBuffered = true; } }
    }
}
