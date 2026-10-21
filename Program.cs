using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

[assembly: AssemblyTitle("Einfach Netzwerk")]
[assembly: AssemblyDescription("Ordner und Datenlaufwerke einfach im Heimnetz freigeben")]
[assembly: AssemblyCompany("Rene Box")]
[assembly: AssemblyProduct("Einfach Netzwerk")]
[assembly: AssemblyVersion("2.0.20.0")]
[assembly: AssemblyFileVersion("2.0.20.0")]

namespace EinfachNetzwerk
{
    internal static class Program
    {
        private static bool handlingError;
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 3 && args[0] == "--worker") return RunWorker(args[1], args[2]);
            if (args.Length == 0)
            {
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += delegate(object sender, System.Threading.ThreadExceptionEventArgs e) { HandleUnexpectedError(e.Exception); };
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                if (args.Length > 0 && args[0] == "--self-test") return SelfTests.Run(args.Length > 1 ? args[1] : null);
                if (args.Length == 2 && args[0] == "--render-preview")
                {
                    using (MainForm form = new MainForm(true)) { form.RenderPreview(Path.GetFullPath(args[1])); }
                    return 0;
                }
                if (args.Length >= 2 && args[0] == "--render-wizard-preview")
                {
                    if (args.Length == 3) I18n.Language = args[2];
                    MainForm.RenderWizardPreview(Path.GetFullPath(args[1]));
                    return 0;
                }
                if (args.Length == 3 && args[0] == "--render-preview-language")
                {
                    I18n.Language = args[2];
                    using (MainForm form = new MainForm(true)) { form.RenderPreview(Path.GetFullPath(args[1])); }
                    return 0;
                }
                Application.Run(new MainForm(false));
                return 0;
            }
            catch (Exception ex)
            {
                if (args.Length == 0) HandleUnexpectedError(ex);
                else { DiagnosticReports.Current.RecordException("Programmstart / Vorschau", ex); MessageBox.Show(ex.Message, "Einfach Netzwerk", MessageBoxButtons.OK, MessageBoxIcon.Error); }
                return 1;
            }
        }
        private static void HandleUnexpectedError(Exception error)
        {
            List<string> values = new List<string>();
            foreach (Form form in Application.OpenForms) FindPasswordValues(form, values);
            using (DiagnosticReports.Current.ProtectSecrets(values.ToArray()))
            {
                DiagnosticReports.Current.RecordException("Unerwarteter Programmfehler", error);
                if (handlingError) return;
                handlingError = true;
                try
                {
                    Form owner = Form.ActiveForm;
                    string message = DiagnosticReports.Current.Redact(error.Message) + "\n\n" + I18n.T("Ein unerwarteter Fehler ist aufgetreten. Möchtest du den Fehlerbericht als TXT speichern?");
                    if (MessageBox.Show(owner, message, I18n.T("Unerwarteter Programmfehler"), MessageBoxButtons.YesNo, MessageBoxIcon.Error) == DialogResult.Yes)
                        DiagnosticReports.Current.SaveReport(owner);
                }
                finally { handlingError = false; }
            }
        }
        private static void FindPasswordValues(Control control, List<string> values)
        {
            TextBox input = control as TextBox;
            if (input != null && (input.UseSystemPasswordChar || input.PasswordChar != '\0' || String.Equals(input.Name, "NetworkPassword", StringComparison.Ordinal)) && !String.IsNullOrEmpty(input.Text)) values.Add(input.Text);
            foreach (Control child in control.Controls) FindPasswordValues(child, values);
        }
        private static int RunWorker(string requestPath, string resultPath)
        {
            DirectoryGuard directoryGuard = null;
            bool safeOutput = false;
            try
            {
                requestPath = Path.GetFullPath(requestPath); resultPath = Path.GetFullPath(resultPath);
                string parent = Path.GetDirectoryName(requestPath);
                if (!String.Equals(parent, Path.GetDirectoryName(resultPath), StringComparison.OrdinalIgnoreCase) ||
                    Path.GetFileName(requestPath) != "Request.json" || Path.GetFileName(resultPath) != "Result.json")
                    throw new InvalidOperationException("Der Windows-Auftrag hat einen ungültigen Speicherort.");
                // Hold every ancestor without delete sharing. The requesting user cannot replace
                // a session or one of its parents with a junction while the elevated worker writes.
                directoryGuard = DirectoryGuard.Acquire(parent);
                safeOutput = true;
                string requestJson = DirectoryGuard.ReadRequest(requestPath);
                ShareRequest request = JsonData.Parse<ShareRequest>(requestJson);
                string error = RequestRules.Validate(request);
                if (error != null) throw new InvalidOperationException(error);
                bool admin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
                if (WorkerAuthorization.RequiresAdministrator(request) && !admin)
                    throw new InvalidOperationException("Diese Einrichtung benötigt Windows-Administratorrechte.");
                string script;
                using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("EinfachNetzwerk.ShareWorker.ps1"))
                {
                    if (resource == null) throw new InvalidOperationException("Das Windows-Modul fehlt.");
                    using (StreamReader reader = new StreamReader(resource, Encoding.UTF8)) script = reader.ReadToEnd();
                }
                using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("EinfachNetzwerk.ClientAccessWorker.ps1"))
                {
                    if (resource == null) throw new InvalidOperationException("Das Windows-Client-Modul fehlt.");
                    string clientScript;
                    using (StreamReader reader = new StreamReader(resource, Encoding.UTF8)) clientScript = reader.ReadToEnd();
                    int insertion = script.IndexOf("# Windows PowerShell", StringComparison.Ordinal);
                    if (insertion < 0) throw new InvalidOperationException("Das Windows-Modul hat ein unbekanntes Format.");
                    script = script.Insert(insertion, clientScript + Environment.NewLine);
                }
                using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("EinfachNetzwerk.ServiceHealthWorker.ps1"))
                {
                    if (resource == null) throw new InvalidOperationException("Das Windows-Dienst-Modul fehlt.");
                    string serviceScript;
                    using (StreamReader reader = new StreamReader(resource, Encoding.UTF8)) serviceScript = reader.ReadToEnd();
                    int insertion = script.IndexOf("# Windows PowerShell", StringComparison.Ordinal);
                    if (insertion < 0) throw new InvalidOperationException("Das Windows-Modul hat ein unbekanntes Format.");
                    script = script.Insert(insertion, serviceScript + Environment.NewLine);
                }
                // Run the embedded, trusted module in memory. An elevated process never executes
                // a script from a directory writable by an unelevated user.
                Type type = Assembly.Load("System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35").GetType("System.Management.Automation.PowerShell", true);
                object shell = type.GetMethod("Create", Type.EmptyTypes).Invoke(null, null);
                try
                {
                    type.GetMethod("AddScript", new[] { typeof(string) }).Invoke(shell, new object[] { script });
                    MethodInfo parameter = type.GetMethod("AddParameter", new[] { typeof(string), typeof(object) });
                    parameter.Invoke(shell, new object[] { "RequestPath", requestPath });
                    parameter.Invoke(shell, new object[] { "ResultPath", resultPath });
                    parameter.Invoke(shell, new object[] { "RequestJson", requestJson });
                    MethodInfo invoke = type.GetMethods().First(m => m.Name == "Invoke" && !m.IsGenericMethod && m.GetParameters().Length == 0);
                    invoke.Invoke(shell, null);
                    if (!File.Exists(resultPath)) throw new InvalidOperationException("Das Windows-Modul konnte kein Ergebnis erstellen.");
                    WorkerResult result = JsonData.Parse<WorkerResult>(File.ReadAllText(resultPath, Encoding.UTF8));
                    return result != null && result.Success ? 0 : 1;
                }
                finally { ((IDisposable)shell).Dispose(); }
            }
            catch (Exception ex)
            {
                Exception error = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException : ex;
                if (safeOutput)
                {
                    try
                    {
                        using (FileStream output = new FileStream(resultPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        using (StreamWriter writer = new StreamWriter(output, new UTF8Encoding(false)))
                            writer.Write(JsonData.Serialize(BackendClient.Failure(error.Message, error)));
                    }
                    catch { }
                }
                return 1;
            }
            finally { if (directoryGuard != null) directoryGuard.Dispose(); }
        }

        private sealed class DirectoryGuard : IDisposable
        {
            private readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();
            internal static DirectoryGuard Acquire(string directory)
            {
                string full = Path.GetFullPath(directory);
                string root = Path.GetPathRoot(full);
                if (root == null || root.StartsWith("\\\\", StringComparison.Ordinal) || root.Length != 3)
                    throw new InvalidOperationException("Der Windows-Auftrag muss auf einem lokalen Laufwerk liegen.");
                DirectoryGuard guard = new DirectoryGuard();
                try
                {
                    string current = root;
                    guard.Lock(current);
                    foreach (string part in full.Substring(root.Length).Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        current = Path.Combine(current, part);
                        guard.Lock(current);
                    }
                    return guard;
                }
                catch { guard.Dispose(); throw; }
            }
            private void Lock(string path)
            {
                SafeFileHandle handle = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
                if (handle.IsInvalid) { handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
                handles.Add(handle);
                AttributeTag information;
                if (!GetFileInformationByHandleEx(handle, 9, out information, (uint)Marshal.SizeOf(typeof(AttributeTag))))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if ((information.Attributes & 0x10) == 0 || (information.Attributes & 0x400) != 0)
                    throw new InvalidOperationException("Verknüpfte Auftragsverzeichnisse sind nicht erlaubt.");
            }
            internal static string ReadRequest(string path)
            {
                // Inspect and read the same no-follow handle; a replaced request cannot expose
                // privileged file contents through a JSON error message.
                using (SafeFileHandle handle = CreateFile(path, 0x80000000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero))
                {
                    if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                    AttributeTag information;
                    if (!GetFileInformationByHandleEx(handle, 9, out information, (uint)Marshal.SizeOf(typeof(AttributeTag))))
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    if ((information.Attributes & 0x400) != 0) throw new InvalidOperationException("Verknüpfte Auftragsdateien sind nicht erlaubt.");
                    using (FileStream input = new FileStream(handle, FileAccess.Read))
                    {
                        if (input.Length > 128 * 1024) throw new InvalidOperationException("Der Windows-Auftrag ist zu groß.");
                        using (StreamReader reader = new StreamReader(input, Encoding.UTF8)) return reader.ReadToEnd();
                    }
                }
            }
            public void Dispose() { for (int index = handles.Count - 1; index >= 0; index--) handles[index].Dispose(); handles.Clear(); }
            [StructLayout(LayoutKind.Sequential)]
            private struct AttributeTag { internal uint Attributes; internal uint ReparseTag; }
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int informationClass, out AttributeTag information, uint size);
        }
        internal static IDisposable LockDataFolder(string path) { return DirectoryGuard.Acquire(path); }
    }
}
