using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal sealed class ShareOverviewDialog : AeroGlassForm
    {
        private WorkerResult inventory;
        private readonly bool preview;
        private readonly Func<ShareItem, Task<WorkerResult>> removeShare;
        private readonly Func<Task<WorkerResult>> refreshShares;
        private readonly ListView shares;
        private readonly TextBox details;
        private readonly Label summary;
        private readonly Button copy, open, remove, close, export, refresh;
        private readonly Label operationStatus, explanation;
        private readonly Label selectedName, selectedAccess;
        private readonly TextBox selectedPath;
        private readonly CollapsibleSection detailSection;
        private bool busy;
        private readonly ProblemHistory problemHistory = new ProblemHistory();
        private readonly Label problemNotice;
        private string InventoryContext { get { return "inventory:" + (inventory.ComputerName ?? Environment.MachineName); } }

        internal ShareOverviewDialog(WorkerResult inventory, bool preview)
            : this(inventory, preview, null, null) { }

        internal ShareOverviewDialog(WorkerResult inventory, bool preview,
            Func<ShareItem, Task<WorkerResult>> removeShare, Func<Task<WorkerResult>> refreshShares)
        {
            this.inventory = inventory ?? new WorkerResult();
            this.preview = preview;
            this.removeShare = removeShare;
            this.refreshShares = refreshShares;
            problemHistory.Observe(this.inventory, InventoryContext);
            Text = I18n.T("Freigabenübersicht");
            AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 9.5f);
            ForeColor = AeroTheme.Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(227, 243, 253);
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96, 96);
            ClientSize = new Size(980, 720);
            MinimumSize = new Size(870, 650);
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            MinimizeBox = false;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);

            TableLayoutPanel shell = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(12, 0, 12, 12), Margin = Padding.Empty };
            shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 104));
            shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            shell.RowStyles.Add(new RowStyle(SizeType.Absolute, 98));
            Controls.Add(shell);
            shell.Controls.Add(new AeroHeader { Dock = DockStyle.Fill, Heading = "Freigabenübersicht", Subtitle = "Deine Ordner und Laufwerke im Heimnetz.", Margin = new Padding(0, 0, 0, 8) }, 0, 0);

            OverviewScrollPanel body = new OverviewScrollPanel { Dock = DockStyle.Fill, AutoScroll = true, Margin = Padding.Empty, Padding = Padding.Empty };
            TableLayoutPanel stack = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, RowCount = 7, Margin = Padding.Empty, Padding = new Padding(2, 4, 2, 0) };
            stack.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            for (int i = 0; i < 7; i++) stack.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            body.Controls.Add(stack);
            shell.Controls.Add(body, 0, 1);
            summary = new Label { Dock = DockStyle.Top, AutoSize = true, Font = new Font("Segoe UI", 12, FontStyle.Bold), Margin = new Padding(0, 0, 0, 6), UseMnemonic = false };
            stack.Controls.Add(summary, 0, 0);
            explanation = new Label { Dock = DockStyle.Top, AutoSize = true, UseMnemonic = false, Margin = new Padding(0, 0, 0, 12), ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(80, 103, 120) };
            stack.Controls.Add(explanation, 0, 1);
            UpdateExplanation();
            problemNotice = new Label { Dock = DockStyle.Top, AutoSize = true, UseMnemonic = false, Margin = new Padding(0, 0, 0, 10), ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(158, 71, 40), Text = problemHistory.Notice(), Visible = problemHistory.HasProblems };
            stack.Controls.Add(problemNotice, 0, 2);

            shares = new SmoothListView { Dock = DockStyle.Top, Height = 245, View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false, ShowItemToolTips = true, BorderStyle = BorderStyle.FixedSingle, Margin = new Padding(0, 0, 0, 12), AccessibleName = I18n.T("Freigabenübersicht") };
            shares.Columns.Add(I18n.T("Freigabe"), 150);
            shares.Columns.Add(I18n.T("Art"), 145);
            shares.Columns.Add(I18n.T("Zugriff"), 160);
            shares.Columns.Add(I18n.T("Status"), 155);
            shares.SelectedIndexChanged += delegate { UpdateDetails(); };
            shares.SizeChanged += delegate { FitShareColumns(); };
            stack.Controls.Add(shares, 0, 3);

            TableLayoutPanel selected = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, RowCount = 3, Margin = new Padding(0, 0, 0, 10), Padding = new Padding(2, 0, 2, 0) };
            selected.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            for (int i = 0; i < 3; i++) selected.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            selectedName = new Label { Dock = DockStyle.Top, AutoSize = true, Font = new Font("Segoe UI", 10.5f, FontStyle.Bold), UseMnemonic = false, Margin = new Padding(0, 0, 0, 4), AccessibleName = I18n.T("Ausgewählte Freigabe") };
            selectedPath = new TextBox { Dock = DockStyle.Top, ReadOnly = true, BorderStyle = BorderStyle.FixedSingle, BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(250, 253, 255), ForeColor = AeroTheme.Ink, Margin = new Padding(0, 0, 0, 4), AccessibleName = I18n.T("Lokaler Pfad") };
            selectedAccess = new Label { Dock = DockStyle.Top, AutoSize = true, UseMnemonic = false, Margin = Padding.Empty, ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(80, 103, 120) };
            selected.Controls.Add(selectedName, 0, 0);
            selected.Controls.Add(selectedPath, 0, 1);
            selected.Controls.Add(selectedAccess, 0, 2);
            stack.Controls.Add(selected, 0, 4);

            TableLayoutPanel actions = new TableLayoutPanel { Dock = DockStyle.Top, Height = 39, ColumnCount = 3, RowCount = 1, Margin = new Padding(0, 0, 0, 12), Padding = Padding.Empty };
            actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38));
            actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 32));
            actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 30));
            actions.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            open = new AeroButton { Text = I18n.T("Ordner / Laufwerk öffnen"), Dock = DockStyle.Fill, Enabled = false, Margin = new Padding(0, 0, 8, 0), Primary = true };
            copy = new AeroButton { Text = I18n.T("Verbindung kopieren"), Dock = DockStyle.Fill, Enabled = false, Margin = new Padding(0, 0, 0, 0) };
            remove = new AeroButton { Text = I18n.T("Freigabe entfernen"), Dock = DockStyle.Fill, Enabled = false, Margin = new Padding(20, 0, 0, 0) };
            actions.Controls.Add(open, 0, 0);
            actions.Controls.Add(copy, 1, 0);
            actions.Controls.Add(remove, 2, 0);
            stack.Controls.Add(actions, 0, 5);

            detailSection = new CollapsibleSection("Details und Verbindungsdaten") { Margin = Padding.Empty, Expanded = false };
            details = new TextBox { Dock = DockStyle.Top, Height = 184, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, BorderStyle = BorderStyle.FixedSingle, BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(250, 253, 255), ForeColor = AeroTheme.Ink, Font = new Font("Segoe UI", 9.5f), Margin = new Padding(0, 8, 0, 0), AccessibleName = I18n.T("Details zur Freigabe") };
            detailSection.Content.Controls.Add(details);
            stack.Controls.Add(detailSection, 0, 6);

            TableLayoutPanel buttons = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 2, Margin = Padding.Empty, Padding = new Padding(0, 8, 0, 0) };
            buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 43));
            buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 37));
            buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 20));
            buttons.RowStyles.Add(new RowStyle(SizeType.Absolute, 39));
            buttons.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            close = new AeroButton { Text = I18n.T("Schließen"), Width = 145, Height = 36, Anchor = AnchorStyles.Right | AnchorStyles.Top, DialogResult = DialogResult.OK, Margin = new Padding(0, 5, 0, 0) };
            export = new AeroButton { Text = I18n.T("Fehlerbericht exportieren"), Dock = DockStyle.Fill, Margin = new Padding(0, 5, 8, 0) };
            refresh = new AeroButton { Text = I18n.T("Freigaben erneut prüfen"), Dock = DockStyle.Fill, Enabled = !preview && refreshShares != null, Primary = !this.inventory.Success, Margin = new Padding(0, 5, 8, 0) };
            refresh.Click += async delegate { await RefreshInventory(); };
            export.Click += delegate { DiagnosticReports.Current.SaveReport(this); };
            open.Click += delegate { OpenSelectedFolder(); };
            remove.Click += async delegate { await RemoveSelectedShare(); };
            copy.Click += delegate { CopySelectedConnection(); };
            operationStatus = new Label { Dock = DockStyle.Fill, UseMnemonic = false, AutoSize = false, Text = I18n.T(preview ? "Beispielübersicht. Es werden keine Windows-Einstellungen verändert." : "Wähle eine Freigabe für die gewünschte Aktion."), Margin = new Padding(0, 8, 10, 0), ForeColor = AeroTheme.Ink };
            buttons.Controls.Add(operationStatus, 0, 1);
            buttons.SetColumnSpan(operationStatus, 3);
            buttons.Controls.Add(export, 0, 0);
            buttons.Controls.Add(refresh, 1, 0);
            buttons.Controls.Add(close, 2, 0);
            shell.Controls.Add(buttons, 0, 2);
            body.SizeChanged += delegate
            {
                int width = Math.Max(120, stack.ClientSize.Width - stack.Padding.Horizontal);
                explanation.MaximumSize = new Size(width, 0);
                problemNotice.MaximumSize = new Size(width, 0);
                selectedName.MaximumSize = new Size(Math.Max(120, selected.ClientSize.Width - selected.Padding.Horizontal), 0);
                selectedAccess.MaximumSize = selectedName.MaximumSize;
            };
            stack.SizeChanged += delegate
            {
                explanation.MaximumSize = new Size(Math.Max(120, stack.ClientSize.Width - stack.Padding.Horizontal), 0);
                problemNotice.MaximumSize = explanation.MaximumSize;
                selectedName.MaximumSize = new Size(Math.Max(120, selected.ClientSize.Width - selected.Padding.Horizontal), 0);
                selectedAccess.MaximumSize = selectedName.MaximumSize;
            };
            bool fittingBody = false;
            Action fitBody = delegate
            {
                if (fittingBody) return;
                fittingBody = true;
                try
                {
                    int occupied = stack.Padding.Vertical;
                    foreach (Control child in stack.Controls)
                    {
                        if (child == shares) continue;
                        occupied += child.Margin.Vertical;
                        occupied += child == detailSection ? detailSection.ToggleButton.Height + detailSection.Padding.Vertical : child.Height;
                    }
                    int target = Math.Max(shares.Font.Height * 7, Math.Min(shares.Font.Height * 14, body.ClientSize.Height - occupied - shares.Margin.Vertical - 4));
                    if (shares.Height != target) shares.Height = target;
                }
                finally { fittingBody = false; }
            };
            body.SizeChanged += delegate { fitBody(); };
            stack.Layout += delegate { fitBody(); };
            CancelButton = close;
            AcceptButton = close;
            PopulateShares();
            I18n.Apply(this);
            AeroTheme.StyleGlassChildren(this);
            Shown += delegate { AeroTheme.GlassFrame(this); FitShareColumns(); shares.Focus(); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
        }

        private void UpdateExplanation()
        {
            string text = I18n.T(preview
                ? "Beispielübersicht. Es werden keine Windows-Einstellungen verändert."
                : "Wähle eine Freigabe. Öffnen, Verbindung kopieren oder Freigabe entfernen.");
            if (!inventory.Success)
                text = String.IsNullOrWhiteSpace(inventory.Message) ? I18n.T("Das Prüfergebnis zeigt ein Problem. Die Ursache und der ursprüngliche Fehlercode bleiben unten sichtbar.") : I18n.TranslatePhase(inventory.Message);
            explanation.Text = text;
            explanation.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : !inventory.Success ? Color.FromArgb(158, 71, 40) : Color.FromArgb(80, 103, 120);
        }

        private void PopulateShares()
        {
            ShareItem previous = SelectedShare();
            string previousName = previous == null ? null : previous.Name;
            List<ShareItem> ordered = new List<ShareItem>();
            foreach (ShareItem share in inventory.Shares ?? new ShareItem[0]) if (share != null) ordered.Add(share);
            ordered.Sort(delegate(ShareItem first, ShareItem second)
            {
                if (first.Available != second.Available) return first.Available ? -1 : 1;
                return StringComparer.CurrentCultureIgnoreCase.Compare(first.Name, second.Name);
            });
            int active = 0;
            shares.BeginUpdate();
            shares.Items.Clear();
            foreach (ShareItem share in ordered)
            {
                if (share.Available) active++;
                ListViewItem row = new ListViewItem(share.Name ?? String.Empty) { Tag = share };
                row.SubItems.Add(I18n.T(IsDriveRoot(share.Path) ? "Ganzes Laufwerk" : "Ordner"));
                row.SubItems.Add(AccessDescription(share));
                row.SubItems.Add(I18n.T(share.Available ? "Freigegeben" : "Nicht mehr freigegeben"));
                row.ToolTipText = share.Path ?? String.Empty;
                if (!share.Available) row.ForeColor = SystemInformation.HighContrast ? SystemColors.GrayText : Color.FromArgb(133, 101, 64);
                shares.Items.Add(row);
            }
            shares.EndUpdate();
            summary.Text = I18n.Format("Aktuelle Freigaben: {0}", active);
            if (active == 0)
                summary.Text = !inventory.Success ? I18n.T("Bitte Prüfergebnis beachten") : summary.Text + "  ·  " + I18n.T("Noch keine Datenfreigabe vorhanden");
            if (shares.Items.Count > 0)
            {
                ListViewItem preferred = shares.Items[0];
                foreach (ListViewItem item in shares.Items)
                    if (String.Equals(((ShareItem)item.Tag).Name, previousName, StringComparison.OrdinalIgnoreCase)) { preferred = item; break; }
                preferred.Selected = true;
                preferred.Focused = true;
            }
            else UpdateDetails();
            FitShareColumns();
        }

        private void UpdateDetails()
        {
            ShareItem selected = SelectedShare();
            copy.Enabled = !busy && selected != null && selected.Available;
            open.Enabled = !busy && !preview && selected != null && LocalFolderPath(selected.Path) != null;
            remove.Enabled = !busy && !preview && selected != null && selected.Available && removeShare != null && refreshShares != null;
            if (selected == null)
            {
                selectedName.Text = I18n.T(inventory.Success ? "Noch keine Datenfreigabe vorhanden" : "Bitte Prüfergebnis beachten");
                selectedPath.Text = String.Empty;
                selectedPath.Visible = false;
                selectedAccess.Text = I18n.T(inventory.Success
                    ? "Starte den Assistenten im Hauptfenster, um einen Ordner oder ein Laufwerk freizugeben."
                    : "Bitte beachte das Prüfergebnis im Hauptfenster.");
                selectedAccess.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : !inventory.Success ? Color.FromArgb(158, 71, 40) : Color.FromArgb(80, 103, 120);
                details.Text = problemHistory.AppendDetails(inventory.Success
                    ? I18n.T("Starte den Assistenten im Hauptfenster, um einen Ordner oder ein Laufwerk freizugeben.")
                    : I18n.TranslatePhase(inventory.Message ?? String.Empty));
                return;
            }
            selectedName.Text = I18n.T("Ausgewählte Freigabe") + ": " + selected.Name;
            selectedPath.Text = selected.Path ?? String.Empty;
            selectedPath.Visible = true;
            selectedAccess.Text = AccessDescription(selected) + "  ·  " + I18n.T(selected.Available ? "Freigegeben" : "Nicht mehr freigegeben");
            selectedAccess.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : !selected.Available ? Color.FromArgb(158, 71, 40) : Color.FromArgb(80, 103, 120);
            details.Text = problemHistory.AppendDetails(Describe(selected));
            details.SelectionStart = 0;
            details.SelectionLength = 0;
        }

        private ShareItem SelectedShare() { return shares.SelectedItems.Count == 0 ? null : shares.SelectedItems[0].Tag as ShareItem; }

        private void FitShareColumns()
        {
            if (shares == null || shares.Columns.Count != 4 || shares.ClientSize.Width < 100) return;
            int available = Math.Max(100, shares.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 4);
            int type = Math.Max(90, TextRenderer.MeasureText(I18n.T("Ganzes Laufwerk"), shares.Font).Width + 20);
            int access = Math.Max(125, TextRenderer.MeasureText(I18n.T("Windows-Berechtigungen"), shares.Font).Width + 20);
            int status = Math.Max(140, TextRenderer.MeasureText(I18n.T("Nicht mehr freigegeben"), shares.Font).Width + 20);
            shares.Columns[0].Width = Math.Max(100, available - type - access - status);
            shares.Columns[1].Width = type;
            shares.Columns[2].Width = access;
            shares.Columns[3].Width = status;
        }

        private string Describe(ShareItem share)
        {
            StringBuilder text = new StringBuilder();
            Line(text, "Freigabe", share.Name);
            Line(text, "Lokaler Pfad", share.Path);
            Line(text, "Status", I18n.T(share.Available ? "Freigegeben" : "Nicht mehr freigegeben"));
            Line(text, "Zugriff", AccessDescription(share));
            if (!share.Available)
            {
                AppendStoredDetails(text, share);
                text.AppendLine();
                text.Append(I18n.T("Nur die gespeicherte Einrichtung ist noch vorhanden. Dieser Eintrag ist derzeit keine Windows-Freigabe."));
                return text.ToString();
            }
            string computer = String.IsNullOrEmpty(inventory.ComputerName) ? Environment.MachineName : inventory.ComputerName;
            string address = AddressFor(share);
            if (!String.IsNullOrEmpty(address)) Line(text, "IP-Adresse", address);
            Line(text, "Port", "445 (TCP / SMB)");
            Line(text, "Windows-Pfad", "\\\\" + computer + "\\" + share.Name);
            if (!String.IsNullOrEmpty(address)) Line(text, "SMB-Adresse", "smb://" + address + "/" + Uri.EscapeDataString(share.Name ?? String.Empty));
            if (!String.IsNullOrEmpty(share.UserName))
            {
                string account = share.UserName.IndexOf('\\') >= 0 ? share.UserName : computer + "\\" + share.UserName;
                Line(text, "Benutzer", account);
            }
            if (String.Equals(share.Mode, "Guest", StringComparison.OrdinalIgnoreCase)) text.AppendLine(I18n.T("Passwort leer lassen; Anonym deaktivieren."));
            else if (String.Equals(share.Mode, "Password", StringComparison.OrdinalIgnoreCase)) text.AppendLine(I18n.T("Mit Passwort: „Anonym“ deaktivieren; Netzwerk-Benutzer und Passwort eintragen."));
            else text.AppendLine(I18n.T("Der Zugriff richtet sich nach den vorhandenen Windows-Berechtigungen."));
            text.AppendLine();
            AppendStoredDetails(text, share);
            return text.ToString().TrimEnd();
        }

        private static void AppendStoredDetails(StringBuilder text, ShareItem share)
        {
            Line(text, "Art", I18n.T(IsDriveRoot(share.Path) ? "Ganzes Laufwerk" : "Ordner"));
            Line(text, "Verwaltung", I18n.T(share.Managed ? "Dieses Programm" : "Windows / andere"));
            if (share.Managed && !String.IsNullOrEmpty(share.Mode)) Line(text, "Dateirechte", I18n.T(share.AllowWrite ? "Lesen und Schreiben" : "Nur Lesen"));
        }

        private string AddressFor(ShareItem share)
        {
            foreach (NetworkItem network in inventory.Networks ?? new NetworkItem[0])
                if (network != null && network.Id == share.AdapterId && !String.IsNullOrWhiteSpace(network.Address)) return network.Address;
            if (!String.IsNullOrWhiteSpace(inventory.Address)) return inventory.Address;
            foreach (NetworkItem network in inventory.Networks ?? new NetworkItem[0])
                if (network != null && !String.IsNullOrWhiteSpace(network.Address)) return network.Address;
            return String.Empty;
        }

        private static string AccessDescription(ShareItem share)
        {
            if (String.Equals(share.Mode, "Guest", StringComparison.OrdinalIgnoreCase)) return I18n.T("Ohne Passwort");
            if (String.Equals(share.Mode, "Password", StringComparison.OrdinalIgnoreCase)) return I18n.T("Mit Passwort");
            return I18n.T("Windows-Berechtigungen");
        }
        private static void Line(StringBuilder text, string label, string value) { text.Append(I18n.T(label)).Append(": ").AppendLine(value ?? String.Empty); }
        private static bool IsDriveRoot(string path)
        {
            try
            {
                if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) || path.StartsWith("\\\\", StringComparison.Ordinal)) return false;
                string full = Path.GetFullPath(path);
                return String.Equals(full.TrimEnd('\\', '/'), Path.GetPathRoot(full).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
            }
            catch (ArgumentException) { return false; }
            catch (NotSupportedException) { return false; }
            catch (PathTooLongException) { return false; }
        }
        private void CopySelectedConnection()
        {
            ShareItem selected = SelectedShare();
            if (busy || selected == null || !selected.Available) return;
            try { Clipboard.SetText(Describe(selected)); SetOperationStatus(I18n.T("Verbindungsdaten in die Zwischenablage kopiert."), false); }
            catch (Exception ex) { DiagnosticReports.Current.RecordException("Freigabenübersicht: Verbindung kopieren", ex); ShowOperationError(I18n.T("Die Zwischenablage ist gerade nicht erreichbar.") + "\r\n" + ex.Message, BackendClient.Failure(ex.Message, ex).ErrorCode); }
        }

        private static string LocalFolderPath(string path)
        {
            try
            {
                if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) || path.StartsWith("\\\\", StringComparison.Ordinal)) return null;
                string full = Path.GetFullPath(path);
                if (full.Length < 3 || full[1] != ':' || full[2] != '\\' || !Directory.Exists(full)) return null;
                return full;
            }
            catch (Exception) { return null; }
        }

        private void OpenSelectedFolder()
        {
            ShareItem selected = SelectedShare();
            if (busy || preview || selected == null) return;
            string path = LocalFolderPath(selected.Path);
            if (path == null)
            {
                string message = I18n.T("Der lokale Ordner oder das Laufwerk ist momentan nicht verfügbar.");
                DiagnosticReports.Current.RecordOperation("Freigabenübersicht: Ordner / Laufwerk öffnen", new ShareRequest { FolderPath = selected.Path, ShareName = selected.Name }, new WorkerResult { Success = false, Message = message });
                ShowOperationError(message);
                return;
            }
            try
            {
                Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
                SetOperationStatus(I18n.T("Ordner oder Laufwerk im Explorer geöffnet."), false);
            }
            catch (Exception ex) { DiagnosticReports.Current.RecordException("Freigabenübersicht: Ordner / Laufwerk öffnen", ex, new ShareRequest { FolderPath = selected.Path, ShareName = selected.Name }); ShowOperationError(I18n.T("Der Ordner oder das Laufwerk konnte nicht geöffnet werden.") + "\r\n" + ex.Message, BackendClient.Failure(ex.Message, ex).ErrorCode); }
        }

        private async Task RemoveSelectedShare()
        {
            ShareItem selected = SelectedShare();
            if (busy || preview || selected == null || !selected.Available || removeShare == null || refreshShares == null) return;
            string confirmation = I18n.Format("Freigabe „{0}“ entfernen?\n\nLokaler Pfad: {1}\n\nDer Netzwerkzugriff über diese Freigabe wird beendet. Deine Ordner und Dateien bleiben erhalten. Andere Freigaben, Dateirechte und Konten bleiben unverändert.", selected.Name, selected.Path);
            if (MessageBox.Show(this, confirmation, I18n.T("Freigabe entfernen"), MessageBoxButtons.OKCancel, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2) != DialogResult.OK) return;
            await RemoveConfirmedShare(selected);
        }

        private async Task RemoveConfirmedShare(ShareItem selected)
        {
            if (busy || preview || selected == null || !selected.Available || removeShare == null || refreshShares == null) return;
            bool removed = false;
            SetBusy(true);
            SetOperationStatus(I18n.T("Freigabe wird entfernt …"), false);
            try
            {
                WorkerResult result = await removeShare(selected);
                if (result == null || !result.Success)
                {
                    if (result != null) problemHistory.Observe(result, "remove:" + selected.Name + ":" + selected.Path);
                    ShowOperationError(result == null ? I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen.") : I18n.TranslateResult(result).Message, result == null ? null : result.ErrorCode, result == null);
                    return;
                }
                removed = true;
                // Once Windows confirms removal, the old row must not retain
                // an active connection while the fresh inventory is loading.
                MarkRemovedLocally(selected);
                SetOperationStatus(I18n.T("Freigaben werden aktualisiert …"), false);
                WorkerResult refreshed = await refreshShares();
                if (refreshed == null) throw new InvalidOperationException(I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen."));
                inventory = refreshed;
                problemHistory.Observe(refreshed, InventoryContext); UpdateProblemNotice();
                PopulateShares();
                UpdateExplanation();
                if (!refreshed.Success)
                {
                    ShowOperationError(I18n.T("Die Freigabe wurde entfernt. Bitte das Prüfergebnis zur aktualisierten Freigabeliste beachten.") + "\r\n" + I18n.TranslateResult(refreshed).Message, refreshed.ErrorCode, false);
                    return;
                }
                SetOperationStatus(I18n.T("Freigabe entfernt. Deine Dateien bleiben erhalten."), false);
            }
            catch (Exception ex)
            {
                DiagnosticReports.Current.RecordException("Freigabenübersicht: Freigabe entfernen / Liste aktualisieren", ex, new ShareRequest { FolderPath = selected.Path, ShareName = selected.Name });
                ShowOperationError(removed
                    ? I18n.T("Die Freigabe wurde entfernt. Die Freigabeliste konnte danach nicht aktualisiert werden.") + "\r\n" + ex.Message
                    : ex.Message, BackendClient.Failure(ex.Message, ex).ErrorCode);
            }
            finally { SetBusy(false); }
        }

        private void MarkRemovedLocally(ShareItem selected)
        {
            inventory = JsonData.Parse<WorkerResult>(JsonData.Serialize(inventory));
            List<ShareItem> remaining = new List<ShareItem>();
            foreach (ShareItem share in inventory.Shares ?? new ShareItem[0])
            {
                if (share == null) continue;
                if (String.Equals(share.Name, selected.Name, StringComparison.OrdinalIgnoreCase))
                {
                    if (!share.Managed) continue;
                    share.Available = false;
                }
                remaining.Add(share);
            }
            inventory.Shares = remaining.ToArray();
            PopulateShares();
        }

        private void SetBusy(bool value)
        {
            busy = value;
            shares.Enabled = !value;
            close.Enabled = !value;
            export.Enabled = !value;
            refresh.Enabled = !value && !preview && refreshShares != null;
            UseWaitCursor = value;
            UpdateDetails();
        }
        private void SetOperationStatus(string text, bool error)
        {
            operationStatus.Text = text ?? I18n.T("Vorgang nicht abgeschlossen");
            operationStatus.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : error ? Color.FromArgb(158, 71, 40) : AeroTheme.Ink;
        }
        private void ShowOperationError(string text, string code = null, bool remember = true)
        {
            string message = String.IsNullOrWhiteSpace(text) ? I18n.T("Vorgang nicht abgeschlossen") : text;
            if (remember) problemHistory.RememberFailure(message, code, "overview-operation");
            SetOperationStatus(message, true);
            ((AeroButton)export).Primary = true;
            ((AeroButton)refresh).Primary = refreshShares != null;
            UpdateProblemNotice(); UpdateDetails(); detailSection.Expanded = true;
        }
        private void UpdateProblemNotice()
        {
            problemNotice.Text = problemHistory.Notice(); problemNotice.Visible = problemHistory.HasProblems;
            problemNotice.ForeColor = SystemInformation.HighContrast ? SystemColors.WindowText : problemHistory.HasUnresolved ? Color.FromArgb(158, 71, 40) : AeroTheme.Ink;
        }
        private async Task RefreshInventory()
        {
            if (busy || preview || refreshShares == null) return;
            SetBusy(true); SetOperationStatus(I18n.T("Freigaben werden aktualisiert …"), false);
            try
            {
                WorkerResult fresh = await refreshShares();
                if (fresh == null) throw new InvalidOperationException(I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen."));
                inventory = fresh; problemHistory.Observe(fresh, InventoryContext);
                PopulateShares(); UpdateExplanation(); UpdateProblemNotice();
                if (!fresh.Success) { ShowOperationError(I18n.TranslatePhase(fresh.Message), fresh.ErrorCode, false); return; }
                SetOperationStatus(I18n.T("Wähle eine Freigabe für die gewünschte Aktion."), false);
                ((AeroButton)refresh).Primary = false; ((AeroButton)export).Primary = problemHistory.HasUnresolved;
            }
            catch (Exception error)
            {
                DiagnosticReports.Current.RecordException("Freigabenübersicht: erneut prüfen", error);
                WorkerResult failed = BackendClient.Failure(error.Message, error);
                ShowOperationError(failed.Message, failed.ErrorCode);
            }
            finally { SetBusy(false); }
        }
        private sealed class SmoothListView : ListView { internal SmoothListView() { DoubleBuffered = true; } }
        private sealed class OverviewScrollPanel : Panel
        {
            internal OverviewScrollPanel() { SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true); }
        }
    }
}
