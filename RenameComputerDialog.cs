using System;
using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal sealed class RenameComputerDialog : AeroGlassForm
    {
        private readonly TextBox name;
        private readonly Button export;
        internal string ComputerName { get { return name.Text.Trim().ToUpperInvariant(); } }
        internal RenameComputerDialog(string currentName)
        {
            Text = I18n.T("Computername ändern");
            AeroTheme.ApplyWindowIcon(this);
            Font = new Font("Segoe UI", 10);
            ForeColor = AeroTheme.Ink;
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(233, 246, 255);
            ClientSize = new Size(590, 443);
            MinimumSize = new Size(590, 443);
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            MaximizeBox = false;
            MinimizeBox = false;
            TableLayoutPanel panel = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), ColumnCount = 1, RowCount = 7 };
            panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 30));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 43));
            panel.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 49));
            panel.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
            Controls.Add(panel);
            panel.Controls.Add(new Label { Text = I18n.T("Ein Name, den du leicht erkennst"), Dock = DockStyle.Fill, Font = new Font("Segoe UI", 19), AutoSize = true }, 0, 0);
            panel.Controls.Add(new Label { Text = I18n.T("Aktueller Name") + ": " + currentName, Dock = DockStyle.Fill, AutoSize = true }, 0, 1);
            panel.Controls.Add(new Label { Text = I18n.T("Neuer Computername"), Dock = DockStyle.Fill, AutoSize = true }, 0, 2);
            name = new TextBox { Text = currentName, Font = new Font("Segoe UI", 13), Dock = DockStyle.Top, MaxLength = 15 };
            panel.Controls.Add(name, 0, 3);
            panel.Controls.Add(new Label { Text = I18n.T("Zum Beispiel WOHNZIMMER-PC. Verwende 1 bis 15 Buchstaben, Zahlen oder Bindestriche. Der Name wird nach einem Windows-Neustart aktiv; deine Dateien bleiben erhalten."), Dock = DockStyle.Fill, AutoSize = false }, 0, 4);
            FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false };
            Button apply = new AeroButton { Text = I18n.T("Name übernehmen"), Primary = true, Height = 38, Width = 230 };
            Button cancel = new AeroButton { Text = I18n.T("Abbrechen"), Height = 38, Width = 180, DialogResult = DialogResult.Cancel };
            buttons.Controls.AddRange(new Control[] { apply, cancel });
            panel.Controls.Add(buttons, 0, 5);
            export = new AeroButton { Text = I18n.T("Fehlerbericht exportieren"), Height = 38, Width = 345, Anchor = AnchorStyles.Left | AnchorStyles.Top, Margin = new Padding(0, 5, 0, 0) };
            export.Click += delegate { DiagnosticReports.Current.SaveReport(this); };
            panel.Controls.Add(export, 0, 6);
            AcceptButton = apply;
            CancelButton = cancel;
            apply.Click += delegate
            {
                string selected = ComputerName;
                if (!Regex.IsMatch(selected, "^[A-Z0-9](?:[A-Z0-9-]{0,13}[A-Z0-9])?$") || Regex.IsMatch(selected, "^[0-9]+$"))
                {
                    MessageBox.Show(this, I18n.T("Bitte wähle 1 bis 15 Buchstaben, Zahlen oder Bindestriche. Der Name darf nicht nur aus Zahlen bestehen und muss mit einem Buchstaben oder einer Zahl beginnen und enden."), Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                    name.Focus();
                    return;
                }
                DialogResult = DialogResult.OK;
                Close();
            };
            Shown += delegate { AeroTheme.GlassFrame(this); name.SelectAll(); name.Focus(); };
            I18n.Apply(this);
            AeroTheme.StyleGlassChildren(this);
        }
    }
}
