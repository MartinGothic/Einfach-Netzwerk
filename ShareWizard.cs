using System;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal sealed class WizardSelection
    {
        internal string FolderPath, ShareName, UserName, Password;
        internal bool Guest = true, AllowWrite = true, AllowDrive, AllowGuest, AdvancedRepair = true, PrepareReceiver = true;
        internal NetworkItem Network;
    }

    internal sealed class ShareWizard : AeroGlassForm
    {
        private readonly bool preview;
        private readonly Func<WizardSelection, Action<string>, Task<WorkerResult>> apply;
        private readonly Func<WizardSelection, Action<string>, Action<WorkProgress>, Task<WorkerResult>> applyCounted;
        private readonly Func<Task<NetworkItem[]>> refresh;
        private readonly WizardSelection selected = new WizardSelection();
        private readonly ProblemHistory problemHistory = new ProblemHistory();
        internal CheckItem RequestedProblem { get; private set; }
        private Button problemHelp;
        private readonly Panel page = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(24, 13, 24, 12) };
        private readonly Label steps = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, ForeColor = AeroTheme.Ink, Font = new Font("Segoe UI", 10, FontStyle.Bold) };
        private readonly Button back, next, close, export;
        private readonly AeroHeader header;
        private TextBox path, name, user, secret;
        private ComboBox disks, network;
        private RadioButton chooseFolder, chooseDisk, guest, withPassword;
        private CheckBox driveConsent, guestConsent, writable, autoRepair, prepareReceiver;
        private bool receiverPreference = true;
        private Label operationPhase;
        private Label operationPercentage;
        private ProgressBar operationProgress;
        private CountedProgressPresenter operationPresenter;
        private NetworkItem[] available;
        private int step;
        private bool working;
        private WorkerResult result;

        internal ShareWizard(NetworkItem[] networks, bool preview, Func<WizardSelection, Action<string>, Task<WorkerResult>> apply, Func<Task<NetworkItem[]>> refresh)
            : this(networks, preview, apply, refresh, null) { }

        internal ShareWizard(NetworkItem[] networks, bool preview, Func<WizardSelection, Action<string>, Task<WorkerResult>> apply,
            Func<Task<NetworkItem[]>> refresh, Func<WizardSelection, Action<string>, Action<WorkProgress>, Task<WorkerResult>> applyCounted)
        {
            this.preview = preview;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
            this.apply = apply;
            this.applyCounted = applyCounted;
            this.refresh = refresh;
            available = networks ?? new NetworkItem[0];
            Text = I18n.T("Freigabe-Assistent");
            AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 10);
            ForeColor = AeroTheme.Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(222, 240, 251);
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96, 96);
            MinimumSize = new Size(750, 705);
            ClientSize = new Size(800, 730);
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            TableLayoutPanel shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Margin = Padding.Empty };
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 116));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 47));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 112));
            Controls.Add(shell);
            header = new AeroHeader { Dock = DockStyle.Fill, Margin = Padding.Empty, Heading = "Freigabe-Assistent", Subtitle = "Ein Schritt nach dem anderen. Du entscheidest, was geteilt wird." };
            shell.Controls.Add(header, 0, 0);
            steps.Padding = new Padding(24, 0, 24, 0);
            shell.Controls.Add(steps, 0, 1);
            page.BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(247, 252, 255);
            shell.Controls.Add(page, 0, 2);
            TableLayoutPanel footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = Padding.Empty, Padding = new Padding(18, 5, 18, 7) };
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 49));
            footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new Padding(0, 4, 0, 0), Margin = Padding.Empty };
            next = Button("Weiter", 205, true);
            back = Button("Zurück", 155, false);
            close = Button("Abbrechen", 155, false);
            buttons.Controls.AddRange(new Control[] { next, back, close });
            footer.Controls.Add(buttons, 0, 0);
            export = Button("Fehlerbericht exportieren", 345, false);
            export.Anchor = AnchorStyles.Left | AnchorStyles.Top;
            export.Margin = new Padding(0, 4, 0, 0);
            export.Click += delegate { DiagnosticReports.Current.SaveReport(this); };
            footer.Controls.Add(export, 0, 1);
            shell.Controls.Add(footer, 0, 3);
            next.Click += async delegate { await Next(); };
            back.Click += delegate { if (!working && step > 0 && step < 4) { ReadPage(); step--; BuildPage(); } };
            close.Click += delegate { if (!working) Close(); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (working) e.Cancel = true; };
            Shown += delegate { AeroTheme.GlassFrame(this); };
            I18n.Changed += LanguageChanged;
            BuildPage();
        }
        private void LanguageChanged(object sender, EventArgs e) { if (!working) { ReadPage(); BuildPage(); } header.Invalidate(); Text = I18n.T("Freigabe-Assistent"); }
        private static Button Button(string text, int width, bool primary)
        {
            return new AeroButton { Text = I18n.T(text), Width = width, Height = 40, Primary = primary, Margin = new Padding(7, 0, 0, 0) };
        }
        private TableLayoutPanel Stack()
        {
            TableLayoutPanel stack = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 1, Margin = Padding.Empty, Padding = Padding.Empty };
            stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            page.Controls.Add(stack);
            return stack;
        }
        private static Label TextLine(string text, Control parent, bool title)
        {
            Label label = new Label { Text = I18n.T(text), AutoSize = true, Dock = DockStyle.Top, Font = new Font("Segoe UI", title ? 17 : 10, title ? FontStyle.Regular : FontStyle.Regular), ForeColor = AeroTheme.Ink, Margin = new Padding(0, title ? 0 : 7, 0, title ? 7 : 6), MaximumSize = new Size(690, 0) };
            parent.SizeChanged += delegate { label.MaximumSize = new Size(Math.Max(100, parent.ClientSize.Width - parent.Padding.Horizontal), 0); };
            parent.Controls.Add(label);
            return label;
        }
        private static TextBox Input(string value)
        {
            return new TextBox { Text = value ?? String.Empty, Dock = DockStyle.Top, Font = new Font("Segoe UI", 11), Margin = new Padding(0, 4, 0, 9) };
        }
        private static ComboBox Choice()
        {
            return new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Top, Font = new Font("Segoe UI", 11), DropDownHeight = 220, IntegralHeight = false, Margin = new Padding(0, 5, 0, 10) };
        }
        private static CheckBox RepairOption(string text, TableLayoutPanel parent, bool isChecked, bool required)
        {
            CheckBox check = new CheckBox { Text = I18n.T(text), Checked = isChecked, AutoCheck = !required, AutoSize = true, Dock = DockStyle.Top, Margin = new Padding(0, 3, 0, 3), MaximumSize = new Size(645, 0) };
            parent.SizeChanged += delegate { check.MaximumSize = new Size(Math.Max(100, parent.ClientSize.Width - parent.Padding.Horizontal), 0); };
            parent.Controls.Add(check);
            return check;
        }
        private void BuildPage()
        {
            if (operationPresenter != null) { operationPresenter.Dispose(); operationPresenter = null; }
            operationPhase = operationPercentage = null;
            operationProgress = null;
            problemHelp = null;
            page.SuspendLayout();
            foreach (Control child in page.Controls.Cast<Control>().ToArray()) child.Dispose();
            page.Controls.Clear();
            path = name = user = secret = null;
            disks = network = null;
            guest = withPassword = chooseFolder = chooseDisk = null;
            driveConsent = guestConsent = writable = autoRepair = prepareReceiver = null;
            steps.Text = String.Format(I18n.T("Schritt {0} von 5  ·  {1}"), Math.Min(5, step + 1), I18n.T(new[] { "Auswahl", "Zugriff", "Heimnetz", "Überblick", "Verbinden" }[step]));
            back.Enabled = !working && step > 0 && step < 4;
            back.Visible = step < 4;
            next.Visible = step < 4;
            next.Text = I18n.T(step == 3 ? "Freigabe einrichten" : "Weiter");
            close.Text = I18n.T(step == 4 ? "Fertig" : "Abbrechen");
            export.Enabled = !working;
            ((AeroButton)export).Primary = result != null && (!result.Success || ProblemHistory.HasCurrentProblem(result) || problemHistory.HasUnresolved);
            TableLayoutPanel stack = Stack();
            if (step == 0) BuildSelection(stack);
            else if (step == 1) BuildAccess(stack);
            else if (step == 2) BuildNetwork(stack);
            else if (step == 3) BuildSummary(stack);
            else BuildResult(stack);
            I18n.Apply(this);
            AeroTheme.StyleGlassChildren(this);
            page.ResumeLayout(true);
        }
        private void BuildSelection(TableLayoutPanel stack)
        {
            TextLine("Was möchtest du teilen?", stack, true);
            TextLine("Wähle einen einzelnen Ordner oder eine ganze Datenfestplatte. Deine Dateien bleiben auf diesem PC.", stack, false);
            FlowLayoutPanel kind = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = false, Margin = new Padding(0, 7, 0, 7) };
            chooseFolder = new RadioButton { Text = I18n.T("Ordner"), AutoSize = true, Checked = !selected.AllowDrive, Margin = new Padding(0, 0, 35, 0) };
            chooseDisk = new RadioButton { Text = I18n.T("Ganze Festplatte / USB-Laufwerk"), AutoSize = true, Checked = selected.AllowDrive };
            kind.Controls.AddRange(new Control[] { chooseFolder, chooseDisk });
            stack.Controls.Add(kind);
            TableLayoutPanel pick = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, Margin = Padding.Empty };
            pick.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            pick.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 155));
            path = Input(selected.FolderPath);
            Button browse = Button("Ordner wählen …", 150, false);
            browse.Height = 32;
            pick.Controls.Add(path, 0, 0);
            pick.Controls.Add(browse, 1, 0);
            stack.Controls.Add(pick);
            disks = Choice();
            disks.Items.Add(I18n.T("Datenlaufwerk auswählen …"));
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                try
                {
                    if (drive.IsReady && (drive.DriveType == DriveType.Fixed || drive.DriveType == DriveType.Removable) && !SystemRoot(drive.Name))
                        disks.Items.Add(new DiskChoice(drive.Name, drive.Name + "  " + (String.IsNullOrEmpty(drive.VolumeLabel) ? I18n.T("Datenlaufwerk") : drive.VolumeLabel)));
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            disks.SelectedIndex = 0;
            for (int i = 1; i < disks.Items.Count; i++) { DiskChoice disk = disks.Items[i] as DiskChoice; if (disk != null && String.Equals(disk.Path, selected.FolderPath, StringComparison.OrdinalIgnoreCase)) disks.SelectedIndex = i; }
            stack.Controls.Add(disks);
            driveConsent = new CheckBox { Text = I18n.T("Alle Dateien auf diesem Datenlaufwerk freigeben"), AutoSize = true, Dock = DockStyle.Top, Checked = selected.AllowDrive, Margin = new Padding(0, 5, 0, 8) };
            stack.Controls.Add(driveConsent);
            TextLine("Name, den deine Geräte sehen", stack, false);
            name = Input(selected.ShareName);
            stack.Controls.Add(name);
            TextLine("Tipp: Zum Beispiel „Familienbilder“ oder „Meine Daten“. Das Windows-Systemlaufwerk wird nicht als Ganzes geteilt.", stack, false);
            Action updateKind = delegate { bool whole = chooseDisk.Checked; pick.Enabled = !whole; disks.Visible = whole; driveConsent.Visible = whole || RootPath(path.Text); };
            chooseDisk.CheckedChanged += delegate { updateKind(); };
            chooseFolder.CheckedChanged += delegate { updateKind(); };
            path.TextChanged += delegate { if (String.IsNullOrWhiteSpace(name.Text)) name.Text = NameFor(path.Text); updateKind(); };
            browse.Click += delegate
            {
                using (FolderBrowserDialog dialog = new FolderBrowserDialog { Description = I18n.T("Welchen Ordner möchtest du teilen?"), ShowNewFolderButton = true })
                {
                    if (Directory.Exists(path.Text)) dialog.SelectedPath = path.Text;
                    if (dialog.ShowDialog(this) == DialogResult.OK) { path.Text = dialog.SelectedPath; name.Text = NameFor(dialog.SelectedPath); }
                }
            };
            disks.SelectedIndexChanged += delegate { DiskChoice disk = disks.SelectedItem as DiskChoice; if (disk != null) { path.Text = disk.Path; name.Text = NameFor(disk.Path); } };
            updateKind();
        }
        private void BuildAccess(TableLayoutPanel stack)
        {
            TextLine("Wie sollen deine Geräte zugreifen?", stack, true);
            guest = new RadioButton { Text = I18n.T("Ohne Passwort"), AutoSize = true, Dock = DockStyle.Top, Checked = selected.Guest, Margin = new Padding(0, 8, 0, 8), Font = new Font("Segoe UI", 11, FontStyle.Bold) };
            withPassword = new RadioButton { Text = I18n.T("Mit Benutzername und Passwort"), AutoSize = true, Dock = DockStyle.Top, Checked = !selected.Guest, Margin = new Padding(0, 1, 0, 8), Font = new Font("Segoe UI", 11, FontStyle.Bold) };
            stack.Controls.Add(guest);
            stack.Controls.Add(withPassword);
            TableLayoutPanel account = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, Margin = Padding.Empty };
            account.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            account.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            account.Controls.Add(new Label { Text = I18n.T("Netzwerk-Benutzer"), AutoSize = true }, 0, 0);
            account.Controls.Add(new Label { Text = I18n.T("Passwort (mindestens 8 Zeichen)"), AutoSize = true }, 1, 0);
            user = Input(String.IsNullOrEmpty(selected.UserName) ? "NetzwerkUser" : selected.UserName);
            secret = Input(selected.Password);
            secret.UseSystemPasswordChar = true;
            user.Margin = new Padding(0, 4, 10, 7);
            account.Controls.Add(user, 0, 1);
            account.Controls.Add(secret, 1, 1);
            stack.Controls.Add(account);
            guestConsent = new CheckBox { Text = I18n.T("Gastmodus auf diesem PC aktivieren"), AutoSize = true, Dock = DockStyle.Top, Checked = selected.AllowGuest, Margin = new Padding(0, 7, 0, 6) };
            stack.Controls.Add(guestConsent);
            Label explanation = TextLine(String.Empty, stack, false);
            writable = new CheckBox { Text = I18n.T("Dateien auch bearbeiten und löschen erlauben"), AutoSize = true, Dock = DockStyle.Top, Checked = selected.AllowWrite, Margin = new Padding(0, 9, 0, 7) };
            stack.Controls.Add(writable);
            TextLine("Im nächsten Schritt wählst du die vorbeugende Reparatur für diesen PC.", stack, false);
            Action update = delegate
            {
                account.Visible = withPassword.Checked;
                guestConsent.Visible = guest.Checked;
                explanation.Text = I18n.T(guest.Checked
                    ? "Ohne Passwort können Geräte im gewählten Heimnetz zugreifen. Dafür werden das Windows-Gastkonto und die eingehende SMB-Signaturpflicht dieses PCs angepasst. Manche Geräte verlangen trotzdem ein Passwort."
                    : "Das Programm richtet ein eigenes Netzwerk-Konto ein. Auf dem anderen Gerät verwendest du diesen Benutzer und dieses Passwort. Deine Windows-PIN wird nicht benötigt.");
            };
            guest.CheckedChanged += delegate { update(); };
            withPassword.CheckedChanged += delegate { update(); };
            update();
        }
        private void BuildNetwork(TableLayoutPanel stack)
        {
            TextLine("Welches Heimnetz möchtest du nutzen?", stack, true);
            TextLine("Wähle deine LAN- oder WLAN-Verbindung. Alle Geräte müssen am selben Router sein.", stack, false);
            network = Choice();
            foreach (NetworkItem item in available) network.Items.Add(new NetworkChoice(item));
            if (network.Items.Count == 0) network.Items.Add(I18n.T("Keine verbundene Heimnetz-Verbindung gefunden"));
            network.SelectedIndex = 0;
            for (int i = 0; i < network.Items.Count; i++) { NetworkChoice item = network.Items[i] as NetworkChoice; if (item != null && selected.Network != null && item.Item.Id == selected.Network.Id) network.SelectedIndex = i; }
            TableLayoutPanel networkSelection = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 2, Margin = Padding.Empty };
            networkSelection.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            networkSelection.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 255));
            networkSelection.Controls.Add(network, 0, 0);
            Button reload = Button("Verbindungen neu prüfen", 247, false);
            reload.Height = 32;
            reload.Margin = new Padding(8, 4, 0, 7);
            networkSelection.Controls.Add(reload, 1, 0);
            stack.Controls.Add(networkSelection);
            reload.Click += async delegate
            {
                if (refresh == null || preview) return;
                working = true;
                reload.Enabled = false;
                next.Enabled = false;
                export.Enabled = false;
                try { available = await refresh() ?? new NetworkItem[0]; ReadPage(); BuildPage(); }
                catch (Exception ex) { DiagnosticReports.Current.RecordException("Freigabe-Assistent: Netzwerkliste laden", ex); MessageBox.Show(this, I18n.T("Die Netzwerkliste konnte nicht geladen werden.") + "\n\n" + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Information); }
                finally { working = false; if (!IsDisposed) { next.Enabled = true; back.Enabled = true; export.Enabled = true; if (!reload.IsDisposed) reload.Enabled = true; } }
            };
            GlassCard repairs = new GlassCard { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 1, Padding = new Padding(12, 7, 12, 9), Margin = new Padding(0, 6, 0, 7) };
            repairs.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            stack.Controls.Add(repairs);
            TextLine("Bekannten Blockaden vorbeugen", repairs, false).Font = new Font("Segoe UI", 11, FontStyle.Bold);
            TextLine("Die ersten drei Punkte gehören zu jeder Freigabe. Windows wird erst beim Einrichten geändert.", repairs, false);
            RepairOption("Windows-Dienste für Freigaben starten", repairs, true, true);
            RepairOption("Diesen PC im Heimnetz sichtbar machen", repairs, true, true);
            RepairOption("Port 445, Freigabe und Dateirechte einrichten", repairs, true, true);
            autoRepair = RepairOption("Zugriffsblockaden automatisch beheben", repairs, selected.AdvancedRepair, false);
            prepareReceiver = RepairOption("Auf diesem PC auch andere Gastfreigaben öffnen", repairs, selected.Guest && receiverPreference, false);
            prepareReceiver.Enabled = selected.Guest;
            TextLine("Prüft die Netzwerkbindung und die Rechte des gewählten Ordners. Änderungen werden gesichert und danach erneut geprüft.", repairs, false);
            TextLine(selected.Guest
                ? "Falls nötig: Gastanmeldung zulassen und die SMB-Signatur- und Verschlüsselungspflicht für ausgehende Verbindungen dieses PCs anpassen. Die ursprünglichen Werte werden gesichert."
                : "Diese Zusatzoption gehört zum Zugriff ohne Passwort. Im Passwortmodus bleiben die Gast- und SMB-Sicherheitsregeln dieses Empfängers erhalten.", repairs, false);
            TextLine("Vermeide ein WLAN-Gastnetz: Dort trennt der Router Geräte häufig voneinander. Eine Freigabe kann diese Router-Einstellung nicht ändern.", stack, false);
        }
        private void BuildSummary(TableLayoutPanel stack)
        {
            TextLine("Alles bereit zum Einrichten", stack, true);
            TextLine("Bitte prüfe deine Auswahl. Erst der nächste Klick richtet Windows ein.", stack, false);
            GlassCard card = new GlassCard { AutoSize = true, Dock = DockStyle.Top, ColumnCount = 1, Padding = new Padding(17), Margin = new Padding(0, 13, 0, 10) };
            card.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            stack.Controls.Add(card);
            TextLine((RootPath(selected.FolderPath) ? I18n.T("Gesamtes Datenlaufwerk") : I18n.T("Ordner")) + ": " + selected.FolderPath, card, false);
            TextLine(I18n.T("Freigabename") + ": " + selected.ShareName, card, false);
            TextLine(I18n.T("Heimnetz") + ": " + (selected.Network == null ? "—" : selected.Network.Name + " · " + selected.Network.Address), card, false);
            TextLine(I18n.T("Zugriff") + ": " + I18n.T(selected.Guest ? "Ohne Passwort (Gast)" : "Mit Passwort") + (selected.Guest ? "" : " · " + selected.UserName), card, false);
            TextLine(I18n.T("Rechte") + ": " + I18n.T(selected.AllowWrite ? "Lesen, bearbeiten und löschen" : "Nur lesen"), card, false);
            TextLine(I18n.T("Automatische Reparatur") + ": " + I18n.T(selected.AdvancedRepair ? "Aktiv" : "Aus"), card, false);
            TextLine(I18n.T("Andere Gastfreigaben auf diesem PC") + ": " + I18n.T(selected.Guest && selected.PrepareReceiver ? "Aktiv" : "Aus"), card, false);
            TextLine("Dienste, Erkennung, Port 445 und Dateirechte werden für diese Freigabe eingerichtet.", stack, false);
            if (selected.Guest && selected.PrepareReceiver) TextLine("Zusätzlich wird dieser Windows-PC für den Zugriff auf andere Gastfreigaben vorbereitet. Der andere Computer wird dadurch nicht verändert oder als erreichbar bestätigt.", stack, false);
            TextLine("Windows fragt nach Administratorrechten. Bestätige diese Abfrage, damit Freigabe, Dienste und Firewall eingerichtet werden können.", stack, false);
            TextLine("Das Programm meldet Computernamen, Freigaben und Netzwerk-Benutzer im privaten Heimnetz. Passwörter werden dabei nicht veröffentlicht.", stack, false);
            TextLine("Deine Dateien werden nicht verschoben. Das Programm sichert seine Einstellungen, damit du die Einrichtung später zurücknehmen kannst.", stack, false);
        }
        private void BuildResult(TableLayoutPanel stack)
        {
            if (result == null)
            {
                TextLine("Windows wird eingerichtet", stack, true);
                TextLine("Bitte warte. Hier siehst du den aktuellen Arbeitsschritt.", stack, false);
                operationPhase = TextLine("Windows wird vorbereitet …", stack, false);
                bool counted = !preview && applyCounted != null;
                if (counted) operationPercentage = TextLine("0 %", stack, false);
                operationProgress = counted ? (ProgressBar)new AeroProgressBar() : new ProgressBar();
                operationProgress.Style = counted ? ProgressBarStyle.Continuous : ProgressBarStyle.Marquee;
                operationProgress.MarqueeAnimationSpeed = AeroTheme.Animations ? 25 : 0;
                operationProgress.Height = 18;
                operationProgress.Dock = DockStyle.Top;
                operationProgress.Margin = new Padding(0, 12, 0, 20);
                stack.Controls.Add(operationProgress);
                if (counted) { operationPresenter = new CountedProgressPresenter(operationProgress, operationPercentage); operationPresenter.Begin(); }
                return;
            }
            bool receiverIncomplete = result.WizardReceiverRequested && !result.WizardReceiverReady;
            problemHistory.Observe(result, selected.FolderPath + "|" + selected.ShareName);
            TextLine(receiverIncomplete ? "Freigabe eingerichtet, ein Schritt fehlt" : result.Success ? (result.ConnectionVerified ? "SMB-Zugriff lokal geprüft" : "Windows-Einstellungen geprüft") : "Hier ist noch ein Schritt nötig", stack, true);
            if (problemHistory.HasProblems)
            {
                TextLine(problemHistory.Notice(), stack, false);
                CheckItem offered = null;
                foreach (string state in new[] { "error", "warning" })
                {
                    foreach (CheckItem item in result.Checks ?? new CheckItem[0])
                        if (item != null && String.Equals(item.State, state, StringComparison.OrdinalIgnoreCase) && ErrorFixDialog.ActionFor(item) != ErrorFixAction.None) { offered = item; break; }
                    if (offered != null) break;
                }
                if (offered != null)
                {
                    CheckItem selectedProblem = offered;
                    problemHelp = Button(offered.Fixable ? "Dieses Problem beheben" : "Passende Hilfe öffnen", 345, true);
                    problemHelp.Enabled = !preview && !working;
                    problemHelp.Click += delegate { RequestProblemHelp(selectedProblem); };
                    stack.Controls.Add(problemHelp);
                }
                TextBox problemDetails = new TextBox { Multiline = true, ReadOnly = true, Dock = DockStyle.Top, Height = 125, ScrollBars = ScrollBars.Both, WordWrap = false, BackColor = Color.White, Margin = new Padding(0, 4, 0, 10), AccessibleName = I18n.T("Ursache / Details"), Text = problemHistory.AppendDetails(String.Empty) };
                stack.Controls.Add(problemDetails);
            }
            TextLine("Diese Freigabe wurde auf dem freigebenden PC geprüft. Öffne „Anderen Computer verbinden“ auf dem zugreifenden Windows-PC, um den tatsächlichen Zugriff zu prüfen.", stack, false);
            TextLine("Öffne das Programm auch auf dem anderen Windows-PC. Die Heimnetzsuche übernimmt gemeldete Freigaben und prüft den Zugriff nach deiner Auswahl automatisch.", stack, false);
            if (result.WizardReceiverRequested) TextLine(result.WizardReceiverReady
                ? "Dieser PC ist auch für andere Gastfreigaben vorbereitet. Der tatsächliche Zugriff wird nach der Auswahl des anderen Computers geprüft."
                : "Die lokale Freigabe ist eingerichtet. Die Vorbereitung für andere Gastfreigaben braucht noch einen Schritt. Das Prüfergebnis zeigt die Ursache und die passende Reparatur.", stack, false);
            TextLine(I18n.TranslatePhase(result.Message ?? String.Empty), stack, false);
            TextBox details = new TextBox { Multiline = true, ReadOnly = true, Dock = DockStyle.Top, Height = 145, Font = new Font("Consolas", 10), ScrollBars = ScrollBars.Both, WordWrap = false, Text = result.ConnectionText ?? String.Empty, BackColor = Color.White, Margin = new Padding(0, 12, 0, 10), Visible = false };
            stack.Controls.Add(details);
            TextLine(I18n.T("Host / Server") + ": " + (String.IsNullOrWhiteSpace(result.Address) ? "—" : result.Address), stack, false);
            TextLine("Port: 445 · separat eintragen, nicht an die IP anhängen.", stack, false);
            TextLine(I18n.T("Benutzername") + ": " + (String.IsNullOrWhiteSpace(result.LoginUserName) ? "—" : result.LoginUserName), stack, false);
            TextLine(selected.Guest ? "Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen." : "Mit Passwort: „Anonym“ deaktivieren; Netzwerk-Benutzer und Passwort eintragen.", stack, false);
            Button copy = Button("Verbindung kopieren", 230, false);
            copy.Margin = new Padding(0, 0, 0, 5);
            FlowLayoutPanel copyActions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = Padding.Empty };
            Button copyIp = Button("IP kopieren", 165, false);
            copyIp.Margin = new Padding(0, 0, 10, 5);
            Button copyUser = Button("Benutzername kopieren", 230, false);
            copyUser.Margin = new Padding(0, 0, 10, 5);
            copyUser.Enabled = !String.IsNullOrWhiteSpace(result.LoginUserName);
            copyActions.Controls.AddRange(new Control[] { copyIp, copyUser, copy });
            stack.Controls.Add(copyActions);
            copyIp.Click += delegate { try { if (!String.IsNullOrWhiteSpace(result.Address)) Clipboard.SetText(result.Address); copyIp.Text = I18n.T("Kopiert"); } catch (Exception ex) { ShowClipboardError("Freigabe-Assistent: IP kopieren", ex); } };
            copyUser.Click += delegate { try { if (!String.IsNullOrWhiteSpace(result.LoginUserName)) Clipboard.SetText(result.LoginUserName); copyUser.Text = I18n.T("Kopiert"); } catch (Exception ex) { ShowClipboardError("Freigabe-Assistent: Benutzername kopieren", ex); } };
            copy.Click += delegate { try { Clipboard.SetText(details.Text + "\r\n\r\n" + I18n.T(selected.Guest ? "Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen." : "Mit Passwort: „Anonym“ deaktivieren; Netzwerk-Benutzer und Passwort eintragen.")); copy.Text = I18n.T("Kopiert"); } catch (Exception ex) { ShowClipboardError("Freigabe-Assistent: Verbindung kopieren", ex); } };
            TextLine("Jetzt auf deinem Gerät öffnen", stack, false);
            ComboBox device = Choice();
            device.Items.AddRange(new object[] { I18n.T("Android · Samsung und andere"), "Windows", "iPhone / iPad", "Mac", "Linux" });
            stack.Controls.Add(device);
            Label help = TextLine(String.Empty, stack, false);
            device.SelectedIndexChanged += delegate
            {
                string[] tips = {
                    "In einer Dateien-App Netzwerkspeicher / SMB hinzufügen. Bei Samsung: Eigene Dateien → Netzwerkspeicher. IP und Port 445 eintragen.",
                    "Explorer öffnen und den Windows-Pfad oben in die Adressleiste einfügen.",
                    "Dateien → Durchsuchen → … → Mit Server verbinden. Die SMB-Adresse oben eintragen.",
                    "Finder → Gehe zu → Mit Server verbinden. Die SMB-Adresse oben eintragen.",
                    "Im Dateimanager „Mit Server verbinden“ wählen und die SMB-Adresse oben eintragen." };
                help.Text = I18n.T(tips[device.SelectedIndex]) + "\n\n" + I18n.T(selected.Guest ? "Ohne Passwort: „Anonym“ deaktivieren; den angezeigten Benutzernamen eintragen, Passwort leer lassen." : "Mit dem eingerichteten Netzwerk-Benutzer und deinem Passwort anmelden.");
            };
            device.SelectedIndex = 0;
            if ((!result.Success || receiverIncomplete) && result.Checks != null)
                foreach (CheckItem item in result.Checks.Where(c => c != null && !String.IsNullOrWhiteSpace(c.NextStep))) TextLine(I18n.TranslatePhase(item.NextStep), stack, false);
            TextLine("Die Verbindung vom anderen Gerät prüfst du dort. Der PC muss eingeschaltet und wach bleiben.", stack, false);
            Button showAll = Button("Alle Verbindungsdaten anzeigen", 315, false);
            showAll.Margin = new Padding(0, 8, 0, 5);
            showAll.Height = 34;
            stack.Controls.Add(showAll);
            showAll.Click += delegate { details.Visible = !details.Visible; showAll.Text = I18n.T(details.Visible ? "Verbindungsdaten ausblenden" : "Alle Verbindungsdaten anzeigen"); };
            close.Focus();
        }
        private void RequestProblemHelp(CheckItem problem)
        {
            if (preview || working || problem == null || ErrorFixDialog.ActionFor(problem) == ErrorFixAction.None) return;
            if (!String.Equals(problem.State, "error", StringComparison.OrdinalIgnoreCase) && !String.Equals(problem.State, "warning", StringComparison.OrdinalIgnoreCase)) return;
            RequestedProblem = problem; Close();
        }
        private void ReadPage()
        {
            if (step == 0 && path != null)
            {
                selected.FolderPath = path.Text.Trim();
                selected.ShareName = name.Text.Trim();
                selected.AllowDrive = driveConsent.Checked && RootPath(path.Text);
            }
            else if (step == 1 && guest != null)
            {
                selected.Guest = guest.Checked;
                selected.UserName = user.Text.Trim();
                selected.Password = secret.Text;
                selected.AllowGuest = guestConsent.Checked;
                selected.AllowWrite = writable.Checked;
                selected.PrepareReceiver = selected.Guest && receiverPreference;
            }
            else if (step == 2 && network != null)
            {
                NetworkChoice chosen = network.SelectedItem as NetworkChoice;
                selected.Network = chosen == null ? null : chosen.Item;
                selected.AdvancedRepair = autoRepair.Checked;
                if (selected.Guest) receiverPreference = prepareReceiver.Checked;
                selected.PrepareReceiver = selected.Guest && receiverPreference;
            }
        }
        private string ValidationMessage()
        {
            if (step == 0)
            {
                if (chooseDisk != null && chooseDisk.Checked && !RootPath(selected.FolderPath)) return "Wähle zuerst ein Datenlaufwerk aus.";
                if (String.IsNullOrWhiteSpace(selected.FolderPath) || (!preview && !Directory.Exists(selected.FolderPath))) return "Wähle zuerst einen vorhandenen Ordner oder ein Datenlaufwerk.";
                if (selected.FolderPath.StartsWith("\\\\", StringComparison.Ordinal)) return "Wähle einen lokalen Ordner auf diesem PC.";
                if (SystemRoot(selected.FolderPath)) return "Wähle einen Datenordner auf dem Windows-Laufwerk oder ein anderes Datenlaufwerk.";
                if (RootPath(selected.FolderPath) && !selected.AllowDrive) return "Bestätige, dass du alle Dateien auf dem Datenlaufwerk teilen möchtest.";
                if (String.IsNullOrWhiteSpace(selected.ShareName) || selected.ShareName.Length > 80 || selected.ShareName.IndexOfAny(new[] { '\\', '/', ':', '*', '?', '"', '<', '>', '|', '[', ']', ';', ',', '+', '=', '$' }) >= 0) return "Wähle einen einfachen Freigabenamen mit Buchstaben, Zahlen oder Leerzeichen.";
            }
            if (step == 1)
            {
                if (selected.Guest && !selected.AllowGuest) return "Bestätige den Gastmodus, damit der Zugriff ohne Passwort eingerichtet werden darf.";
                if (!selected.Guest && (String.IsNullOrWhiteSpace(selected.UserName) || String.IsNullOrEmpty(selected.Password) || selected.Password.Length < 8)) return "Gib einen Netzwerk-Benutzer und ein Passwort mit mindestens 8 Zeichen ein.";
            }
            if (step == 2 && selected.Network == null) return "Verbinde den PC mit deinem Heimnetz und prüfe die Verbindungen erneut.";
            return null;
        }
        private async Task Next()
        {
            if (working || step == 4) return;
            ReadPage();
            string error = ValidationMessage();
            if (error != null) { MessageBox.Show(this, I18n.T(error), Text, MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
            if (step < 3) { step++; BuildPage(); return; }
            working = true;
            step = 4;
            BuildPage();
            close.Enabled = false;
            using (DiagnosticReports.Current.ProtectSecrets(selected.Password))
            {
                try
                {
                    if (preview) result = new WorkerResult { Success = true, Address = "192.168.178.24", Message = "Sichere Vorschau: Es wurden keine Windows-Einstellungen verändert.", ConnectionText = "IP-Adresse: 192.168.178.24\r\nPort: 445 (SMB)\r\nFreigabe: " + selected.ShareName + "\r\nSMB-Adresse: smb://192.168.178.24/" + selected.ShareName };
                    else if (applyCounted != null) result = await applyCounted(selected, UpdateOperationPhase, UpdateOperationProgress);
                    else result = await apply(selected, UpdateOperationPhase);
                    if (result == null)
                    {
                        result = new WorkerResult { Success = false, Message = "Die Einrichtung wurde nicht abgeschlossen. Bitte beachte das Prüfergebnis im Hauptfenster." };
                        DiagnosticReports.Current.RecordOperation("Freigabe-Assistent: fehlendes Ergebnis", DiagnosticContext(), result);
                    }
                }
                catch (Exception ex) { DiagnosticReports.Current.RecordException("Freigabe-Assistent: Einrichten", ex, DiagnosticContext()); result = BackendClient.Failure(ex.Message, ex); }
                try
                {
                    // Keep this page visible while every reported percent is shown.
                    // A successful result alone authorizes the final 100 percent.
                    if (operationPresenter != null) await operationPresenter.FinishAsync(result != null && result.Success);
                }
                catch (Exception ex) { DiagnosticReports.Current.RecordException("Freigabe-Assistent: Fortschritt abschließen", ex, DiagnosticContext()); result = BackendClient.Failure(ex.Message, ex); }
                finally { working = false; selected.Password = String.Empty; close.Enabled = true; BuildPage(); }
            }
        }

        private ShareRequest DiagnosticContext()
        {
            return new ShareRequest { Action = "Apply", FolderPath = selected.FolderPath, ShareName = selected.ShareName, Mode = selected.Guest ? "Guest" : "Password", UserName = selected.UserName, AdapterId = selected.Network == null ? 0 : selected.Network.Id };
        }

        private void ShowClipboardError(string operation, Exception error)
        {
            DiagnosticReports.Current.RecordException(operation, error);
            WorkerResult failed = BackendClient.Failure(I18n.T("Die Zwischenablage ist gerade nicht erreichbar.") + "\r\n" + error.Message, error);
            problemHistory.Observe(failed, "clipboard");
            BuildPage();
        }

        private void UpdateOperationPhase(string text)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(UpdateOperationPhase), text); return; }
            if (operationPhase != null && !operationPhase.IsDisposed) operationPhase.Text = I18n.TranslatePhase(text);
        }
        private void UpdateOperationProgress(WorkProgress progress)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { BeginInvoke(new Action<WorkProgress>(UpdateOperationProgress), progress); return; }
            if (operationPresenter != null)
            {
                if (progress != null && progress.PhaseStart) operationPresenter.Begin();
                operationPresenter.Report(progress);
            }
        }
        private static string NameFor(string path)
        {
            try { return RootPath(path) ? "Daten-" + Path.GetPathRoot(path).Substring(0, 1).ToUpperInvariant() : Path.GetFileName(path.TrimEnd('\\', '/')); }
            catch (Exception) { return String.Empty; }
        }
        private static bool RootPath(string path)
        {
            try { return !String.IsNullOrWhiteSpace(path) && String.Equals(Path.GetFullPath(path).TrimEnd('\\', '/'), Path.GetPathRoot(Path.GetFullPath(path)).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase); }
            catch (Exception) { return false; }
        }
        private static bool SystemRoot(string path)
        {
            try { return RootPath(path) && String.Equals(Path.GetPathRoot(Path.GetFullPath(path)), Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)), StringComparison.OrdinalIgnoreCase); }
            catch (Exception) { return false; }
        }
        internal static void RunPreviewSelfTest()
        {
            int mutations = 0;
            using (ShareWizard wizard = new ShareWizard(new[] { new NetworkItem { Id = 12, Name = "Test-Heimnetz", Address = "192.168.178.24" } }, true,
                delegate { mutations++; return Task.FromResult(new WorkerResult()); }, delegate { return Task.FromResult(new NetworkItem[0]); }))
            {
                wizard.ShowInTaskbar = false;
                wizard.StartPosition = FormStartPosition.Manual;
                wizard.Location = new Point(-32000, -32000);
                wizard.Show();
                Application.DoEvents();
                wizard.path.Text = @"D:\Familienbilder";
                wizard.name.Text = "Familienbilder";
                if (!wizard.Next().IsCompleted || wizard.step != 1) throw new InvalidOperationException("Wizard: Ordner-Auswahl fehlt.");
                wizard.ReadPage();
                if (wizard.ValidationMessage() == null) throw new InvalidOperationException("Wizard: Gast-Einwilligung wurde übergangen.");
                wizard.withPassword.Checked = true;
                wizard.user.Text = "DateiUser";
                wizard.secret.Text = "123";
                wizard.ReadPage();
                if (wizard.ValidationMessage() == null) throw new InvalidOperationException("Wizard: Kurzes Passwort wurde akzeptiert.");
                wizard.guest.Checked = true;
                wizard.guestConsent.Checked = true;
                wizard.Next().GetAwaiter().GetResult();
                wizard.Next().GetAwaiter().GetResult();
                if (wizard.step != 3 || wizard.selected.Network == null) throw new InvalidOperationException("Wizard: Heimnetz-Auswahl fehlt.");
                wizard.Next().GetAwaiter().GetResult();
                if (wizard.step != 4 || wizard.result == null || !wizard.result.Success || mutations != 0) throw new InvalidOperationException("Wizard: Vorschau hat echte Einrichtung gestartet.");
                wizard.Close();
            }
        }
        internal void RenderPreview(string file)
        {
            RenderPreview(file, 3);
        }
        internal void RenderPreview(string file, int previewStep)
        {
            if (!preview) throw new InvalidOperationException("Sichere Vorschau erforderlich.");
            selected.FolderPath = @"D:\Familienbilder";
            selected.ShareName = "Familienbilder";
            selected.Network = available.FirstOrDefault();
            selected.AllowGuest = true;
            step = Math.Max(0, Math.Min(4, previewStep));
            if (step == 4) result = new WorkerResult { Success = true, Address = "192.168.178.24", LoginUserName = @"Mein-PC\Gast", Message = "Sichere Vorschau: Es wurden keine Windows-Einstellungen verändert.", ConnectionText = I18n.TranslateConnection("IP-Adresse: 192.168.178.24\r\nPort: 445 (SMB)\r\nFreigabe: Familienbilder\r\nWindows: \\\\Mein-PC\\Familienbilder\r\nSMB-Adresse: smb://192.168.178.24/Familienbilder\r\nBenutzer: Mein-PC\\Gast\r\nPasswort: keines") };
            BuildPage();
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Show();
            Application.DoEvents();
            using (Bitmap bitmap = new Bitmap(Width, Height)) { DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size)); bitmap.Save(file, System.Drawing.Imaging.ImageFormat.Png); }
            Hide();
        }
        protected override void Dispose(bool disposing)
        {
            if (disposing) { selected.Password = String.Empty; I18n.Changed -= LanguageChanged; if (operationPresenter != null) { operationPresenter.Dispose(); operationPresenter = null; } }
            base.Dispose(disposing);
        }
        private sealed class DiskChoice
        {
            internal readonly string Path;
            private readonly string text;
            internal DiskChoice(string path, string text) { Path = path; this.text = text; }
            public override string ToString() { return text; }
        }
        private sealed class NetworkChoice
        {
            internal readonly NetworkItem Item;
            internal NetworkChoice(NetworkItem item) { Item = item; }
            public override string ToString() { return Item.Name + " · " + Item.Address; }
        }
    }
}
