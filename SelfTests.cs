using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace EinfachNetzwerk
{
    public static class SelfTests
    {
        public static int Run(string reportPath)
        {
            List<string> passed = new List<string>();
            List<string> failed = new List<string>();
            Action<string, Action> check = delegate(string name, Action assertion)
            { try { assertion(); passed.Add(name); } catch (Exception ex) { failed.Add(name + ": " + ex.Message); } };
            check("Ungueltige Aktionen werden abgewiesen", delegate { Require(RequestRules.Validate(new ShareRequest { Action = "install-everything" }) != null); });
            check("Read-only Inspect benoetigt keinen Ordner", delegate { Require(RequestRules.Validate(new ShareRequest { Action = "Inspect" }) == null); });
            check("Reset-Inventur bleibt ohne Administratorrechte ausfuehrbar", delegate {
                Require(RequestRules.Validate(new ShareRequest { Action = "InspectResetShares" }) == null);
                foreach (string action in new[] { "Inspect", "InspectRemote", "ConnectRemote", "InspectServices", "InspectClient", "EnumerateComputer", "InspectResetShares" })
                {
                    Require(WorkerAuthorization.IsNonElevatedAction(action));
                    Require(!WorkerAuthorization.RequiresAdministrator(new ShareRequest { Action = action }));
                    Require(!WorkerAuthorization.RequiresAdministrator(new ShareRequest { Action = action.ToLowerInvariant() }));
                }
                foreach (string action in new[] { "Apply", "Repair", "Remove", "Restore", "Rename", "RepairSystem", "RemoveListedShare", "RepairClient", "RestoreClient", "PrepareClient", "RepairServices", "RestoreServices", "BackupReset" })
                {
                    Require(!WorkerAuthorization.IsNonElevatedAction(action));
                    Require(WorkerAuthorization.RequiresAdministrator(new ShareRequest { Action = action }));
                    Require(!WorkerAuthorization.RequiresAdministrator(new ShareRequest { Action = action, DryRun = true }));
                }
                Require(!WorkerAuthorization.IsNonElevatedAction("unknown") && !WorkerAuthorization.IsNonElevatedAction(null));
                Require(WorkerAuthorization.RequiresAdministrator(null));
            });
            check("Empfaengerpruefung benoetigt keine bekannten entfernten Freigaben", delegate {
                Require(RequestRules.Validate(new ShareRequest { Action = "InspectClient" }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "PrepareClient", Mode = "Guest", AllowGuestSettings = true }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "PrepareClient", Mode = "Guest" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "PrepareClient", Mode = "Password", AllowGuestSettings = true }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "PrepareClient", Mode = "Guest", AllowGuestSettings = true, ProtectedPassword = "not-used" }) != null);
            });
            check("Computeraufzaehlung verlangt kein erratenes Gastkonto", delegate {
                Require(RequestRules.Validate(new ShareRequest { Action = "EnumerateComputer", RemoteHost = "192.168.178.21", Mode = "Guest" }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "EnumerateComputer", RemoteHost = "TEST-NOTEBOOK", Mode = "Guest", RemoteUserName = @"TEST-NOTEBOOK\Gast" }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "EnumerateComputer", RemoteHost = "192.168.178.21", Mode = "Password" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "EnumerateComputer", RemoteHost = "8.8.8.8", Mode = "Guest" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "EnumerateComputer", RemoteHost = "192.168.178.21\\445", Mode = "Guest" }) != null);
            });
            check("Bestaetigte Freigabenliste bestaetigt noch keinen Ordnerzugriff", delegate {
                WorkerResult result = new WorkerResult { Success = true, RemoteComputerEnumerationVerified = true, RemoteShares = new[] { new RemoteShareItem { Name = "Desktop", AccessMode = "Guest", SuggestedUserName = @"TEST-NOTEBOOK\Gast", MetadataVerified = true } } };
                WorkerResult copy = JsonData.Parse<WorkerResult>(JsonData.Serialize(result));
                Require(copy.RemoteComputerEnumerationVerified && copy.RemoteShares.Length == 1 && copy.RemoteShares[0].Name == "Desktop" && copy.RemoteShares[0].MetadataVerified);
                Require(!copy.ConnectionVerified && !copy.NativeConnectionVerified && !copy.NamedConnectionVerified);
            });
            check("Verweigerte anonyme Liste bleibt von einer Ordnerpruefung getrennt", delegate {
                WorkerResult result = new WorkerResult { Success = false, ErrorCode = "Win32: 5", AnonymousShareListDenied = true };
                WorkerResult copy = JsonData.Parse<WorkerResult>(JsonData.Serialize(result));
                Require(copy.AnonymousShareListDenied && copy.ErrorCode == "Win32: 5" && !copy.Success && !copy.RemoteComputerEnumerationVerified);
                Require(!copy.ConnectionVerified && !copy.NativeConnectionVerified && !copy.NamedConnectionVerified);
                Require(!new WorkerResult { ErrorCode = "Win32: 5" }.AnonymousShareListDenied);
            });
            check("Remote-Aktionen verlangen eine genaue Datenfreigabe", delegate {
                foreach (string action in new[] { "InspectRemote", "ConnectRemote", "RepairClient" })
                    Require(RequestRules.Validate(new ShareRequest { Action = action, RemoteHost = "192.168.178.21", RemoteShareName = "Desktop", RemoteUserName = @"COMPUTER\Gast", Mode = "Guest" }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "RestoreClient" }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "InspectRemote", RemoteHost = "192.168.178.21\\445", RemoteShareName = "Desktop", RemoteUserName = @"COMPUTER\Gast", Mode = "Guest" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "InspectRemote", RemoteHost = "192.168.178.21", RemoteShareName = "C$", RemoteUserName = @"COMPUTER\Gast", Mode = "Guest" }) != null);
            });
            check("Uebersicht kann Ordner- und Laufwerksfreigaben entfernen", delegate {
                Require(RequestRules.Validate(new ShareRequest { Action = "RemoveListedShare", ShareName = "Fotos", FolderPath = @"D:\Fotos" }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "RemoveListedShare", ShareName = "Backup$", FolderPath = @"E:\" }) == null);
            });
            check("Entfernen aus Uebersicht verlangt einen genauen lokalen Eintrag", delegate {
                Require(RequestRules.Validate(new ShareRequest { Action = "RemoveListedShare", ShareName = "C$", FolderPath = @"C:\" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "RemoveListedShare", ShareName = "Fotos*", FolderPath = @"D:\Fotos" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "RemoveListedShare", ShareName = "Fotos", FolderPath = @"\\server\Fotos" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "RemoveListedShare", ShareName = "Fotos", FolderPath = @"D:Fotos" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "RemoveListedShare", ShareName = "Fotos" }) != null);
            });
            check("Administrative Namen werden abgewiesen", delegate { ShareRequest r = Valid(); r.ShareName = "C$"; Require(RequestRules.Validate(r) != null); });
            check("UNC-Quellen werden abgewiesen", delegate { ShareRequest r = Valid(); r.FolderPath = "\\\\server\\fremdeFreigabe"; Require(RequestRules.Validate(r) != null); });
            check("Systemlaufwerk wird nicht pauschal geoeffnet", delegate { ShareRequest r = Valid(); r.FolderPath = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)); r.AllowDriveRoot = true; Require(RequestRules.Validate(r) != null); });
            check("Gastmodus verlangt ausdrueckliche Zustimmung", delegate { ShareRequest r = Valid(); r.AllowGuestSettings = false; Require(RequestRules.Validate(r) != null); });
            check("JSON behandelt Sonderzeichen als Daten", delegate { ShareRequest r = Valid(); r.FolderPath = @"D:\Daten\Rene's Dateien; $(ignored)"; ShareRequest copy = JsonData.Parse<ShareRequest>(JsonData.Serialize(r)); Require(copy.FolderPath == r.FolderPath); });
            check("Kennwort wird mit Windows-DPAPI verschluesselt", delegate {
                string sample = "EinTest!KeineEchtenZugangsdaten42";
                string protectedValue = BackendClient.ProtectPassword(sample);
                Require(protectedValue.IndexOf(sample, StringComparison.Ordinal) < 0);
                byte[] restored = ProtectedData.Unprotect(Convert.FromBase64String(protectedValue), BackendClient.Entropy, DataProtectionScope.CurrentUser);
                try { Require(Encoding.UTF8.GetString(restored) == sample); } finally { Array.Clear(restored, 0, restored.Length); }
            });
            check("Verbindungsdaten und Listen ueberstehen JSON", delegate {
                WorkerResult r = new WorkerResult { Success = true, Address = "192.168.10.20", Shares = new[] { new ShareItem { Name = "Fotos", Path = @"D:\Fotos", Available = true, Managed = true, Mode = "Password", UserName = "NetzwerkUser", AdapterId = 17, AllowWrite = false }, new ShareItem { Name = "Entfernt", Path = @"D:\Alt", Available = false, Managed = true } } };
                WorkerResult copy = JsonData.Parse<WorkerResult>(JsonData.Serialize(r)); Require(copy.Shares[0].Mode == "Password" && !copy.Shares[0].AllowWrite && copy.Address == r.Address && copy.Shares[0].Available && !copy.Shares[1].Available);
            });
            check("PowerShell-Modul ist in der einzelnen EXE enthalten", delegate {
                using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("EinfachNetzwerk.ShareWorker.ps1")) { Require(stream != null && stream.Length > 0); }
            });
            check("Native Client-Pruefung ist in der einzelnen EXE enthalten", delegate {
                using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("EinfachNetzwerk.ClientAccessWorker.ps1")) { Require(stream != null && stream.Length > 0); }
                WorkerResult result = new WorkerResult { Success = true, ConnectionVerified = true, NativeConnectionVerified = true, RemoteAddress = "192.168.178.21", RemoteShareName = "Desktop", SharePath = @"\\192.168.178.21\Desktop", ClientRepairAvailable = true };
                WorkerResult copy = JsonData.Parse<WorkerResult>(JsonData.Serialize(result));
                Require(copy.NativeConnectionVerified && copy.ClientRepairAvailable && copy.RemoteAddress == result.RemoteAddress && copy.SharePath == result.SharePath);
            });
            check("Windows-PowerShell fuer In-Memory-Worker verfuegbar", delegate { Require(Assembly.Load("System.Management.Automation, Version=3.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35").GetType("System.Management.Automation.PowerShell") != null); });
            check("Namensverbindung bleibt auf den Gastmodus ohne Kennwort begrenzt", delegate {
                ShareRequest guest = new ShareRequest { Action = "ConnectRemote", Mode = "Guest", RemoteHost = "TEST-NOTEBOOK", RemoteShareName = "Desktop", RemoteUserName = @"TEST-NOTEBOOK\Gast", AllowNameConnection = true };
                Require(RequestRules.Validate(guest) == null);
                guest.ProtectedPassword = "must-not-reach-name-auth"; Require(RequestRules.Validate(guest) != null);
                guest.ProtectedPassword = null; guest.Mode = "Password"; Require(RequestRules.Validate(guest) != null);
                WorkerResult result = new WorkerResult { ConnectionVerified = true, NativeConnectionVerified = true, NamedConnectionVerified = false, RemoteName = "TEST-NOTEBOOK", NamedSharePath = @"\\TEST-NOTEBOOK\Desktop", NamedAccessCode = "Win32: 53", NamedAccessMessage = "name-access failed" };
                WorkerResult copy = JsonData.Parse<WorkerResult>(JsonData.Serialize(result));
                Require(copy.ConnectionVerified && !copy.NamedConnectionVerified && copy.NamedAccessCode == result.NamedAccessCode && copy.NamedSharePath == result.NamedSharePath);
            });
            check("Lokale Dienstpruefung ist eingebettet und von einer SMB-Verbindung getrennt", delegate {
                using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("EinfachNetzwerk.ServiceHealthWorker.ps1")) { Require(stream != null && stream.Length > 0); }
                foreach (string action in new[] { "InspectServices", "RepairServices", "RestoreServices" }) Require(RequestRules.Validate(new ShareRequest { Action = action }) == null);
                WorkerResult result = new WorkerResult { ServiceHealthVerified = true, ServiceRepairAvailable = true, ServiceBackupPath = "protected-service-state.json" };
                WorkerResult copy = JsonData.Parse<WorkerResult>(JsonData.Serialize(result));
                Require(copy.ServiceHealthVerified && copy.ServiceRepairAvailable && !copy.ConnectionVerified && !copy.NativeConnectionVerified && copy.ServiceBackupPath == result.ServiceBackupPath);
            });
            check("Vorschau-Aktionen veraendern kein Windows", delegate { MainForm.RunPreviewSelfTest(); });
            check("Computernamen werden ohne Freigabe validiert", delegate {
                Require(RequestRules.Validate(new ShareRequest { Action = "Rename", ComputerName = "Mein-NetzwerkPC" }) == null);
                Require(RequestRules.Validate(new ShareRequest { Action = "Rename", ComputerName = "12345" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "Rename", ComputerName = "PC\\445" }) != null);
                Require(RequestRules.Validate(new ShareRequest { Action = "Rename", ComputerName = "DieserNameIstZuLang" }) != null);
            });
            check("Sieben Sprachen erhalten Daten und Platzhalter", delegate { I18n.RunSelfTest(); });
            string json = JsonData.Serialize(new { Success = failed.Count == 0, Passed = passed, Failed = failed, Scope = "Isolierte Validierung, DPAPI, eingebetteter Worker, UI-Vorschau; keine Freigabe, Benutzer-, Firewall- oder Windows-Aenderung." });
            if (reportPath != null) File.WriteAllText(Path.GetFullPath(reportPath), json, new UTF8Encoding(false));
            return failed.Count == 0 ? 0 : 1;
        }
        private static ShareRequest Valid() { return new ShareRequest { Action = "Apply", FolderPath = @"D:\Daten", ShareName = "Daten", Mode = "Guest", AdapterId = 17, AllowGuestSettings = true }; }
        private static void Require(bool condition) { if (!condition) throw new InvalidOperationException("Erwartung nicht erfuellt."); }
    }
}
