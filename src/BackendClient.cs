using System;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    public static class BackendClient
    {
        internal static readonly byte[] Entropy = Encoding.UTF8.GetBytes("EinfachNetzwerk-v1");
        public static IDisposable LockDataFolder(string path) { return Program.LockDataFolder(path); }
        public static string ProtectPassword(string password)
        {
            byte[] plain = Encoding.UTF8.GetBytes(password ?? "");
            try { return Convert.ToBase64String(ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser)); }
            finally { Array.Clear(plain, 0, plain.Length); }
        }
        public static Task<WorkerResult> RunAsync(ShareRequest request, bool elevated, Action<string> progress)
        {
            return RunAsync(request, elevated, progress, null);
        }
        public static Task<WorkerResult> RunAsync(ShareRequest request, bool elevated, Action<string> progress, Action<WorkProgress> countedProgress)
        {
            SynchronizationContext context = SynchronizationContext.Current;
            return Task.Run(delegate { return Execute(request, elevated, progress, countedProgress, context); });
        }
        private static WorkerResult Execute(ShareRequest request, bool elevated, Action<string> progress, Action<WorkProgress> countedProgress, SynchronizationContext context)
        {
            string operation = null;
            WorkProgress lastCounted = null;
            try
            {
                string validation = RequestRules.Validate(request);
                if (validation != null) return Failure(validation);
                // Every caller uses the same action classification as RunWorker.
                // A requested elevation cannot turn a pure inventory into a UAC prompt.
                elevated = elevated && WorkerAuthorization.RequiresAdministrator(request);
                if (String.IsNullOrWhiteSpace(request.OriginalUserSid)) request.OriginalUserSid = WindowsIdentity.GetCurrent().User.Value;
                string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EinfachNetzwerk", "Sessions");
                operation = Path.Combine(root, Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(operation);
                DirectorySecurity security = new DirectorySecurity();
                security.SetAccessRuleProtection(true, false);
                foreach (SecurityIdentifier sid in new[] { WindowsIdentity.GetCurrent().User,
                    new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null) })
                    security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                new DirectoryInfo(operation).SetAccessControl(security);
                string requestPath = Path.Combine(operation, "Request.json");
                string resultPath = Path.Combine(operation, "Result.json");
                File.WriteAllText(requestPath, JsonData.Serialize(request), new UTF8Encoding(false));
                Notify(progress, context, elevated ? "Windows-Administratorfreigabe abwarten …" : "Windows und Netzwerk prüfen …");
                ProcessStartInfo start = new ProcessStartInfo(Application.ExecutablePath, "--worker " + Quote(requestPath) + " " + Quote(resultPath));
                start.UseShellExecute = elevated;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                start.CreateNoWindow = true;
                if (elevated) start.Verb = "runas";
                using (Process worker = Process.Start(start))
                {
                    Notify(progress, context, elevated ? "Freigabe und Windows-Einstellungen bearbeiten …" : "Dienste, Zugriffsrechte und Verbindung prüfen …");
                    Stopwatch timer = Stopwatch.StartNew();
                    string lastPhase = "";
                    while (!worker.WaitForExit(250))
                    {
                        string phasePath = resultPath + ".phase";
                        if (File.Exists(phasePath))
                        {
                            try
                            {
                                string phase;
                                using (FileStream input = new FileStream(phasePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                                using (StreamReader reader = new StreamReader(input, Encoding.UTF8)) phase = reader.ReadToEnd().Trim();
                                if (phase.Length > 0 && phase != lastPhase)
                                {
                                    lastPhase = phase;
                                    WorkProgress snapshot = NotifyPhase(progress, countedProgress, context, phase);
                                    if (snapshot != null) lastCounted = snapshot;
                                }
                            }
                            catch (IOException) { }
                        }
                        if (!elevated && timer.Elapsed > TimeSpan.FromMinutes(3))
                        {
                            worker.Kill();
                            return Failure("Die reine Prüfung hat zu lange gedauert. Bitte erneut prüfen; eine Windows-Richtlinie oder ein Dienst kann den Zugriff blockieren.", new TimeoutException("Der Prüfprozess hat nach drei Minuten kein Ergebnis geliefert."));
                        }
                    }
                    if (!File.Exists(resultPath)) return Failure("Windows hat kein Prüfergebnis geliefert. Bitte erneut versuchen. Fehlercode: " + worker.ExitCode + ".", "Prozess-Exitcode: " + worker.ExitCode, "WorkerProcess", null);
                    // A short worker may finish between polls. Read its last counted snapshot too.
                    string finalPhasePath = resultPath + ".phase";
                    if (File.Exists(finalPhasePath))
                    {
                        try
                        {
                            WorkProgress snapshot = NotifyPhase(progress, countedProgress, context, File.ReadAllText(finalPhasePath, Encoding.UTF8));
                            if (snapshot != null) lastCounted = snapshot;
                        }
                        catch (IOException) { }
                    }
                }
                WorkerResult result = JsonData.Parse<WorkerResult>(File.ReadAllText(resultPath, Encoding.UTF8));
                if (result != null && result.Success)
                {
                    int total = lastCounted == null ? 1 : lastCounted.Total;
                    NotifyCounted(countedProgress, context, new WorkProgress { Text = result.Message, Completed = total, Total = total, Percent = 100, ResultAccepted = true });
                }
                return result ?? Failure("Das Windows-Ergebnis konnte nicht gelesen werden.");
            }
            catch (System.ComponentModel.Win32Exception ex)
            {
                return Failure(ex.NativeErrorCode == 1223 ? "Die Windows-Administratorfreigabe wurde abgebrochen. Es wurde keine Einrichtung gestartet." : "Windows konnte die Einrichtung nicht starten: " + ex.Message, ex);
            }
            catch (Exception ex) { return Failure("Die Aktion konnte nicht abgeschlossen werden: " + ex.Message, ex); }
            finally
            {
                // Delete only the sensitive request; retain diagnostic data if an error needs inspection.
                if (operation != null)
                {
                    try { string requestPath = Path.Combine(operation, "Request.json"); if (File.Exists(requestPath)) File.Delete(requestPath); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
                if (request != null) request.ProtectedPassword = null;
            }
        }
        private static void Notify(Action<string> progress, SynchronizationContext context, string phase)
        {
            if (progress == null) return;
            if (context == null) progress(phase); else context.Post(delegate { progress(phase); }, null);
        }
        private static WorkProgress NotifyPhase(Action<string> progress, Action<WorkProgress> countedProgress, SynchronizationContext context, string phase)
        {
            WorkProgress counted = WorkProgress.Read(phase);
            if (counted == null)
            {
                // Accept legacy plain-text workers, but do not display partial JSON as a phase.
                if (!phase.TrimStart().StartsWith("{", StringComparison.Ordinal)) Notify(progress, context, phase);
                return null;
            }
            Notify(progress, context, counted.Text ?? String.Empty);
            NotifyCounted(countedProgress, context, counted);
            return counted;
        }
        private static void NotifyCounted(Action<WorkProgress> callback, SynchronizationContext context, WorkProgress counted)
        {
            if (callback == null) return;
            if (context == null) callback(counted);
            else context.Post(delegate { callback(counted); }, null);
        }
        internal static string Quote(string value)
        {
            if (value.IndexOf('"') >= 0 || value.IndexOf('\r') >= 0 || value.IndexOf('\n') >= 0) throw new ArgumentException("Ungültiger Dateipfad.");
            return "\"" + value + "\"";
        }
        internal static WorkerResult Failure(string message)
        {
            return Failure(message, null, null, null);
        }
        internal static WorkerResult Failure(string message, Exception error)
        {
            if (error == null) return Failure(message);
            StringBuilder codes = new StringBuilder();
            Exception current = error;
            for (int depth = 0; current != null && depth < 16; depth++, current = current.InnerException)
            {
                if (depth > 0) codes.Append("; InnerException[" + depth + "]: ");
                codes.Append("HRESULT: 0x" + current.HResult.ToString("X8", System.Globalization.CultureInfo.InvariantCulture));
                System.ComponentModel.Win32Exception native = current as System.ComponentModel.Win32Exception;
                if (native != null) codes.Append("; Win32: " + native.NativeErrorCode.ToString(System.Globalization.CultureInfo.InvariantCulture));
            }
            return Failure(message, codes.ToString(), error.GetType().FullName, error.ToString());
        }
        private static WorkerResult Failure(string message, string code, string errorType, string stackTrace)
        {
            return new WorkerResult { Success = false, Message = message, ErrorCode = code, ErrorType = errorType, ErrorStackTrace = stackTrace,
                Checks = new[] { new CheckItem { Name = "Aktion", State = "error", Detail = message, Code = code } } };
        }
    }
}
