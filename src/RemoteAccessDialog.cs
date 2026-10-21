using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Text;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    // Runs on the receiving Windows computer. A local share inventory cannot
    // certify another computer's SMB client or a real remote connection.
    internal sealed class RemoteAccessDialog : AeroGlassForm
    {
        private readonly bool preview;
        private readonly Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> execute;
        private readonly TextBox targetHost, targetShare, user, password, details;
        private readonly RadioButton guest, withPassword;
        private readonly CheckBox guestConsent, nameConnection;
        private readonly Button check, repair, open, openComputer, export, restore, close, serviceRepair;
        internal event EventHandler ServiceRepairRequested;
        private readonly Label source, status, percentage, accessHint, guestExplanation, nameExplanation;
        private readonly ListView checks;
        private readonly GroupBox resultGroup;
        private readonly Panel scroll;
        private readonly CountedProgressPresenter presenter;
        private readonly string sourceComputer, sourceAddress;
        private readonly AeroHeader remoteHeader;
        private readonly Func<Action<DiscoveryProgress>, CancellationToken, Task<DiscoveryResult>> discover;
        private readonly Func<string, string, bool> consentPrompt;
        private readonly ComboBox computers, discoveredShares;
        private readonly Button refreshDiscovery, stopDiscovery, suggestedRepair;
        private readonly Label discoveryStatus, selectionHint, repairQuestion;
        private readonly GroupBox repairSuggestion;
        private readonly GroupBox receiverGroup;
        private readonly Button receiverSetup;
        private readonly Label receiverStatus;
        private readonly System.Windows.Forms.Timer automaticCheck;
        private CancellationTokenSource discoveryCancellation;
        private DiscoveryResult discoveryResult;
        private bool discovering, fillingSelection, shown, closingDiscovery, hasRepairSuggestion;
        private int inputRevision, discoveryGeneration, selectionRevision = -1;
        private int selectedAdapterId;
        private string selectedAdapterAddress;
        private string lastAutomaticTarget;
        private bool busy, repairSequence, verified, namedVerified;
        private bool clientRepairAvailable;
        private string verifiedPath, verifiedComputerPath, backupPath;
        private WorkerResult lastResult;
        private WorkerResult receiverResult;
        private bool receiverWorkflow, receiverInspected, receiverPreparation;
        private bool prepareOnShown;
        private string lastEnumeratedComputer;
        private string verifiedContextKey;
        private ConnectionProof enumerationProof;
        private readonly ProblemHistory problemHistory = new ProblemHistory();
        private readonly Label problemNotice;
        private readonly GroupBox connectionSummaryGroup;
        private readonly TableLayoutPanel connectionSummaryGrid;
        private readonly Label[] summaryHeadings, summaryValues;
        private ConnectionSummarySnapshot connectionSummary, summaryBeforeOperation;
        private string activeSummaryContext;
        private bool fittingConnectionSummary;

        internal RemoteAccessDialog(WorkerResult localInventory, bool preview,
            Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> execute)
            : this(localInventory, preview, execute, null) { }

        internal RemoteAccessDialog(WorkerResult localInventory, bool preview,
            Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> execute,
            Func<Action<DiscoveryProgress>, CancellationToken, Task<DiscoveryResult>> discover)
            : this(localInventory, preview, execute, discover, null) { }

        internal RemoteAccessDialog(WorkerResult localInventory, bool preview,
            Func<ShareRequest, Action<string>, Action<WorkProgress>, Task<WorkerResult>> execute,
            Func<Action<DiscoveryProgress>, CancellationToken, Task<DiscoveryResult>> discover,
            Func<string, string, bool> consentPrompt)
        {
            this.preview = preview;
            this.execute = execute;
            this.discover = discover ?? delegate(Action<DiscoveryProgress> reportDiscovery, CancellationToken cancellation) { return Task.Run(delegate { return NetworkDiscovery.Scan(reportDiscovery, cancellation); }); };
            this.consentPrompt = consentPrompt ?? delegate(string explanation, string title) { return MessageBox.Show(this, explanation, title, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes; };
            sourceComputer = localInventory == null || String.IsNullOrWhiteSpace(localInventory.ComputerName) ? Environment.MachineName : localInventory.ComputerName;
            sourceAddress = localInventory == null ? String.Empty : localInventory.Address ?? String.Empty;
            backupPath = localInventory == null ? null : localInventory.ClientBackupPath;
            clientRepairAvailable = localInventory != null && localInventory.ClientRepairAvailable;
            Text = I18n.T("Anderen Computer verbinden");
            AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 9.5f);
            ForeColor = AeroTheme.Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(227, 243, 253);
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96, 96);
            ClientSize = new Size(1010, 810);
            MinimumSize = new Size(950, 725);
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            MinimizeBox = false;

            TableLayoutPanel shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new Padding(12, 0, 12, 12), Margin = Padding.Empty };
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 78));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 141));
            Controls.Add(shell);
            remoteHeader = new AeroHeader { Heading = "Anderen Computer verbinden", Subtitle = "Zugriff prüfen und diesen Windows-Computer passend einrichten.", Dock = DockStyle.Fill, Margin = new Padding(0, 0, 0, 8) };
            shell.Controls.Add(remoteHeader, 0, 0);
            source = new Label { Dock = DockStyle.Fill, AutoSize = false, UseMnemonic = false, Margin = new Padding(3, 2, 3, 5), Font = new Font("Segoe UI", 10, FontStyle.Bold) };
            shell.Controls.Add(source, 0, 1);
            scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(3, 0, 3, 4), Margin = Padding.Empty };
            shell.Controls.Add(scroll, 0, 2);
            TableLayoutPanel stack = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Margin = Padding.Empty, Padding = Padding.Empty };
            stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            scroll.Controls.Add(stack);
            Add(stack, Wrapped("Öffne dieses Fenster auf dem Computer, der auf eine Freigabe zugreifen soll. Den freigebenden Computer richtest du mit dem Freigabe-Assistenten ein."));

            GroupBox discoveryGroup = Group("Computer und Freigaben automatisch finden", 228);
            TableLayoutPanel discoveryGrid = Grid(3, 5);
            discoveryGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 164));
            discoveryGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            discoveryGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 200));
            discoveryGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            discoveryGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            discoveryGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
            discoveryGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            discoveryGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
            computers = Choice("Gefundener Computer"); discoveredShares = Choice("Gefundene Freigabe");
            discoveryGrid.Controls.Add(FieldLabel("Gefundener Computer"), 0, 0); discoveryGrid.Controls.Add(computers, 1, 0);
            discoveryGrid.Controls.Add(FieldLabel("Gefundene Freigabe"), 0, 1); discoveryGrid.Controls.Add(discoveredShares, 1, 1);
            refreshDiscovery = ActionButton("Erneut suchen", false); stopDiscovery = ActionButton("Suche abbrechen", false); stopDiscovery.Enabled = false;
            discoveryGrid.Controls.Add(refreshDiscovery, 2, 0); discoveryGrid.Controls.Add(stopDiscovery, 2, 1);
            discoveryStatus = FieldLabel(preview ? "Vorschau: Die Netzwerksuche ist ausgeschaltet." : "Die Suche startet beim Öffnen. Wähle danach einen Computer und eine Freigabe.");
            discoveryGrid.Controls.Add(discoveryStatus, 0, 2); discoveryGrid.SetColumnSpan(discoveryStatus, 3);
            selectionHint = Wrapped("Die Suche liest Geräte und Freigaben im privaten Heimnetz. Passwörter werden nicht erraten. Eine Freigabe wird erst nach einem tatsächlichen Zugriff als erreichbar angezeigt.");
            selectionHint.Dock = DockStyle.Fill; selectionHint.AutoSize = false;
            discoveryGrid.Controls.Add(selectionHint, 0, 3); discoveryGrid.SetColumnSpan(selectionHint, 3);
            Label manualHint = FieldLabel("Oder trage ein bekanntes Ziel unten selbst ein."); discoveryGrid.Controls.Add(manualHint, 0, 4); discoveryGrid.SetColumnSpan(manualHint, 3);
            discoveryGroup.Controls.Add(discoveryGrid); Add(stack, discoveryGroup);

            receiverGroup = Group("Diesen PC für Netzwerkzugriff einrichten", 156); receiverGroup.Width = ClientSize.Width - 54; receiverGroup.Visible = false;
            TableLayoutPanel receiverGrid = Grid(1, 2);
            receiverGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            receiverGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); receiverGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
            receiverStatus = Wrapped("Dieser PC empfängt Freigaben anderer Computer. Die Prüfung unterscheidet Windows-Einstellungen und den tatsächlichen Zugriff.");
            receiverStatus.Dock = DockStyle.Fill; receiverStatus.AutoSize = false;
            receiverSetup = ActionButton("Diesen PC für Netzwerkzugriff einrichten", true);
            receiverGrid.Controls.Add(receiverStatus, 0, 0); receiverGrid.Controls.Add(receiverSetup, 0, 1);
            receiverGroup.Controls.Add(receiverGrid); Add(stack, receiverGroup);
            receiverGrid.Size = new Size(receiverGroup.Width - receiverGroup.Padding.Horizontal, receiverGroup.Height - receiverGroup.Padding.Vertical);
            receiverGrid.PerformLayout();

            GroupBox destination = Group("1 · Ziel eingeben", 164);
            TableLayoutPanel target = Grid(2, 3);
            target.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 164));
            target.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            target.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            target.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            target.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            target.Controls.Add(FieldLabel("Zielcomputer / IP"), 0, 0);
            target.Controls.Add(FieldLabel("Freigabename"), 0, 1);
            targetHost = Input("Zielcomputer / IP", 255);
            targetShare = Input("Freigabename", 80);
            target.Controls.Add(targetHost, 1, 0);
            target.Controls.Add(targetShare, 1, 1);
            Label targetHelp = Wrapped("Aus den Verbindungsdaten des anderen Computers übernehmen. Beispiel: IP 192.168.178.21 und Freigabe Desktop. Port 445 wird automatisch verwendet.");
            targetHelp.Dock = DockStyle.Fill;
            targetHelp.AutoSize = false;
            target.Controls.Add(targetHelp, 0, 2); target.SetColumnSpan(targetHelp, 2);
            destination.Controls.Add(target); Add(stack, destination);

            GroupBox access = Group("Anmeldung am Zielcomputer", 185);
            TableLayoutPanel credentials = Grid(2, 4);
            credentials.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            credentials.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            credentials.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
            credentials.RowStyles.Add(new RowStyle(SizeType.Absolute, 23));
            credentials.RowStyles.Add(new RowStyle(SizeType.Absolute, 33));
            credentials.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            guest = new RadioButton { Text = I18n.T("Ohne Passwort"), Checked = true, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(2, 0, 5, 0) };
            withPassword = new RadioButton { Text = I18n.T("Mit Passwort"), AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(2, 0, 0, 0) };
            credentials.Controls.Add(guest, 0, 0); credentials.Controls.Add(withPassword, 1, 0);
            credentials.Controls.Add(FieldLabel("Benutzername am Zielcomputer"), 0, 1);
            credentials.Controls.Add(FieldLabel("Passwort"), 1, 1);
            user = Input("Benutzername am Zielcomputer", 256);
            password = Input("Passwort", 256); password.UseSystemPasswordChar = true;
            credentials.Controls.Add(user, 0, 2); credentials.Controls.Add(password, 1, 2);
            accessHint = Wrapped(String.Empty); accessHint.Dock = DockStyle.Fill; accessHint.AutoSize = false;
            credentials.Controls.Add(accessHint, 0, 3); credentials.SetColumnSpan(accessHint, 2);
            access.Controls.Add(credentials); Add(stack, access);
            guestExplanation = Wrapped("Für „Ohne Passwort“ darf dieses Programm auf diesem Computer Gastanmeldungen zulassen und die verpflichtende SMB-Signierung sowie die verpflichtende SMB-Verschlüsselung abschalten. Das gilt für den gesamten Windows-SMB-Client und wird vorher gesichert.");
            guestExplanation.Margin = new Padding(8, 5, 8, 5);
            Add(stack, guestExplanation);
            guestConsent = new CheckBox { Text = I18n.T("Gast-Kompatibilität auf diesem Computer erlauben"), AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(8, 0, 8, 12), UseMnemonic = false, AccessibleDescription = guestExplanation.Text };
            Add(stack, guestConsent);
            nameExplanation = Wrapped("Das Programm verbindet zusätzlich den geprüften Computernamen mit dem angegebenen Gastkonto und leerem Passwort. Es prüft auch die Freigabenübersicht, damit du den Computer im Windows-Explorer öffnen kannst.");
            nameExplanation.Margin = new Padding(8, 3, 8, 5);
            nameConnection = new CheckBox { Text = I18n.T("Auch über den Computernamen verbinden"), Checked = true, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(8, 0, 8, 3), UseMnemonic = false, AccessibleDescription = nameExplanation.Text };
            Add(stack, nameConnection); Add(stack, nameExplanation);
            problemNotice = Wrapped(String.Empty); problemNotice.Visible = false; Add(stack, problemNotice);

            repairSuggestion = Group("Zugriffsproblem erkannt", 122); repairSuggestion.Visible = false;
            TableLayoutPanel suggestionGrid = Grid(2, 1);
            suggestionGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); suggestionGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 340));
            repairQuestion = Wrapped(String.Empty); repairQuestion.Dock = DockStyle.Fill; repairQuestion.AutoSize = false;
            repairQuestion.SizeChanged += delegate { FitAnonymousListSuggestion(); };
            suggestedRepair = ActionButton("Ja, jetzt beheben", true);
            suggestionGrid.Controls.Add(repairQuestion, 0, 0); suggestionGrid.Controls.Add(suggestedRepair, 1, 0);
            repairSuggestion.Controls.Add(suggestionGrid); Add(stack, repairSuggestion);

            connectionSummaryGroup = Group("Verbindung auf einen Blick", 178);
            connectionSummaryGroup.Visible = false;
            connectionSummaryGrid = Grid(2, 3);
            // This measured card owns its content bounds. A hidden GroupBox
            // can retain an earlier docked table height; its final table row
            // then stretches and vertically centers text below the card.
            connectionSummaryGrid.Dock = DockStyle.None;
            connectionSummaryGrid.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            connectionSummaryGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 34));
            connectionSummaryGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 66));
            summaryHeadings = new Label[3]; summaryValues = new Label[3];
            string[] summaryTitles = { "Dieser PC vorbereitet", "Anderer Computer erreichbar", "Ordnerzugriff bestätigt" };
            for (int index = 0; index < summaryTitles.Length; index++)
            {
                connectionSummaryGrid.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));
                summaryHeadings[index] = FieldLabel(summaryTitles[index]);
                summaryHeadings[index].Font = new Font(Font, FontStyle.Bold);
                summaryValues[index] = FieldLabel(String.Empty);
                summaryValues[index].AccessibleName = I18n.T(summaryTitles[index]);
                summaryHeadings[index].Margin = new Padding(2, 6, 12, 6);
                summaryValues[index].Margin = new Padding(2, 6, 2, 6);
                connectionSummaryGrid.Controls.Add(summaryHeadings[index], 0, index);
                connectionSummaryGrid.Controls.Add(summaryValues[index], 1, index);
            }
            connectionSummaryGroup.Controls.Add(connectionSummaryGrid);
            connectionSummaryGroup.SizeChanged += delegate { FitConnectionSummary(); };
            connectionSummaryGrid.SizeChanged += delegate { FitConnectionSummary(); };
            Add(stack, connectionSummaryGroup);
            connectionSummary = ConnectionSummaryEvidence.Unknown(String.Empty);
            RenderConnectionSummary();

            resultGroup = Group("Prüfergebnis des tatsächlichen Zugriffs", 267);
            TableLayoutPanel result = Grid(1, 2); result.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            result.RowStyles.Add(new RowStyle(SizeType.Percent, 55)); result.RowStyles.Add(new RowStyle(SizeType.Percent, 45));
            checks = new RemoteChecks { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false, Margin = new Padding(0, 0, 0, 6), AccessibleName = I18n.T("Prüfergebnis des tatsächlichen Zugriffs") };
            checks.Columns.Add(I18n.T("Prüfung"), 200); checks.Columns.Add(I18n.T("Status"), 130); checks.Columns.Add(I18n.T("Ursache / Details"), 590);
            details = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(250, 253, 255), AccessibleName = I18n.T("Verbindungsangaben") };
            checks.SelectedIndexChanged += delegate { ShowSelectedCheck(); };
            result.Controls.Add(checks, 0, 0); result.Controls.Add(details, 0, 1);
            resultGroup.Controls.Add(result); resultGroup.Visible = false; Add(stack, resultGroup);

            TableLayoutPanel work = Grid(2, 2); work.Padding = new Padding(3, 4, 3, 4);
            work.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); work.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 65));
            work.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); work.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
            status = new Label { Dock = DockStyle.Fill, AutoSize = false, UseMnemonic = false, Text = I18n.T(preview ? "Vorschau: Es werden keine Verbindungen oder Windows-Änderungen ausgeführt." : "2 · Klicke auf „Zugriff prüfen“. Erst ein bestätigter Zugriff schaltet „Freigabe öffnen“ frei.") };
            percentage = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.BottomRight, Text = "0 %", Visible = false };
            AeroProgressBar progress = new AeroProgressBar { Dock = DockStyle.Fill, Visible = false, Margin = new Padding(0, 0, 0, 0) };
            work.Controls.Add(status, 0, 0); work.SetColumnSpan(status, 2); work.Controls.Add(progress, 0, 1); work.Controls.Add(percentage, 1, 1);
            shell.Controls.Add(work, 0, 3);
            presenter = new CountedProgressPresenter(progress, percentage);

            TableLayoutPanel buttons = Grid(3, 3);
            buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 34)); buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33));
            buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 33)); buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 34)); buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 33));
            check = ActionButton("2 · Zugriff prüfen", true); repair = ActionButton("3 · Automatisch beheben", false); open = ActionButton("4 · Freigabe öffnen", false);
            export = ActionButton("Fehlerbericht exportieren", false); restore = ActionButton("Client-Änderungen zurücknehmen", false); close = ActionButton("Schließen", false);
            serviceRepair = ActionButton("Windows-Dienste auf diesem PC reparieren", false);
            openComputer = ActionButton("Computer öffnen", false);
            open.Enabled = openComputer.Enabled = false; restore.Enabled = clientRepairAvailable || !String.IsNullOrWhiteSpace(backupPath);
            buttons.Controls.Add(check, 0, 0); buttons.Controls.Add(repair, 1, 0); buttons.Controls.Add(open, 2, 0);
            buttons.Controls.Add(export, 0, 1); buttons.Controls.Add(restore, 1, 1); buttons.Controls.Add(close, 2, 1);
            buttons.Controls.Add(serviceRepair, 0, 2); buttons.SetColumnSpan(serviceRepair, 2);
            buttons.Controls.Add(openComputer, 2, 2);
            shell.Controls.Add(buttons, 0, 4);
            check.Click += async delegate { if (receiverWorkflow && String.IsNullOrWhiteSpace(targetShare.Text)) { lastEnumeratedComputer = null; if (String.IsNullOrWhiteSpace(targetHost.Text)) await InspectReceiver(); else await EnumerateSelectedComputer(); } else await Operate("InspectRemote"); };
            repair.Click += async delegate { if (receiverWorkflow) await PrepareReceiver(); else await RepairAutomatically(); };
            suggestedRepair.Click += async delegate { await AcceptSuggestedRepair(); };
            receiverSetup.Click += async delegate { await PrepareReceiver(); };
            refreshDiscovery.Click += async delegate { await DiscoverNetwork(); };
            stopDiscovery.Click += delegate { if (discoveryCancellation != null) discoveryCancellation.Cancel(); };
            computers.SelectedIndexChanged += delegate { SelectDiscoveredComputer(); };
            discoveredShares.SelectedIndexChanged += delegate { SelectDiscoveredShare(); };
            restore.Click += async delegate { await Operate("RestoreClient"); };
            open.Click += async delegate { await Operate("ConnectRemote"); OpenVerifiedShare(); };
            openComputer.Click += async delegate { await Operate("ConnectRemote"); OpenVerifiedComputer(); };
            export.Click += delegate { DiagnosticReports.Current.SaveReport(this); };
            close.Click += delegate { if (!busy && !repairSequence) Close(); };
            serviceRepair.Click += delegate { if (!busy && !repairSequence) { EventHandler handler = ServiceRepairRequested; if (handler != null) handler(this, EventArgs.Empty); Close(); } };
            guest.CheckedChanged += delegate { UpdateMode(); InvalidateVerifiedConnection(); };
            targetHost.TextChanged += delegate { if (!fillingSelection) { selectedAdapterId = 0; selectedAdapterAddress = null; } InvalidateVerifiedConnection(); };
            targetShare.TextChanged += delegate { InvalidateVerifiedConnection(); };
            user.TextChanged += delegate { InvalidateVerifiedConnection(); };
            password.TextChanged += delegate { InvalidateVerifiedConnection(); };
            nameConnection.CheckedChanged += delegate { InvalidateVerifiedConnection(); };
            automaticCheck = new System.Windows.Forms.Timer { Interval = 650 };
            automaticCheck.Tick += async delegate { automaticCheck.Stop(); if (!withPassword.Checked) await InspectSelectedTarget(); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy || repairSequence) e.Cancel = true; else { closingDiscovery = true; automaticCheck.Stop(); if (discoveryCancellation != null) discoveryCancellation.Cancel(); password.Clear(); } };
            Shown += async delegate
            {
                shown = true; AeroTheme.GlassFrame(this); computers.Focus();
                if (prepareOnShown)
                {
                    await InspectReceiver();
                    if (!preview && !closingDiscovery && !IsDisposed && CanPrepareDirectly(receiverResult)) await PrepareReceiver();
                    return;
                }
                await DiscoverNetwork();
                if (receiverWorkflow && !preview && !closingDiscovery && !IsDisposed) await InspectReceiver();
                ScheduleAutomaticCheck();
            };
            I18n.Changed += LanguageChanged;
            CancelButton = close;
            AcceptButton = check;
            UpdateMode(); UpdateSource(); UpdateDiscoveryControls();
            I18n.Apply(this); AeroTheme.StyleGlassChildren(this);
        }

        private static TableLayoutPanel Grid(int columns, int rows) { return new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = columns, RowCount = rows, Margin = Padding.Empty, Padding = Padding.Empty }; }
        private static GroupBox Group(string title, int height) { return new GroupBox { Text = I18n.T(title), Dock = DockStyle.Top, Height = height, Margin = new Padding(0, 3, 0, 8), Padding = new Padding(10, 20, 10, 9) }; }
        private static void Add(TableLayoutPanel parent, Control child)
        {
            int row = parent.RowCount++; parent.RowStyles.Add(new RowStyle(SizeType.AutoSize)); parent.Controls.Add(child, 0, row);
            Label label = child as Label;
            if (label != null && label.AutoSize)
            {
                EventHandler measure = delegate
                {
                    int width = Math.Max(100, parent.ClientSize.Width - label.Margin.Horizontal);
                    label.MaximumSize = new Size(width, 0);
                    Size text = TextRenderer.MeasureText(label.Text, label.Font, new Size(width, 10000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                    // Label.AutoSize sometimes returns a single-line height in
                    // an AutoSize table. Reserve the actual wrapped text height.
                    label.MinimumSize = new Size(0, text.Height + 2);
                };
                parent.SizeChanged += measure; label.TextChanged += measure; label.FontChanged += measure;
            }
        }
        private static Label FieldLabel(string text) { return new Label { Text = I18n.T(text), Dock = DockStyle.Fill, AutoSize = false, TextAlign = ContentAlignment.MiddleLeft, UseMnemonic = false, Margin = new Padding(2, 0, 8, 0) }; }
        private static TextBox Input(string name, int maximum) { return new TextBox { Dock = DockStyle.Top, Font = new Font("Segoe UI", 11), MaxLength = maximum, Margin = new Padding(2, 1, 7, 5), AccessibleName = I18n.T(name) }; }
        private static ComboBox Choice(string name) { return new ComboBox { Dock = DockStyle.Top, DropDownStyle = ComboBoxStyle.DropDownList, Font = new Font("Segoe UI", 10), Margin = new Padding(2, 1, 7, 5), AccessibleName = I18n.T(name), IntegralHeight = false, DropDownHeight = 250 }; }
        private static Label Wrapped(string text) { return new Label { Text = I18n.T(text), Dock = DockStyle.Top, AutoSize = true, MaximumSize = new Size(930, 0), UseMnemonic = false, Margin = new Padding(3, 3, 3, 8), ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(80, 103, 120) }; }
        private static Button ActionButton(string text, bool primary) { return new AeroButton { Text = I18n.T(text), Primary = primary, Dock = DockStyle.Fill, Margin = new Padding(3, 5, 3, 5) }; }

        private void UpdateSource() { source.Text = I18n.Format("Dieser Computer (Empfänger): {0}", sourceComputer) + (String.IsNullOrWhiteSpace(sourceAddress) ? String.Empty : "  ·  " + sourceAddress); }
        private void UpdateMode()
        {
            password.Enabled = !busy && !repairSequence && !discovering && withPassword.Checked;
            guestConsent.Visible = guest.Checked;
            guestExplanation.Visible = guest.Checked;
            guestConsent.AccessibleDescription = guestExplanation.Text;
            nameConnection.Visible = nameExplanation.Visible = guest.Checked;
            nameConnection.AccessibleDescription = nameExplanation.Text;
            accessHint.Text = I18n.T(guest.Checked
                ? "Ohne Passwort: Übernimm den Benutzer aus den Verbindungsdaten des Zielcomputers, z. B. COMPUTER\\Gast. Passwort leer lassen. Verwende den dort angezeigten Kontonamen."
                : "Mit Passwort: Verwende den Netzwerk-Benutzer und das Passwort des Zielcomputers, z. B. COMPUTER\\Netzwerk. Eine Windows-PIN ist kein Netzwerk-Passwort.");
        }
        private void ClearVerifiedConnection() { verified = namedVerified = false; verifiedPath = verifiedComputerPath = verifiedContextKey = null; }
        private void InvalidateVerifiedConnection() { if (busy || repairSequence || closingDiscovery || Disposing || IsDisposed) return; inputRevision++; ClearVerifiedConnection(); ResetConnectionSummary(); open.Enabled = openComputer.Enabled = false; if (repairSuggestion != null) repairSuggestion.Visible = false; ScheduleAutomaticCheck(); }
        private void ResetConnectionSummary()
        {
            if (connectionSummaryGrid == null || closingDiscovery || Disposing || IsDisposed) return;
            connectionSummary = ConnectionSummaryEvidence.Unknown(CurrentConnectionContext());
            summaryBeforeOperation = null; RenderConnectionSummary();
        }
        private void RenderConnectionSummary()
        {
            if (connectionSummary == null || summaryValues == null) return;
            connectionSummaryGroup.Text = I18n.T("Verbindung auf einen Blick");
            string[] titles = { "Dieser PC vorbereitet", "Anderer Computer erreichbar", "Ordnerzugriff bestätigt" };
            ConnectionSummaryState[] states = { connectionSummary.Local, connectionSummary.Computer, connectionSummary.Folder };
            string[] hints = { connectionSummary.LocalHint, connectionSummary.ComputerHint, connectionSummary.FolderHint };
            for (int index = 0; index < titles.Length; index++)
            {
                summaryHeadings[index].Text = I18n.T(titles[index]);
                string state = states[index] == ConnectionSummaryState.Unchecked ? "Noch nicht geprüft"
                    : states[index] == ConnectionSummaryState.Confirmed ? (index == 0 ? "Vorbereitung bestätigt" : index == 1 ? "Computer antwortet" : "Ordnerzugriff funktioniert")
                    : index == 0 ? "Vorbereitung fehlt" : index == 1 ? "Computer antwortet nicht" : "Ordnerzugriff fehlgeschlagen";
                summaryValues[index].Text = I18n.T(state) + "\r\n" + I18n.T(hints[index]);
                summaryValues[index].AccessibleName = I18n.T(titles[index]);
                summaryValues[index].AccessibleDescription = summaryValues[index].Text;
                summaryValues[index].ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText
                    : states[index] == ConnectionSummaryState.Confirmed ? Color.FromArgb(32, 110, 60)
                    : states[index] == ConnectionSummaryState.Problem ? Color.FromArgb(174, 49, 40) : AeroTheme.Ink;
            }
            FitConnectionSummary();
        }
        private void FitConnectionSummary()
        {
            if (fittingConnectionSummary || closingDiscovery || Disposing || IsDisposed || connectionSummaryGroup == null || connectionSummaryGrid == null || summaryValues == null) return;
            fittingConnectionSummary = true;
            connectionSummaryGrid.SuspendLayout(); connectionSummaryGroup.SuspendLayout();
            try
            {
                int width = Math.Max(200, connectionSummaryGroup.DisplayRectangle.Width);
                int height = 0;
                for (int index = 0; index < summaryValues.Length; index++)
                {
                    int headingWidth = Math.Max(60, (int)(width * .34) - summaryHeadings[index].Margin.Horizontal - 4);
                    int valueWidth = Math.Max(80, (int)(width * .66) - summaryValues[index].Margin.Horizontal - 4);
                    // The scroll container can finish docking the grid after
                    // the outer GroupBox size event. Until then reserve enough
                    // height for the narrower actual label width as well.
                    if (summaryHeadings[index].ClientSize.Width > 60) headingWidth = Math.Min(headingWidth, summaryHeadings[index].ClientSize.Width - 4);
                    if (summaryValues[index].ClientSize.Width > 80) valueWidth = Math.Min(valueWidth, summaryValues[index].ClientSize.Width - 4);
                    Size heading = TextRenderer.MeasureText(summaryHeadings[index].Text, summaryHeadings[index].Font, new Size(headingWidth, 10000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                    Size value = TextRenderer.MeasureText(summaryValues[index].Text, summaryValues[index].Font, new Size(valueWidth, 10000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
                    int rowHeight = Math.Max(heading.Height, value.Height) + summaryValues[index].Margin.Vertical + 6;
                    connectionSummaryGrid.RowStyles[index].Height = rowHeight; height += rowHeight;
                }
                // GroupBox.DisplayRectangle includes the native caption inset
                // in addition to Padding. Batch row changes to avoid reentrant
                // table layout when the group grows or gains a scrollbar.
                int required = height + connectionSummaryGroup.Height - connectionSummaryGroup.DisplayRectangle.Height + 4;
                if (connectionSummaryGroup.Height != required) connectionSummaryGroup.Height = required;
                connectionSummaryGrid.Bounds = connectionSummaryGroup.DisplayRectangle;
            }
            finally
            {
                connectionSummaryGroup.ResumeLayout(true); connectionSummaryGrid.ResumeLayout(true);
                fittingConnectionSummary = false;
            }
        }
        private void ApplyConnectionSummary(WorkerResult result, ShareRequest request, string action)
        {
            string context = CurrentConnectionContext();
            bool localAction = action == "InspectClient" || action == "PrepareClient";
            bool selectionMatches = request != null && String.Equals(request.Mode, guest.Checked ? "Guest" : "Password", StringComparison.OrdinalIgnoreCase) &&
                (localAction || (String.Equals(request.RemoteHost, targetHost.Text.Trim(), StringComparison.OrdinalIgnoreCase) &&
                    String.Equals(request.RemoteUserName ?? String.Empty, user.Text.Trim(), StringComparison.OrdinalIgnoreCase) &&
                    (action == "EnumerateComputer" || String.Equals(request.RemoteShareName, targetShare.Text.Trim(), StringComparison.OrdinalIgnoreCase))));
            bool fresh = !preview && selectionMatches && (activeSummaryContext == null || String.Equals(activeSummaryContext, context, StringComparison.Ordinal));
            connectionSummary = ConnectionSummaryEvidence.Evaluate(result, request, action, context, sourceComputer, fresh, summaryBeforeOperation ?? connectionSummary);
            RenderConnectionSummary(); connectionSummaryGroup.Visible = true; FitConnectionSummary();
        }
        private string CurrentConnectionContext()
        {
            string value = targetHost.Text.Trim() + "\0" + targetShare.Text.Trim() + "\0" + user.Text.Trim() + "\0" +
                (guest.Checked ? "Guest" : "Password") + "\0" + password.Text + "\0" + nameConnection.Checked;
            byte[] bytes = Encoding.UTF8.GetBytes(value);
            try { using (SHA256 hash = SHA256.Create()) return Convert.ToBase64String(hash.ComputeHash(bytes)); }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }
        private ConnectionProof CaptureEnumerationProof(ShareRequest request)
        {
            if (request == null || !verified || String.IsNullOrWhiteSpace(verifiedPath) ||
                !String.Equals(verifiedContextKey, CurrentConnectionContext(), StringComparison.Ordinal) ||
                !String.Equals(request.RemoteHost, targetHost.Text.Trim(), StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(request.RemoteUserName ?? String.Empty, user.Text.Trim(), StringComparison.Ordinal) ||
                !String.Equals(request.Mode, guest.Checked ? "Guest" : "Password", StringComparison.Ordinal)) return null;
            return new ConnectionProof { ContextKey = verifiedContextKey, Verified = verified, NamedVerified = namedVerified, SharePath = verifiedPath, ComputerPath = verifiedComputerPath };
        }
        private sealed class ConnectionProof
        {
            internal string ContextKey, SharePath, ComputerPath;
            internal bool Verified, NamedVerified;
        }
        internal static bool IsAnonymousListLimitation(WorkerResult result, ShareRequest request, string action)
        {
            return result != null && request != null && action == "EnumerateComputer" && result.AnonymousShareListDenied && !result.Success &&
                String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) && String.IsNullOrEmpty(request.RemoteUserName) && String.IsNullOrEmpty(request.ProtectedPassword) &&
                !result.ConnectionVerified && !result.NativeConnectionVerified && !result.NamedConnectionVerified && !result.RemoteComputerEnumerationVerified &&
                Regex.IsMatch(result.ErrorCode ?? String.Empty, @"^(?:Win32:\s*)?5(?:$|[;\s])", RegexOptions.CultureInvariant);
        }

        private async Task DiscoverNetwork()
        {
            if (preview) { discoveryStatus.Text = I18n.T("Vorschau: Die Netzwerksuche ist ausgeschaltet."); return; }
            if (discovering || busy || repairSequence || closingDiscovery || IsDisposed) return;
            discovering = true; int generation = ++discoveryGeneration;
            CancellationTokenSource cancellation = new CancellationTokenSource(); discoveryCancellation = cancellation;
            automaticCheck.Stop(); presenter.Begin(); SetBusy(false);
            discoveryStatus.Text = status.Text = I18n.T("Computer und Freigaben im Heimnetz suchen …");
            lastEnumeratedComputer = null;
            try
            {
                DiscoveryResult found = await discover(delegate(DiscoveryProgress value)
                {
                    if (value == null || !IsHandleCreated || IsDisposed || closingDiscovery) return;
                    try { BeginInvoke((Action)delegate { if (!IsDisposed && !closingDiscovery && discovering && generation == discoveryGeneration) { AddDiscoveredComputer(value.Computer); int completed = Math.Max(0, Math.Min(100, value.Percent)); presenter.Report(new WorkProgress { Text = value.Phase, Completed = completed, Total = 100, Percent = completed }); discoveryStatus.Text = status.Text = I18n.Format("Suche läuft: {0} von {1} Adressen geprüft · {2} %", value.Completed, value.Total, completed); } }); }
                    catch (InvalidOperationException) { }
                }, cancellation.Token);
                if (closingDiscovery || IsDisposed || generation != discoveryGeneration) return;
                discoveryResult = found ?? new DiscoveryResult();
                if (discoveryResult.Cancelled || cancellation.IsCancellationRequested)
                {
                    if (discoveryResult.Computers == null) discoveryResult.Computers = new List<DiscoveredComputer>();
                    foreach (ComputerChoice known in computers.Items)
                    {
                        bool present = false; foreach (DiscoveredComputer candidate in discoveryResult.Computers) if (candidate != null && String.Equals(candidate.Address, known.Value.Address, StringComparison.OrdinalIgnoreCase)) { present = true; break; }
                        if (!present) discoveryResult.Computers.Add(known.Value);
                    }
                }
                PopulateDiscoveredComputers();
                if (discoveryResult.Cancelled || cancellation.IsCancellationRequested) discoveryStatus.Text = I18n.T("Suche abgebrochen. Bereits gefundene Geräte bleiben auswählbar.");
                else if (computers.Items.Count == 0) discoveryStatus.Text = I18n.T("Kein erreichbarer Freigabe-PC gefunden. Prüfe, ob er wach und im gleichen Heimnetz ist.");
                else discoveryStatus.Text = I18n.Format("{0} Computer gefunden. Wähle einen Computer und seine Freigabe.", computers.Items.Count);
                if (discoveryResult.Truncated) selectionHint.Text = I18n.T("Die Suche wurde auf einen begrenzten Bereich des Heimnetzes beschränkt. Ein bekanntes Ziel kannst du unten selbst eintragen.");
                if (discoveryResult.Errors != null && discoveryResult.Errors.Count > 0)
                {
                    DiagnosticReports.Current.RecordException("NetworkDiscovery", new InvalidOperationException(String.Join("\r\n", discoveryResult.Errors.ToArray())));
                    if (computers.Items.Count == 0) selectionHint.Text = I18n.T("Die Suche konnte nicht vollständig abgeschlossen werden. Der Fehlerbericht enthält die Einzelheiten. Ein bekanntes Ziel kannst du unten selbst eintragen.");
                }
                bool completedSearch = found != null && !discoveryResult.Cancelled && !discoveryResult.TimedOut && !cancellation.IsCancellationRequested;
                await presenter.FinishAsync(completedSearch);
                status.Text = I18n.T(completedSearch ? "Die Suche ist abgeschlossen. Wähle jetzt einen Computer." : "Die Suche wurde nicht vollständig abgeschlossen. Bereits gefundene Computer bleiben auswählbar.");
            }
            catch (OperationCanceledException) { presenter.Stop(); if (!closingDiscovery && !IsDisposed) discoveryStatus.Text = status.Text = I18n.T("Suche abgebrochen. Bereits gefundene Geräte bleiben auswählbar."); }
            catch (Exception error)
            {
                presenter.Stop(); if (!closingDiscovery && !IsDisposed) { DiagnosticReports.Current.RecordException("NetworkDiscovery", error); discoveryStatus.Text = status.Text = I18n.T("Die Netzwerksuche ist fehlgeschlagen. Du kannst ein bekanntes Ziel selbst eintragen und den Fehlerbericht exportieren."); }
            }
            finally
            {
                if (ReferenceEquals(discoveryCancellation, cancellation)) discoveryCancellation = null;
                cancellation.Dispose(); discovering = false;
                if (!closingDiscovery && !IsDisposed) { SetBusy(false); ScheduleAutomaticCheck(); }
            }
        }
        private void AddDiscoveredComputer(DiscoveredComputer computer)
        {
            if (computer == null || String.IsNullOrWhiteSpace(computer.Address)) return;
            bool selected = false; int existing = -1;
            for (int i = 0; i < computers.Items.Count; i++) if (String.Equals(((ComputerChoice)computers.Items[i]).Value.Address, computer.Address, StringComparison.OrdinalIgnoreCase)) { existing = i; selected = computers.SelectedIndex == i; break; }
            fillingSelection = true; try { if (existing < 0) computers.Items.Add(new ComputerChoice(computer)); else { computers.Items[existing] = new ComputerChoice(computer); if (selected) computers.SelectedIndex = existing; } } finally { fillingSelection = false; }
            if (selected) RefreshSelectedShares(computer);
            UpdateDiscoveryControls();
        }
        private void PopulateDiscoveredComputers()
        {
            DiscoveredComputer selected = SelectedComputer(); string previous = selected == null ? null : selected.Address;
            fillingSelection = true;
            try
            {
                computers.BeginUpdate(); computers.Items.Clear();
                if (discoveryResult != null && discoveryResult.Computers != null)
                    foreach (DiscoveredComputer computer in discoveryResult.Computers) if (computer != null) computers.Items.Add(new ComputerChoice(computer));
                computers.EndUpdate();
                if (previous != null) for (int i = 0; i < computers.Items.Count; i++) if (String.Equals(((ComputerChoice)computers.Items[i]).Value.Address, previous, StringComparison.OrdinalIgnoreCase)) computers.SelectedIndex = i;
            }
            finally { fillingSelection = false; }
            if (SelectedComputer() != null) RefreshSelectedShares(SelectedComputer());
        }
        private void RefreshSelectedShares(DiscoveredComputer computer)
        {
            DiscoveredShare previous = SelectedShare(); string name = previous == null ? null : previous.Name;
            fillingSelection = true;
            try
            {
                discoveredShares.BeginUpdate(); discoveredShares.Items.Clear();
                if (computer.Shares != null) foreach (DiscoveredShare share in computer.Shares) if (share != null) discoveredShares.Items.Add(new ShareChoice(share));
                discoveredShares.EndUpdate();
                if (name != null) for (int i = 0; i < discoveredShares.Items.Count; i++) if (String.Equals(((ShareChoice)discoveredShares.Items[i]).Value.Name, name, StringComparison.OrdinalIgnoreCase)) discoveredShares.SelectedIndex = i;
            }
            finally { fillingSelection = false; }
            DiscoveredShare selected = SelectedShare();
            if (selected != null && selected.MetadataVerified && inputRevision == selectionRevision && String.IsNullOrWhiteSpace(user.Text) && password.Text.Length == 0) SelectDiscoveredShare();
            UpdateDiscoveryControls();
        }
        private DiscoveredComputer SelectedComputer() { ComputerChoice item = computers.SelectedItem as ComputerChoice; return item == null ? null : item.Value; }
        private DiscoveredShare SelectedShare() { ShareChoice item = discoveredShares.SelectedItem as ShareChoice; return item == null ? null : item.Value; }
        private void SelectDiscoveredComputer()
        {
            if (fillingSelection || busy || repairSequence || discovering) return;
            DiscoveredComputer computer = SelectedComputer(); if (computer == null) return;
            fillingSelection = true;
            try
            {
                targetHost.Text = computer.Address ?? String.Empty; targetShare.Clear(); user.Clear(); password.Clear();
                selectedAdapterId = Math.Max(0, computer.AdapterId); selectedAdapterAddress = computer.Address;
                discoveredShares.BeginUpdate(); discoveredShares.Items.Clear();
                if (computer.Shares != null) foreach (DiscoveredShare share in computer.Shares) if (share != null) discoveredShares.Items.Add(new ShareChoice(share));
                discoveredShares.EndUpdate(); discoveredShares.SelectedIndex = -1;
                selectionHint.Text = !computer.Port445Checked ? I18n.T("Dieser Computer wurde im Heimnetz gemeldet. SMB-Port und Freigaben werden noch geprüft.")
                    : !computer.Port445Open ? I18n.T("Dieser Computer antwortet nicht auf SMB-Port 445. Prüfe zuerst, ob er wach ist. Serverdienst und Firewall prüfst du im Programm auf diesem Computer.")
                    : discoveredShares.Items.Count == 0 ? I18n.T(receiverWorkflow ? "SMB-Port 445 antwortet. Es wurden noch keine Verbindungsdaten gemeldet. Das Programm prüft jetzt die Freigabenliste dieses Computers." : "SMB-Port 445 antwortet. Die Freigabenliste ist noch nicht lesbar. Trage eine bekannte Freigabe und den dort angezeigten Netzwerk-Benutzer unten ein.")
                    : I18n.T("Wähle die gewünschte Freigabe. Der Zugriff wird anschließend automatisch mit Windows geprüft.");
                if (!String.IsNullOrWhiteSpace(computer.ErrorCode)) selectionHint.Text += "\r\n" + I18n.T("Fehlercode") + ": " + computer.ErrorCode + (String.IsNullOrWhiteSpace(computer.ErrorMessage) ? String.Empty : " · " + computer.ErrorMessage);
            }
            finally { fillingSelection = false; }
            InvalidateVerifiedConnection(); UpdateDiscoveryControls();
        }
        private void SelectDiscoveredShare()
        {
            if (fillingSelection || busy || repairSequence || discovering) return;
            DiscoveredComputer computer = SelectedComputer(); DiscoveredShare share = SelectedShare(); if (computer == null || share == null) return;
            fillingSelection = true;
            try
            {
                targetHost.Text = computer.Address ?? String.Empty; targetShare.Text = share.Name ?? String.Empty; user.Clear(); password.Clear();
                selectedAdapterId = Math.Max(0, computer.AdapterId); selectedAdapterAddress = computer.Address;
                ShareRequest metadata = new ShareRequest { Action = "InspectRemote", Mode = share.AccessMode, RemoteHost = computer.Address, RemoteShareName = share.Name, RemoteUserName = share.SuggestedUserName };
                if (share.MetadataVerified && !String.IsNullOrWhiteSpace(computer.ComputerName) &&
                    !String.IsNullOrWhiteSpace(share.SuggestedUserName) && share.SuggestedUserName.StartsWith(computer.ComputerName + "\\", StringComparison.OrdinalIgnoreCase) &&
                    RequestRules.Validate(metadata) == null)
                {
                    guest.Checked = String.Equals(share.AccessMode, "Guest", StringComparison.OrdinalIgnoreCase); withPassword.Checked = !guest.Checked;
                    user.Text = share.SuggestedUserName;
                    selectionHint.Text = I18n.T(guest.Checked ? "Gastkonto vom Freigabe-PC gemeldet. Das Programm prüft jetzt die Anmeldung mit leerem Passwort und den Zugriff über den Computernamen." : "Netzwerk-Benutzer vom Freigabe-PC gemeldet. Bitte gib sein Passwort ein; es wird nicht über das Netzwerk veröffentlicht.");
                }
                else selectionHint.Text = I18n.T("Freigabe gefunden. Die Anmeldedaten sind noch unbekannt. Übernimm den Netzwerk-Benutzer und die Zugriffsart vom freigebenden Computer.");
            }
            finally { fillingSelection = false; }
            InvalidateVerifiedConnection(); selectionRevision = inputRevision; ScheduleAutomaticCheck();
        }
        private void UpdateDiscoveryControls()
        {
            if (IsDisposed) return;
            bool blocked = busy || repairSequence || discovering;
            computers.Enabled = !blocked && computers.Items.Count > 0;
            discoveredShares.Enabled = !blocked && discoveredShares.Items.Count > 0;
            refreshDiscovery.Enabled = !blocked && !discovering && !preview;
            stopDiscovery.Enabled = discovering && !busy && !repairSequence;
            suggestedRepair.Enabled = !blocked && !preview;
            receiverSetup.Enabled = !blocked && !preview;
        }
        private void ScheduleAutomaticCheck()
        {
            if (automaticCheck == null) return;
            automaticCheck.Stop();
            if (!shown || preview || prepareOnShown || fillingSelection || closingDiscovery || busy || repairSequence || discovering || receiverPreparation || withPassword.Checked) return;
            automaticCheck.Start();
        }
        private async Task InspectSelectedTarget()
        {
            if (preview || busy || repairSequence || discovering || receiverPreparation || closingDiscovery || IsDisposed) return;
            if (receiverWorkflow && !String.IsNullOrWhiteSpace(targetHost.Text) && String.IsNullOrWhiteSpace(targetShare.Text)) { await EnumerateSelectedComputer(); return; }
            string host, share;
            if (!TryNormalizeTarget(targetHost.Text, targetShare.Text, out host, out share) || String.IsNullOrWhiteSpace(user.Text) || (withPassword.Checked && password.Text.Length == 0)) return;
            ShareRequest checkRequest = new ShareRequest { Action = "InspectRemote", RemoteHost = host, RemoteShareName = share, RemoteUserName = user.Text.Trim(), Mode = guest.Checked ? "Guest" : "Password" };
            if (RequestRules.Validate(checkRequest) != null) return;
            string key = inputRevision.ToString() + ":" + host + "\\" + share + ":" + checkRequest.RemoteUserName + ":" + checkRequest.Mode;
            if (String.Equals(lastAutomaticTarget, key, StringComparison.Ordinal)) return;
            lastAutomaticTarget = key;
            // Selecting a guest share establishes the requested Windows-session
            // login. No machine-wide policy changes run without the repair action.
            await Operate(guest.Checked ? "ConnectRemote" : "InspectRemote");
        }
        private sealed class ComputerChoice
        {
            internal readonly DiscoveredComputer Value; internal ComputerChoice(DiscoveredComputer value) { Value = value; }
            public override string ToString() { return (String.IsNullOrWhiteSpace(Value.ComputerName) ? String.IsNullOrWhiteSpace(Value.DisplayName) ? Value.Address : Value.DisplayName : Value.ComputerName) + "  ·  " + Value.Address + "  ·  " + I18n.T(!Value.Port445Checked ? "SMB noch ungeprüft" : Value.Port445Open ? "SMB erreichbar · Zugriff noch ungeprüft" : "SMB-Port 445 antwortet nicht"); }
        }
        private sealed class ShareChoice
        {
            internal readonly DiscoveredShare Value; internal ShareChoice(DiscoveredShare value) { Value = value; }
            public override string ToString() { return Value.Name + (Value.MetadataVerified ? "  ·  " + I18n.T(String.Equals(Value.AccessMode, "Guest", StringComparison.OrdinalIgnoreCase) ? "Ohne Passwort" : "Mit Passwort") : String.Empty); }
        }

        internal static bool TryNormalizeTarget(string hostInput, string shareInput, out string host, out string share)
        {
            host = (hostInput ?? String.Empty).Trim(); share = (shareInput ?? String.Empty).Trim();
            if (host.StartsWith(@"\\", StringComparison.Ordinal))
            {
                string[] parts = host.Substring(2).Split('\\');
                if (parts.Length != 2 || String.IsNullOrWhiteSpace(parts[0]) || String.IsNullOrWhiteSpace(parts[1])) return false;
                if (share.Length > 0 && !String.Equals(share, parts[1], StringComparison.OrdinalIgnoreCase)) return false;
                host = parts[0]; share = parts[1];
            }
            else if (host.StartsWith("smb://", StringComparison.OrdinalIgnoreCase))
            {
                Uri uri;
                if (!Uri.TryCreate(host, UriKind.Absolute, out uri) || !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Query) || !String.IsNullOrEmpty(uri.Fragment) || (uri.Port != -1 && uri.Port != 445)) return false;
                string path = uri.AbsolutePath.Trim('/');
                if (String.IsNullOrWhiteSpace(path) || path.IndexOf('/') >= 0) return false;
                string parsed = Uri.UnescapeDataString(path);
                if (share.Length > 0 && !String.Equals(share, parsed, StringComparison.OrdinalIgnoreCase)) return false;
                host = uri.Host; share = parsed;
            }
            return host.Length > 0 && share.Length > 0;
        }

        internal void ActivateReceiverRepairWorkflow()
        {
            if (shown || busy) return;
            receiverWorkflow = true; receiverGroup.Visible = true;
            Text = I18n.T("Zugriff auf Netzwerk-PCs reparieren");
            remoteHeader.Heading = "Zugriff auf Netzwerk-PCs reparieren";
            check.Text = I18n.T("Freigaben prüfen");
            repair.Text = I18n.T("Diesen PC einrichten");
        }
        internal void ActivateReceiverPreparationWorkflow()
        {
            if (shown || busy) return;
            ActivateReceiverRepairWorkflow(); prepareOnShown = true;
        }
        private static bool CanPrepareDirectly(WorkerResult result)
        {
            if (result == null || result.Success || result.InspectionIncomplete || !String.Equals(result.ErrorCode, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", StringComparison.Ordinal)) return false;
            foreach (CheckItem item in result.Checks ?? new CheckItem[0])
                if (item != null && item.Fixable && (item.State == "error" || item.State == "warning") && String.Equals(item.Code, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", StringComparison.Ordinal)) return true;
            return false;
        }
        private async Task InspectReceiver()
        {
            if (preview || busy || repairSequence || discovering || closingDiscovery || IsDisposed) return;
            receiverStatus.Text = I18n.T("Windows-Einstellungen dieses Empfänger-PCs prüfen …");
            await Operate("InspectClient");
            receiverResult = lastResult; receiverInspected = receiverResult != null;
            if (receiverResult != null) receiverStatus.Text = receiverResult.Success
                ? I18n.T(prepareOnShown ? "Die Windows-Client-Einstellungen sind bereit. Der Zugriff auf einen anderen Computer ist noch ungeprüft." : "Die Einstellungen dieses PCs sind bereit. Wähle einen gefundenen Computer; erst ein geprüfter Zugriff schaltet das Öffnen frei.")
                : I18n.TranslatePhase(receiverResult.Message ?? String.Empty) + (String.IsNullOrWhiteSpace(receiverResult.ErrorCode) ? String.Empty : "\r\n" + I18n.T("Fehlercode") + ": " + receiverResult.ErrorCode);
        }
        private async Task PrepareReceiver()
        {
            if (preview || busy || repairSequence || discovering || receiverPreparation || closingDiscovery || IsDisposed) return;
            if (!receiverInspected) await InspectReceiver();
            if (prepareOnShown && !CanPrepareDirectly(receiverResult)) return;
            if (receiverResult != null && String.Equals(receiverResult.ErrorCode, "SERVICE_WORKSTATION_NOT_RUNNING", StringComparison.Ordinal))
            {
                EventHandler handler = ServiceRepairRequested; if (handler != null) handler(this, EventArgs.Empty); Close(); return;
            }
            if (receiverResult != null && !receiverResult.Success && !String.Equals(receiverResult.ErrorCode, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", StringComparison.Ordinal))
            {
                await InspectReceiver(); return;
            }
            if (!guest.Checked)
            {
                await InspectReceiver();
                receiverStatus.Text = I18n.T("Für eine Anmeldung mit Passwort gib zuerst Netzwerk-Benutzer und Passwort des Zielcomputers ein."); return;
            }
            string explanation = guestExplanation.Text + "\r\n\r\n" + I18n.T("Möchtest du diesen PC für Freigaben ohne Passwort einrichten?");
            if (!guestConsent.Checked && !consentPrompt(explanation, I18n.T("Gast-Kompatibilität auf diesem PC erlauben?"))) return;
            guestConsent.Checked = true; receiverPreparation = true;
            try
            {
                await Operate("PrepareClient");
                if (lastResult == null || !lastResult.Success) return;
                await InspectReceiver();
                if (receiverResult != null && receiverResult.Success)
                {
                    if (prepareOnShown)
                        receiverStatus.Text = status.Text = I18n.T("Dieser Windows-Client ist für Freigaben ohne Passwort vorbereitet. Der Zugriff auf einen anderen Computer ist noch ungeprüft.");
                    else
                    {
                        receiverStatus.Text = I18n.T("Empfänger-PC eingerichtet. Die Suche wird erneut gestartet; der Zugriff auf andere Computer ist noch nicht bestätigt.");
                        await DiscoverNetwork();
                    }
                }
            }
            finally { receiverPreparation = false; SetBusy(false); ScheduleAutomaticCheck(); }
        }
        private async Task EnumerateSelectedComputer()
        {
            if (preview || busy || repairSequence || discovering || closingDiscovery || IsDisposed || String.IsNullOrWhiteSpace(targetHost.Text)) return;
            if (withPassword.Checked && (String.IsNullOrWhiteSpace(user.Text) || password.Text.Length == 0))
            { status.Text = I18n.T("Für eine Anmeldung mit Passwort gib zuerst Netzwerk-Benutzer und Passwort des Zielcomputers ein."); return; }
            string key = inputRevision.ToString() + ":" + targetHost.Text.Trim() + ":" + user.Text.Trim() + ":" + (guest.Checked ? "Guest" : "Password");
            if (String.Equals(lastEnumeratedComputer, key, StringComparison.Ordinal)) return;
            lastEnumeratedComputer = key; status.Text = I18n.T("Freigaben des ausgewählten Computers werden geprüft …");
            await Operate("EnumerateComputer");
        }
        private ShareRequest CreateRequest(string action)
        {
            string host = null, share = null;
            bool receiverAction = action == "InspectClient" || action == "PrepareClient";
            if (action == "EnumerateComputer") { host = targetHost.Text.Trim(); share = null; }
            else if (receiverAction) { host = share = null; }
            else if (action != "RestoreClient" && !TryNormalizeTarget(targetHost.Text, targetShare.Text, out host, out share))
                throw new ArgumentException(I18n.T("Bitte Zielcomputer und Freigabename getrennt eintragen, oder einen vollständigen Pfad wie \\\\COMPUTER\\Desktop einfügen."));
            if (action == "RestoreClient") { host = targetHost.Text.Trim(); share = targetShare.Text.Trim(); }
            else if (!receiverAction && action != "EnumerateComputer") { targetHost.Text = host; targetShare.Text = share; }
            ShareRequest request = new ShareRequest { Action = action, RemoteHost = host, RemoteShareName = share, RemoteUserName = receiverAction ? null : user.Text.Trim(), Mode = guest.Checked ? "Guest" : "Password", AllowGuestSettings = guestConsent.Checked, AllowNameConnection = !receiverAction && action != "EnumerateComputer" && guest.Checked && nameConnection.Checked, BackupPath = backupPath, ProtectedPassword = receiverAction || guest.Checked || password.Text.Length == 0 ? String.Empty : BackendClient.ProtectPassword(password.Text) };
            DiscoveredComputer selected = SelectedComputer();
            if (selected != null && selectedAdapterId > 0 && selected.AdapterId == selectedAdapterId &&
                String.Equals(selected.Address, host, StringComparison.Ordinal) && String.Equals(selectedAdapterAddress, host, StringComparison.Ordinal)) request.AdapterId = selectedAdapterId;
            string validation = RequestRules.Validate(request);
            if (validation != null) throw new ArgumentException(I18n.T(validation));
            return request;
        }

        private async Task RepairAutomatically()
        {
            if (busy || repairSequence || discovering) return;
            if (receiverWorkflow && (String.IsNullOrWhiteSpace(targetHost.Text) || String.IsNullOrWhiteSpace(targetShare.Text) || String.IsNullOrWhiteSpace(user.Text))) { await PrepareReceiver(); return; }
            if (preview || !guest.Checked) { await Operate("RepairClient"); return; }
            repairSequence = true;
            SetBusy(false);
            try
            {
                // Explorer needs the connection in this user's Windows session.
                // Try that login before requesting any machine-wide changes.
                await OperateCore("ConnectRemote", true);
                if (lastResult == null) return;
                if (verified) { await presenter.FinishAsync(lastResult.Success); return; }
                if (!guestConsent.Checked)
                {
                    status.Text = I18n.T("Der Zugriff ist noch blockiert. Für weitere Gast-Kompatibilitätsänderungen aktiviere die entsprechende Option. Der ursprüngliche Fehler steht in den Details.");
                    return;
                }
                await OperateCore("RepairClient", true);
                if (lastResult != null && lastResult.Success) await Operate("ConnectRemote");
            }
            finally { repairSequence = false; SetBusy(false); }
        }
        private static bool IsGuestPolicyCode(string code) { return Regex.IsMatch(code ?? String.Empty, @"^(?:Win32:\s*)?(?:1272|-1067646973|-1067646972)(?:$|[;\s])", RegexOptions.CultureInvariant); }
        private async Task AcceptSuggestedRepair()
        {
            if (preview || busy || repairSequence || closingDiscovery) return;
            if (Object.Equals(suggestedRepair.Tag, "Services"))
            {
                EventHandler handler = ServiceRepairRequested; if (handler != null) handler(this, EventArgs.Empty); Close(); return;
            }
            if (Object.Equals(suggestedRepair.Tag, "Receiver")) { await PrepareReceiver(); return; }
            if (Object.Equals(suggestedRepair.Tag, "InspectReceiver")) { await InspectReceiver(); return; }
            if (Object.Equals(suggestedRepair.Tag, "Enumeration")) { lastEnumeratedComputer = null; await EnumerateSelectedComputer(); return; }
            if (Object.Equals(suggestedRepair.Tag, "EnumerationAccount")) { await RetryEnumerationWithAccount(); return; }
            if (!Object.Equals(suggestedRepair.Tag, true)) { await Operate(guest.Checked ? "ConnectRemote" : "InspectRemote"); return; }
            if (guest.Checked && !guestConsent.Checked && lastResult != null && IsGuestPolicyCode(lastResult.ErrorCode))
            {
                string explanation = guestExplanation.Text + "\r\n\r\n" + I18n.T("Diese Änderungen betreffen diesen zugreifenden PC. Möchtest du die Gast-Kompatibilität jetzt ausdrücklich erlauben?");
                if (!consentPrompt(explanation, I18n.T("Gast-Kompatibilität auf diesem PC erlauben?"))) return;
                guestConsent.Checked = true;
            }
            await RepairAutomatically();
        }
        private string SuggestedConnectionAccount()
        {
            DiscoveredComputer selected = SelectedComputer();
            if (!guest.Checked || selected == null || !selected.ConnectionUserNameVerified || String.IsNullOrWhiteSpace(selected.ConnectionUserName) ||
                !String.Equals(selected.Address, targetHost.Text.Trim(), StringComparison.OrdinalIgnoreCase)) return null;
            ShareRequest candidate = new ShareRequest { Action = "EnumerateComputer", RemoteHost = selected.Address, RemoteUserName = selected.ConnectionUserName, Mode = "Guest" };
            return RequestRules.Validate(candidate) == null ? selected.ConnectionUserName : null;
        }
        private async Task RetryEnumerationWithAccount()
        {
            if (preview || busy || repairSequence || discovering || closingDiscovery || IsDisposed) return;
            if (String.IsNullOrWhiteSpace(user.Text))
            {
                string known = SuggestedConnectionAccount();
                if (!String.IsNullOrWhiteSpace(known)) { user.Text = known; selectionHint.Text = I18n.T("Das Konto stammt aus einer bestehenden Windows-Verbindung. Der gewählte Anmeldemodus bleibt erhalten; ein Passwort wird nicht übernommen."); }
                else { status.Text = I18n.T("Trage den tatsächlichen Netzwerk-Benutzer dieses Computers ein. Danach kannst du die Freigabenliste mit diesem Konto erneut prüfen."); scroll.ScrollControlIntoView(user); user.Focus(); return; }
            }
            if (withPassword.Checked && password.Text.Length == 0)
            { status.Text = I18n.T("Gib für das gewählte Passwortkonto auch sein Netzwerk-Passwort ein."); scroll.ScrollControlIntoView(password); password.Focus(); return; }
            lastEnumeratedComputer = null; await EnumerateSelectedComputer();
        }
        private Task Operate(string action) { return OperateCore(action, false); }
        private async Task OperateCore(string action, bool deferCompletion)
        {
            if (busy || discovering) return;
            if (preview) { status.Text = I18n.T("Vorschau: Es werden keine Verbindungen oder Windows-Änderungen ausgeführt."); return; }
            automaticCheck.Stop();
            bool receiverAction = action == "InspectClient" || action == "PrepareClient";
            bool enumeration = action == "EnumerateComputer";
            if (!receiverAction && action != "RestoreClient" && (String.IsNullOrWhiteSpace(targetHost.Text) || !enumeration && (String.IsNullOrWhiteSpace(targetShare.Text) || String.IsNullOrWhiteSpace(user.Text))))
            {
                status.Text = I18n.T("Wähle oben einen Computer und eine Freigabe. Fehlt das gemeldete Konto, trage den Netzwerk-Benutzer vom Freigabe-PC ein.");
                scroll.ScrollControlIntoView(computers); return;
            }
            ShareRequest request = null;
            using (DiagnosticReports.Current.ProtectSecrets(password.Text))
            {
                try
                {
                    lastResult = null;
                    if (execute == null) throw new InvalidOperationException(I18n.T("Die Netzwerkaktion ist derzeit nicht verfügbar."));
                    request = CreateRequest(action);
                    enumerationProof = enumeration ? CaptureEnumerationProof(request) : null;
                    activeSummaryContext = CurrentConnectionContext();
                    summaryBeforeOperation = connectionSummary;
                    connectionSummary = ConnectionSummaryEvidence.Unknown(activeSummaryContext); RenderConnectionSummary();
                    SetBusy(true);
                    WorkerResult result = await execute(request, Phase, delegate(WorkProgress value) { if (!IsDisposed) presenter.Report(value); });
                    if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Prüfergebnis geliefert."));
                    if (action == "InspectClient" || action == "EnumerateComputer") await presenter.FinishInspectionAsync();
                    else await presenter.FinishAsync(result.Success && !deferCompletion);
                    if (!String.IsNullOrWhiteSpace(result.ClientBackupPath)) backupPath = result.ClientBackupPath;
                    clientRepairAvailable = result.ClientRepairAvailable;
                    if (action == "RestoreClient" && result.Success) { backupPath = null; clientRepairAvailable = false; }
                    ShowResult(result, request, action);
                }
                catch (Exception error)
                {
                    presenter.Stop(); ClearVerifiedConnection();
                    ResetConnectionSummary(); connectionSummaryGroup.Visible = true;
                    DiagnosticReports.Current.RecordException(action, error, request);
                    status.Text = I18n.Format("Nicht abgeschlossen: {0}", error.Message);
                    status.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(174, 49, 40);
                    ((AeroButton)export).Primary = true;
                    WorkerResult failed = BackendClient.Failure(error.Message, error);
                    problemHistory.Observe(failed, CurrentConnectionContext());
                    details.Text = problemHistory.AppendDetails(failed.Message + "\r\n" + I18n.T("Fehlercode") + ": " + failed.ErrorCode);
                    problemNotice.Text = problemHistory.Notice() + "\r\n" + I18n.T("Für dieses Problem ist keine sichere automatische Reparatur bestätigt. Die Details bleiben sichtbar; exportiere den Fehlerbericht für die weitere Prüfung.");
                    problemNotice.Visible = true; resultGroup.Visible = true;
                    repairSuggestion.Visible = hasRepairSuggestion = false;
                    ((AeroButton)repair).Primary = ((AeroButton)serviceRepair).Primary = false;
                    scroll.ScrollControlIntoView(problemNotice);
                }
                finally { enumerationProof = null; activeSummaryContext = null; summaryBeforeOperation = null; if (request != null) request.ProtectedPassword = null; SetBusy(false); }
            }
        }
        private void Phase(string text) { if (!IsDisposed) status.Text = I18n.TranslatePhase(text); }
        private void SetBusy(bool value)
        {
            busy = value;
            bool blocked = value || repairSequence || discovering;
            targetHost.Enabled = targetShare.Enabled = user.Enabled = guest.Enabled = withPassword.Enabled = guestConsent.Enabled = nameConnection.Enabled = !blocked;
            check.Enabled = repair.Enabled = serviceRepair.Enabled = !blocked;
            export.Enabled = close.Enabled = !value && !repairSequence;
            restore.Enabled = !blocked && (clientRepairAvailable || !String.IsNullOrWhiteSpace(backupPath));
            open.Enabled = !blocked && !preview && verified;
            openComputer.Enabled = !blocked && !preview && verified && namedVerified;
            UpdateDiscoveryControls();
            UpdateMode();
            if (value) { ClearVerifiedConnection(); status.ForeColor = AeroTheme.Ink; presenter.Begin(); }
        }
        private void ShowResult(WorkerResult result, ShareRequest request, string action)
        {
            lastResult = result;
            string problemContext = action == "InspectClient" || action == "PrepareClient" ? sourceComputer + ":client:" + request.AdapterId : CurrentConnectionContext();
            problemHistory.Observe(result, problemContext, !preview && !request.DryRun);
            bool anonymousListLimitation = IsAnonymousListLimitation(result, request, action);
            resultGroup.Text = I18n.T(anonymousListLimitation ? "Ergebnis der automatischen Freigabenliste" : "Prüfergebnis des tatsächlichen Zugriffs");
            string nativeHost, nativeShare;
            verified = action != "RestoreClient" && result.ConnectionVerified && result.NativeConnectionVerified &&
                !String.IsNullOrWhiteSpace(result.SharePath) && result.SharePath.StartsWith(@"\\", StringComparison.Ordinal) &&
                TryNormalizeTarget(result.SharePath, String.Empty, out nativeHost, out nativeShare) &&
                String.Equals(nativeShare, request.RemoteShareName, StringComparison.OrdinalIgnoreCase) &&
                (String.Equals(nativeHost, result.RemoteAddress, StringComparison.OrdinalIgnoreCase) || String.Equals(nativeHost, request.RemoteHost, StringComparison.OrdinalIgnoreCase));
            verifiedPath = verified ? result.SharePath : null;
            string namedSharePath = null;
            verifiedComputerPath = null;
            namedVerified = verified && action != "RestoreClient" && TryVerifiedNamedPaths(result, request, out verifiedComputerPath, out namedSharePath);
            if (namedVerified) verifiedPath = namedSharePath;
            verifiedContextKey = verified ? CurrentConnectionContext() : null;
            if (anonymousListLimitation && enumerationProof != null && String.Equals(enumerationProof.ContextKey, CurrentConnectionContext(), StringComparison.Ordinal))
            {
                verified = enumerationProof.Verified; namedVerified = enumerationProof.NamedVerified;
                verifiedPath = enumerationProof.SharePath; verifiedComputerPath = enumerationProof.ComputerPath; verifiedContextKey = enumerationProof.ContextKey;
            }
            if (!preview && !request.DryRun && !result.InspectionIncomplete && result.ConnectionVerified && result.NativeConnectionVerified && result.NamedConnectionVerified &&
                String.Equals(result.NamedAccessCode, "WINDOWS_NATIVE_NAME_ACCESS_VERIFIED", StringComparison.Ordinal) && namedVerified)
                problemHistory.Confirm(problemContext, delegate(CheckItem item) { return String.Equals(item.Name, "Windows-Zugriff über den Computernamen", StringComparison.Ordinal); });
            checks.BeginUpdate(); checks.Items.Clear();
            foreach (CheckItem item in result.Checks ?? new CheckItem[0])
            {
                if (item == null) continue;
                ListViewItem row = new ListViewItem(I18n.T(item.Name ?? String.Empty)) { Tag = item };
                row.SubItems.Add(StateText(item.State)); row.SubItems.Add(I18n.TranslatePhase(item.Detail ?? String.Empty));
                if (String.Equals(item.State, "error", StringComparison.OrdinalIgnoreCase)) row.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(174, 49, 40);
                checks.Items.Add(row);
            }
            checks.EndUpdate();
            details.Text = I18n.TranslatePhase(result.Message ?? String.Empty) + "\r\n" + I18n.TranslateConnection(result.ConnectionText ?? String.Empty) + (String.IsNullOrWhiteSpace(result.ErrorCode) ? String.Empty : "\r\n" + I18n.T("Fehlercode") + ": " + result.ErrorCode);
            if (!String.IsNullOrWhiteSpace(result.NamedAccessMessage)) details.AppendText("\r\n" + I18n.TranslatePhase(result.NamedAccessMessage) + (String.IsNullOrWhiteSpace(result.NamedAccessCode) ? String.Empty : "\r\n" + I18n.T("Fehlercode") + ": " + result.NamedAccessCode));
            details.Text = problemHistory.AppendDetails(details.Text);
            status.Text = I18n.TranslatePhase(result.Message ?? String.Empty);
            bool receiverAction = action == "InspectClient" || action == "PrepareClient";
            bool enumeration = action == "EnumerateComputer";
            if (enumeration && result.RemoteComputerEnumerationVerified) PopulateEnumeratedShares(result, request);
            if (receiverAction) status.Text = result.Success
                ? I18n.T("Die Einstellungen dieses Empfänger-PCs sind bereit; ein Zugriff auf einen anderen Computer ist damit noch nicht bestätigt.")
                : I18n.TranslatePhase(result.Message ?? String.Empty);
            else if (enumeration) status.Text = I18n.T(result.RemoteComputerEnumerationVerified
                ? "Freigabenliste mit Windows geprüft. Wähle eine Freigabe für den tatsächlichen Ordnerzugriff."
                : "Die Freigabenliste dieses Computers wurde nicht bestätigt. Der ursprüngliche Fehlercode steht in den Details.");
            else if (verified) status.Text = I18n.T("Windows hat den Zugriff auf diese Freigabe bestätigt. Du kannst sie jetzt öffnen.");
            if (namedVerified) status.Text = I18n.T("Freigabe und Computerübersicht sind über den Computernamen geprüft. Du kannst beide jetzt öffnen.");
            else if (verified && request.AllowNameConnection && String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase)) status.Text = I18n.T("Die Freigabe ist über die IP-Adresse erreichbar. Der Zugriff über den Computernamen ist noch nicht bestätigt; die Details zeigen die Ursache.");
            else if (!receiverAction && !enumeration && !verified && action != "RestoreClient") status.Text = I18n.T("Der Zugriff wurde noch nicht bestätigt. Beachte das Prüfergebnis oder exportiere den Fehlerbericht.");
            if (anonymousListLimitation) status.Text = I18n.T("Nur die automatische Freigabenliste ohne Konto wurde abgelehnt. Bekannte Ordner können trotzdem erreichbar sein.");
            status.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : anonymousListLimitation ? AeroTheme.Ink : verified || ((receiverAction || enumeration || action == "RestoreClient") && result.Success) ? Color.FromArgb(32, 110, 60) : Color.FromArgb(153, 89, 29);
            ((AeroButton)export).Primary = !anonymousListLimitation && !result.Success && !verified && action != "RestoreClient";
            ShowRepairSuggestion(result, request, action);
            bool localService = hasRepairSuggestion && Object.Equals(suggestedRepair.Tag, "Services");
            bool supported = hasRepairSuggestion && (localService || Object.Equals(suggestedRepair.Tag, "Receiver") || Object.Equals(suggestedRepair.Tag, true));
            ((AeroButton)serviceRepair).Primary = localService;
            ((AeroButton)repair).Primary = supported && !localService;
            if (!supported && !anonymousListLimitation && (!result.Success || ProblemHistory.HasCurrentProblem(result))) ((AeroButton)export).Primary = true;
            problemNotice.Text = problemHistory.Notice(); problemNotice.Visible = problemHistory.HasProblems;
            problemNotice.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : problemHistory.HasUnresolved ? Color.FromArgb(153, 89, 29) : AeroTheme.Ink;
            ProblemHistory.SelectFirstProblem(checks);
            ApplyConnectionSummary(result, request, action);
            resultGroup.Visible = true;
            ScrollToConnectionResult();
            // Showing a result changes the AutoSize stack and its scroll range.
            // Bring the same result into view again after that layout settles.
            string resultContext = CurrentConnectionContext();
            if (IsHandleCreated && !closingDiscovery && !Disposing && !IsDisposed)
                try { BeginInvoke((Action)delegate {
                    if (!closingDiscovery && !Disposing && !IsDisposed && Object.ReferenceEquals(lastResult, result) &&
                        String.Equals(resultContext, CurrentConnectionContext(), StringComparison.Ordinal)) ScrollToConnectionResult();
                }); }
                catch (InvalidOperationException) { if (!closingDiscovery && !Disposing && !IsDisposed) throw; }
        }
        private void ScrollToConnectionResult()
        {
            Control target = hasRepairSuggestion ? (Control)repairSuggestion : connectionSummaryGroup;
            // After completing a check, move keyboard focus to its next action.
            // Otherwise WinForms keeps scrolling back to the formerly focused
            // input whenever the result changes the AutoSize layout.
            if (!busy && ActiveControl != null && scroll.Contains(ActiveControl))
            {
                Control nextAction = hasRepairSuggestion ? (Control)suggestedRepair : verified ? (Control)open : check;
                if (nextAction.Enabled) ActiveControl = nextAction;
            }
            if (target.Parent != null) target.Parent.PerformLayout();
            scroll.PerformLayout();
            // Derive the stack position in managed coordinates. Native
            // ScrollControlIntoView can use stale descendant window positions
            // while a formerly hidden card is joining this AutoSize stack.
            int top = target.Top; Control parent = target.Parent;
            while (parent != null && parent != scroll) { top += parent.Top; parent = parent.Parent; }
            if (parent == scroll)
                scroll.AutoScrollPosition = new Point(Math.Max(0, -scroll.AutoScrollPosition.X), Math.Max(0, top - scroll.AutoScrollPosition.Y));
        }
        private void PopulateEnumeratedShares(WorkerResult result, ShareRequest request)
        {
            if (result == null || request == null || !result.RemoteComputerEnumerationVerified) return;
            DiscoveredComputer computer = SelectedComputer();
            if (computer != null && (!String.Equals(result.RemoteAddress, computer.Address, StringComparison.Ordinal) || String.IsNullOrWhiteSpace(result.RemoteAddress))) return;
            if (computer == null || !String.Equals(computer.Address, request.RemoteHost, StringComparison.OrdinalIgnoreCase))
            {
                if (String.IsNullOrWhiteSpace(result.RemoteAddress)) return;
                computer = new DiscoveredComputer { Address = result.RemoteAddress, AdapterId = request.AdapterId, Port445Open = true, Port445Checked = true };
                fillingSelection = true;
                try { computers.Items.Add(new ComputerChoice(computer)); computers.SelectedIndex = computers.Items.Count - 1; targetHost.Text = computer.Address; }
                finally { fillingSelection = false; }
            }
            List<DiscoveredShare> shares = new List<DiscoveredShare>();
            foreach (RemoteShareItem item in result.RemoteShares ?? new RemoteShareItem[0])
            {
                if (item == null || String.IsNullOrWhiteSpace(item.Name)) continue;
                shares.Add(new DiscoveredShare { Name = item.Name, Remark = item.Remark, SuggestedUserName = item.SuggestedUserName, AccessMode = item.AccessMode, MetadataVerified = item.MetadataVerified });
            }
            computer.Shares = shares; computer.SharesComplete = true; computer.ShareCode = 0;
            if (IsCanonicalComputerName(result.RemoteName) && String.Equals(result.RemoteAddress, computer.Address, StringComparison.Ordinal))
            { computer.ComputerName = result.RemoteName; computer.IdentityVerified = true; }
            RefreshSelectedShares(computer);
            selectionHint.Text = I18n.T("Die Freigabenliste ist bestätigt. Für den Ordnerzugriff wähle eine Freigabe und verwende die gemeldeten Anmeldedaten.");
        }
        private static bool IsCanonicalComputerName(string name)
        {
            return !String.IsNullOrWhiteSpace(name) && name.Length <= 15 &&
                Regex.IsMatch(name, @"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", RegexOptions.CultureInvariant) &&
                !Regex.IsMatch(name, @"^[0-9]+$", RegexOptions.CultureInvariant);
        }
        private void ShowRepairSuggestion(WorkerResult result, ShareRequest request, string action)
        {
            hasRepairSuggestion = false; repairSuggestion.Visible = false;
            if (IsAnonymousListLimitation(result, request, action) && !preview)
            {
                repairSuggestion.Height = 204;
                suggestedRepair.Tag = "EnumerationAccount"; suggestedRepair.Text = I18n.T("Mit Netzwerk-Konto erneut prüfen");
                repairQuestion.Text = I18n.T("Windows erlaubt die automatische anonyme Freigabenliste dieses Computers nicht. Das ist kein Nachweis, dass freigegebene Ordner gesperrt sind. Verwende für die Liste den tatsächlichen Netzwerk-Benutzer des Computers.");
                string known = SuggestedConnectionAccount(); if (!String.IsNullOrWhiteSpace(known)) repairQuestion.Text += "\r\n" + I18n.Format("Windows meldet für die bereits bestehende Verbindung das Konto {0}. Übernehmen und erneut prüfen.", known);
                repairQuestion.AccessibleDescription = repairQuestion.Text;
                hasRepairSuggestion = true; repairSuggestion.Text = I18n.T("Freigabenliste: Anmeldung erforderlich"); repairSuggestion.Visible = true; FitAnonymousListSuggestion(); return;
            }
            repairSuggestion.Height = 122; repairSuggestion.Text = I18n.T("Zugriffsproblem erkannt");
            if (action == "RestoreClient" || preview || request == null || result == null || (verified && (!request.AllowNameConnection || namedVerified || !guest.Checked))) return;
            if ((action == "InspectClient" || action == "PrepareClient" || action == "EnumerateComputer") && result.Success) return;
            string code = verified ? result.NamedAccessCode : result.ErrorCode;
            foreach (CheckItem item in result.Checks ?? new CheckItem[0]) if (item != null && (item.State == "error" || item.State == "warning") && String.IsNullOrWhiteSpace(code)) code = item.Code;
            bool localService = String.Equals(code, "SERVICE_WORKSTATION_NOT_RUNNING", StringComparison.Ordinal);
            bool receiverFix = receiverWorkflow && guest.Checked && (String.Equals(code, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", StringComparison.Ordinal) && CanPrepareDirectly(result) ||
                action == "EnumerateComputer" && IsGuestPolicyCode(code));
            bool fixable = localService || guest.Checked && (IsGuestPolicyCode(code) ||
                (verified && request.AllowNameConnection && Regex.IsMatch(code ?? String.Empty, @"^(?:Win32:\s*)?53$", RegexOptions.CultureInvariant)));
            suggestedRepair.Tag = localService ? (object)"Services" : receiverFix ? (object)"Receiver"
                : action == "InspectClient" || action == "PrepareClient" ? (object)"InspectReceiver"
                : action == "EnumerateComputer" ? (object)"Enumeration" : fixable;
            suggestedRepair.Text = I18n.T(fixable || receiverFix ? "Ja, jetzt beheben" : "Erneut prüfen");
            repairQuestion.Text = receiverFix ? I18n.T("Windows-Einstellungen dieses Empfänger-PCs können Gastanmeldungen blockieren. Möchtest du die Gast-Kompatibilität einrichten?")
                : localService ? I18n.Format("Der Windows-Dienst zum Öffnen von Freigaben läuft auf diesem Empfänger-PC ({0}) nicht. Möchtest du ihn mit der lokalen Dienstreparatur beheben?", sourceComputer)
                : I18n.Format(fixable ? "Windows konnte den Zugriff auf {0} noch nicht vollständig bestätigen. Fehlercode: {1}. Möchtest du das beheben?"
                : "Der Zugriff auf {0} ist noch nicht bestätigt. Fehlercode: {1}. Die Details zeigen, welcher Computer oder welche Eingabe geprüft werden muss. Du kannst den Zugriff erneut prüfen.",
                request.RemoteHost, String.IsNullOrWhiteSpace(code) ? I18n.T("Details im Prüfergebnis") : code);
            if (localService) repairQuestion.Text += "\r\n" + I18n.T("Fehlercode") + ": " + code;
            repairQuestion.AccessibleDescription = repairQuestion.Text;
            hasRepairSuggestion = true; repairSuggestion.Visible = true;
        }
        private void FitAnonymousListSuggestion()
        {
            if (suggestedRepair == null || repairSuggestion == null || repairQuestion == null || !Object.Equals(suggestedRepair.Tag, "EnumerationAccount")) return;
            int width = Math.Max(250, repairQuestion.ClientSize.Width);
            Size needed = TextRenderer.MeasureText(repairQuestion.Text, repairQuestion.Font, new Size(width, 10000), TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix);
            int height = Math.Max(168, needed.Height + repairSuggestion.Padding.Vertical + 18);
            if (repairSuggestion.Height != height) repairSuggestion.Height = height;
        }
        private void ShowSelectedCheck()
        {
            if (checks.SelectedItems.Count == 0) return;
            CheckItem item = checks.SelectedItems[0].Tag as CheckItem;
            if (item == null) return;
            StringBuilder value = new StringBuilder(I18n.TranslatePhase(item.Detail ?? String.Empty));
            if (!String.IsNullOrWhiteSpace(item.Code)) value.AppendLine().Append(I18n.T("Fehlercode")).Append(": ").Append(item.Code);
            if (!String.IsNullOrWhiteSpace(item.NextStep)) value.AppendLine().Append(I18n.T("Nächster Schritt")).Append(": ").Append(I18n.TranslatePhase(item.NextStep));
            details.Text = problemHistory.AppendDetails(value.ToString());
        }
        private void OpenVerifiedShare()
        {
            if (preview || busy || !verified || String.IsNullOrWhiteSpace(verifiedPath)) return;
            try { Process.Start(new ProcessStartInfo(verifiedPath) { UseShellExecute = true }); }
            catch (Exception error) { ShowOpenError("OpenRemoteShare", error); }
        }
        internal static bool TryVerifiedNamedPaths(WorkerResult result, ShareRequest request, out string computerPath, out string sharePath)
        {
            computerPath = sharePath = null;
            if (result == null || request == null || !request.AllowNameConnection || !String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) ||
                !result.ConnectionVerified || !result.NativeConnectionVerified || !result.NamedConnectionVerified ||
                String.IsNullOrWhiteSpace(result.RemoteName) || result.RemoteName.Length > 15 ||
                !Regex.IsMatch(result.RemoteName, @"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", RegexOptions.CultureInvariant) ||
                Regex.IsMatch(result.RemoteName, @"^[0-9]+$", RegexOptions.CultureInvariant) ||
                !String.Equals(result.RemoteShareName, request.RemoteShareName, StringComparison.OrdinalIgnoreCase)) return false;
            string login = request.RemoteUserName ?? String.Empty;
            int separator = login.IndexOf('\\');
            string domain = separator > 0 ? login.Substring(0, separator) : null;
            if (!String.IsNullOrWhiteSpace(domain) && !String.Equals(domain, result.RemoteName, StringComparison.OrdinalIgnoreCase)) return false;
            if (!String.Equals(request.RemoteHost, result.RemoteName, StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(domain, result.RemoteName, StringComparison.OrdinalIgnoreCase)) return false;
            string expected = @"\\" + result.RemoteName + @"\" + request.RemoteShareName;
            if (!String.Equals(result.NamedSharePath, expected, StringComparison.OrdinalIgnoreCase)) return false;
            computerPath = @"\\" + result.RemoteName;
            sharePath = expected;
            return true;
        }
        private void OpenVerifiedComputer()
        {
            if (preview || busy || !verified || !namedVerified || String.IsNullOrWhiteSpace(verifiedComputerPath)) return;
            try { Process.Start(new ProcessStartInfo(verifiedComputerPath) { UseShellExecute = true }); }
            catch (Exception error) { ShowOpenError("OpenRemoteComputer", error); }
        }
        private void ShowOpenError(string action, Exception error)
        {
            DiagnosticReports.Current.RecordException(action, error);
            WorkerResult failed = BackendClient.Failure(error.Message, error);
            problemHistory.Observe(failed, CurrentConnectionContext());
            problemNotice.Text = problemHistory.Notice(); problemNotice.Visible = true;
            status.Text = error.Message; details.Text = problemHistory.AppendDetails(error.Message);
            ((AeroButton)export).Primary = true; resultGroup.Visible = true;
            scroll.ScrollControlIntoView(problemNotice);
        }
        private void LanguageChanged(object sender, EventArgs args)
        {
            I18n.Apply(this); UpdateSource(); UpdateMode(); RenderConnectionSummary();
            fillingSelection = true;
            try
            {
                int computerIndex = computers.SelectedIndex, shareIndex = discoveredShares.SelectedIndex;
                for (int i = 0; i < computers.Items.Count; i++) computers.Items[i] = computers.Items[i];
                for (int i = 0; i < discoveredShares.Items.Count; i++) discoveredShares.Items[i] = discoveredShares.Items[i];
                computers.SelectedIndex = computerIndex; discoveredShares.SelectedIndex = shareIndex;
            }
            finally { fillingSelection = false; }
            checks.Columns[0].Text = I18n.T("Prüfung"); checks.Columns[1].Text = I18n.T("Status"); checks.Columns[2].Text = I18n.T("Ursache / Details");
            if (lastResult != null)
                foreach (ListViewItem row in checks.Items) { CheckItem item = row.Tag as CheckItem; if (item != null) { row.Text = I18n.T(item.Name ?? String.Empty); row.SubItems[1].Text = StateText(item.State); row.SubItems[2].Text = I18n.TranslatePhase(item.Detail ?? String.Empty); } }
            problemNotice.Text = problemHistory.Notice();
            if (checks.SelectedItems.Count != 0) ShowSelectedCheck();
        }
        internal void SetTarget(string host, string share, string userName) { if (busy || repairSequence) return; targetHost.Text = host ?? String.Empty; targetShare.Text = share ?? String.Empty; user.Text = userName ?? String.Empty; }
        private static string StateText(string value) { return I18n.T(value == "ok" ? "OK" : value == "error" ? "Fehlt / Fehler" : value == "warning" ? "Hinweis" : "Info"); }
        private sealed class RemoteChecks : ListView { internal RemoteChecks() { DoubleBuffered = true; } }
        protected override void Dispose(bool disposing) { if (disposing) { closingDiscovery = true; discoveryGeneration++; if (discoveryCancellation != null) discoveryCancellation.Cancel(); if (automaticCheck != null) automaticCheck.Dispose(); I18n.Changed -= LanguageChanged; if (presenter != null) presenter.Dispose(); if (password != null) password.Clear(); } base.Dispose(disposing); }
    }
}
