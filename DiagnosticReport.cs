using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    /// <summary>One in-memory session shared by all application windows. Nothing is saved automatically.</summary>
    public static class DiagnosticReports
    {
        private static readonly DiagnosticSession current = new DiagnosticSession();
        public static DiagnosticSession Current { get { return current; } }
    }

    public sealed class DiagnosticSession
    {
        public const int MaximumHistory = 20;
        private const int MaximumFieldLength = 20000;
        private readonly object gate = new object();
        private readonly Dictionary<string, int> secrets = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly List<Record> history = new List<Record>();
        private Record latest;
        private int omittedHistory;

        // These patterns cover labelled credentials even when a provider supplied a value
        // which was never typed into the program. Known passwords are removed separately.
        private static readonly Regex quotedCredential = new Regex(@"(?<key>['"" ]*(?:ProtectedPassword|password|passwort|kennwort|api[_ -]?key|access[_ -]?token|secret)['"" ]*\s*[:=]\s*)(?<quote>['""])(?<value>.*?)(?:\k<quote>)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Singleline);
        private static readonly Regex plainCredential = new Regex(@"(?<key>\b(?:ProtectedPassword|password|passwort|kennwort|api[_ -]?key|access[_ -]?token|secret)\s*[:=]\s*)(?<value>[^\r\n;,&]+)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        private static readonly Regex addressCredential = new Regex(@"(?<prefix>\b[a-z][a-z0-9+.-]*://[^\s/:@]+:)(?<value>[^\s/@]+)(?=@)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        public int HistoryCount { get { lock (gate) return history.Count; } }

        /// <summary>Keep secrets only while an operation is running; all retained records are already redacted.</summary>
        public IDisposable ProtectSecrets(params string[] values)
        {
            List<string> protectedValues = new List<string>();
            lock (gate)
            {
                foreach (string value in values ?? new string[0])
                {
                    if (String.IsNullOrEmpty(value) || protectedValues.Contains(value)) continue;
                    int count;
                    secrets.TryGetValue(value, out count);
                    secrets[value] = count + 1;
                    protectedValues.Add(value);
                }
            }
            return new SecretScope(this, protectedValues.ToArray());
        }

        public void RecordOperation(string operation, ShareRequest context, WorkerResult result, Exception error = null)
        {
            using (ProtectSecrets(context == null ? null : context.ProtectedPassword))
            lock (gate)
            {
                Record record = StartRecord(operation, context);
                if (result != null) AddResult(record, result);
                if (error != null) AddException(record, error);
                if (result == null && error == null) Add(record, "Ergebnis", "Es liegt kein Ergebnis vor.");
                Retain(record);
                ProblemMemory.Observe(operation, context, result, error, Redact);
            }
        }

        public void RecordException(string operation, Exception error, ShareRequest context = null)
        {
            if (error == null) return;
            RecordOperation(operation, context, null, error);
        }

        public void RecordMessage(string operation, string message, string code = null)
        {
            lock (gate)
            {
                Record record = StartRecord(operation, null);
                record.Attention = true;
                Add(record, "Fehlermeldung", message);
                Add(record, "Fehlercode", CodeOrMissing(code));
                Retain(record);
                ProblemMemory.Observe(operation, null, new WorkerResult { Success = false, Message = message, ErrorCode = code }, null, Redact);
            }
        }

        public string BuildReport()
        {
            lock (gate)
            {
                StringBuilder report = new StringBuilder();
                report.AppendLine(I18n.T("Einfach Netzwerk – Diagnosebericht"));
                report.AppendLine(new string('=', 62));
                Line(report, "Erstellt (UTC)", DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", CultureInfo.InvariantCulture));
                Line(report, "Programmversion", AppInfo.Version);
                Line(report, "Windows-Version", Environment.OSVersion.VersionString);
                Line(report, ".NET-Laufzeit", Environment.Version.ToString());
                Line(report, "Betriebssystem / Prozess", (Environment.Is64BitOperatingSystem ? "64" : "32") + " Bit / " + (Environment.Is64BitProcess ? "64" : "32") + " Bit");
                Line(report, "Computer", Environment.MachineName);
                report.AppendLine(I18n.T("Kennwörter sind entfernt. Der Bericht enthält technische Angaben und ausgewählte lokale Pfade."));
                report.AppendLine();
                report.AppendLine(I18n.T("Letzte Aktion"));
                report.AppendLine(new string('-', 62));
                if (latest == null) report.AppendLine(I18n.T("Es wurde noch keine Aktion erfasst."));
                else AppendRecord(report, latest);
                report.AppendLine();
                report.AppendLine(I18n.T("Bisherige Fehler und Warnungen (Sitzung)"));
                report.AppendLine(new string('-', 62));
                if (history.Count == 0) report.AppendLine(I18n.T("In dieser Sitzung wurden keine Fehler oder Warnungen erfasst."));
                if (omittedHistory > 0) report.AppendLine(I18n.Format("{0} ältere Einträge wurden wegen der begrenzten Sitzungsverlaufslänge verworfen.", omittedHistory));
                for (int index = 0; index < history.Count; index++)
                {
                    report.AppendLine("[" + (index + 1).ToString(CultureInfo.InvariantCulture) + "]");
                    AppendRecord(report, history[index]);
                    report.AppendLine();
                }
                report.AppendLine(I18n.T("Fehlende Fehlercodes werden als „nicht bereitgestellt“ angegeben; Windows-Fehlernummern werden nicht erfunden."));
                return Scrub(report.ToString(), false);
            }
        }

        /// <summary>Only call from an explicit export action. The chooser confirms overwriting an existing file.</summary>
        public bool SaveReport(IWin32Window owner)
        {
            using (SaveFileDialog chooser = new SaveFileDialog())
            {
                chooser.Title = I18n.T("Fehlerbericht als TXT speichern");
                chooser.Filter = I18n.T("Textdatei") + " (*.txt)|*.txt";
                chooser.DefaultExt = "txt";
                chooser.AddExtension = true;
                chooser.OverwritePrompt = true;
                chooser.CheckPathExists = true;
                chooser.FileName = "Einfach-Netzwerk-Fehlerbericht-" + DateTime.Now.ToString("yyyy-MM-dd-HHmmss", CultureInfo.InvariantCulture) + ".txt";
                if (chooser.ShowDialog(owner) != DialogResult.OK) return false;
                try
                {
                    WriteReport(chooser.FileName);
                    MessageBox.Show(owner, I18n.Format("Der Fehlerbericht wurde gespeichert:\n{0}", chooser.FileName), I18n.T("Fehlerbericht exportieren"), MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return true;
                }
                catch (Exception error)
                {
                    RecordException("Fehlerbericht speichern", error);
                    MessageBox.Show(owner, I18n.Format("Der Fehlerbericht konnte nicht gespeichert werden:\n{0}", Redact(error.Message)), I18n.T("Fehlerbericht exportieren"), MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return false;
                }
            }
        }

        /// <summary>Atomic local UTF-8 export. It reads no request files, journals, or shared folder contents.</summary>
        public void WriteReport(string path)
        {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("Ein Exportpfad ist erforderlich.", "path");
            string destination = Path.GetFullPath(path);
            string folder = Path.GetDirectoryName(destination);
            string temporary = Path.Combine(folder, ".EinfachNetzwerk-Bericht-" + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                using (FileStream file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (StreamWriter writer = new StreamWriter(file, new UTF8Encoding(true))) writer.Write(BuildReport());
                if (File.Exists(destination)) File.Replace(temporary, destination, null);
                else File.Move(temporary, destination);
            }
            finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } }
        }

        public string Redact(string value) { lock (gate) return Scrub(value, false); }

        private Record StartRecord(string operation, ShareRequest context)
        {
            Record record = new Record { Timestamp = DateTime.UtcNow, ClientWorkflow = IsClientWorkflow(operation) || context != null && IsClientWorkflow(context.Action),
                AnonymousListContext = context != null && operation == "EnumerateComputer" && String.Equals(context.Mode, "Guest", StringComparison.OrdinalIgnoreCase) && String.IsNullOrEmpty(context.RemoteUserName) && String.IsNullOrEmpty(context.ProtectedPassword) };
            Add(record, "Aktion", String.IsNullOrWhiteSpace(operation) ? "nicht bereitgestellt" : operation);
            if (context != null)
            {
                Add(record, "Ausgewählter Ordner / Datenträger", context.FolderPath);
                Add(record, "Freigabe", context.ShareName);
                Add(record, "Zugriffsmodus", context.Mode);
                Add(record, "Netzwerkadapter-ID", context.AdapterId.ToString(CultureInfo.InvariantCulture));
                Add(record, "Schreibzugriff", context.AllowWrite.ToString());
                Add(record, "Ausgewählter Benutzer", context.UserName);
                Add(record, "Gewünschter Computername", context.ComputerName);
                Add(record, "Zielcomputer", context.RemoteHost);
                Add(record, "Zielfreigabe", context.RemoteShareName);
                Add(record, "Windows-Anmeldung am Ziel", context.RemoteUserName);
                if (!String.IsNullOrEmpty(context.RemoteHost)) Add(record, "Namensverbindung gewünscht", context.AllowNameConnection.ToString());
                if (!String.IsNullOrEmpty(context.RemoteHost) || record.ClientWorkflow)
                    Add(record, "Gastkompatibilität ausdrücklich bestätigt", context.AllowGuestSettings.ToString());
                Add(record, "Vorschau / Testlauf", context.DryRun.ToString());
            }
            return record;
        }

        private void AddResult(Record record, WorkerResult result)
        {
            record.Attention = !result.Success;
            Add(record, "Ergebnis", result.Success ? "Erfolgreich" : IsAnonymousListNotice(record, result) ? "Hinweis" : "Fehlgeschlagen");
            Add(record, "Ergebnismeldung", result.Message);
            Add(record, "Computer", result.ComputerName);
            Add(record, "IP-Adresse", result.Address);
            Add(record, "SMB-Port (TCP)", "445");
            Add(record, "Sicherung der Aktion", result.BackupPath);
            Add(record, "Sicherung der Client-Einstellungen", result.ClientBackupPath);
            Add(record, "Sicherung der Dienst-Einstellungen", result.ServiceBackupPath);
            Add(record, "Freigabepfad", result.SharePath);
            Add(record, "Anmeldebenutzer", result.LoginUserName);
            Add(record, "SMB-Verbindung geprüft", result.ConnectionVerified.ToString());
            if (result.WizardReceiverRequested)
            {
                Add(record, "Assistent: Empfänger-Vorbereitung gewählt", "True");
                Add(record, "Assistent: Empfänger-Einstellungen bestätigt", result.WizardReceiverReady.ToString());
            }
            if (result.InspectionIncomplete) Add(record, "Prüfung vollständig", "False");
            Add(record, "Lokale Windows-Dienste geprüft", result.ServiceHealthVerified.ToString());
            Add(record, "Gespeicherte Dienst-Reparatur vorhanden", result.ServiceRepairAvailable.ToString());
            Add(record, "Zielcomputer", result.RemoteComputerName);
            Add(record, "Ziel-IP-Adresse", result.RemoteAddress);
            Add(record, "Zielfreigabe", result.RemoteShareName);
            if (!String.IsNullOrEmpty(result.RemoteComputerName) || !String.IsNullOrEmpty(result.RemoteAddress) || record.ClientWorkflow)
            {
                Add(record, "Windows-Zugriff geprüft", result.NativeConnectionVerified.ToString());
                Add(record, "Windows-Namenszugriff geprüft", result.NamedConnectionVerified.ToString());
                Add(record, "Freigabenliste des Zielcomputers geprüft", result.RemoteComputerEnumerationVerified.ToString());
                Add(record, "Anonyme Freigabenliste verweigert", result.AnonymousShareListDenied.ToString());
                Add(record, "Bestätigter Computername", result.RemoteName);
                Add(record, "Namens-Freigabepfad", result.NamedSharePath);
                Add(record, "Namenszugriff-Code", result.NamedAccessCode);
                Add(record, "Namenszugriff-Details", result.NamedAccessMessage);
                Add(record, "Gespeicherte Client-Reparatur vorhanden", result.ClientRepairAvailable.ToString());
            }
            Add(record, "Verbindungsangaben", result.ConnectionText);
            Add(record, "Wiederholungen", result.RetryCount.ToString(CultureInfo.InvariantCulture));
            Add(record, "Neustart erforderlich", result.RestartRequired.ToString());
            Add(record, "Vorgemerkter Computername", result.PendingComputerName);
            string resultCode = result.ErrorCode;
            if (!result.Success || !String.IsNullOrEmpty(resultCode)) Add(record, "Fehlercode", CodeOrMissing(resultCode));
            Add(record, "Fehlertyp", result.ErrorType);
            Add(record, "Aufrufliste", result.ErrorStackTrace);
            int index = 0;
            foreach (NetworkItem network in result.Networks ?? new NetworkItem[0])
            {
                if (network == null) continue;
                Section(record, "Netzwerk {0}", ++index);
                Add(record, "Netzwerkadapter-ID", network.Id.ToString(CultureInfo.InvariantCulture));
                Add(record, "Netzwerkname", network.Name);
                Add(record, "IP-Adresse", network.Address);
                Add(record, "Subnetz", network.Subnet);
                Add(record, "Netzwerkprofil", network.Category);
            }
            index = 0;
            foreach (CheckItem check in result.Checks ?? new CheckItem[0])
            {
                if (check == null) continue;
                if (AttentionState(check.State)) record.Attention = true;
                Section(record, "Prüfung {0}", ++index);
                Add(record, "Prüfungsname", CodeOrMissing(check.Name));
                Add(record, "Status", CodeOrMissing(check.State));
                Add(record, "Fehlercode", CodeOrMissing(check.Code));
                Add(record, "Ursache / Details", CodeOrMissing(check.Detail));
                Add(record, "Automatisch behebbar", check.Fixable.ToString());
                Add(record, "Nächster Schritt", CodeOrMissing(check.NextStep));
                Add(record, "Zugehörige Freigabe", check.TargetShare);
                Add(record, "Zieladresse der Prüfung", check.RemoteHost);
            }
            index = 0;
            foreach (RemoteShareItem share in result.RemoteShares ?? new RemoteShareItem[0])
            {
                if (share == null) continue;
                Section(record, "Gefundene entfernte Freigabe {0}", ++index);
                Add(record, "Freigabe", share.Name);
                Add(record, "Öffentliche Freigabebeschreibung", share.Remark);
                Add(record, "Gemeldeter Netzwerk-Benutzer", share.SuggestedUserName);
                Add(record, "Gemeldete Zugangsart", share.AccessMode);
                Add(record, "Verbindungsdaten formal geprüft", share.MetadataVerified.ToString());
            }
            index = 0;
            foreach (ShareItem share in result.Shares ?? new ShareItem[0])
            {
                if (share == null) continue;
                Section(record, "Erfasste Freigabe {0}", ++index);
                Add(record, "Freigabe", share.Name);
                Add(record, "Ausgewählter Ordner / Datenträger", share.Path);
                Add(record, "Im Netzwerk eingerichtet", share.Available.ToString());
                Add(record, "Vom Programm verwaltet", share.Managed.ToString());
                Add(record, "Zugriffsmodus", share.Mode);
                Add(record, "Ausgewählter Benutzer", share.UserName);
                Add(record, "Schreibzugriff", share.AllowWrite.ToString());
                Add(record, "Netzwerkadapter-ID", share.AdapterId.ToString(CultureInfo.InvariantCulture));
            }
        }

        private void AddException(Record record, Exception exception)
        {
            record.Attention = true;
            List<Exception> pending = new List<Exception> { exception };
            HashSet<Exception> seen = new HashSet<Exception>();
            int index = 0;
            while (pending.Count > 0 && index < 32)
            {
                Exception current = pending[0]; pending.RemoveAt(0);
                if (current == null || !seen.Add(current)) continue;
                Section(record, "Ausnahme {0}", ++index);
                Add(record, "Fehlertyp", current.GetType().FullName);
                Add(record, "Fehlermeldung", current.Message);
                Add(record, "HRESULT", "0x" + unchecked((uint)current.HResult).ToString("X8", CultureInfo.InvariantCulture) + " (" + current.HResult.ToString(CultureInfo.InvariantCulture) + ")");
                Win32Exception native = current as Win32Exception;
                Add(record, "Win32-Fehlercode", native == null ? "nicht bereitgestellt" : native.NativeErrorCode.ToString(CultureInfo.InvariantCulture));
                Add(record, "Aufrufliste", current.StackTrace);
                AggregateException aggregate = current as AggregateException;
                if (aggregate != null) foreach (Exception inner in aggregate.InnerExceptions) pending.Add(inner);
                else if (current.InnerException != null) pending.Add(current.InnerException);
            }
        }

        private static bool AttentionState(string state)
        {
            return String.Equals(state, "Error", StringComparison.OrdinalIgnoreCase) || String.Equals(state, "Warning", StringComparison.OrdinalIgnoreCase) || String.Equals(state, "Warn", StringComparison.OrdinalIgnoreCase) || String.Equals(state, "Failed", StringComparison.OrdinalIgnoreCase);
        }
        private static bool IsClientWorkflow(string action)
        {
            switch ((action ?? String.Empty).ToLowerInvariant())
            {
                case "inspectclient": case "prepareclient": case "enumeratecomputer":
                case "inspectremote": case "connectremote": case "repairclient": case "restoreclient": return true;
                default: return false;
            }
        }
        private static bool IsAnonymousListNotice(Record record, WorkerResult result)
        {
            return record.AnonymousListContext && result.AnonymousShareListDenied && !result.Success &&
                !result.ConnectionVerified && !result.NativeConnectionVerified && !result.NamedConnectionVerified && !result.RemoteComputerEnumerationVerified &&
                Regex.IsMatch(result.ErrorCode ?? String.Empty, @"^(?:Win32:\s*)?5(?:$|[;\s])", RegexOptions.CultureInvariant);
        }
        private static string CodeOrMissing(string code) { return String.IsNullOrWhiteSpace(code) ? "nicht bereitgestellt" : code; }
        private void Add(Record record, string label, string value)
        {
            if (String.IsNullOrEmpty(value)) return;
            record.Lines.Add(new ReportLine { Label = label, Value = Scrub(value, true) });
        }
        private static void Section(Record record, string format, int index)
        {
            record.Lines.Add(new ReportLine { Label = format, Number = index, IsSection = true });
        }
        private void Retain(Record record)
        {
            latest = record;
            if (!record.Attention) return;
            history.Add(record);
            if (history.Count > MaximumHistory) { history.RemoveAt(0); omittedHistory++; }
        }
        private void AppendRecord(StringBuilder report, Record record)
        {
            Line(report, "Erfasst (UTC)", record.Timestamp.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", CultureInfo.InvariantCulture));
            foreach (ReportLine line in record.Lines)
            {
                if (line.IsSection) { report.AppendLine(); report.AppendLine(I18n.Format(line.Label, line.Number)); }
                else Line(report, line.Label, line.Value);
            }
        }
        private void Line(StringBuilder report, string label, string value)
        {
            // Preserve raw codes, paths, adapter names and provider error messages verbatim.
            bool fixedValue = value == "nicht bereitgestellt" || label == "Ergebnis";
            report.Append(I18n.T(label)).Append(": ").AppendLine(Scrub(fixedValue ? I18n.T(value) : value, false));
        }
        private string Scrub(string value, bool bound)
        {
            if (String.IsNullOrEmpty(value)) return value ?? "";
            // Do this before truncation: a long credential must never survive as a prefix.
            List<string> ordered = new List<string>(secrets.Keys);
            ordered.Sort(delegate(string left, string right) { return right.Length.CompareTo(left.Length); });
            foreach (string secret in ordered) value = value.Replace(secret, "[ENTFERNT]");
            value = quotedCredential.Replace(value, "${key}${quote}[ENTFERNT]${quote}");
            value = plainCredential.Replace(value, "${key}[ENTFERNT]");
            value = addressCredential.Replace(value, "${prefix}[ENTFERNT]");
            if (bound && value.Length > MaximumFieldLength) value = value.Substring(0, MaximumFieldLength) + "\n[" + I18n.T("Langer Eintrag gekürzt") + "]";
            return value;
        }
        private void Release(string[] values)
        {
            lock (gate)
            {
                foreach (string value in values)
                {
                    int count;
                    if (!secrets.TryGetValue(value, out count)) continue;
                    if (count > 1) secrets[value] = count - 1; else secrets.Remove(value);
                }
            }
        }
        private sealed class SecretScope : IDisposable
        {
            private DiagnosticSession owner;
            private string[] values;
            internal SecretScope(DiagnosticSession session, string[] protectedValues) { owner = session; values = protectedValues; }
            public void Dispose()
            {
                if (owner == null) return;
                owner.Release(values); Array.Clear(values, 0, values.Length); values = null; owner = null;
            }
        }
        private sealed class Record { internal DateTime Timestamp; internal bool Attention, ClientWorkflow, AnonymousListContext; internal readonly List<ReportLine> Lines = new List<ReportLine>(); }
        private sealed class ReportLine { internal string Label, Value; internal int Number; internal bool IsSection; }
    }
}
