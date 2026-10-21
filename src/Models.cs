using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace EinfachNetzwerk
{
    public static class AppInfo { public const string Version = "2.0.19"; }

    public sealed class ShareRequest
    {
        public string Action { get; set; }
        public string FolderPath { get; set; }
        public string ShareName { get; set; }
        public string Mode { get; set; }
        public string UserName { get; set; }
        public string ProtectedPassword { get; set; }
        public string OriginalUserSid { get; set; }
        public string BackupPath { get; set; }
        public int AdapterId { get; set; }
        public bool AllowWrite { get; set; }
        public bool AllowDriveRoot { get; set; }
        public bool AllowGuestSettings { get; set; }
        public bool DryRun { get; set; }
        public bool AllowAdvancedRepair { get; set; }
        public string ComputerName { get; set; }
        public string RemoteHost { get; set; }
        public string RemoteShareName { get; set; }
        public string RemoteUserName { get; set; }
        public bool AllowNameConnection { get; set; }
    }

    public sealed class WorkerResult
    {
        public bool Success { get; set; }
        public bool WizardReceiverRequested { get; set; }
        public bool WizardReceiverReady { get; set; }
        public bool InspectionIncomplete { get; set; }
        public string Message { get; set; }
        public string ErrorCode { get; set; }
        public string ErrorType { get; set; }
        public string ErrorStackTrace { get; set; }
        public string ComputerName { get; set; }
        public string Address { get; set; }
        public string SharePath { get; set; }
        public string ConnectionText { get; set; }
        public string LoginUserName { get; set; }
        public bool ConnectionVerified { get; set; }
        public bool NativeConnectionVerified { get; set; }
        public bool RemoteComputerEnumerationVerified { get; set; }
        public bool AnonymousShareListDenied { get; set; }
        public RemoteShareItem[] RemoteShares { get; set; }
        public string RemoteComputerName { get; set; }
        public string RemoteAddress { get; set; }
        public string RemoteShareName { get; set; }
        public bool NamedConnectionVerified { get; set; }
        public string RemoteName { get; set; }
        public string NamedSharePath { get; set; }
        public string NamedAccessCode { get; set; }
        public string NamedAccessMessage { get; set; }
        public bool ClientRepairAvailable { get; set; }
        public string ClientBackupPath { get; set; }
        public bool ServiceHealthVerified { get; set; }
        public bool ServiceRepairAvailable { get; set; }
        public string ServiceBackupPath { get; set; }
        public string BackupPath { get; set; }
        public string PendingComputerName { get; set; }
        public bool RestartRequired { get; set; }
        public int RetryCount { get; set; }
        public CheckItem[] Checks { get; set; }
        public NetworkItem[] Networks { get; set; }
        public ShareItem[] Shares { get; set; }
        public WorkerResult() { Checks = new CheckItem[0]; Networks = new NetworkItem[0]; Shares = new ShareItem[0]; RemoteShares = new RemoteShareItem[0]; }
    }
    public sealed class RemoteShareItem
    {
        public string Name { get; set; }
        public string Remark { get; set; }
        public string SuggestedUserName { get; set; }
        public string AccessMode { get; set; }
        public bool MetadataVerified { get; set; }
    }
    public sealed class CheckItem { public string Name { get; set; } public string State { get; set; } public string Detail { get; set; } public string Code { get; set; } public bool Fixable { get; set; } public string NextStep { get; set; } public string TargetShare { get; set; } public string RemoteHost { get; set; } }
    public sealed class NetworkItem
    {
        public int Id { get; set; }
        public string Name { get; set; }
        public string Address { get; set; }
        public string Subnet { get; set; }
        public string Category { get; set; }
        public override string ToString() { return Name + "  ·  " + Address + "  (" + Category + ")"; }
    }
    public sealed class ShareItem
    {
        public string Name { get; set; }
        public string Path { get; set; }
        public bool Available { get; set; }
        public bool Managed { get; set; }
        public string Mode { get; set; }
        public string UserName { get; set; }
        public bool AllowWrite { get; set; }
        public int AdapterId { get; set; }
        public override string ToString() { return Name + "  ·  " + Path + (Managed ? "  [vom Programm verwaltet]" : ""); }
    }

    public static class JsonData
    {
        public static string Serialize(object data) { return new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 }.Serialize(data); }
        public static T Parse<T>(string json) { return new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 }.Deserialize<T>(json); }
    }

    public static class RequestRules
    {
        public static string Validate(ShareRequest request)
        {
            if (request == null) return "Der Auftrag fehlt.";
            string action = (request.Action ?? "").ToLowerInvariant();
            if (!new[] { "inspect", "apply", "repair", "remove", "restore", "rename", "repairsystem", "removelistedshare", "inspectremote", "connectremote", "repairclient", "restoreclient", "inspectservices", "repairservices", "restoreservices", "inspectclient", "prepareclient", "enumeratecomputer", "backupreset", "inspectresetshares" }.Contains(action)) return "Unbekannte Aktion.";
            if (action == "inspect" || action == "inspectresetshares") return null;
            if (action == "backupreset") return null;
            if (action == "inspectclient") return null;
            if (action == "prepareclient")
            {
                if (!String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) || !request.AllowGuestSettings) return "Die Einrichtung für passwortfreien Netzwerkzugriff benötigt deine ausdrückliche Zustimmung.";
                if (!String.IsNullOrEmpty(request.ProtectedPassword)) return "Die Einrichtung des Windows-Clients verwendet kein Netzwerk-Passwort.";
                if (request.AdapterId < 0) return "Bitte eine aktive Heimnetzverbindung auswählen.";
                return null;
            }
            if (action == "inspectservices" || action == "repairservices" || action == "restoreservices") return null;
            if (action == "restoreclient") return null;
            if (action == "inspectremote" || action == "connectremote" || action == "repairclient" || action == "enumeratecomputer")
            {
                if (request.AllowNameConnection && (!String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) || !String.IsNullOrEmpty(request.ProtectedPassword)))
                    return "Die Verbindung über den Computernamen verwendet ausschließlich den Gastmodus mit leerem Passwort.";
                string host = request.RemoteHost ?? String.Empty;
                System.Net.IPAddress parsed;
                if (host.Length == 0 || host.Length > 253 || host != host.Trim() || host.Contains("..") ||
                    !(Regex.IsMatch(host, @"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$") || System.Net.IPAddress.TryParse(host, out parsed)))
                    return "Bitte eine lokale IPv4-Adresse oder einen gültigen Computernamen ohne Port und Pfad eingeben.";
                if (System.Net.IPAddress.TryParse(host, out parsed))
                {
                    byte[] bytes = parsed.GetAddressBytes();
                    if (!Regex.IsMatch(host, @"^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$") || host != parsed.ToString() ||
                        parsed.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork ||
                        !(bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168)))
                        return "Die Verbindung ist auf die private IPv4-Adresse eines Computers im Heimnetz beschränkt.";
                }
                else if (Regex.IsMatch(host, @"^[0-9.]+$") || host.Split('.').Any(label => label.Length > 63 || !Regex.IsMatch(label, @"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")))
                    return "Bitte eine lokale IPv4-Adresse oder einen gültigen Computernamen ohne Port und Pfad eingeben.";
                string name = request.RemoteShareName ?? String.Empty;
                if (action != "enumeratecomputer" && (String.IsNullOrWhiteSpace(name) || name.Length > 80 || name.Trim() != name || name.EndsWith(".") ||
                    Regex.IsMatch(name, @"[\\/\[\]:;|=,+*?<>""\x00-\x1f]") || Regex.IsMatch(name, @"^(?:ADMIN\$?|IPC\$?|[A-Z]\$)$", RegexOptions.IgnoreCase)))
                    return "Bitte den Namen einer Datenfreigabe eingeben, zum Beispiel Desktop.";
                if (!String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) && !String.Equals(request.Mode, "Password", StringComparison.OrdinalIgnoreCase))
                    return "Bitte einen Zugriffsmodus auswählen.";
                string login = request.RemoteUserName ?? String.Empty;
                if (action == "enumeratecomputer" && login.Length == 0 && String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase) && String.IsNullOrEmpty(request.ProtectedPassword)) return null;
                if (String.IsNullOrWhiteSpace(login) || login.Length > 256 || login != login.Trim() || Regex.IsMatch(login, @"[/\x00-\x1f\x7f]") ||
                    !Regex.IsMatch(login, @"^[^\\]+(?:\\[^\\]+)?$"))
                    return "Bitte den angezeigten Netzwerk-Benutzernamen des anderen Computers eintragen.";
                return null;
            }
            if (action == "removelistedshare")
            {
                string name = request.ShareName ?? "";
                if (String.IsNullOrWhiteSpace(name) || name.Length > 80 || name.Trim() != name || name.EndsWith(".") ||
                    Regex.IsMatch(name, @"[\\/\[\]:;|=,+*?<>""\x00-\x1f]") || Regex.IsMatch(name, @"^(?:ADMIN\$?|IPC\$?|[A-Z]\$)$", RegexOptions.IgnoreCase))
                    return "Bitte eine vorhandene Datenfreigabe auswählen. Windows-Systemfreigaben werden nicht entfernt.";
                if (String.IsNullOrWhiteSpace(request.FolderPath) || !Regex.IsMatch(request.FolderPath, @"^[A-Za-z]:[\\/]"))
                    return "Der ausgewählte lokale Freigabeordner fehlt oder ist ungültig.";
                try { Path.GetFullPath(request.FolderPath); }
                catch (Exception) { return "Der ausgewählte lokale Freigabeordner fehlt oder ist ungültig."; }
                return null;
            }
            if (action == "repairsystem") return request.AllowAdvancedRepair ? null : "Bitte die automatische Blockaden-Reparatur aktivieren.";
            if (action == "rename")
            {
                string name = request.ComputerName ?? "";
                if (!Regex.IsMatch(name, "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$") || Regex.IsMatch(name, "^[0-9]+$"))
                    return "Der Computername muss 1 bis 15 Buchstaben, Ziffern oder Bindestriche enthalten, mit einem Buchstaben oder einer Ziffer beginnen und enden und darf nicht nur aus Ziffern bestehen.";
                return null;
            }
            if (String.IsNullOrWhiteSpace(request.ShareName) || request.ShareName.Length > 80 ||
                Regex.IsMatch(request.ShareName, "[\\\\/\\[\\]:;|=,+*?<>\"$\\x00-\\x1f]") || request.ShareName.Trim() != request.ShareName || request.ShareName.EndsWith(".") ||
                String.Equals(request.ShareName, "ADMIN", StringComparison.OrdinalIgnoreCase) || String.Equals(request.ShareName, "IPC", StringComparison.OrdinalIgnoreCase))
                return "Bitte einen Freigabenamen ohne Sonderzeichen oder abschließenden Punkt eingeben.";
            if (action == "remove" || action == "restore") return null;
            if (request.Mode != "guest" && request.Mode != "password" && request.Mode != "Guest" && request.Mode != "Password") return "Bitte einen Zugriffsmodus auswählen.";
            if (String.IsNullOrWhiteSpace(request.FolderPath) || request.FolderPath.StartsWith("\\\\") || !Path.IsPathRooted(request.FolderPath)) return "Bitte einen lokalen Ordner oder Datenträger auswählen.";
            try
            {
                string full = Path.GetFullPath(request.FolderPath);
                string root = Path.GetPathRoot(full);
                if (String.Equals(full.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) && !request.AllowDriveRoot)
                    return "Die Freigabe des gesamten Datenträgers muss ausdrücklich bestätigt werden.";
                string systemRoot = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows));
                if (String.Equals(full.TrimEnd('\\'), systemRoot.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                    return "Auf dem Windows-Systemlaufwerk bitte einen Datenordner auswählen. Das gesamte Windows-Laufwerk wird nicht pauschal geöffnet.";
            }
            catch (Exception) { return "Der Ordnerpfad ist ungültig."; }
            if (request.AdapterId <= 0) return "Bitte eine aktive Heimnetzverbindung auswählen.";
            if (String.Equals(request.Mode, "guest", StringComparison.OrdinalIgnoreCase) && !request.AllowGuestSettings)
                return "Bitte den Gastzugang und seine Windows-Einstellungen ausdrücklich bestätigen.";
            if (String.Equals(request.Mode, "password", StringComparison.OrdinalIgnoreCase) &&
                (String.IsNullOrWhiteSpace(request.UserName) || request.UserName.Length > 20 || Regex.IsMatch(request.UserName, "[\\\\/\\[\\]:;|=,+*?<>\"@\\x00-\\x1f]")))
                return "Bitte einen gültigen lokalen Netzwerk-Benutzernamen eingeben (maximal 20 Zeichen).";
            return null;
        }
    }
}
