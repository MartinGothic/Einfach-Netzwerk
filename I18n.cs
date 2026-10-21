using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    public sealed class LanguageItem
    {
        public string Code { get; private set; }
        public string NativeName { get; private set; }
        public LanguageItem(string code, string nativeName) { Code = code; NativeName = nativeName; }
        public override string ToString() { return NativeName; }
    }

    public static partial class I18n
    {
        public static readonly LanguageItem[] Languages = {
            new LanguageItem("de", "Deutsch"), new LanguageItem("en", "English"),
            new LanguageItem("fr", "Français"), new LanguageItem("es", "Español"),
            new LanguageItem("it", "Italiano"), new LanguageItem("pt", "Português"),
            new LanguageItem("pl", "Polski")
        };
        private static string language = "de";
        private static readonly Dictionary<string, string[]> catalog = new Dictionary<string, string[]>(StringComparer.Ordinal);
        private static readonly Dictionary<string, string> sources = new Dictionary<string, string>(StringComparer.Ordinal);
        private static readonly List<Template> templates = new List<Template>();
        private static readonly ConditionalWeakTable<object, TextRecord> textRecords = new ConditionalWeakTable<object, TextRecord>();
        public static event EventHandler Changed;
        static I18n() { AddInterface(); AddWizard(); AddDiagnostics(); AddRecovery(); AddGuestConnection(); AddSmbVerification(); AddOverview(); AddHome(); AddProgress(); AddExport(); AddRemoteAccess(); AddServiceHealth(); AddClientName(); AddDiscovery(); AddReceiver(); AddErrorFix(); AddErrorFixWorkflow(); AddResetNetwork(); AddResetWorkflow(); AddResetInventory(); AddProblems(); AddProblemHelp(); AddWizardAccess(); AddConnectionSummary(); }
        public static string Language
        {
            get { return language; }
            set
            {
                string selected = (value ?? "de").ToLowerInvariant();
                bool known = false;
                foreach (LanguageItem item in Languages) if (item.Code == selected) known = true;
                if (!known) selected = "de";
                if (selected == language) return;
                language = selected;
                EventHandler handler = Changed;
                if (handler != null) handler(null, EventArgs.Empty);
            }
        }
        private static int Index { get { for (int i = 0; i < Languages.Length; i++) if (Languages[i].Code == language) return i; return 0; } }
        public static string T(string original)
        {
            if (String.IsNullOrEmpty(original) || language == "de") return original;
            string[] values;
            if (catalog.TryGetValue(original, out values)) return values[Index];
            foreach (Template template in templates)
            {
                Match match = template.Pattern.Match(original);
                if (!match.Success) continue;
                string translated = catalog[template.Source][Index];
                // Dynamic values (paths, addresses, account names and Windows error details) are kept verbatim.
                for (int i = 0; i < template.Arguments; i++) translated = translated.Replace("{" + i.ToString(CultureInfo.InvariantCulture) + "}", match.Groups["v" + i.ToString(CultureInfo.InvariantCulture)].Value);
                return translated;
            }
            return original;
        }
        public static string Format(string original, params object[] values) { return String.Format(CultureInfo.CurrentCulture, T(original), values); }
        internal static string SourceOf(string value) { string source; return sources.TryGetValue(value ?? String.Empty, out source) ? source : value; }
        private static void Rows(string rows)
        {
            foreach (string row in rows.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                string[] values = row.Split('|');
                if (values.Length != 7) throw new InvalidOperationException("Localization row requires seven languages: " + values[0]);
                for (int i = 0; i < values.Length; i++) values[i] = values[i].Replace("\\n", "\n").Replace("\\r", "\r");
                string key = values[0];
                if (catalog.ContainsKey(key)) throw new InvalidOperationException("Duplicate localization source: " + key);
                catalog.Add(key, values);
                foreach (string value in values) if (!sources.ContainsKey(value)) sources.Add(value, key);
                MatchCollection placeholders = Regex.Matches(key, @"\{(\d+)\}");
                if (placeholders.Count == 0) continue;
                string pattern = Regex.Escape(key);
                int arguments = 0;
                foreach (Match placeholder in placeholders)
                {
                    int number = Int32.Parse(placeholder.Groups[1].Value, CultureInfo.InvariantCulture);
                    arguments = Math.Max(arguments, number + 1);
                    pattern = pattern.Replace(Regex.Escape(placeholder.Value), "(?<v" + number.ToString(CultureInfo.InvariantCulture) + ">.*?)");
                }
                for (int i = 1; i < values.Length; i++)
                    for (int p = 0; p < arguments; p++)
                        if (!values[i].Contains("{" + p.ToString(CultureInfo.InvariantCulture) + "}")) throw new InvalidOperationException("Missing localization placeholder: " + key);
                templates.Add(new Template { Source = key, Arguments = arguments, Pattern = new Regex("\\A" + pattern + "\\z", RegexOptions.Singleline | RegexOptions.CultureInvariant) });
            }
        }
        private sealed class Template { internal string Source; internal int Arguments; internal Regex Pattern; }
        private sealed class TextRecord { internal string Source, Applied; }
        private static string ControlText(object owner, string current)
        {
            TextRecord record = textRecords.GetOrCreateValue(owner);
            if (record.Source == null || current != record.Applied)
            {
                string source;
                record.Source = sources.TryGetValue(current ?? "", out source) ? source : current;
            }
            record.Applied = T(record.Source);
            return record.Applied;
        }
        public static void Apply(Control root)
        {
            if (root == null) return;
            // Never rewrite editable values or user file/account names.
            if (!(root is TextBoxBase) && !(root is ComboBox)) root.Text = ControlText(root, root.Text);
            ComboBox combo = root as ComboBox;
            if (combo != null && combo.DropDownStyle == ComboBoxStyle.DropDownList)
            {
                combo.BeginUpdate();
                try
                {
                    for (int i = 0; i < combo.Items.Count; i++)
                    {
                        string text = combo.Items[i] as string;
                        string source;
                        if (text != null && sources.TryGetValue(text, out source)) combo.Items[i] = T(source);
                    }
                }
                finally { combo.EndUpdate(); }
            }
            ListView list = root as ListView;
            if (list != null) foreach (ColumnHeader header in list.Columns) header.Text = ControlText(header, header.Text);
            ToolStrip strip = root as ToolStrip;
            if (strip != null) ApplyItems(strip.Items);
            if (root.ContextMenuStrip != null) ApplyItems(root.ContextMenuStrip.Items);
            foreach (Control child in root.Controls) Apply(child);
        }
        private static void ApplyItems(ToolStripItemCollection items)
        {
            foreach (ToolStripItem item in items)
            {
                item.Text = ControlText(item, item.Text);
                ToolStripDropDownItem menu = item as ToolStripDropDownItem;
                if (menu != null) ApplyItems(menu.DropDownItems);
            }
        }
        public static string TranslatePhase(string value) { return TranslateDiagnostic(value); }
        private static string TranslateDiagnostic(string value)
        {
            if (String.IsNullOrEmpty(value)) return value;
            string smbFailure = TranslateSmbFailure(value);
            if (smbFailure != null) return smbFailure;
            if (language == "de") return value;
            string translated = T(value);
            if (translated != value) return translated;
            // Paragraphs and known error prefixes can be translated while preserving native OS details.
            if (value.Contains("\n"))
            {
                string[] lines = value.Replace("\r\n", "\n").Split('\n');
                for (int i = 0; i < lines.Length; i++) lines[i] = TranslateDiagnostic(lines[i]);
                return String.Join("\n", lines);
            }
            return value;
        }
        public static WorkerResult TranslateResult(WorkerResult result)
        {
            if (result == null) return null;
            WorkerResult translated = JsonData.Parse<WorkerResult>(JsonData.Serialize(result));
            translated.Message = TranslateDiagnostic(result.Message);
            translated.ConnectionText = TranslateConnection(result.ConnectionText);
            foreach (CheckItem item in translated.Checks ?? new CheckItem[0])
            {
                item.Name = T(item.Name);
                item.Detail = TranslateDiagnostic(item.Detail);
                item.NextStep = TranslateDiagnostic(item.NextStep);
                // State and diagnostic codes remain canonical for severity and repair decisions.
            }
            foreach (NetworkItem item in translated.Networks ?? new NetworkItem[0]) item.Category = T(item.Category);
            return translated;
        }
        public static string TranslateConnection(string value)
        {
            if (String.IsNullOrEmpty(value) || language == "de") return value;
            string[] lines = value.Replace("\r\n", "\n").Split('\n');
            for (int i = 0; i < lines.Length; i++)
            {
                int colon = lines[i].IndexOf(':');
                if (colon <= 0) { lines[i] = T(lines[i]); continue; }
                string label = lines[i].Substring(0, colon);
                string raw = lines[i].Substring(colon + 1);
                string content = raw.TrimStart();
                int spaces = raw.Length - content.Length;
                string fixedValue = T(content);
                // Only labels and fixed descriptions are localized, never smb:// paths or identifiers.
                lines[i] = T(label) + ":" + new string(' ', spaces) + fixedValue;
            }
            return String.Join("\r\n", lines);
        }
        public static int TranslationCount { get { return catalog.Count; } }
        public static bool HasTranslation(string source) { return catalog.ContainsKey(source); }
        public static void RunSelfTest()
        {
            RunRecoverySelfTest();
            RunGuestConnectionSelfTest();
            RunSmbVerificationSelfTest();
            string saved = Language;
            try
            {
                foreach (LanguageItem item in Languages)
                {
                    Language = item.Code;
                    foreach (KeyValuePair<string, string[]> row in catalog)
                    {
                        if (String.IsNullOrWhiteSpace(row.Value[Index])) throw new InvalidOperationException("Empty localization: " + row.Key);
                    }
                    string path = @"D:\Bilder\Prüfen";
                    if (!Format("Ordner: {0}", path).Contains(path)) throw new InvalidOperationException("Localization changed a path.");
                }
                using (Panel panel = new Panel())
                using (Button button = new Button { Text = "Prüfen" })
                using (TextBox input = new TextBox { Text = "Prüfen" })
                {
                    panel.Controls.Add(button); panel.Controls.Add(input);
                    foreach (LanguageItem item in Languages) { Language = item.Code; Apply(panel); if (input.Text != "Prüfen" || button.Text != T("Prüfen")) throw new InvalidOperationException("Language switching changed an input or lost its source."); }
                    Language = "de"; Apply(panel); if (button.Text != "Prüfen") throw new InvalidOperationException("German source was not restored.");
                }
            }
            finally { Language = saved; }
        }
    }
}
