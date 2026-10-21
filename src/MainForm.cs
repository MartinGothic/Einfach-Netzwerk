using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    public sealed partial class MainForm : AeroGlassForm
    {
        private static readonly Color Ink = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(30, 48, 65);
        private static readonly Color Muted = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(92, 109, 123);
        private static readonly Color Accent = AeroTheme.Accent;
        private readonly bool preview;
        private readonly Stopwatch watch = new Stopwatch();
        private readonly Timer elapsedTimer;
        private readonly CountedProgressPresenter countedProgress;
        private readonly ToolTip homeHints = new ToolTip();
        private TextBox folder, shareName, userName, password, connection, host, phoneUser;
        private ComboBox drives, networks, existingShares, deviceHelp;
        private RadioButton guestMode, passwordMode;
        private CheckBox allowWrite, allowDrive, allowGuest, advancedRepair, animations;
        private Label driveHint, accessHint, writeAccessHint, networkHint, resultTitle, resultMessage, checkDetail, helpText, status;
        private ListView checks;
        private ProgressBar progress;
        private Label progressPercent;
        private Button applyButton, checkButton, repairButton, removeButton, restoreButton, copyButton, openButton;
        private Control settingsPanel, credentialPanel;
        private bool busy, loading, automaticName = true, wizardApproved, drivesLoaded, translatingInterface;
        private Button wizardButton, advancedButton, renameButton, overviewButton, reportButton, remoteButton, receiverRepairButton, resultLink, errorFixButton;
        private Panel homeScroll;
        private ComboBox languages;
        private AeroHeader aeroHeader;
        private Control advancedSettings;
        private Label homeSummary;
        private Action<string> wizardProgress;
        private Action<WorkProgress> wizardCountedProgress;
        private string proposedComputerName;
        private string lastAutomaticName = String.Empty, phase = "Bereit", currentBackup = String.Empty;
        private string restoreName = String.Empty, restoreFolder = String.Empty, restoreBackup = String.Empty;
        private WorkerResult lastResult, lastRawResult, lastRemoteResult, lastServiceResult;
        private DiscoveryPeerService discoveryPeer;
        private System.Threading.CancellationTokenSource homeSearchCancellation;
        private Label discoverySummary;
        private int discoveredComputerCount;
        private bool homeSearchRunning;
        private string rememberedRemoteHost, rememberedRemoteShare, rememberedRemoteUser;
        private Label phoneLogin;
        private Button phoneUserCopy;
        private CollapsibleSection checkSection, connectionSection, helpSection;

        public MainForm(bool preview)
        {
            this.preview = preview;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
            Text = I18n.T("Einfach Netzwerk") + " " + AppInfo.Version + (preview ? I18n.T(" — Vorschau") : "");
            AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 9.5f);
            ForeColor = Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(222, 240, 251);
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96f, 96f);
            MinimumSize = new Size(940, 760);
            ClientSize = new Size(1030, 820);
            StartPosition = FormStartPosition.CenterScreen;
            BuildUi();
            AeroTheme.StyleGlassChildren(this);
            countedProgress = new CountedProgressPresenter(progress, progressPercent);
            I18n.Apply(this);
            I18n.Changed += LanguageChanged;
            if (!preview) { ProblemMemory.Changed += ProblemMemoryChanged; RefreshProblemNotice(); }
            elapsedTimer = new Timer { Interval = 1000 };
            elapsedTimer.Tick += delegate { UpdateStatus(); };
            Shown += delegate
            {
                AeroTheme.GlassFrame(this);
                if (this.preview) ShowPreview();
            };
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (!busy) return;
                e.Cancel = true;
                MessageBox.Show(this, I18n.T("Windows wird gerade geprüft oder eingerichtet. Bitte warte, bis dieser Schritt beendet ist."), I18n.T("Vorgang läuft"), MessageBoxButtons.OK, MessageBoxIcon.Information);
            };
        }

        private void BuildUi()
        {
            TableLayoutPanel shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(12, 0, 12, 0) };
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 122));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 70));
            Controls.Add(shell);
            aeroHeader = new AeroHeader { Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 10), Subtitle = "Ordner und Festplatten teilen. Schritt für Schritt." };
            shell.Controls.Add(aeroHeader, 0, 0);
            TableLayoutPanel preferences = new TableLayoutPanel { Width = 215, Height = 104, Anchor = AnchorStyles.Right | AnchorStyles.Top, Location = new Point(aeroHeader.Width - 225, 7), ColumnCount = 1, RowCount = 3, BackColor = Color.Transparent };
            preferences.RowStyles.Add(new RowStyle(SizeType.Absolute, 31));
            preferences.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
            preferences.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            aeroHeader.Controls.Add(preferences);
            aeroHeader.Resize += delegate { preferences.Left = Math.Max(0, aeroHeader.ClientSize.Width - preferences.Width - 13); };
            languages = Choice();
            languages.Font = new Font("Segoe UI", 9);
            foreach (LanguageItem language in I18n.Languages) languages.Items.Add(language);
            for (int i = 0; i < languages.Items.Count; i++) if (((LanguageItem)languages.Items[i]).Code == I18n.Language) languages.SelectedIndex = i;
            languages.SelectedIndexChanged += delegate { LanguageItem selected = languages.SelectedItem as LanguageItem; if (selected != null) I18n.Language = selected.Code; };
            preferences.Controls.Add(languages, 0, 0);
            animations = new CheckBox { Text = I18n.T("Animationen"), AutoSize = true, Checked = true, ForeColor = Ink, BackColor = Color.Transparent, Margin = new Padding(1, 3, 0, 0) };
            animations.CheckedChanged += delegate { AeroTheme.Animations = animations.Checked; };
            homeHints.SetToolTip(animations, I18n.T("Effekte und Animationen"));
            preferences.Controls.Add(animations, 0, 1);
            renameButton = ActionButton("Computername ändern", 212, false);
            renameButton.Height = 30;
            renameButton.Margin = Padding.Empty;
            renameButton.Dock = DockStyle.Fill;
            renameButton.Click += async delegate { await RenameComputer(); };
            preferences.Controls.Add(renameButton, 0, 2);

            Panel scroll = homeScroll = new BufferedScrollPanel { Dock = DockStyle.Fill, AutoScroll = true, Margin = Padding.Empty };
            shell.Controls.Add(scroll, 0, 1);
            TableLayoutPanel body = Stack();
            body.Padding = new Padding(0, 0, 12, 0);
            scroll.Controls.Add(body);
            body.Controls.Add(BuildWelcomeCard());
            body.Controls.Add(BuildTools());
            body.Controls.Add(BuildProblemNotice());
            TableLayoutPanel details = Stack();
            advancedSettings = details;
            settingsPanel = details;
            details.Controls.Add(BuildFolderCard());
            details.Controls.Add(BuildAccessCard());
            details.Controls.Add(BuildNetworkCard());
            details.Controls.Add(BuildAdvancedActions());
            details.Visible = false;
            body.Controls.Add(details);
            Label detailsHint = Paragraph("Details bei Bedarf öffnen: Klicke auf eine Überschrift.", body);
            detailsHint.Margin = new Padding(3, 2, 0, 3);
            body.Controls.Add(detailsHint);
            body.Controls.Add(BuildCheckCard());
            body.Controls.Add(BuildConnectionCard());
            body.Controls.Add(BuildHelpCard());

            TableLayoutPanel footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty, Padding = new Padding(0, 8, 0, 8) };
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 25));
            footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.Controls.Add(footer, 0, 2);
            TableLayoutPanel meter = ActionGrid(2);
            meter.Dock = DockStyle.Fill;
            meter.ColumnStyles.Clear();
            meter.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            meter.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 64));
            progress = new AeroProgressBar { Dock = DockStyle.Fill, Style = ProgressBarStyle.Continuous, Minimum = 0, Maximum = 100, Visible = false, Margin = new Padding(0, 2, 0, 2) };
            progressPercent = new Label { Text = "0 %", Dock = DockStyle.Fill, Font = new Font("Segoe UI", 10, FontStyle.Bold), TextAlign = ContentAlignment.MiddleCenter, ForeColor = Accent, Visible = false, Margin = new Padding(5, 0, 0, 0) };
            meter.Controls.Add(progress, 0, 0);
            meter.Controls.Add(progressPercent, 1, 0);
            footer.Controls.Add(meter, 0, 0);
            UpdateProgressHint();
            status = new Label { Text = preview ? "Sichere Vorschau • Windows-Einstellungen werden nicht verändert." : "Bereit • Es wurde noch nichts verändert.", Dock = DockStyle.Fill, AutoSize = true, ForeColor = Muted, Margin = new Padding(0, 3, 0, 0) };
            footer.Controls.Add(status, 0, 1);
            advancedButton.Click += delegate { advancedSettings.Visible = !advancedSettings.Visible; if (advancedSettings.Visible) LoadLocalDrives(); advancedButton.Text = I18n.T(advancedSettings.Visible ? "Einstellungen ausblenden" : "Weitere Einstellungen"); };
            errorFixButton.Click += async delegate { await OpenErrorFixWindow(); };
            checkButton.Click += async delegate { await RunOperation("Inspect"); };
            repairButton.Click += async delegate
            {
                if (HasServiceFailure()) { OpenServiceRepair(); return; }
                SelectDiscoveryRepairTarget(true);
                if (!IsManagedSelection()) OpenServiceRepair(); else await RunOperation("Repair");
            };
            removeButton.Click += async delegate { await RunOperation("Remove"); };
            restoreButton.Click += async delegate { await RunOperation("Restore"); };
            copyButton.Click += delegate { CopyConnection(); };
            overviewButton.Click += async delegate { await OpenShareOverview(); };
            reportButton.Click += delegate { DiagnosticReports.Current.SaveReport(this); };
            AcceptButton = applyButton;
        }

        private Control BuildWelcomeCard()
        {
            TableLayoutPanel card = Card("Was möchtest du machen?", "Wähle eine Aufgabe. Der Assistent führt dich durch die Einrichtung.");
            TableLayoutPanel actions = ActionGrid(3);
            actions.Height = 136;
            actions.Margin = new Padding(0, 14, 0, 0);
            wizardButton = ActionButton("Freigabe erstellen", 260, true);
            wizardButton.Click += delegate { OpenWizard(); };
            applyButton = wizardButton;
            overviewButton = ActionButton("Meine Freigaben", 260, false);
            overviewButton.AccessibleName = I18n.T("Freigabenübersicht");
            remoteButton = ActionButton("Andere Computer", 260, false);
            remoteButton.Click += delegate { OpenRemoteAccess(); };
            actions.Controls.Add(BuildTaskTile(wizardButton, "Einen Ordner oder eine Datenfestplatte im Heimnetz teilen."), 0, 0);
            actions.Controls.Add(BuildTaskTile(overviewButton, "Vorhandene Freigaben öffnen, verwalten oder entfernen."), 1, 0);
            actions.Controls.Add(BuildTaskTile(remoteButton, "Computer finden, verbinden und Zugriffsfehler beheben."), 2, 0);
            card.Controls.Add(actions);
            homeSummary = Paragraph("Noch keine Freigabe ausgewählt. Starte mit dem Assistenten.", card);
            card.Controls.Add(homeSummary);
            resultLink = LinkButton("Prüfergebnis anzeigen", 400);
            resultLink.Visible = false;
            resultLink.Click += delegate
            {
                checkSection.Expanded = true;
                homeScroll.ScrollControlIntoView(checkSection);
                checkSection.ToggleButton.Focus();
            };
            card.Controls.Add(resultLink);
            return card;
        }

        private static Control BuildTaskTile(Button action, string explanation)
        {
            TableLayoutPanel tile = new GlassCard { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Padding = new Padding(10), Margin = new Padding(0, 0, 8, 0) };
            tile.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            tile.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
            tile.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            action.Dock = DockStyle.Fill;
            action.Margin = Padding.Empty;
            action.Font = new Font("Segoe UI", 11, FontStyle.Bold);
            action.AccessibleDescription = I18n.T(explanation);
            tile.Controls.Add(action, 0, 0);
            Label description = new Label { Text = I18n.T(explanation), Dock = DockStyle.Fill, UseMnemonic = false, ForeColor = Muted, Margin = new Padding(2, 9, 2, 0) };
            tile.Controls.Add(description, 0, 1);
            return tile;
        }

        private Control BuildTools()
        {
            TableLayoutPanel tools = ActionGrid(3);
            tools.Height = 38;
            tools.Margin = new Padding(0, 0, 0, 8);
            advancedButton = ActionButton("Weitere Einstellungen", 220, false);
            errorFixButton = ActionButton("Fehler beheben", 220, false);
            reportButton = ActionButton("Fehlerbericht exportieren", 245, false);
            reportButton.AccessibleDescription = I18n.T("Kennwörter sind entfernt. Der Bericht enthält technische Angaben und ausgewählte lokale Pfade.");
            homeHints.SetToolTip(reportButton, reportButton.AccessibleDescription);
            Button[] buttons = { errorFixButton, advancedButton, reportButton };
            for (int i = 0; i < buttons.Length; i++)
            {
                buttons[i].Dock = DockStyle.Fill;
                buttons[i].Margin = new Padding(i == 0 ? 0 : 4, 0, i == 0 ? 4 : 0, 0);
                tools.Controls.Add(buttons[i], i, 0);
            }
            return tools;
        }

        private Control BuildAdvancedActions()
        {
            TableLayoutPanel card = Card("Gespeicherte Einrichtung verwalten", "Wähle oben eine gespeicherte Freigabe für diese Aktionen.");
            TableLayoutPanel actions = ActionGrid(2);
            actions.Height = 38;
            actions.Margin = new Padding(0, 12, 0, 0);
            removeButton = ActionButton("Freigabe entfernen", 215, false);
            restoreButton = ActionButton("Einrichtung zurücknehmen", 290, false);
            removeButton.Dock = restoreButton.Dock = DockStyle.Fill;
            removeButton.Margin = new Padding(0, 0, 6, 0);
            restoreButton.Margin = new Padding(6, 0, 0, 0);
            actions.Controls.Add(removeButton, 0, 0);
            actions.Controls.Add(restoreButton, 1, 0);
            card.Controls.Add(actions);
            return card;
        }

        private static TableLayoutPanel ActionGrid(int columns)
        {
            TableLayoutPanel panel = new TableLayoutPanel { Dock = DockStyle.Top, ColumnCount = columns, RowCount = 1, Margin = Padding.Empty, Padding = Padding.Empty, BackColor = Color.Transparent };
            for (int i = 0; i < columns; i++) panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / columns));
            panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            return panel;
        }

        private void LanguageChanged(object sender, EventArgs e)
        {
            Text = I18n.T("Einfach Netzwerk") + " " + AppInfo.Version + (preview ? I18n.T(" — Vorschau") : "");
            if (languages != null)
                for (int i = 0; i < languages.Items.Count; i++)
                    if (((LanguageItem)languages.Items[i]).Code == I18n.Language && languages.SelectedIndex != i) languages.SelectedIndex = i;
            I18n.Apply(this);
            if (aeroHeader != null) aeroHeader.Invalidate();
            UpdateFolder();
            UpdateMode();
            UpdateNetworkHint();
            UpdateDeviceHelp();
            UpdateProgressHint();
            if (lastRawResult != null)
            {
                translatingInterface = true;
                try { ShowResult(lastRawResult); }
                finally { translatingInterface = false; }
            }
            if (!preview) RefreshProblemNotice();
        }

        private void UpdateProgressHint()
        {
            if (progress == null || progressPercent == null) return;
            string hint = I18n.T("Fortschritt zählt erledigte Arbeitsschritte.");
            homeHints.SetToolTip(progress, hint);
            homeHints.SetToolTip(progressPercent, hint);
            progress.AccessibleDescription = hint;
            progressPercent.AccessibleDescription = hint;
            if (animations != null) homeHints.SetToolTip(animations, I18n.T("Effekte und Animationen"));
            if (reportButton != null)
            {
                reportButton.AccessibleDescription = I18n.T("Kennwörter sind entfernt. Der Bericht enthält technische Angaben und ausgewählte lokale Pfade.");
                homeHints.SetToolTip(reportButton, reportButton.AccessibleDescription);
            }
            if (wizardButton != null) wizardButton.AccessibleDescription = I18n.T("Einen Ordner oder eine Datenfestplatte im Heimnetz teilen.");
            if (overviewButton != null) overviewButton.AccessibleDescription = I18n.T("Vorhandene Freigaben öffnen, verwalten oder entfernen.");
            if (remoteButton != null) remoteButton.AccessibleDescription = I18n.T("Computer finden, verbinden und Zugriffsfehler beheben.");
        }

        private async void OpenWizard()
        {
            if (busy) return;
            NetworkItem[] items = lastResult == null ? new NetworkItem[0] : lastResult.Networks;
            CheckItem requestedProblem;
            using (ShareWizard wizard = new ShareWizard(items, preview, null, RefreshWizardNetworks, ApplyWizardCounted))
            {
                wizard.ShowDialog(this);
                requestedProblem = wizard.RequestedProblem;
            }
            if (requestedProblem == null || preview) return;
            try { await RouteErrorFix(ErrorFixDialog.ActionFor(requestedProblem), requestedProblem); }
            catch (Exception error)
            {
                DiagnosticReports.Current.RecordException("Freigabe-Assistent: passende Reparatur öffnen", error);
                status.Text = I18n.TranslatePhase(error.Message);
            }
        }

        private void OpenRemoteAccess() { OpenRemoteAccess(true); }
        private void OpenRemoteAccess(bool receiverRepair)
        { OpenRemoteAccess(receiverRepair, false); }
        private void OpenRemoteAccess(bool receiverRepair, bool prepareClient)
        {
            if (busy) return;
            if (homeSearchCancellation != null) homeSearchCancellation.Cancel();
            WorkerResult clientState = lastRemoteResult ?? lastRawResult;
            WorkerResult inventory = new WorkerResult {
                ComputerName = lastRawResult == null ? Environment.MachineName : lastRawResult.ComputerName,
                Address = lastRawResult == null ? String.Empty : lastRawResult.Address,
                ClientRepairAvailable = clientState != null && clientState.ClientRepairAvailable,
                ClientBackupPath = clientState == null ? null : clientState.ClientBackupPath
            };
            bool servicesRequested = false;
            using (RemoteAccessDialog dialog = new RemoteAccessDialog(inventory, preview, RunRemoteRequest))
            {
                if (prepareClient) dialog.ActivateReceiverPreparationWorkflow();
                else if (receiverRepair) dialog.ActivateReceiverRepairWorkflow();
                if (!prepareClient && !String.IsNullOrWhiteSpace(rememberedRemoteHost)) dialog.SetTarget(rememberedRemoteHost, rememberedRemoteShare, rememberedRemoteUser);
                dialog.ServiceRepairRequested += delegate { servicesRequested = true; };
                dialog.ShowDialog(this);
            }
            if (servicesRequested) OpenServiceRepair();
        }

        private void StartDiscoveryPeer()
        {
            if (preview || discoveryPeer != null) return;
            try
            {
                discoveryPeer = DiscoveryPeerService.Start();
                if (!discoveryPeer.IsListening)
                    DiagnosticReports.Current.RecordOperation("Heimnetz-Datenmeldung", null, new WorkerResult { Success = false, Message = discoveryPeer.ErrorMessage, ErrorCode = discoveryPeer.ErrorCode });
            }
            catch (Exception error) { DiagnosticReports.Current.RecordException("Heimnetz-Datenmeldung", error); }
        }

        private async void StartHomeSearch()
        {
            if (preview || homeSearchRunning || IsDisposed) return;
            homeSearchRunning = true;
            homeSearchCancellation = new System.Threading.CancellationTokenSource();
            System.Threading.CancellationToken cancellation = homeSearchCancellation.Token;
            try
            {
                discoverySummary.Text = I18n.T("Computer und Freigaben im Heimnetz suchen …");
                DiscoveryResult found = await Task.Run(delegate { return NetworkDiscovery.Scan(null, cancellation); });
                if (IsDisposed || cancellation.IsCancellationRequested) return;
                discoveredComputerCount = found.Computers.Count;
                discoverySummary.Text = I18n.Format("{0} Computer im Heimnetz gefunden. Öffne „Andere Computer“, um Freigaben auszuwählen.", discoveredComputerCount);
                if (found.Truncated || found.TimedOut) discoverySummary.Text += " " + I18n.T("Die Suche war begrenzt; weitere Geräte können fehlen.");
                if (found.Errors.Count > 0)
                    DiagnosticReports.Current.RecordOperation("Automatische Heimnetzsuche", null, new WorkerResult { Success = false, Message = String.Join("; ", found.Errors.ToArray()), ErrorCode = "DISCOVERY_INCOMPLETE" });
            }
            catch (Exception error)
            {
                if (!IsDisposed && !cancellation.IsCancellationRequested)
                {
                    DiagnosticReports.Current.RecordException("Automatische Heimnetzsuche", error);
                    discoverySummary.Text = I18n.T("Die Heimnetzsuche konnte nicht abgeschlossen werden. Im Verbindungsfenster erneut suchen oder den Fehlerbericht exportieren.");
                }
            }
            finally { homeSearchRunning = false; }
        }

        private bool HasServiceFailure()
        {
            return lastRawResult != null && (lastRawResult.Checks ?? new CheckItem[0]).Any(item =>
                item != null && item.State == "error" && (item.Name == "LanmanServer" || item.Name == "LanmanWorkstation" || item.Name == "FDResPub" || item.Name == "fdPHost" || (item.Code ?? String.Empty).StartsWith("SERVICE_", StringComparison.Ordinal)));
        }

        private void OpenServiceRepair()
        {
            if (busy) return;
            WorkerResult inventory = lastServiceResult ?? lastRawResult ?? new WorkerResult { ComputerName = Environment.MachineName };
            using (ServiceRepairDialog dialog = new ServiceRepairDialog(inventory, preview, RunServiceRequest)) dialog.ShowDialog(this);
        }

        private async Task<WorkerResult> RunServiceRequest(ShareRequest request, Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            if (busy || preview) throw new InvalidOperationException(I18n.T("Windows wird gerade geprüft oder eingerichtet. Bitte warte, bis dieser Schritt beendet ist."));
            bool mutate = request.Action != "InspectServices";
            SetBusy(true);
            try
            {
                WorkerResult result = await BackendClient.RunAsync(request, mutate,
                    delegate(string text) { UpdatePhase(text); if (phaseSink != null) phaseSink(I18n.TranslatePhase(text)); },
                    delegate(WorkProgress value) { UpdateCountedProgress(value); if (countedSink != null) countedSink(value); });
                if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen."));
                lastServiceResult = result;
                DiagnosticReports.Current.RecordOperation(request.Action, request, result);
                await countedProgress.FinishAsync(result.Success);
                phase = I18n.TranslatePhase(result.Message ?? String.Empty);
                status.ForeColor = result.Success ? Accent : Color.FromArgb(160, 80, 36);
                return result;
            }
            catch (Exception error)
            {
                DiagnosticReports.Current.RecordException(request.Action, error, request);
                countedProgress.Stop(); phase = DiagnosticReports.Current.Redact(error.Message);
                status.ForeColor = Color.FromArgb(160, 80, 36); throw;
            }
            finally { SetBusy(false); status.Text = phase; }
        }

        private async Task<WorkerResult> RunRemoteRequest(ShareRequest request, Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            if (busy) throw new InvalidOperationException(I18n.T("Windows wird gerade geprüft oder eingerichtet. Bitte warte, bis dieser Schritt beendet ist."));
            if (preview) throw new InvalidOperationException(I18n.T("Sichere Vorschau • Windows-Einstellungen werden nicht verändert."));
            bool mutate = request.Action == "RepairClient" || request.Action == "PrepareClient" || request.Action == "RestoreClient";
            SetBusy(true);
            using (DiagnosticReports.Current.ProtectSecrets(request.ProtectedPassword))
            {
                try
                {
                    WorkerResult result = await BackendClient.RunAsync(request, mutate,
                        delegate(string text) { UpdatePhase(text); if (phaseSink != null) phaseSink(I18n.TranslatePhase(text)); },
                        delegate(WorkProgress value) { UpdateCountedProgress(value); if (countedSink != null) countedSink(value); });
                    if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen."));
                    if (result.Success || result.ClientRepairAvailable || !String.IsNullOrWhiteSpace(result.RemoteAddress)) lastRemoteResult = result;
                    if (RequestRules.Validate(request) == null && request.Action != "RestoreClient" && !String.IsNullOrWhiteSpace(request.RemoteHost))
                    {
                        bool sameRememberedComputer = String.Equals(rememberedRemoteHost, request.RemoteHost, StringComparison.OrdinalIgnoreCase);
                        rememberedRemoteHost = request.RemoteHost;
                        if (request.Action != "EnumerateComputer" || !sameRememberedComputer) rememberedRemoteShare = request.RemoteShareName;
                        rememberedRemoteUser = request.RemoteUserName;
                    }
                    DiagnosticReports.Current.RecordOperation(request.Action, request, result);
                    if (request.Action == "InspectClient" || request.Action == "EnumerateComputer") await countedProgress.FinishInspectionAsync();
                    else await countedProgress.FinishAsync(result.Success);
                    // Remote results belong to the connecting dialog. They must
                    // never replace this computer's selected local share or undo state.
                    phase = I18n.TranslatePhase(result.Message ?? String.Empty);
                    status.ForeColor = RemoteAccessDialog.IsAnonymousListLimitation(result, request, request.Action) ? Muted : result.Success ? Accent : Color.FromArgb(160, 80, 36);
                    return result;
                }
                catch (Exception error)
                {
                    DiagnosticReports.Current.RecordException(request.Action, error, request);
                    countedProgress.Stop();
                    phase = DiagnosticReports.Current.Redact(error.Message);
                    status.ForeColor = Color.FromArgb(160, 80, 36);
                    throw;
                }
                finally { SetBusy(false); status.Text = phase; }
            }
        }

        private async Task OpenShareOverview()
        {
            if (busy) return;
            WorkerResult previous = lastRawResult;
            await RunOperation("Inspect");
            // RunOperation reports an interrupted/failed request itself. Never show
            // a stale inventory as if the refresh had just succeeded.
            if (lastRawResult == null || Object.ReferenceEquals(previous, lastRawResult)) return;
            using (ShareOverviewDialog dialog = new ShareOverviewDialog(lastRawResult, preview, RemoveOverviewShare, RefreshOverviewInventory)) dialog.ShowDialog(this);
        }

        private async Task<WorkerResult> RemoveOverviewShare(ShareItem selected)
        {
            if (preview || selected == null || !selected.Available) throw new InvalidOperationException(I18n.T("Die ausgewählte Freigabe ist momentan nicht verfügbar."));
            ShareRequest request = CreateRequest("RemoveListedShare");
            request.ShareName = selected.Name;
            request.FolderPath = selected.Path;
            request.ProtectedPassword = String.Empty;
            request.BackupPath = String.Empty;
            return await RunOverviewRequest(request, true);
        }

        private async Task<WorkerResult> RefreshOverviewInventory()
        {
            ShareRequest request = CreateRequest("Inspect");
            request.ShareName = String.Empty;
            request.FolderPath = String.Empty;
            request.ProtectedPassword = String.Empty;
            return await RunOverviewRequest(request, false);
        }

        private async Task<WorkerResult> RunOverviewRequest(ShareRequest request, bool mutate)
        {
            if (busy) throw new InvalidOperationException(I18n.T("Windows wird gerade geprüft oder eingerichtet. Bitte warte, bis dieser Schritt beendet ist."));
            if (preview) throw new InvalidOperationException(I18n.T("Beispielübersicht. Es werden keine Windows-Einstellungen verändert."));
            SetBusy(true);
            using (DiagnosticReports.Current.ProtectSecrets(password.Text, request.ProtectedPassword))
            {
            try
            {
                WorkerResult result = await BackendClient.RunAsync(request, mutate, UpdatePhase, UpdateCountedProgress);
                if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen."));
                DiagnosticReports.Current.RecordOperation(request.Action, request, result);
                await countedProgress.FinishAsync(result.Success);
                ShowResult(result);
                if (mutate && result.Success) resultTitle.Text = I18n.T("Freigabe entfernt");
                phase = I18n.TranslatePhase(result.Message ?? String.Empty);
                status.ForeColor = result.Success ? Accent : Color.FromArgb(160, 80, 36);
                return result;
            }
            catch (Exception ex)
            {
                DiagnosticReports.Current.RecordException(request.Action, ex, request);
                countedProgress.Stop();
                phase = ex.Message;
                status.ForeColor = Color.FromArgb(160, 80, 36);
                throw;
            }
            finally { SetBusy(false); status.Text = phase; }
            }
        }

        private async Task<NetworkItem[]> RefreshWizardNetworks()
        {
            WorkerResult previous = lastRawResult;
            await RunOperation("Inspect");
            return lastRawResult == null || Object.ReferenceEquals(previous, lastRawResult) ? new NetworkItem[0] : lastRawResult.Networks ?? new NetworkItem[0];
        }

        private async Task<WorkerResult> ApplyWizard(WizardSelection selection, Action<string> progressSink)
        {
            return await ApplyWizardCounted(selection, progressSink, null);
        }

        private async Task<WorkerResult> ApplyWizardCounted(WizardSelection selection, Action<string> progressSink, Action<WorkProgress> countedSink)
        {
            NetworkItem[] fresh = lastRawResult == null ? new NetworkItem[0] : lastRawResult.Networks ?? new NetworkItem[0];
            if (!preview && (selection == null || selection.Network == null || !fresh.Any(item => item != null && item.Id == selection.Network.Id && String.Equals(item.Address, selection.Network.Address, StringComparison.Ordinal))))
                return new WorkerResult { Success = false, Message = I18n.T("Bitte eine aktive Heimnetzverbindung auswählen."), ErrorCode = "WIZARD_NETWORK_REFRESH_REQUIRED", Checks = new[] { new CheckItem { Name = "Heimnetz", State = "error", Code = "WIZARD_NETWORK_REFRESH_REQUIRED", Detail = I18n.T("Bitte eine aktive Heimnetzverbindung auswählen.") } } };
            if (!preview) LoadNetworks(fresh);
            loading = true;
            folder.Text = selection.FolderPath;
            shareName.Text = selection.ShareName;
            guestMode.Checked = selection.Guest;
            passwordMode.Checked = !selection.Guest;
            userName.Text = selection.UserName ?? "NetzwerkUser";
            password.Text = selection.Password ?? String.Empty;
            allowWrite.Checked = selection.AllowWrite;
            allowDrive.Checked = selection.AllowDrive;
            allowGuest.Checked = selection.AllowGuest;
            advancedRepair.Checked = selection.AdvancedRepair;
            automaticName = false;
            for (int i = 0; i < networks.Items.Count; i++)
            {
                NetworkChoice item = networks.Items[i] as NetworkChoice;
                if (item != null && selection.Network != null && item.Item.Id == selection.Network.Id) networks.SelectedIndex = i;
            }
            loading = false;
            UpdateFolder();
            wizardApproved = true;
            wizardProgress = progressSink;
            wizardCountedProgress = countedSink;
            lastResult = null;
            try
            {
                WorkerResult previous = lastRawResult;
                await RunOperation("Apply");
                WorkerResult source = Object.ReferenceEquals(previous, lastRawResult) ? null : lastRawResult;
                wizardProgress = null;
                wizardCountedProgress = null;
                WorkerResult prepared = await WizardPreparationWorkflow.PrepareReceiverAsync(selection, source, RunRemoteRequest, progressSink, countedSink);
                if (prepared != null && !Object.ReferenceEquals(prepared, source))
                {
                    DiagnosticReports.Current.RecordOperation("Assistentenabschluss", new ShareRequest { Action = "Apply", FolderPath = selection.FolderPath, ShareName = selection.ShareName, Mode = selection.Guest ? "Guest" : "Password", AdapterId = selection.Network == null ? 0 : selection.Network.Id }, prepared);
                    ShowResult(prepared);
                }
                return prepared == null ? null : I18n.TranslateResult(prepared);
            }
            finally { wizardApproved = false; wizardProgress = null; wizardCountedProgress = null; password.Clear(); }
        }

        private async Task RenameComputer()
        {
            if (busy) return;
            using (RenameComputerDialog dialog = new RenameComputerDialog(Environment.MachineName))
            {
                if (dialog.ShowDialog(this) != DialogResult.OK) return;
                proposedComputerName = dialog.ComputerName;
            }
            try { await RunOperation("Rename"); }
            finally { proposedComputerName = null; }
        }

        private Control BuildFolderCard()
        {
            TableLayoutPanel card = Card("1  Was möchtest du teilen?", "Wähle einen Ordner oder ein vollständiges Datenlaufwerk.");
            TableLayoutPanel select = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, Margin = new Padding(0, 8, 0, 0) };
            select.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            select.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 103));
            folder = Input();
            folder.TextChanged += delegate { if (!loading) UpdateFolder(); };
            Button browse = ActionButton("Ordner …", 96, false);
            browse.Margin = new Padding(7, 0, 0, 0);
            browse.Click += delegate
            {
                using (FolderBrowserDialog dialog = new FolderBrowserDialog { Description = "Welchen lokalen Ordner möchtest du im Heimnetz freigeben?", ShowNewFolderButton = true })
                {
                    if (Directory.Exists(folder.Text)) dialog.SelectedPath = folder.Text;
                    if (dialog.ShowDialog(this) == DialogResult.OK) SetFolder(dialog.SelectedPath);
                }
            };
            select.Controls.Add(folder, 0, 0);
            select.Controls.Add(browse, 1, 0);
            card.Controls.Add(select);
            drives = Choice();
            drives.Margin = new Padding(0, 7, 0, 0);
            drives.Items.Add(new DriveChoice(null, "Oder: Festplatte / USB-Laufwerk auswählen …"));
            drives.SelectedIndex = 0;
            drives.SelectedIndexChanged += delegate
            {
                DriveChoice chosen = drives.SelectedItem as DriveChoice;
                if (chosen != null && !String.IsNullOrEmpty(chosen.Path)) SetFolder(chosen.Path);
            };
            card.Controls.Add(drives);
            card.Controls.Add(FieldLabel("Name der Freigabe"));
            shareName = Input();
            shareName.TextChanged += delegate { if (!loading && shareName.Text != lastAutomaticName) automaticName = false; UpdateManagedActions(); };
            card.Controls.Add(shareName);
            allowDrive = new CheckBox { Text = "Ich möchte das gesamte Datenlaufwerk teilen.", AutoSize = true, Dock = DockStyle.Top, Visible = false, Margin = new Padding(0, 8, 0, 0) };
            card.Controls.Add(allowDrive);
            driveHint = Paragraph("Ein Ordner kann auch auf einer externen Festplatte liegen.", card);
            driveHint.ForeColor = Muted;
            card.Controls.Add(driveHint);
            card.Controls.Add(FieldLabel("Vorhandene Freigaben"));
            existingShares = Choice();
            existingShares.Items.Add("Noch keine Prüfung durchgeführt");
            existingShares.SelectedIndex = 0;
            existingShares.SelectedIndexChanged += delegate
            {
                if (translatingInterface) return;
                ShareChoice chosen = existingShares.SelectedItem as ShareChoice;
                if (chosen == null) return;
                loading = true;
                folder.Text = chosen.Item.Path ?? String.Empty;
                shareName.Text = chosen.Item.Name ?? String.Empty;
                automaticName = false;
                if (chosen.Item.Managed && !String.IsNullOrEmpty(chosen.Item.Mode))
                {
                    passwordMode.Checked = String.Equals(chosen.Item.Mode, "password", StringComparison.OrdinalIgnoreCase);
                    guestMode.Checked = !passwordMode.Checked;
                    userName.Text = String.IsNullOrEmpty(chosen.Item.UserName) ? "NetzwerkUser" : chosen.Item.UserName;
                    allowWrite.Checked = chosen.Item.AllowWrite;
                    password.Clear();
                    for (int i = 0; i < networks.Items.Count; i++)
                    {
                        NetworkChoice item = networks.Items[i] as NetworkChoice;
                        if (item != null && item.Item.Id == chosen.Item.AdapterId) networks.SelectedIndex = i;
                    }
                }
                loading = false;
                UpdateFolder();
                UpdateManagedActions();
            };
            card.Controls.Add(existingShares);
            return card;
        }

        private Control BuildAccessCard()
        {
            TableLayoutPanel card = Card("2  Wer darf darauf zugreifen?", "Die gewählten Rechte gelten nur für diese Freigabe.");
            guestMode = new RadioButton { Text = "Ohne Passwort · Gastzugang", Checked = true, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 9, 0, 0) };
            passwordMode = new RadioButton { Text = "Mit Benutzername und Passwort", AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 6, 0, 0) };
            card.Controls.Add(guestMode);
            card.Controls.Add(passwordMode);
            TableLayoutPanel credentials = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, Margin = new Padding(0, 8, 0, 0) };
            credentialPanel = credentials;
            credentials.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            credentials.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            credentials.Controls.Add(new Label { Text = "Netzwerk-Benutzer", AutoSize = true, Margin = new Padding(0, 0, 0, 4) }, 0, 0);
            credentials.Controls.Add(new Label { Text = "Passwort (mindestens 8 Zeichen)", AutoSize = true, Margin = new Padding(6, 0, 0, 4) }, 1, 0);
            userName = Input();
            userName.Text = "NetzwerkUser";
            userName.Margin = new Padding(0, 0, 6, 0);
            password = Input();
            password.UseSystemPasswordChar = true;
            password.Margin = new Padding(6, 0, 0, 0);
            credentials.Controls.Add(userName, 0, 1);
            credentials.Controls.Add(password, 1, 1);
            card.Controls.Add(credentials);
            writeAccessHint = Paragraph(String.Empty, card);
            card.Controls.Add(writeAccessHint);
            allowWrite = new CheckBox { Text = "Dateien bearbeiten, hinzufügen und löschen erlauben", Checked = false, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 7, 0, 0) };
            card.Controls.Add(allowWrite);
            allowWrite.CheckedChanged += delegate { UpdateWriteAccessHint(); };
            advancedRepair = new CheckBox { Text = I18n.T("Zugriffsblockaden automatisch beheben"), Checked = true, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 9, 0, 0) };
            card.Controls.Add(advancedRepair);
            card.Controls.Add(Paragraph("Die Reparatur prüft Dateirechte, Netzwerkbindung und Windows-Zugriffssperren für deine Auswahl. Sie sichert Änderungen und prüft danach erneut.", card));
            allowGuest = new CheckBox { Text = "Gastmodus für diesen PC aktivieren", AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 9, 0, 0) };
            card.Controls.Add(allowGuest);
            accessHint = Paragraph(String.Empty, card);
            card.Controls.Add(accessHint);
            guestMode.CheckedChanged += delegate { UpdateMode(); };
            passwordMode.CheckedChanged += delegate { UpdateMode(); };
            UpdateMode();
            return card;
        }

        private Control BuildNetworkCard()
        {
            TableLayoutPanel card = Card("3  In welchem Heimnetz?", "Eigene Firewallregeln gelten für das gewählte Heimnetz.");
            networks = Choice();
            networks.Margin = new Padding(0, 9, 0, 0);
            networks.Items.Add("Noch keine Prüfung durchgeführt");
            networks.SelectedIndex = 0;
            networks.SelectedIndexChanged += delegate { UpdateNetworkHint(); };
            card.Controls.Add(networks);
            networkHint = Paragraph("Prüfen zeigt die verfügbaren LAN- und WLAN-Verbindungen.", card);
            card.Controls.Add(networkHint);
            Button direct = ActionButton("Auswahl jetzt freigeben", 295, true);
            direct.Dock = DockStyle.Top;
            direct.Margin = new Padding(0, 13, 0, 0);
            direct.Click += async delegate { await RunOperation("Apply"); };
            card.Controls.Add(direct);
            return card;
        }

        private Control BuildConnectionCard()
        {
            CollapsibleSection section = connectionSection = CollapsibleCard("So verbinden sich deine Geräte", "Alle Angaben an einer Stelle — auch zum Kopieren.");
            TableLayoutPanel card = section.Content;
            resultTitle = new Label { Text = "Noch keine Freigabe geprüft", AutoSize = true, Dock = DockStyle.Top, Font = new Font("Segoe UI", 11, FontStyle.Bold), ForeColor = Accent, Margin = new Padding(0, 11, 0, 7) };
            card.Controls.Add(resultTitle);
            connection = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Horizontal, WordWrap = false, BackColor = Color.FromArgb(247, 250, 251), ForeColor = Ink, BorderStyle = BorderStyle.FixedSingle, Height = 167, Dock = DockStyle.Top, Font = new Font("Consolas", 10), Text = "IP-Adresse:  —\r\nPort:         445 (SMB)\r\nFreigabe:     —\r\nWindows:      —\r\nSMB-Adresse:  —\r\nBenutzer:     —", Margin = Padding.Empty };
            card.Controls.Add(connection);
            card.Controls.Add(FieldLabel("Host / Server"));
            TableLayoutPanel phone = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, Margin = Padding.Empty };
            phone.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            phone.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 126));
            host = Input();
            host.ReadOnly = true;
            host.Text = "—";
            Button hostCopy = ActionButton("IP kopieren", 119, false);
            hostCopy.Height = 28;
            hostCopy.Margin = new Padding(7, 0, 0, 0);
            hostCopy.Click += delegate { try { if (host.Text != "—") Clipboard.SetText(host.Text); } catch (Exception ex) { ShowError(ex); } };
            phone.Controls.Add(host, 0, 0);
            phone.Controls.Add(hostCopy, 1, 0);
            card.Controls.Add(phone);
            card.Controls.Add(Paragraph("Port: 445 · separat eintragen, nicht an die IP anhängen.", card));
            card.Controls.Add(FieldLabel("Benutzername"));
            TableLayoutPanel login = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, Margin = Padding.Empty };
            login.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            login.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 126));
            phoneUser = Input();
            phoneUser.ReadOnly = true;
            phoneUser.Text = "—";
            phoneUserCopy = ActionButton("Kopieren", 119, false);
            phoneUserCopy.Height = 28;
            phoneUserCopy.Margin = new Padding(7, 0, 0, 0);
            phoneUserCopy.Enabled = false;
            phoneUserCopy.Click += delegate { try { if (phoneUser.Text != "—") Clipboard.SetText(phoneUser.Text); } catch (Exception ex) { ShowError(ex); } };
            login.Controls.Add(phoneUser, 0, 0);
            login.Controls.Add(phoneUserCopy, 1, 0);
            card.Controls.Add(login);
            phoneLogin = Paragraph("Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen.", card);
            card.Controls.Add(phoneLogin);
            copyButton = ActionButton("Verbindung kopieren", 220, false);
            copyButton.Margin = new Padding(0, 10, 0, 0);
            card.Controls.Add(copyButton);
            openButton = LinkButton("Lokalen Ordner öffnen", 183);
            openButton.Margin = new Padding(0, 6, 0, 0);
            openButton.Click += delegate
            {
                try
                {
                    if (Directory.Exists(folder.Text)) Process.Start(new ProcessStartInfo(folder.Text) { UseShellExecute = true });
                    else MessageBox.Show(this, "Bitte wähle einen vorhandenen lokalen Ordner.", "Ordner öffnen", MessageBoxButtons.OK, MessageBoxIcon.Information);
                }
                catch (Exception ex) { ShowError(ex); }
            };
            card.Controls.Add(openButton);
            return section;
        }

        private Control BuildCheckCard()
        {
            CollapsibleSection section = checkSection = CollapsibleCard("Prüfung & Reparatur", "Die Anzeige folgt den tatsächlichen Windows-Prüfungen.");
            TableLayoutPanel card = section.Content;
            TableLayoutPanel actions = ActionGrid(2);
            actions.Height = 38;
            actions.Margin = new Padding(0, 10, 0, 0);
            checkButton = ActionButton("Prüfen", 160, false);
            repairButton = ActionButton("Automatisch reparieren", 260, false);
            checkButton.Dock = repairButton.Dock = DockStyle.Fill;
            checkButton.Margin = new Padding(0, 0, 4, 0);
            repairButton.Margin = new Padding(4, 0, 0, 0);
            actions.Controls.Add(checkButton, 0, 0);
            actions.Controls.Add(repairButton, 1, 0);
            card.Controls.Add(actions);
            receiverRepairButton = ActionButton("Zugriff auf Netzwerk-PCs reparieren", 420, false);
            receiverRepairButton.Dock = DockStyle.Top;
            receiverRepairButton.Margin = new Padding(0, 7, 0, 0);
            receiverRepairButton.Click += delegate { OpenRemoteAccess(true); };
            card.Controls.Add(receiverRepairButton);
            discoverySummary = Paragraph("Die Heimnetzsuche startet bei „Andere Computer“ oder im Fehler-Fixer auf deinen Klick.", card);
            card.Controls.Add(discoverySummary);
            checks = new ListView { View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false, HeaderStyle = ColumnHeaderStyle.Nonclickable, BorderStyle = BorderStyle.FixedSingle, Dock = DockStyle.Top, Height = 162, ShowItemToolTips = true, Margin = new Padding(0, 9, 0, 0) };
            checks.Columns.Add("Prüfung", 255);
            checks.Columns.Add("Status", 105);
            checks.Columns.Add(I18n.T("Ursache / Details"), 240);
            checks.Resize += delegate { ResizeCheckColumns(); };
            checks.SelectedIndexChanged += delegate { UpdateCheckDetails(); };
            card.Controls.Add(checks);
            resultMessage = Paragraph(String.Empty, card);
            resultMessage.Visible = false;
            card.Controls.Add(resultMessage);
            checkDetail = Paragraph("Mit „Prüfen“ erkennst du, was bereit ist und was noch fehlt. Router, WLAN-Gastnetz und Geräte können den Zugriff zusätzlich beeinflussen.", card);
            card.Controls.Add(checkDetail);
            return section;
        }

        private void ResizeCheckColumns()
        {
            int available = checks.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 4;
            if (available <= 0) return;
            int statusWidth = TextRenderer.MeasureText(I18n.T("Fehlt / Fehler"), checks.Font).Width + 14;
            int nameWidth = Math.Max(85, Math.Min(140, available / 4));
            checks.Columns[0].Width = nameWidth;
            checks.Columns[1].Width = statusWidth;
            checks.Columns[2].Width = Math.Max(120, available - nameWidth - statusWidth);
        }

        private static string CheckDetails(CheckItem check)
        {
            string text = (check.Name ?? I18n.T("Prüfung")) + ": " + (check.Detail ?? String.Empty);
            if (!String.IsNullOrWhiteSpace(check.NextStep))
                text += "\n" + I18n.T("So geht es weiter") + ": " + check.NextStep;
            return text;
        }

        private void UpdateCheckDetails()
        {
            if (checkDetail == null) return;
            CheckItem selected = checks.SelectedItems.Count > 0 ? checks.SelectedItems[0].Tag as CheckItem : null;
            checkDetail.Text = selected == null ? I18n.T("Wähle eine Prüfung aus, um die Details zu sehen.") : CheckDetails(selected);
            checkDetail.ForeColor = selected == null ? Muted : StateColor(selected.State);
        }

        private Control BuildHelpCard()
        {
            CollapsibleSection section = helpSection = CollapsibleCard("Auf deinem Gerät öffnen", "Für Geräte und Apps, die SMB 2 oder SMB 3 unterstützen.");
            TableLayoutPanel card = section.Content;
            deviceHelp = Choice();
            deviceHelp.Margin = new Padding(0, 9, 0, 0);
            deviceHelp.Items.AddRange(new object[] { "Android · Samsung und andere", "Windows", "iPhone / iPad", "Mac", "Linux" });
            helpText = Paragraph(String.Empty, card);
            deviceHelp.SelectedIndexChanged += delegate { UpdateDeviceHelp(); };
            card.Controls.Add(deviceHelp);
            card.Controls.Add(helpText);
            deviceHelp.SelectedIndex = 0;
            return section;
        }

        private void SetFolder(string value)
        {
            automaticName = true;
            folder.Text = value;
            UpdateFolder();
        }

        private void UpdateFolder()
        {
            string path = folder.Text.Trim();
            bool root = IsDriveRoot(path);
            allowDrive.Visible = root;
            if (!root) allowDrive.Checked = false;
            allowDrive.Enabled = !IsSystemDrive(path);
            allowDrive.Text = String.Format(I18n.T("Gesamtes Datenlaufwerk {0} freigeben"), path);
            driveHint.Text = I18n.T(root
                ? (IsSystemDrive(path) ? "Das gesamte Windows-Laufwerk wird nicht geteilt. Wähle hier einen Datenordner auf diesem Laufwerk." : "Alle Dateien auf diesem Laufwerk werden erreichbar. Bitte bestätige diese Auswahl oben.")
                : "Auch Datenordner auf externen Festplatten und USB-Laufwerken sind möglich.");
            driveHint.ForeColor = root ? Color.FromArgb(146, 91, 25) : Muted;
            string name = String.Empty;
            try
            {
                name = root ? "Daten-" + path.Substring(0, 1).ToUpperInvariant() : Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            }
            catch (Exception) { }
            if (automaticName || String.IsNullOrWhiteSpace(shareName.Text))
            {
                loading = true;
                shareName.Text = name;
                lastAutomaticName = name;
                loading = false;
            }
            UpdateManagedActions();
        }

        private void UpdateMode()
        {
            if (userName == null || password == null || accessHint == null) return;
            bool usePassword = passwordMode.Checked;
            userName.Enabled = usePassword;
            password.Enabled = usePassword;
            credentialPanel.Visible = usePassword;
            allowGuest.Visible = !usePassword;
            accessHint.ForeColor = usePassword ? Muted : Color.FromArgb(133, 88, 27);
            accessHint.Text = I18n.T(usePassword
                ? "Das Programm richtet ein eigenes lokales Netzwerk-Konto ein. Verwende auf anderen Geräten dieses Passwort, keine Windows-PIN."
                : "Gastmodus verändert das Gastkonto und lockert die eingehende SMB-Signaturpflicht für diesen PC. Alle Geräte im gewählten Heimnetz erhalten die gewählten Rechte. Manche Geräte erlauben keinen Gastzugang.");
            UpdateWriteAccessHint();
        }

        private void UpdateWriteAccessHint()
        {
            if (writeAccessHint == null || allowWrite == null) return;
            writeAccessHint.Text = I18n.T(allowWrite.Checked
                ? "Bearbeiten und Löschen erlaubt. Für Nur lesen die Option unten deaktivieren."
                : "Nur lesen: Öffnen und Kopieren sind erlaubt. Möchtest du auch bearbeiten und löschen?");
        }

        private void UpdateNetworkHint()
        {
            if (networkHint == null) return;
            NetworkChoice selected = networks.SelectedItem as NetworkChoice;
            networkHint.Text = selected == null ? I18n.T("Keine geeignete Verbindung gefunden. Verbinde den PC mit deinem LAN oder WLAN und klicke „Prüfen“.")
                : String.Format(I18n.T("IP {0} · {1}. Diese Verbindung wird als privates Heimnetz eingerichtet. Andere vorhandene Firewallregeln werden geprüft."), selected.Item.Address, selected.Item.Category);
        }

        private void UpdateDeviceHelp()
        {
            if (helpText == null) return;
            string intro;
            switch (deviceHelp.SelectedIndex)
            {
                case 1: intro = "Explorer öffnen. Den Windows-Pfad von oben in die Adressleiste einfügen und Enter drücken. Falls Windows Gastzugriff blockiert, die Freigabe hier mit Benutzername und Passwort einrichten."; break;
                case 2: intro = "Dateien → Durchsuchen → … → Mit Server verbinden. Die SMB-Adresse von oben eintragen."; break;
                case 3: intro = "Finder → Gehe zu → Mit Server verbinden. Die SMB-Adresse von oben einfügen."; break;
                case 4: intro = "Im Dateimanager „Mit Server verbinden“ wählen oder die SMB-Adresse von oben in die Adressleiste eintragen."; break;
                default: intro = "In einer Dateien-App Netzwerkspeicher / SMB hinzufügen. Bei Samsung: Eigene Dateien → Netzwerkspeicher. IP und Port von oben eintragen."; break;
            }
            helpText.Text = I18n.T(intro) + "\n\n" + I18n.T(passwordMode.Checked
                ? "Mit Passwort: „Anonym“ deaktivieren; Netzwerk-Benutzer und Passwort eintragen."
                : "Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen.")
                + "\n\n" + I18n.T("PC und Gerät müssen im selben Heimnetz sein. Der PC muss eingeschaltet und wach bleiben.");
        }

        private async Task RunOperation(string action, ShareRequest confirmedRequest = null)
        {
            if (busy) return;
            if (preview)
            {
                ShowPreview();
                status.Text = "Sichere Vorschau • „" + ActionTitle(action) + "“ verändert hier keine Windows-Einstellungen.";
                return;
            }
            bool mutate = action != "Inspect";
            using (DiagnosticReports.Current.ProtectSecrets(password.Text))
            {
            ShareRequest request;
            try
            {
                if (confirmedRequest != null && (action != "Repair" || confirmedRequest.Action != "Repair")) throw new InvalidOperationException("Ungültiger bestätigter Reparaturauftrag.");
                request = confirmedRequest ?? CreateRequest(action);
            }
            catch (Exception ex) { ShowError(ex, "Der Auftrag konnte nicht vorbereitet werden: "); return; }
            if (mutate && !ValidateRequest(request)) return;
            if (mutate && confirmedRequest == null && !(wizardApproved && action == "Apply") && !ConfirmRequest(request)) return;
            SetBusy(true);
            using (DiagnosticReports.Current.ProtectSecrets(request.ProtectedPassword))
            {
            try
            {
                WorkerResult result = await BackendClient.RunAsync(request, mutate, UpdatePhase, UpdateCountedProgress);
                if (result == null) throw new InvalidOperationException("Windows hat kein Prüfergebnis zurückgegeben. Bitte erneut prüfen.");
                DiagnosticReports.Current.RecordOperation(action, request, result);
                if (action == "Inspect" && !result.Success) await countedProgress.FinishInspectionAsync();
                else await countedProgress.FinishAsync(result.Success);
                if (mutate && result.Success && action != "Restore" && action != "Rename")
                {
                    restoreName = request.ShareName;
                    restoreFolder = request.FolderPath;
                    restoreBackup = result.BackupPath ?? currentBackup;
                }
                if (action == "Restore" && result.Success) { restoreName = String.Empty; restoreFolder = String.Empty; restoreBackup = String.Empty; }
                ShowResult(result);
                if (mutate && result.Success && action == "Apply") password.Clear();
                phase = I18n.TranslatePhase(result.Message ?? (result.Success ? "Vorgang abgeschlossen." : "Der Vorgang konnte nicht abgeschlossen werden."));
                status.ForeColor = result.Success ? Accent : Color.FromArgb(160, 80, 36);
            }
            catch (Exception ex)
            {
                DiagnosticReports.Current.RecordException(action, ex, request);
                countedProgress.Stop();
                phase = "Nicht abgeschlossen: " + ex.Message;
                status.ForeColor = Color.FromArgb(165, 59, 47);
                resultTitle.Text = "Vorgang nicht abgeschlossen";
                resultTitle.ForeColor = Color.FromArgb(165, 59, 47);
                ShowError(ex.Message, false);
            }
            finally
            {
                SetBusy(false);
                status.Text = phase;
            }
            }
            }
        }

        private ShareRequest CreateRequest(string action)
        {
            NetworkChoice selected = networks.SelectedItem as NetworkChoice;
            string sid = String.Empty;
            try { using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) sid = identity.User.Value; }
            catch (Exception) { }
            bool useSavedRestore = action == "Restore" && !String.IsNullOrEmpty(restoreName);
            ShareRequest request = new ShareRequest
            {
                Action = action,
                FolderPath = useSavedRestore ? restoreFolder : folder.Text.Trim(),
                ShareName = useSavedRestore ? restoreName : shareName.Text.Trim(),
                Mode = passwordMode.Checked ? "Password" : "Guest",
                UserName = userName.Text.Trim(),
                ProtectedPassword = !passwordMode.Checked || String.IsNullOrEmpty(password.Text) ? String.Empty : BackendClient.ProtectPassword(password.Text),
                OriginalUserSid = sid,
                BackupPath = useSavedRestore ? restoreBackup : String.Empty,
                AdapterId = selected == null ? 0 : selected.Item.Id,
                AllowWrite = allowWrite.Checked,
                AllowDriveRoot = allowDrive.Checked,
                AllowGuestSettings = allowGuest.Checked,
                AllowAdvancedRepair = advancedRepair.Checked,
                ComputerName = action == "Rename" ? proposedComputerName : null,
                DryRun = false
            };
            ShareItem managed = FindManagedSelection();
            if (action == "Repair" && managed != null)
            {
                request.Mode = managed.Mode;
                request.UserName = managed.UserName;
                request.AllowWrite = managed.AllowWrite;
                request.AdapterId = managed.AdapterId;
                request.AllowDriveRoot = IsDriveRoot(managed.Path);
                request.AllowGuestSettings = String.Equals(managed.Mode, "Guest", StringComparison.OrdinalIgnoreCase);
            }
            return request;
        }

        private bool ValidateRequest(ShareRequest request)
        {
            if (request.Action == "Rename") return true;
            if (request.Action == "Restore" && !String.IsNullOrEmpty(restoreName)) return true;
            if (request.Action == "Remove" || request.Action == "Restore")
            {
                if (!IsManagedSelection()) { ShowError("Wähle eine Freigabe, die mit diesem Programm eingerichtet wurde. Fremde Freigaben werden hier nicht entfernt oder zurückgesetzt."); return false; }
                return true;
            }
            if (request.Action == "Repair" && !IsManagedSelection()) { ShowError("Für diese Auswahl ist noch keine gespeicherte Freigabe dieses Programms vorhanden. Verwende zuerst „Jetzt freigeben“."); return false; }
            if (String.IsNullOrWhiteSpace(request.FolderPath) || !Directory.Exists(request.FolderPath)) { ShowError("Wähle zuerst einen vorhandenen lokalen Ordner oder ein Datenlaufwerk."); return false; }
            if (request.FolderPath.StartsWith("\\\\", StringComparison.Ordinal)) { ShowError("Bitte einen Ordner auf diesem PC auswählen, keine bestehende Netzwerkfreigabe."); return false; }
            if (String.IsNullOrWhiteSpace(request.ShareName)) { ShowError("Gib einen Namen für die Freigabe ein."); return false; }
            if (request.ShareName.IndexOfAny(new char[] { '\\', '/', ':', '*', '?', '"', '<', '>', '|', '[', ']', ';', ',', '+', '=', '$' }) >= 0 || request.ShareName.Length > 80) { ShowError("Der Freigabename darf höchstens 80 Zeichen enthalten. Verwende Buchstaben, Zahlen, Leerzeichen oder Bindestriche."); return false; }
            if (IsDriveRoot(request.FolderPath) && IsSystemDrive(request.FolderPath)) { ShowError("Das gesamte Windows-Laufwerk wird nicht freigegeben. Wähle stattdessen einen Datenordner, zum Beispiel einen Ordner mit deinen Bildern."); return false; }
            if (IsDriveRoot(request.FolderPath) && !request.AllowDriveRoot) { ShowError("Bestätige oben, dass du das gesamte ausgewählte Datenlaufwerk teilen möchtest."); return false; }
            if (!(networks.SelectedItem is NetworkChoice)) { ShowError("Wähle zuerst ein verbundenes Heimnetz. „Prüfen“ lädt die aktuelle Netzwerkliste."); return false; }
            if (String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) && !request.AllowGuestSettings) { ShowError("Bestätige „Gastmodus für diesen PC aktivieren“, damit die Freigabe ohne Passwort eingerichtet werden kann."); return false; }
            if (String.Equals(request.Mode, "Password", StringComparison.OrdinalIgnoreCase))
            {
                if (String.IsNullOrWhiteSpace(request.UserName)) { ShowError("Gib einen Namen für das eigene Netzwerk-Konto ein."); return false; }
                if (request.Action == "Apply" && password.Text.Length < 8) { ShowError("Das Netzwerk-Passwort muss mindestens 8 Zeichen haben."); return false; }
                if (!String.IsNullOrEmpty(password.Text) && password.Text.Length < 8) { ShowError("Das Netzwerk-Passwort muss mindestens 8 Zeichen haben. Für die Reparatur eines gespeicherten Kontos kannst du das Feld leer lassen."); return false; }
            }
            return true;
        }

        private bool ConfirmRequest(ShareRequest request)
        {
            string text;
            if (request.Action == "Rename") text = I18n.T("Computername ändern") + ": " + Environment.MachineName + " → " + request.ComputerName + "\n\n" + I18n.T("Der neue Name wird nach dem nächsten Windows-Neustart verwendet. Das Programm startet den PC nicht automatisch neu.");
            else if (request.Action == "Remove") text = String.Format(I18n.T("Freigabe „{0}“ für\n{1}\n\nentfernen? Deine Dateien bleiben erhalten."), request.ShareName, request.FolderPath);
            else if (request.Action == "Restore") text = String.Format(I18n.T("Die Einrichtung der Freigabe „{0}“ zurücknehmen?\n\n{1}\n\nDas Programm stellt den gesicherten Zustand vor seiner ersten Einrichtung wieder her. Dateien werden nicht gelöscht."), request.ShareName, request.FolderPath);
            else
            {
                NetworkChoice network = networks.SelectedItem as NetworkChoice;
                string networkText = network == null ? "—" : network.ToString();
                if (request.Action == "Repair")
                {
                    foreach (object item in networks.Items)
                    {
                        NetworkChoice saved = item as NetworkChoice;
                        if (saved != null && saved.Item.Id == request.AdapterId) networkText = saved.ToString();
                    }
                }
                text = I18n.T(request.Action == "Repair" ? "Diese Freigabe mit ihrer gespeicherten Konfiguration prüfen und reparieren?" : "Diese Freigabe jetzt einrichten?")
                    + "\n\n" + I18n.T(IsDriveRoot(request.FolderPath) ? "Gesamtes Datenlaufwerk" : "Ordner") + ": " + request.FolderPath
                    + "\n" + I18n.T("Freigabename") + ": " + request.ShareName
                    + "\n" + I18n.T("Heimnetz") + ": " + networkText
                    + "\n" + I18n.T("Zugriff") + ": " + I18n.T(String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) ? "Ohne Passwort (Gast)" : "Mit Passwort") + (String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) ? "" : " · " + request.UserName)
                    + "\n" + I18n.T("Rechte") + ": " + I18n.T(request.AllowWrite ? "Lesen, bearbeiten und löschen" : "Nur lesen")
                    + "\n\n" + I18n.T("Windows richtet die Freigabe, Dateirechte, benötigte Dienste und Firewall für dieses Heimnetz ein. Für diese Änderungen folgt die Windows-Administratorabfrage.");
                if (String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase))
                    text += "\n\n" + I18n.T(request.Action == "Repair"
                        ? "Die Reparatur stellt den gespeicherten Gastmodus inklusive Windows-weitem Gastkonto und SMB-Signatureinstellungen wieder her. Geräte im gewählten Heimnetz können ohne Passwort zugreifen."
                        : "Gastmodus verändert das Gastkonto und lockert die eingehende SMB-Signaturpflicht dieses PCs. Geräte im gewählten Heimnetz können ohne Passwort zugreifen.");
                if (request.Action == "Repair" && lastRawResult != null && (lastRawResult.Checks ?? new CheckItem[0]).Any(item => item != null && item.Code == "DISCOVERY_SETUP_REQUIRED" && String.Equals(item.TargetShare, request.ShareName, StringComparison.OrdinalIgnoreCase)))
                    text = I18n.Format("Für die automatische Heimnetzsuche fehlen noch Erkennungseinstellungen. Möchtest du die Freigabe „{0}“ jetzt aktualisieren?", request.ShareName) + "\n\n" + text;
            }
            return MessageBox.Show(this, I18n.T(text), I18n.T(ActionTitle(request.Action)), MessageBoxButtons.OKCancel, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2) == DialogResult.OK;
        }

        private void ShowResult(WorkerResult result)
        {
            lastRawResult = result;
            if (!preview) StartDiscoveryPeer();
            if (!preview && discoveryPeer != null)
            {
                try { discoveryPeer.UpdateInventory(result.Shares ?? new ShareItem[0]); }
                catch (Exception error) { DiagnosticReports.Current.RecordException("Heimnetz-Freigabedaten", error); }
            }
            result = I18n.TranslateResult(result);
            lastResult = result;
            if (homeSummary != null)
            {
                homeSummary.Text = !result.Success ? I18n.T("Bitte Prüfergebnis beachten") : String.IsNullOrEmpty(shareName.Text) ? I18n.T("Noch keine Freigabe ausgewählt. Starte mit dem Assistenten.") : I18n.T("Ausgewählte Freigabe") + ": " + shareName.Text;
                homeSummary.ForeColor = result.Success ? Muted : StateColor("error");
            }
            if (resultLink != null) resultLink.Visible = !result.Success || (result.Checks ?? new CheckItem[0]).Any(item => item != null && (item.State == "error" || item.State == "warning"));
            if (!String.IsNullOrEmpty(result.BackupPath)) currentBackup = result.BackupPath;
            resultTitle.Text = I18n.T(result.Success ? (result.ConnectionVerified ? "SMB-Zugriff lokal geprüft" : "Windows-Einstellungen geprüft") : "Bitte Prüfergebnis beachten");
            if (result.RestartRequired && !String.IsNullOrEmpty(result.PendingComputerName))
                resultTitle.Text = I18n.T("Neuer Name nach Neustart") + ": " + result.PendingComputerName;
            resultTitle.ForeColor = result.Success ? Accent : Color.FromArgb(149, 88, 29);
            if (!String.IsNullOrEmpty(result.ConnectionText)) connection.Text = result.ConnectionText.Replace("\n", "\r\n").Replace("\r\r\n", "\r\n");
            else
            {
                string address = result.Address ?? String.Empty;
                NetworkChoice n = networks.SelectedItem as NetworkChoice;
                if (String.IsNullOrEmpty(address) && n != null) address = n.Item.Address;
                string name = shareName.Text.Trim();
                string computer = result.ComputerName ?? Environment.MachineName;
                connection.Text = "IP-Adresse:  " + (String.IsNullOrEmpty(address) ? "—" : address)
                    + "\r\nPort:        445 (SMB)\r\nFreigabe:    " + (String.IsNullOrEmpty(name) ? "—" : name)
                    + "\r\nWindows:     " + (String.IsNullOrEmpty(result.SharePath) ? "\\\\" + computer + "\\" + name : result.SharePath)
                    + "\r\nSMB-Adresse: smb://" + address + "/" + name
                    + "\r\nBenutzer:    " + (String.IsNullOrWhiteSpace(result.LoginUserName) ? "—" : result.LoginUserName);
            }
            checks.BeginUpdate();
            checks.Items.Clear();
            ListViewItem firstError = null;
            if (result.Checks != null)
            {
                foreach (CheckItem check in result.Checks)
                {
                    ListViewItem item = new ListViewItem(check.Name ?? I18n.T("Prüfung"));
                    item.SubItems.Add(I18n.T(DisplayState(check.State)));
                    string details = check.Detail ?? String.Empty;
                    if (!String.IsNullOrWhiteSpace(check.NextStep)) details += " · " + I18n.T("So geht es weiter") + ": " + check.NextStep;
                    item.SubItems.Add(details.Replace("\r\n", " · ").Replace("\n", " · ").Replace("\r", " · "));
                    item.ToolTipText = CheckDetails(check);
                    item.Tag = check;
                    item.ForeColor = StateColor(check.State);
                    checks.Items.Add(item);
                    if (firstError == null && DisplayState(check.State) == "Fehlt / Fehler") firstError = item;
                }
            }
            checks.EndUpdate();
            resultMessage.Text = result.Message ?? String.Empty;
            resultMessage.ForeColor = result.Success ? Muted : StateColor("error");
            resultMessage.Visible = !String.IsNullOrWhiteSpace(resultMessage.Text);
            if (!result.Success && firstError != null)
            {
                firstError.Selected = true;
                firstError.Focused = true;
                firstError.EnsureVisible();
            }
            UpdateCheckDetails();
            ResizeCheckColumns();
            if (result.Networks != null) LoadNetworks(result.Networks);
            if (result.Shares != null) LoadShares(result.Shares);
            if (!translatingInterface) SelectDiscoveryRepairTarget();
            string hostAddress = result.Address;
            if (String.IsNullOrWhiteSpace(hostAddress)) { NetworkChoice selected = networks.SelectedItem as NetworkChoice; if (selected != null) hostAddress = selected.Item.Address; }
            host.Text = String.IsNullOrWhiteSpace(hostAddress) ? "—" : hostAddress;
            phoneUser.Text = String.IsNullOrWhiteSpace(result.LoginUserName) ? "—" : result.LoginUserName;
            phoneUserCopy.Enabled = !String.IsNullOrWhiteSpace(result.LoginUserName);
            phoneLogin.Text = I18n.T(passwordMode.Checked ? "Mit Passwort: „Anonym“ deaktivieren; Netzwerk-Benutzer und Passwort eintragen." : "Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen.");
            UpdateDeviceHelp();
            I18n.Apply(this);
            UpdateManagedActions();
            OfferDetectedLocalRepair();
        }

        private void OfferDetectedLocalRepair()
        {
            if (preview || lastRawResult == null) return;
            if (!HasServiceFailure() && !IsManagedSelection()) { ((AeroButton)repairButton).Primary = false; return; }
            CheckItem failure = (lastRawResult.Checks ?? new CheckItem[0]).FirstOrDefault(item => item != null && (item.State == "error" || item.Code == "DISCOVERY_SETUP_REQUIRED") &&
                (item.Fixable || item.Name == "LanmanServer" || item.Name == "LanmanWorkstation" || item.Name == "FDResPub" || item.Name == "fdPHost"));
            ((AeroButton)repairButton).Primary = failure != null;
            if (failure == null) return;
            ((AeroButton)repairButton).Primary = true;
            if (homeSummary != null) homeSummary.Text = I18n.Format("Netzwerkproblem erkannt: {0}. Öffne „Prüfung & Reparatur“, um es zu beheben.", I18n.T(failure.Name ?? "Prüfung"));
            if (resultLink != null) resultLink.Visible = true;
        }

        private void SelectDiscoveryRepairTarget(bool chooseDifferentShare = false)
        {
            if (preview || lastRawResult == null) return;
            ShareItem[] candidates = lastResult == null ? new ShareItem[0] : (lastResult.Shares ?? new ShareItem[0]);
            CheckItem[] issues = (lastRawResult.Checks ?? new CheckItem[0]).Where(item => item != null && item.Code == "DISCOVERY_SETUP_REQUIRED" && item.Fixable && !String.IsNullOrWhiteSpace(item.TargetShare) && candidates.Any(share => share.Managed && share.Available && String.Equals(share.Name, item.TargetShare, StringComparison.OrdinalIgnoreCase))).ToArray();
            CheckItem issue = issues.FirstOrDefault(item => String.Equals(item.TargetShare, shareName.Text.Trim(), StringComparison.OrdinalIgnoreCase));
            if (issue == null && IsManagedSelection() && !chooseDifferentShare) return;
            if (issue == null) issue = issues.FirstOrDefault();
            if (issue == null) return;
            for (int index=0; index<existingShares.Items.Count; index++)
            {
                ShareChoice choice = existingShares.Items[index] as ShareChoice;
                if (choice != null && choice.Item.Managed && choice.Item.Available && String.Equals(choice.Item.Name, issue.TargetShare, StringComparison.OrdinalIgnoreCase))
                { existingShares.SelectedIndex = index; return; }
            }
        }

        private void LoadNetworks(NetworkItem[] items)
        {
            NetworkChoice old = networks.SelectedItem as NetworkChoice;
            int oldId = old == null ? 0 : old.Item.Id;
            networks.BeginUpdate();
            networks.Items.Clear();
            foreach (NetworkItem item in items) networks.Items.Add(new NetworkChoice(item));
            if (networks.Items.Count == 0) networks.Items.Add("Kein geeignetes LAN / WLAN gefunden");
            networks.SelectedIndex = 0;
            for (int i = 0; i < networks.Items.Count; i++)
            {
                NetworkChoice item = networks.Items[i] as NetworkChoice;
                if (item != null && item.Item.Id == oldId) networks.SelectedIndex = i;
            }
            networks.EndUpdate();
            UpdateNetworkHint();
        }

        private void LoadShares(ShareItem[] items)
        {
            string chosenName = shareName.Text.Trim();
            existingShares.BeginUpdate();
            existingShares.Items.Clear();
            existingShares.Items.Add("Freigabe auswählen …");
            foreach (ShareItem item in items) existingShares.Items.Add(new ShareChoice(item));
            existingShares.SelectedIndex = 0;
            // Keep the user's current folder and name while refreshing the inventory.
            for (int i = 1; i < existingShares.Items.Count; i++)
            {
                ShareChoice item = existingShares.Items[i] as ShareChoice;
                if (item != null && String.Equals(item.Item.Name, chosenName, StringComparison.OrdinalIgnoreCase))
                {
                    existingShares.SelectedIndex = i;
                    break;
                }
            }
            existingShares.EndUpdate();
        }

        private bool IsManagedSelection()
        {
            return FindManagedSelection() != null;
        }

        private ShareItem FindManagedSelection()
        {
            if (lastResult == null || lastResult.Shares == null) return null;
            foreach (ShareItem item in lastResult.Shares)
                if (item.Managed && String.Equals(item.Name, shareName.Text.Trim(), StringComparison.OrdinalIgnoreCase) && SamePath(item.Path, folder.Text.Trim())) return item;
            return null;
        }

        private void UpdateManagedActions()
        {
            if (removeButton == null || restoreButton == null) return;
            bool managed = IsManagedSelection();
            removeButton.Enabled = !busy && (preview || managed);
            restoreButton.Enabled = !busy && (preview || managed || !String.IsNullOrEmpty(restoreName));
        }

        private void SetBusy(bool value)
        {
            busy = value;
            settingsPanel.Enabled = !value;
            wizardButton.Enabled = !value;
            advancedButton.Enabled = !value;
            renameButton.Enabled = !value;
            overviewButton.Enabled = !value;
            remoteButton.Enabled = !value;
            receiverRepairButton.Enabled = !value;
            resultLink.Enabled = !value;
            reportButton.Enabled = !value;
            errorFixButton.Enabled = !value;
            languages.Enabled = !value;
            applyButton.Enabled = !value;
            checkButton.Enabled = !value;
            repairButton.Enabled = !value;
            if (value) countedProgress.Begin();
            UseWaitCursor = value;
            if (value)
            {
                phase = "Windows wird vorbereitet …";
                status.ForeColor = Muted;
                watch.Restart();
                elapsedTimer.Start();
                UpdateStatus();
            }
            else
            {
                elapsedTimer.Stop();
                watch.Stop();
            }
            UpdateManagedActions();
            if (!preview) RefreshProblemNotice();
        }

        private void UpdatePhase(string text)
        {
            if (IsDisposed || !IsHandleCreated) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(UpdatePhase), text); return; }
            phase = I18n.TranslatePhase(text);
            if (wizardProgress != null) wizardProgress(phase);
            UpdateStatus();
        }

        private void UpdateCountedProgress(WorkProgress report)
        {
            if (IsDisposed || !IsHandleCreated || !busy) return;
            if (InvokeRequired) { BeginInvoke(new Action<WorkProgress>(UpdateCountedProgress), report); return; }
            if (report != null && report.PhaseStart) countedProgress.Begin();
            countedProgress.Report(report);
            if (wizardCountedProgress != null) wizardCountedProgress(report);
        }

        private void UpdateStatus()
        {
            if (busy) status.Text = phase + "  ·  " + String.Format(I18n.T("{0} Sekunden"), ((int)watch.Elapsed.TotalSeconds));
        }

        private void CopyConnection()
        {
            try
            {
                Clipboard.SetText(I18n.T("Einfach Netzwerk – Verbindung im Heimnetz") + "\r\n\r\n" + connection.Text + "\r\n\r\n"
                    + I18n.T(passwordMode.Checked ? "Mit Passwort: „Anonym“ deaktivieren; Netzwerk-Benutzer und Passwort eintragen." : "Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen.")
                    + "\r\n" + I18n.T("PC und Gerät müssen im selben Heimnetz sein. Der PC muss eingeschaltet und wach bleiben."));
                if (!busy) status.Text = I18n.T("Verbindungsdaten in die Zwischenablage kopiert.");
            }
            catch (Exception ex) { ShowError(ex, "Die Zwischenablage ist gerade nicht erreichbar. "); }
        }

        private void ShowPreview()
        {
            loading = true;
            folder.Text = @"D:\Netzwerk";
            shareName.Text = "Netzwerk";
            automaticName = true;
            lastAutomaticName = "Netzwerk";
            loading = false;
            WorkerResult sample = new WorkerResult
            {
                Success = true,
                Message = "Beispielvorschau. Die echte Geräteverbindung wird hier nicht getestet.",
                ComputerName = "Mein-PC",
                Address = "192.168.178.24",
                SharePath = @"\\Mein-PC\Netzwerk",
                LoginUserName = @"Mein-PC\Gast",
                ConnectionText = "IP-Adresse:  192.168.178.24\r\nPort:        445 (SMB)\r\nFreigabe:    Netzwerk\r\nWindows:     \\\\Mein-PC\\Netzwerk\r\nSMB-Adresse: smb://192.168.178.24/Netzwerk\r\nBenutzer:    Mein-PC\\Gast\r\nPasswort:    keines",
                Checks = new CheckItem[]
                {
                    new CheckItem { Name = "Heimnetz-Verbindung", State = "OK", Detail = "Beispiel: WLAN mit privatem Netzwerkprofil." },
                    new CheckItem { Name = "Ordner & Freigabe", State = "OK", Detail = "Beispiel: Netzwerk ist zum Lesen und Schreiben freigegeben." },
                    new CheckItem { Name = "Dienste & Firewall", State = "OK", Detail = "Beispiel: SMB-Port 445 ist im gewählten Heimnetz erreichbar." },
                    new CheckItem { Name = "Gastzugang", State = "OK", Detail = "Beispiel: Zugang ohne Passwort eingerichtet." },
                    new CheckItem { Name = "Verbindung vom anderen Gerät", State = "Hinweis", Detail = "Am anderen Gerät verbinden. Diese Vorschau führt keine Verbindungstests aus." }
                },
                Networks = new NetworkItem[] { new NetworkItem { Id = 12, Name = "WLAN · Heimnetz", Address = "192.168.178.24", Subnet = "192.168.178.0/24", Category = "Privat" } },
                Shares = new ShareItem[] { new ShareItem { Name = "Netzwerk", Path = @"D:\Netzwerk", Available = true, Managed = true, Mode = "Guest", UserName = "Gast", AllowWrite = true, AdapterId = 12 } }
            };
            ShowResult(sample);
            resultTitle.Text = I18n.T("Beispiel • bereit zum Verbinden");
            UpdateFolder();
            status.Text = I18n.T("Sichere Vorschau • Windows-Einstellungen werden nicht verändert.");
        }

        public void RenderPreview(string path)
        {
            if (!preview) throw new InvalidOperationException("RenderPreview benötigt den sicheren Vorschaumodus.");
            ShowPreview();
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Show();
            Application.DoEvents();
            PerformLayout();
            using (Bitmap bitmap = new Bitmap(Width, Height))
            {
                DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
            Hide();
        }

        public static void RunPreviewSelfTest()
        {
            bool oldAnimations = AeroTheme.Animations;
            AeroTheme.Animations = false;
            try
            {
            ShareWizard.RunPreviewSelfTest();
            using (MainForm form = new MainForm(true))
            {
                form.ShowInTaskbar = false;
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(-32000, -32000);
                form.Show();
                Application.DoEvents();
                form.ShowPreview();
                form.advancedSettings.Visible = true;
                form.checkSection.Expanded = form.connectionSection.Expanded = form.helpSection.Expanded = true;
                foreach (string action in new string[] { "Inspect", "Apply", "Repair", "Remove", "Restore", "Rename" })
                {
                    Task task = form.RunOperation(action);
                    if (!task.IsCompleted || task.IsFaulted || form.busy) throw new InvalidOperationException("Vorschau hat einen echten Vorgang gestartet: " + action);
                }
                if (form.lastResult == null || form.lastResult.Address != "192.168.178.24") throw new InvalidOperationException("Vorschau-Ergebnis fehlt.");
                if (form.phoneUser.Text != @"Mein-PC\Gast" || !form.phoneUserCopy.Enabled
                    || form.phoneLogin.Text != I18n.T("Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen."))
                    throw new InvalidOperationException("Die Verbindungshilfe zeigt nicht den benannten Zugang ohne Passwort.");
                form.SetFolder(@"D:\");
                if (!form.allowDrive.Visible || form.shareName.Text != "Daten-D") throw new InvalidOperationException("Datenlaufwerk-Auswahl ist fehlerhaft.");
                form.SetFolder(@"D:\Familienbilder");
                if (form.allowDrive.Checked || form.shareName.Text != "Familienbilder") throw new InvalidOperationException("Ordner-Auswahl ist fehlerhaft.");
                form.passwordMode.Checked = true;
                if (!form.password.Enabled || form.allowGuest.Visible) throw new InvalidOperationException("Passwortmodus ist fehlerhaft.");
                for (int i = 0; i < form.deviceHelp.Items.Count; i++)
                {
                    form.deviceHelp.SelectedIndex = i;
                    if (String.IsNullOrWhiteSpace(form.helpText.Text)) throw new InvalidOperationException("Gerätehilfe fehlt.");
                }
                form.ShowResult(new WorkerResult
                {
                    Success = true,
                    Shares = new[] { new ShareItem { Name = "GesicherteDaten", Path = @"D:\GesicherteDaten", Managed = true, Mode = "password", UserName = "DateiUser", AllowWrite = false, AdapterId = 12 } },
                    Networks = new[] { new NetworkItem { Id = 12, Name = "Test-Heimnetz", Address = "192.168.178.24", Category = "Privat" } }
                });
                form.existingShares.SelectedIndex = 1;
                if (!form.passwordMode.Checked || form.allowWrite.Checked || form.userName.Text != "DateiUser") throw new InvalidOperationException("Gespeicherte Passwort-Freigabe wurde nicht korrekt geladen.");
                form.guestMode.Checked = true;
                form.allowWrite.Checked = true;
                ShareRequest repair = form.CreateRequest("Repair");
                if (!String.Equals(repair.Mode, "password", StringComparison.OrdinalIgnoreCase) || repair.AllowWrite || repair.UserName != "DateiUser")
                    throw new InvalidOperationException("Reparatur würde die gespeicherte Konfiguration verändern.");
                form.ShowResult(new WorkerResult
                {
                    Success = false,
                    Message = "Die eigentliche Fehlerursache bleibt sichtbar.",
                    Checks = new[] {
                        new CheckItem { Name = "Rücknahme", State = "error", Detail = "Die Rücknahme wurde geprüft." },
                        new CheckItem { Name = "Journal", State = "error", Detail = "Das Journal konnte nicht geöffnet werden.", NextStep = "Das gespeicherte Journal reparieren." },
                        new CheckItem { Name = "Aktion", State = "error", Detail = "Die Aktion ist fehlgeschlagen." }
                    }
                });
                if (form.checks.Columns.Count != 3 || form.checks.Items[1].SubItems[2].Text.IndexOf("Das Journal konnte nicht geöffnet werden.", StringComparison.Ordinal) < 0)
                    throw new InvalidOperationException("Die Fehlerursache fehlt in der sichtbaren Prüfliste.");
                if (form.checks.SelectedItems.Count != 1 || form.checks.SelectedItems[0].Index != 0 || !form.resultMessage.Visible)
                    throw new InvalidOperationException("Fehlermeldung oder automatische Fehlerauswahl fehlt.");
                form.checks.Items[0].Selected = false;
                form.checks.Items[1].Selected = true;
                form.UpdateCheckDetails();
                if (form.resultMessage.Text != "Die eigentliche Fehlerursache bleibt sichtbar." || form.checkDetail.Text.IndexOf("Das gespeicherte Journal reparieren.", StringComparison.Ordinal) < 0)
                    throw new InvalidOperationException("Eine Auswahl verdeckt die eigentliche Fehlerursache oder den nächsten Schritt.");
            }
            }
            finally { AeroTheme.Animations = oldAnimations; }
        }

        public static void RenderWizardPreview(string path)
        {
            using (ShareWizard wizard = new ShareWizard(new[] { new NetworkItem { Id = 12, Name = "WLAN · Heimnetz", Address = "192.168.178.24" } }, true, null, null)) wizard.RenderPreview(path);
        }
        public static void RenderWizardPreview(string path, int step)
        {
            using (ShareWizard wizard = new ShareWizard(new[] { new NetworkItem { Id = 12, Name = "WLAN · Heimnetz", Address = "192.168.178.24" } }, true, null, null)) wizard.RenderPreview(path, step);
        }

        private void ShowError(Exception error, string prefix = "")
        {
            using (DiagnosticReports.Current.ProtectSecrets(password == null ? null : password.Text))
            {
                DiagnosticReports.Current.RecordException("Programmoberfläche", error);
                ShowError(prefix + error.Message, false);
            }
        }

        private void ShowError(string message, bool record = true)
        {
            if (record)
            using (DiagnosticReports.Current.ProtectSecrets(password == null ? null : password.Text))
                DiagnosticReports.Current.RecordMessage("Eingabe / Programmoberfläche", message);
            MessageBox.Show(this, I18n.TranslatePhase(DiagnosticReports.Current.Redact(message)), "Einfach Netzwerk", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private static TableLayoutPanel Stack()
        {
            TableLayoutPanel panel = new BufferedStackPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Dock = DockStyle.Top, GrowStyle = TableLayoutPanelGrowStyle.AddRows, Margin = Padding.Empty, Padding = Padding.Empty };
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            return panel;
        }

        private sealed class BufferedStackPanel : TableLayoutPanel
        {
            internal BufferedStackPanel() { SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true); }
        }

        private sealed class BufferedScrollPanel : Panel
        {
            internal BufferedScrollPanel() { SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true); }
        }

        private static TableLayoutPanel Card(string title, string subtitle)
        {
            TableLayoutPanel card = new GlassCard { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Dock = DockStyle.Top, GrowStyle = TableLayoutPanelGrowStyle.AddRows };
            card.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            card.ControlAdded += delegate(object sender, ControlEventArgs e)
            {
                if (!(e.Control is CheckBox) && !(e.Control is RadioButton)) return;
                Control choice = e.Control;
                EventHandler fit = delegate { choice.MaximumSize = new Size(Math.Max(120, card.ClientSize.Width - card.Padding.Horizontal), 0); };
                card.SizeChanged += fit;
                fit(card, EventArgs.Empty);
            };
            card.Padding = new Padding(15, 13, 15, 13);
            card.Margin = new Padding(0, 0, 0, 12);
            card.Controls.Add(new Label { Text = I18n.T(title), UseMnemonic = false, Font = new Font("Segoe UI", 12, FontStyle.Bold), AutoSize = true, Dock = DockStyle.Top, Margin = Padding.Empty });
            Label hint = Paragraph(subtitle, card);
            hint.Margin = new Padding(0, 5, 0, 0);
            card.Controls.Add(hint);
            return card;
        }

        private static CollapsibleSection CollapsibleCard(string title, string subtitle)
        {
            CollapsibleSection section = new CollapsibleSection(title);
            section.Margin = new Padding(0, 0, 0, 8);
            TableLayoutPanel content = section.Content;
            Label hint = Paragraph(subtitle, content);
            hint.Margin = new Padding(0, 5, 0, 0);
            content.Controls.Add(hint);
            return section;
        }

        private static Label Paragraph(string text, Control parent)
        {
            Label label = new Label { Text = I18n.T(text), UseMnemonic = false, AutoSize = true, Dock = DockStyle.Top, ForeColor = Muted, Margin = new Padding(0, 8, 0, 0), MaximumSize = new Size(450, 0) };
            parent.SizeChanged += delegate
            {
                int width = Math.Max(120, parent.ClientSize.Width - parent.Padding.Horizontal);
                if (label.MaximumSize.Width != width) label.MaximumSize = new Size(width, 0);
            };
            return label;
        }

        private static Label FieldLabel(string text)
        {
            return new Label { Text = I18n.T(text), AutoSize = true, Dock = DockStyle.Top, ForeColor = Muted, Margin = new Padding(0, 8, 0, 4) };
        }

        private static TextBox Input()
        {
            return new TextBox { Dock = DockStyle.Top, Font = new Font("Segoe UI", 10.5f), BorderStyle = BorderStyle.FixedSingle, Margin = Padding.Empty };
        }

        private static ComboBox Choice()
        {
            return new ComboBox { Dock = DockStyle.Top, DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Segoe UI", 10), IntegralHeight = false, DropDownHeight = 220, Margin = Padding.Empty };
        }

        private static Button ActionButton(string text, int width, bool primary)
        {
            Button button = new AeroButton { Text = I18n.T(text), Width = width, Height = 36, Primary = primary, ForeColor = Ink, Margin = new Padding(0, 0, 8, 0), UseVisualStyleBackColor = false };
            return button;
        }

        private static Button LinkButton(string text, int width)
        {
            Button button = new Button { Text = I18n.T(text), Width = width, Height = 28, FlatStyle = FlatStyle.Flat, ForeColor = Accent, BackColor = Color.Transparent, TextAlign = ContentAlignment.MiddleLeft, Cursor = Cursors.Hand, Margin = new Padding(0, 0, 12, 0), Padding = Padding.Empty };
            button.FlatAppearance.BorderSize = 0;
            return button;
        }

        private static bool IsDriveRoot(string path)
        {
            try { return !String.IsNullOrWhiteSpace(path) && Path.IsPathRooted(path) && String.Equals(Path.GetFullPath(path).TrimEnd('\\', '/'), Path.GetPathRoot(Path.GetFullPath(path)).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase); }
            catch (Exception) { return false; }
        }

        private static bool IsSystemDrive(string path)
        {
            try { return IsDriveRoot(path) && String.Equals(Path.GetPathRoot(Path.GetFullPath(path)), Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)), StringComparison.OrdinalIgnoreCase); }
            catch (Exception) { return false; }
        }

        private static bool SamePath(string first, string second)
        {
            try { return String.Equals(Path.GetFullPath(first).TrimEnd('\\', '/'), Path.GetFullPath(second).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase); }
            catch (Exception) { return false; }
        }

        private static string DisplayState(string state)
        {
            string value = (state ?? String.Empty).ToLowerInvariant();
            if (value == "ok" || value == "success" || value == "pass" || value == "ready") return "OK";
            if (value == "warning" || value == "warn" || value == "hinweis") return "Hinweis";
            if (value == "error" || value == "fail" || value == "failed") return "Fehlt / Fehler";
            return String.IsNullOrEmpty(state) ? "—" : state;
        }

        private static Color StateColor(string state)
        {
            string value = (state ?? String.Empty).ToLowerInvariant();
            if (value == "ok" || value == "success" || value == "pass" || value == "ready") return Accent;
            if (value == "error" || value == "fail" || value == "failed") return Color.FromArgb(166, 63, 47);
            return Color.FromArgb(137, 94, 30);
        }

        private static string ActionTitle(string action)
        {
            switch (action)
            {
                case "Rename": return "Computername ändern";
                case "Apply": return "Freigabe einrichten";
                case "Repair": return "Automatisch reparieren";
                case "Remove": return "Freigabe entfernen";
                case "Restore": return "Einrichtung zurücknehmen";
                default: return "Prüfen";
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (elapsedTimer != null) elapsedTimer.Dispose();
                if (countedProgress != null) countedProgress.Dispose();
                homeHints.Dispose();
                if (discoveryPeer != null) { discoveryPeer.Dispose(); discoveryPeer = null; }
                if (homeSearchCancellation != null) { homeSearchCancellation.Cancel(); homeSearchCancellation.Dispose(); homeSearchCancellation = null; }
                I18n.Changed -= LanguageChanged;
                ProblemMemory.Changed -= ProblemMemoryChanged;
            }
            base.Dispose(disposing);
        }

        private sealed class DriveChoice
        {
            internal readonly string Path;
            private readonly string text;
            internal DriveChoice(string path, string text) { Path = path; this.text = text; }
            public override string ToString() { return text; }
        }

        private sealed class NetworkChoice
        {
            internal readonly NetworkItem Item;
            internal NetworkChoice(NetworkItem item) { Item = item; }
            public override string ToString() { return Item.Name + " · " + Item.Address; }
        }

        private sealed class ShareChoice
        {
            internal readonly ShareItem Item;
            internal ShareChoice(ShareItem item) { Item = item; }
            public override string ToString() { return Item.Name + (Item.Managed ? " · von diesem Programm" : " · vorhandene Freigabe"); }
        }
    }

}
