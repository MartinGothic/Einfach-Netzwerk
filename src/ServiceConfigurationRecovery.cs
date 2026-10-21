using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;
using System.Xml;
using Microsoft.Win32;

namespace EinfachNetzwerk
{
    // Recovery definitions come from this installation's protected Windows component
    // manifests. No downloaded registry files or caller-supplied definitions are used.
    public static class ServiceConfigurationRecovery
    {
        const string TrustedInstallerSid = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";
        const int MaxManifestBytes = 4 * 1024 * 1024;
        const string AsmNamespace = "urn:schemas-microsoft-com:asm.v3";
        static readonly string WindowsPath = Environment.GetFolderPath(Environment.SpecialFolder.Windows);

        public static string GetPlanJson(string name)
        {
            return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.Serialize(GetPlan(name));
        }

        public static string ReadServerMetadataJson()
        {
            using (RegistryKey service = Registry.LocalMachine.OpenSubKey("SYSTEM\\CurrentControlSet\\Services\\LanmanServer", false))
            {
                if (service == null) throw new InvalidDataException("Der lokale SMB-Server-Dienstschlüssel fehlt.");
                return MetadataSerializer().Serialize(ReadServerMetadata(service));
            }
        }

        // The worker supplies Before/Expected only from its protected, fixed own
        // journal. This method never accepts a registry path or arbitrary names.
        public static string RestoreServerMetadataJson(string beforeJson, string expectedJson)
        {
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
                throw new UnauthorizedAccessException("Die Windows-Dienstreparatur benötigt Administratorrechte.");
            JavaScriptSerializer serializer = MetadataSerializer();
            ServerMetadata before = serializer.Deserialize<ServerMetadata>(beforeJson);
            ServerMetadata expected = serializer.Deserialize<ServerMetadata>(expectedJson);
            ValidateMetadata(before); ValidateMetadata(expected);
            using (RegistryKey service = Registry.LocalMachine.OpenSubKey("SYSTEM\\CurrentControlSet\\Services\\LanmanServer", true))
            {
                if (service == null) throw new InvalidDataException("Der lokale SMB-Server-Dienstschlüssel fehlt.");
                return serializer.Serialize(RestoreServerMetadata(service, before, expected));
            }
        }

        static JavaScriptSerializer MetadataSerializer() { return new JavaScriptSerializer { MaxJsonLength = 256 * 1024, RecursionLimit = 12 }; }
        static readonly string[] ServerMetadataNames = { "ServiceDll", "ServiceDllUnloadOnStop" };
        static ServerMetadata ReadServerMetadata(RegistryKey service)
        {
            ServerMetadata snapshot = new ServerMetadata { Values = new List<ServerMetadataValue>() };
            using (RegistryKey parameters = service.OpenSubKey("Parameters", false))
            {
                snapshot.ParametersKeyExists = parameters != null;
                foreach (string name in ServerMetadataNames)
                {
                    ServerMetadataValue value = new ServerMetadataValue { Name = name };
                    if (parameters != null && parameters.GetValueNames().Contains(name, StringComparer.OrdinalIgnoreCase))
                    {
                        value.Exists = true;
                        RegistryValueKind kind = parameters.GetValueKind(name);
                        value.Kind = kind.ToString();
                        object content = parameters.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                        switch (kind)
                        {
                            case RegistryValueKind.String:
                            case RegistryValueKind.ExpandString: value.Text = (string)content; break;
                            case RegistryValueKind.MultiString: value.Strings = (string[])content; break;
                            case RegistryValueKind.DWord:
                            case RegistryValueKind.QWord: value.Number = Convert.ToInt64(content, System.Globalization.CultureInfo.InvariantCulture); break;
                            case RegistryValueKind.Binary:
                            case RegistryValueKind.None: value.Binary = Convert.ToBase64String((byte[])content); break;
                            default: throw new InvalidDataException("Nicht unterstützter Typ in der SMB-Dienstregistrierung.");
                        }
                    }
                    snapshot.Values.Add(value);
                }
            }
            ValidateMetadata(snapshot); return snapshot;
        }
        static void ValidateMetadata(ServerMetadata snapshot)
        {
            if (snapshot == null || snapshot.Values == null || snapshot.Values.Count != 2
                || ServerMetadataNames.Any(name => snapshot.Values.Count(value => value != null && value.Name == name) != 1)
                || (!snapshot.ParametersKeyExists && snapshot.Values.Any(value => value.Exists)))
                throw new InvalidDataException("Die SMB-Dienstsicherung hat ein ungültiges Format.");
            foreach (ServerMetadataValue value in snapshot.Values)
            {
                if (!value.Exists) continue;
                if ((value.Text != null && value.Text.Length > 32768)
                    || (value.Strings != null && (value.Strings.Length > 1024 || value.Strings.Any(item => item == null || item.Length > 32768)))
                    || (value.Binary != null && value.Binary.Length > 87384))
                    throw new InvalidDataException("Die SMB-Dienstsicherung überschreitet die erlaubte Größe.");
                switch (value.Kind)
                {
                    case "String": case "ExpandString": if (value.Text == null) throw new InvalidDataException("Diensttext fehlt."); break;
                    case "MultiString": if (value.Strings == null) throw new InvalidDataException("Diensttextliste fehlt."); break;
                    case "DWord": if (value.Number < Int32.MinValue || value.Number > Int32.MaxValue) throw new InvalidDataException("Ungültiger DWORD-Wert."); break;
                    case "QWord": break;
                    case "Binary": case "None": if (value.Binary == null) throw new InvalidDataException("Dienstbytes fehlen."); Convert.FromBase64String(value.Binary); break;
                    default: throw new InvalidDataException("Nicht zugelassener SMB-Dienstsicherungstyp.");
                }
            }
        }
        static bool SameMetadataValue(ServerMetadataValue first, ServerMetadataValue second)
        {
            if (first.Exists != second.Exists) return false;
            if (!first.Exists) return true;
            if (first.Kind != second.Kind) return false;
            switch (first.Kind)
            {
                case "String": case "ExpandString": return first.Text == second.Text;
                case "MultiString": return first.Strings.SequenceEqual(second.Strings, StringComparer.Ordinal);
                case "DWord": case "QWord": return first.Number == second.Number;
                default: return first.Binary == second.Binary;
            }
        }
        static ServerMetadataRestore RestoreServerMetadata(RegistryKey service, ServerMetadata before, ServerMetadata expected)
        {
            ValidateMetadata(before); ValidateMetadata(expected);
            ServerMetadata actual = ReadServerMetadata(service);
            ServerMetadataRestore outcome = new ServerMetadataRestore { Restored = new List<string>(), Preserved = new List<string>() };
            foreach (string name in ServerMetadataNames)
            {
                ServerMetadataValue current = actual.Values.Single(value => value.Name == name);
                ServerMetadataValue saved = before.Values.Single(value => value.Name == name);
                ServerMetadataValue own = expected.Values.Single(value => value.Name == name);
                if (!SameMetadataValue(current, own)) { outcome.Preserved.Add(name); continue; }
                if (SameMetadataValue(current, saved)) continue;
                using (RegistryKey parameters = service.CreateSubKey("Parameters"))
                {
                    if (!saved.Exists) parameters.DeleteValue(name, false);
                    else
                    {
                        RegistryValueKind kind = (RegistryValueKind)Enum.Parse(typeof(RegistryValueKind), saved.Kind);
                        object content;
                        switch (kind)
                        {
                            case RegistryValueKind.String: case RegistryValueKind.ExpandString: content = saved.Text; break;
                            case RegistryValueKind.MultiString: content = saved.Strings; break;
                            case RegistryValueKind.DWord: content = (int)saved.Number; break;
                            case RegistryValueKind.QWord: content = saved.Number; break;
                            default: content = Convert.FromBase64String(saved.Binary); break;
                        }
                        parameters.SetValue(name, content, kind);
                    }
                }
                outcome.Restored.Add(name);
            }
            if (!before.ParametersKeyExists)
            {
                bool empty;
                using (RegistryKey parameters = service.OpenSubKey("Parameters", false))
                    empty = parameters != null && parameters.ValueCount == 0 && parameters.SubKeyCount == 0;
                if (empty) { service.DeleteSubKey("Parameters", false); outcome.ParametersKeyRemoved = true; }
            }
            return outcome;
        }

        // The worker takes a protected backup and validates the Microsoft signatures
        // before calling this method. Rebuild the plan here instead of accepting JSON.
        public static string Repair(string name)
        {
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
                throw new UnauthorizedAccessException("Die Windows-Dienstreparatur benötigt Administratorrechte.");
            RecoveryPlan plan = GetPlan(name);
            // SMB settings, saved shares and network permissions are independent
            // from the service DLL registration. Repair only this owned metadata.
            // SCM startup/dependency health is handled by the service worker with
            // its own protected snapshot before starting the service.
            if (plan.Name == "LanmanServer")
            {
                using (RegistryKey service = Registry.LocalMachine.OpenSubKey("SYSTEM\\CurrentControlSet\\Services\\LanmanServer", true))
                {
                    if (service == null) throw new InvalidDataException("Der lokale SMB-Server-Dienstschlüssel fehlt.");
                    WriteServerMetadataPlan(service, plan);
                }
                return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.Serialize(plan);
            }
            IntPtr manager = OpenSCManagerW(null, null, 3);
            if (manager == IntPtr.Zero) ThrowLastError("Dienstverwaltung öffnen");
            try
            {
                uint access = 0x0002 | 0x0010;
                if (!String.IsNullOrEmpty(plan.ServiceSecurity)) access |= 0x00040000;
                IntPtr service = OpenServiceW(manager, plan.Name, access);
                if (service == IntPtr.Zero)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != 1060) throw new Win32Exception(error, "Dienst öffnen: " + plan.Name);
                    service = CreateServiceW(manager, plan.Name, plan.Configuration.DisplayName, access,
                        plan.Configuration.Type, plan.Configuration.Start, plan.Configuration.ErrorControl,
                        plan.Configuration.ImagePath, null, IntPtr.Zero, MultiString(plan.Configuration.DependOnService),
                        plan.Configuration.ObjectName, "");
                    if (service == IntPtr.Zero) ThrowLastError("Windows-Dienst wiederherstellen: " + plan.Name);
                }
                try
                {
                    WriteManifestRegistry(plan);
                    ServiceBaseConfiguration configuration = plan.Configuration;
                    if (!ChangeServiceConfigW(service, configuration.Type, configuration.Start, configuration.ErrorControl,
                        configuration.ImagePath, "", IntPtr.Zero, MultiString(configuration.DependOnService),
                        configuration.ObjectName, "", configuration.DisplayName)) ThrowLastError("Dienstkonfiguration wiederherstellen");
                    SetDescription(service, configuration.Description);
                    SetPrivileges(service, configuration.RequiredPrivileges);
                    SetSidType(service, configuration.SidType);
                    SetFailures(service, plan.FailureActions);
                    SetTriggers(service, plan.ServiceTriggers);
                    if (!String.IsNullOrEmpty(plan.ServiceSecurity))
                    {
                        RawSecurityDescriptor descriptor = new RawSecurityDescriptor(plan.ServiceSecurity);
                        byte[] bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
                        if (!SetServiceObjectSecurity(service, 4, bytes)) ThrowLastError("Dienstberechtigungen wiederherstellen");
                    }
                }
                finally { CloseServiceHandle(service); }
            }
            finally { CloseServiceHandle(manager); }
            return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.Serialize(plan);
        }

        static void WriteServerMetadataPlan(RegistryKey service, RecoveryPlan plan)
        {
            const string parametersPath = "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer\\Parameters";
            if (plan == null || plan.Name != "LanmanServer" || plan.RegistryValues == null || plan.RegistryValues.Count != 2
                || plan.RegistryValues.Any(value => value.Path != parametersPath || !ServerMetadataNames.Contains(value.Name)))
                throw new InvalidDataException("Die SMB-Dienstreparatur enthält nicht zugelassene Registrierungseinträge.");
            using (RegistryKey parameters = service.CreateSubKey("Parameters"))
            {
                foreach (RegistryValuePlan value in plan.RegistryValues)
                {
                    RegistryValueKind kind = (RegistryValueKind)Enum.Parse(typeof(RegistryValueKind), value.Kind);
                    object actual = parameters.GetValue(value.Name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    bool present = parameters.GetValueNames().Contains(value.Name, StringComparer.OrdinalIgnoreCase);
                    if (present && parameters.GetValueKind(value.Name) == kind && Object.Equals(actual, value.Value)) continue;
                    parameters.SetValue(value.Name, value.Value, kind);
                }
            }
        }

        static void WriteManifestRegistry(RecoveryPlan plan)
        {
            string serviceSecurityPath = "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\" + plan.Name + "\\Security";
            foreach (RegistryValuePlan value in plan.RegistryValues)
            {
                // SCM applies only the original DACL below. Do not replace a current
                // service owner or audit policy with the manifest's complete descriptor.
                if (value.Path.Equals(serviceSecurityPath, StringComparison.OrdinalIgnoreCase)
                    && value.Name.Equals("Security", StringComparison.OrdinalIgnoreCase)) continue;
                using (RegistryKey key = Registry.LocalMachine.CreateSubKey(value.Path.Substring(6)))
                {
                    if (key == null) throw new IOException("Dienstregistrierung kann nicht geöffnet werden.");
                    RegistryValueKind kind = (RegistryValueKind)Enum.Parse(typeof(RegistryValueKind), value.Kind);
                    key.SetValue(value.Name, value.Value, kind);
                }
            }
            foreach (RegistrySecurityPlan security in plan.RegistrySecurity)
            {
                string path = security.Path.Substring(6);
                using (RegistryKey created = Registry.LocalMachine.CreateSubKey(path))
                    if (created == null) throw new IOException("Dienstregistrierung kann nicht geöffnet werden.");
                using (RegistryKey key = Registry.LocalMachine.OpenSubKey(path, RegistryKeyPermissionCheck.ReadWriteSubTree,
                    RegistryRights.ReadKey | RegistryRights.ChangePermissions))
                {
                    if (key == null) throw new IOException("Dienstregistrierung kann nicht geöffnet werden.");
                    RegistrySecurity acl = key.GetAccessControl(AccessControlSections.Access);
                    acl.SetSecurityDescriptorSddlForm(security.Sddl, AccessControlSections.Access);
                    key.SetAccessControl(acl);
                }
            }
        }

        static RecoveryPlan GetPlan(string name)
        {
            name = CanonicalName(name);
            bool server = name == "LanmanServer";
            string component = server ? "Microsoft-Windows-SMBServer" : name;
            string dllName = server ? "srvsvc.dll" : name + ".dll";
            if (Environment.Is64BitOperatingSystem && IntPtr.Size != 8)
                throw new NotSupportedException("Die Windows-Dienstreparatur benötigt auf diesem PC die 64-Bit-Ausführung.");
            string architecture = Environment.Is64BitOperatingSystem ? "amd64" : "x86";
            string manifestDirectory = Path.Combine(WindowsPath, "WinSxS", "Manifests");
            string dllPath = Path.Combine(WindowsPath, "System32", dllName);
            ValidateProtectedPath(dllPath);
            string dllHash;
            using (FileStream file = File.Open(dllPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 hash = SHA256.Create()) dllHash = Convert.ToBase64String(hash.ComputeHash(file));
            string dictionaryPath = FindDictionary(architecture);
            string pattern = architecture + "_" + component.ToLowerInvariant() + "_31bf3856ad364e35_*_none_*.manifest";
            ValidateProtectedPath(manifestDirectory);
            string[] candidates = Directory.GetFiles(manifestDirectory, pattern)
                .OrderByDescending(ManifestVersion).Take(16).ToArray();
            if (candidates.Length == 0) throw new FileNotFoundException("Das originale Windows-Dienstmanifest fehlt: " + name);
            List<string> problems = new List<string>();
            foreach (string manifestPath in candidates)
            {
                try
                {
                    ValidateProtectedPath(manifestPath);
                    XmlDocument document = ReadManifest(manifestPath, dictionaryPath);
                    XmlNamespaceManager namespaces = new XmlNamespaceManager(document.NameTable);
                    namespaces.AddNamespace("a", AsmNamespace); namespaces.AddNamespace("v2", "urn:schemas-microsoft-com:asm.v2");
                    namespaces.AddNamespace("ds", "http://www.w3.org/2000/09/xmldsig#");
                    XmlElement identity = document.SelectSingleNode("/a:assembly/a:assemblyIdentity", namespaces) as XmlElement;
                    if (identity == null || !String.Equals(identity.GetAttribute("name"), component, StringComparison.OrdinalIgnoreCase)
                        || identity.GetAttribute("processorArchitecture") != architecture || identity.GetAttribute("publicKeyToken") != "31bf3856ad364e35"
                        || identity.GetAttribute("language") != "neutral") throw new InvalidDataException("Windows-Manifestidentität passt nicht zum Dienst.");
                    XmlElement dll = document.SelectNodes("/a:assembly/a:file", namespaces).Cast<XmlElement>()
                        .FirstOrDefault(element => String.Equals(element.GetAttribute("name"), dllName, StringComparison.OrdinalIgnoreCase));
                    XmlElement digestMethod = dll == null ? null : dll.SelectSingleNode("v2:hash/ds:DigestMethod", namespaces) as XmlElement;
                    XmlNode digest = dll == null ? null : dll.SelectSingleNode("v2:hash/ds:DigestValue", namespaces);
                    if (digestMethod == null || digestMethod.GetAttribute("Algorithm") != "http://www.w3.org/2000/09/xmldsig#sha256"
                        || digest == null || !String.Equals(digest.InnerText.Trim(), dllHash, StringComparison.Ordinal))
                        throw new InvalidDataException("Das Windows-Dienstmanifest passt nicht zur installierten, geprüften DLL.");
                    return BuildPlan(name, manifestPath, dictionaryPath, dllPath, dllHash, document, namespaces);
                }
                catch (Exception exception) { problems.Add(Path.GetFileName(manifestPath) + ": " + exception.Message); }
            }
            throw new InvalidDataException("Keine verlässlich passende originale Windows-Dienstdefinition gefunden. " + String.Join(" | ", problems.ToArray()));
        }

        static RecoveryPlan BuildPlan(string name, string manifestPath, string dictionaryPath, string dllPath,
            string dllHash, XmlDocument document, XmlNamespaceManager namespaces)
        {
            if (name == "LanmanServer")
                return BuildServerPlan(manifestPath, dictionaryPath, dllPath, dllHash, document, namespaces);
            XmlElement data = document.SelectNodes("//a:serviceData", namespaces).Cast<XmlElement>()
                .FirstOrDefault(element => String.Equals(element.GetAttribute("name"), name, StringComparison.OrdinalIgnoreCase));
            if (data == null) throw new InvalidDataException("Originale Dienstdefinition fehlt im Windows-Manifest.");
            if (data.GetAttribute("type") != "win32ShareProcess" || data.GetAttribute("errorControl") != "normal"
                || data.GetAttribute("start") != "demand" || data.GetAttribute("objectName") != "NT AUTHORITY\\LocalService"
                || data.GetAttribute("sidType") != "unrestricted") throw new InvalidDataException("Nicht unterstützte originale Dienstkonfiguration.");
            string expectedGroup = name == "FDResPub" ? "LocalServiceAndNoImpersonation" : "LocalService";
            string expectedImage = "%SystemRoot%\\system32\\svchost.exe -k " + expectedGroup + " -p";
            if (!String.Equals(data.GetAttribute("imagePath"), expectedImage, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Die originale Dienstdefinition enthält keinen zugelassenen lokalen Windows-Diensthost.");
            RecoveryPlan plan = new RecoveryPlan { Name = name, ManifestPath = manifestPath, DictionaryPath = dictionaryPath,
                DllPath = dllPath, DllHash = Hex(Convert.FromBase64String(dllHash)), RegistryValues = new List<RegistryValuePlan>(),
                RegistrySecurity = new List<RegistrySecurityPlan>(), ServiceTriggers = new List<TriggerPlan>() };
            plan.Configuration = new ServiceBaseConfiguration { Type = 32, Start = 3, ErrorControl = 1, SidType = 1,
                ImagePath = data.GetAttribute("imagePath"), DisplayName = data.GetAttribute("displayName"),
                Description = data.GetAttribute("description"), ObjectName = data.GetAttribute("objectName"),
                DependOnService = SplitList(data.GetAttribute("dependOnService")), RequiredPrivileges = SplitList(data.GetAttribute("requiredPrivileges")) };
            string root = "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\" + name;
            AddValue(plan, root, "Type", "DWord", 32); AddValue(plan, root, "Start", "DWord", 3);
            AddValue(plan, root, "ErrorControl", "DWord", 1); AddValue(plan, root, "ImagePath", "ExpandString", plan.Configuration.ImagePath);
            AddValue(plan, root, "DisplayName", "String", plan.Configuration.DisplayName);
            AddValue(plan, root, "Description", "String", plan.Configuration.Description);
            AddValue(plan, root, "ObjectName", "String", plan.Configuration.ObjectName);
            AddValue(plan, root, "DependOnService", "MultiString", plan.Configuration.DependOnService);
            AddValue(plan, root, "RequiredPrivileges", "MultiString", plan.Configuration.RequiredPrivileges);
            AddValue(plan, root, "ServiceSidType", "DWord", 1);
            string longRoot = "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\" + name;
            foreach (XmlElement key in document.SelectNodes("/a:assembly/a:registryKeys/a:registryKey", namespaces))
            {
                string sourcePath = key.GetAttribute("keyName").TrimEnd('\\');
                if (!sourcePath.Equals(longRoot, StringComparison.OrdinalIgnoreCase)
                    && !sourcePath.StartsWith(longRoot + "\\", StringComparison.OrdinalIgnoreCase)) continue;
                string path = root + sourcePath.Substring(longRoot.Length);
                if (path.IndexOf("..", StringComparison.Ordinal) >= 0) throw new InvalidDataException("Ungültiger Registrierungspfad im Dienstmanifest.");
                foreach (XmlElement value in key.SelectNodes("a:registryValue", namespaces))
                {
                    string kind; object content;
                    switch (value.GetAttribute("valueType"))
                    {
                        case "REG_EXPAND_SZ": kind = "ExpandString"; content = value.GetAttribute("value"); break;
                        case "REG_SZ": kind = "String"; content = value.GetAttribute("value"); break;
                        case "REG_DWORD": kind = "DWord"; content = ParseDword(value.GetAttribute("value")); break;
                        case "REG_BINARY": kind = "Binary"; content = ParseHex(value.GetAttribute("value")); break;
                        default: throw new InvalidDataException("Nicht unterstützter Werttyp im originalen Dienstmanifest.");
                    }
                    AddValue(plan, path, value.GetAttribute("name"), kind, content);
                    if (path.Equals(root + "\\Security", StringComparison.OrdinalIgnoreCase) && value.GetAttribute("name") == "Security")
                        plan.ServiceSecurity = new RawSecurityDescriptor((byte[])content, 0).GetSddlForm(AccessControlSections.Access);
                }
                XmlElement descriptor = key.SelectSingleNode("a:securityDescriptor", namespaces) as XmlElement;
                if (descriptor != null)
                {
                    string descriptorName = descriptor.GetAttribute("name");
                    XmlElement definition = document.SelectNodes("//a:securityDescriptorDefinition", namespaces).Cast<XmlElement>()
                        .FirstOrDefault(element => element.GetAttribute("name") == descriptorName);
                    if (definition == null) throw new InvalidDataException("Originale Dienst-Registrierungsberechtigungen fehlen.");
                    plan.RegistrySecurity.Add(new RegistrySecurityPlan { Path = path, Sddl = definition.GetAttribute("sddl") });
                }
            }
            XmlElement failures = data.SelectSingleNode("a:failureActions", namespaces) as XmlElement;
            if (failures != null)
            {
                plan.FailureActions = new FailurePlan { ResetPeriod = ParseUnsigned(failures.GetAttribute("resetPeriod")), Actions = new List<FailureActionPlan>() };
                foreach (XmlElement action in failures.SelectNodes("a:actions/a:action", namespaces))
                {
                    string type = action.GetAttribute("type");
                    if (type != "none" && type != "restartService") throw new InvalidDataException("Nicht unterstützte originale Fehleraktion.");
                    plan.FailureActions.Actions.Add(new FailureActionPlan { Type = type == "none" ? 0U : 1U, Delay = ParseUnsigned(action.GetAttribute("delay")) });
                }
            }
            foreach (XmlElement trigger in data.SelectNodes("a:serviceTrigger", namespaces))
            {
                if (trigger.GetAttribute("type") != "Custom" || trigger.GetAttribute("action") != "start")
                    throw new InvalidDataException("Nicht unterstützter originaler Diensttrigger.");
                TriggerPlan item = new TriggerPlan { Type = 20, Action = 1, Subtype = new Guid(trigger.GetAttribute("subtype")).ToString("D"), Data = new List<TriggerDataPlan>() };
                foreach (XmlElement value in trigger.SelectNodes("a:triggerData", namespaces))
                {
                    if (value.GetAttribute("type") != "string") throw new InvalidDataException("Nicht unterstützte originale Triggerdaten.");
                    item.Data.Add(new TriggerDataPlan { Type = 2, Value = value.GetAttribute("value") });
                }
                plan.ServiceTriggers.Add(item);
            }
            return plan;
        }

        static RecoveryPlan BuildServerPlan(string manifestPath, string dictionaryPath, string dllPath,
            string dllHash, XmlDocument document, XmlNamespaceManager namespaces)
        {
            const string name = "LanmanServer";
            const string root = "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer";
            const string expectedImage = "%SystemRoot%\\system32\\svchost.exe -k netsvcs -p";
            XmlElement data = document.SelectNodes("//a:serviceData", namespaces).Cast<XmlElement>()
                .SingleOrDefault(element => String.Equals(element.GetAttribute("name"), name, StringComparison.OrdinalIgnoreCase));
            if (data == null || data.GetAttribute("type") != "win32ShareProcess"
                || data.GetAttribute("errorControl") != "normal" || data.GetAttribute("start") != "auto"
                || data.GetAttribute("objectName") != "LocalSystem" || data.GetAttribute("sidType") != "unrestricted"
                || !String.Equals(data.GetAttribute("imagePath"), expectedImage, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Nicht unterstützte originale SMB-Server-Dienstkonfiguration.");
            string[] dependencies = SplitList(data.GetAttribute("dependOnService"));
            string[] privileges = SplitList(data.GetAttribute("requiredPrivileges"));
            if (!dependencies.OrderBy(item => item, StringComparer.OrdinalIgnoreCase).SequenceEqual(new[] { "SamSS", "Srv2" }, StringComparer.OrdinalIgnoreCase)
                || !privileges.OrderBy(item => item, StringComparer.OrdinalIgnoreCase).SequenceEqual(new[] { "SeAuditPrivilege", "SeChangeNotifyPrivilege", "SeImpersonatePrivilege" }, StringComparer.OrdinalIgnoreCase))
                throw new InvalidDataException("Die originale SMB-Server-Definition enthält nicht zugelassene Abhängigkeiten oder Berechtigungen.");
            RecoveryPlan plan = new RecoveryPlan { Name = name, ManifestPath = manifestPath, DictionaryPath = dictionaryPath,
                DllPath = dllPath, DllHash = Hex(Convert.FromBase64String(dllHash)), RegistryValues = new List<RegistryValuePlan>(),
                RegistrySecurity = new List<RegistrySecurityPlan>(), ServiceTriggers = new List<TriggerPlan>() };
            plan.Configuration = new ServiceBaseConfiguration { Type = 32, Start = 2, ErrorControl = 1, SidType = 1,
                ImagePath = data.GetAttribute("imagePath"), DisplayName = data.GetAttribute("displayName"),
                Description = data.GetAttribute("description"), ObjectName = data.GetAttribute("objectName"),
                DependOnService = dependencies, RequiredPrivileges = privileges };
            string parameters = root + "\\Parameters";
            string longParameters = "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer\\Parameters";
            foreach (XmlElement key in document.SelectNodes("/a:assembly/a:registryKeys/a:registryKey", namespaces))
            {
                if (!key.GetAttribute("keyName").TrimEnd('\\').Equals(longParameters, StringComparison.OrdinalIgnoreCase)) continue;
                foreach (XmlElement value in key.SelectNodes("a:registryValue", namespaces))
                {
                    string valueName = value.GetAttribute("name");
                    if (valueName == "ServiceDll")
                    {
                        string content = value.GetAttribute("value");
                        if (value.GetAttribute("valueType") != "REG_EXPAND_SZ"
                            || !String.Equals(content, "%SystemRoot%\\system32\\srvsvc.dll", StringComparison.OrdinalIgnoreCase)
                            || !String.Equals(Environment.ExpandEnvironmentVariables(content), dllPath, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("Die originale SMB-Dienstdatei stimmt nicht mit der geprüften DLL überein.");
                        AddValue(plan, parameters, valueName, "ExpandString", content);
                    }
                    else if (valueName == "ServiceDllUnloadOnStop")
                    {
                        if (value.GetAttribute("valueType") != "REG_DWORD" || ParseDword(value.GetAttribute("value")) != 1)
                            throw new InvalidDataException("Nicht unterstützte originale SMB-DLL-Option.");
                        AddValue(plan, parameters, valueName, "DWord", 1);
                    }
                    // All remaining values belong to file sharing/security policy.
                    // A missing ServiceDll must never reset these user settings.
                }
            }
            if (plan.RegistryValues.Count != 2
                || plan.RegistryValues.Count(value => value.Name == "ServiceDll") != 1
                || plan.RegistryValues.Count(value => value.Name == "ServiceDllUnloadOnStop") != 1)
                throw new InvalidDataException("Die originale SMB-Dienstregistrierung ist unvollständig oder mehrdeutig.");
            return plan;
        }

        static void AddValue(RecoveryPlan plan, string path, string name, string kind, object value)
        {
            if (String.IsNullOrEmpty(name) || name.Length > 256) throw new InvalidDataException("Ungültiger Registrierungswert im Windows-Manifest.");
            plan.RegistryValues.Add(new RegistryValuePlan { Path = path, Name = name, Kind = kind, Value = value });
        }
        static string CanonicalName(string name)
        {
            if (String.Equals(name, "LanmanServer", StringComparison.OrdinalIgnoreCase)) return "LanmanServer";
            if (String.Equals(name, "FDResPub", StringComparison.OrdinalIgnoreCase)) return "FDResPub";
            if (String.Equals(name, "fdPHost", StringComparison.OrdinalIgnoreCase)) return "fdPHost";
            throw new ArgumentException("Nur die originalen Windows-SMB- und Netzwerkerkennungsdienste können wiederhergestellt werden.", "name");
        }
        static Version ManifestVersion(string path)
        {
            Version version;
            string[] pieces = Path.GetFileName(path).Split('_');
            return pieces.Length > 3 && Version.TryParse(pieces[3], out version) ? version : new Version(0, 0);
        }
        static string FindDictionary(string architecture)
        {
            string store = Path.Combine(WindowsPath, "WinSxS"); ValidateProtectedPath(store);
            string[] directories = Directory.GetDirectories(store, architecture + "_microsoft-windows-servicingstack_31bf3856ad364e35_*_none_*")
                .OrderByDescending(ManifestVersion).Take(16).ToArray();
            foreach (string directory in directories)
            {
                string path = Path.Combine(directory, "wcp.dll");
                if (File.Exists(path)) { ValidateProtectedPath(path); return path; }
            }
            throw new FileNotFoundException("Die originale Windows-Komponentenmanifestbibliothek fehlt.");
        }
        static void ValidateProtectedPath(string path)
        {
            string full = Path.GetFullPath(path), windows = Path.GetFullPath(WindowsPath).TrimEnd('\\');
            if (!full.StartsWith(windows + "\\", StringComparison.OrdinalIgnoreCase) && !full.Equals(windows, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Dienstreparaturquelle liegt außerhalb des Windows-Verzeichnisses.");
            string current = full;
            for (;;)
            {
                FileAttributes attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Umgeleitete Windows-Reparaturquellen sind nicht erlaubt.");
                FileSystemSecurity security = (attributes & FileAttributes.Directory) != 0
                    ? (FileSystemSecurity)Directory.GetAccessControl(current) : File.GetAccessControl(current);
                string owner = security.GetOwner(typeof(SecurityIdentifier)).Value;
                if (!IsTrustedPrincipal(owner)) throw new UnauthorizedAccessException("Windows-Reparaturquelle gehört keinem vertrauenswürdigen Systemkonto.");
                foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
                {
                    if (rule.AccessControlType != AccessControlType.Allow || (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0) continue;
                    uint rights = unchecked((uint)rule.FileSystemRights);
                    uint write = unchecked((uint)(FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership)) | 0x50000000U;
                    if ((rights & write) != 0 && !IsTrustedPrincipal(((SecurityIdentifier)rule.IdentityReference).Value))
                        throw new UnauthorizedAccessException("Ein gewöhnliches Konto kann die Windows-Reparaturquelle verändern.");
                }
                if (current.Equals(windows, StringComparison.OrdinalIgnoreCase)) break;
                current = Path.GetDirectoryName(current);
                if (String.IsNullOrEmpty(current)) throw new InvalidDataException("Ungültiger Windows-Reparaturquellpfad.");
            }
        }
        static bool IsTrustedPrincipal(string sid) { return sid == TrustedInstallerSid || sid == "S-1-5-18" || sid == "S-1-5-32-544"; }
        static XmlDocument ReadManifest(string path, string dictionary)
        {
            byte[] bytes;
            using (FileStream stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length <= 0 || stream.Length > MaxManifestBytes) throw new InvalidDataException("Windows-Dienstmanifest hat eine unzulässige Größe.");
                bytes = new byte[(int)stream.Length]; int read = 0;
                while (read < bytes.Length) { int count = stream.Read(bytes, read, bytes.Length - read); if (count == 0) throw new EndOfStreamException(); read += count; }
            }
            if (bytes.Length >= 8 && bytes[0] == 0x44 && bytes[1] == 0x43 && bytes[2] == 0x4d && bytes[3] == 1)
                bytes = Decompress(bytes, dictionary);
            XmlReaderSettings settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaxManifestBytes };
            XmlDocument document = new XmlDocument { XmlResolver = null };
            using (MemoryStream stream = new MemoryStream(bytes, false))
            using (XmlReader reader = XmlReader.Create(stream, settings)) document.Load(reader);
            return document;
        }
        static byte[] Decompress(byte[] bytes, string dictionary)
        {
            if (bytes[4] != 0x50 || bytes[5] != 0x41 || bytes[6] != 0x33 || bytes[7] != 0x30)
                throw new InvalidDataException("Nicht unterstützte Windows-Manifestkomprimierung.");
            string deltaPath = Path.Combine(WindowsPath, "System32", "msdelta.dll"); ValidateProtectedPath(deltaPath);
            using (FileStream guard = File.Open(dictionary, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                IntPtr module = LoadLibraryExW(deltaPath, IntPtr.Zero, 0x800);
                if (module == IntPtr.Zero) ThrowLastError("Originale Windows-Deltabibliothek laden");
                try
                {
                    IntPtr applyPointer = GetProcAddress(module, "ApplyDeltaB"), freePointer = GetProcAddress(module, "DeltaFree"), infoPointer = GetProcAddress(module, "GetDeltaInfoB");
                    if (applyPointer == IntPtr.Zero || freePointer == IntPtr.Zero || infoPointer == IntPtr.Zero) throw new EntryPointNotFoundException("Windows-Deltabibliothek ist unvollständig.");
                    ApplyDelta apply = (ApplyDelta)Marshal.GetDelegateForFunctionPointer(applyPointer, typeof(ApplyDelta));
                    FreeDelta free = (FreeDelta)Marshal.GetDelegateForFunctionPointer(freePointer, typeof(FreeDelta));
                    GetDeltaInfo info = (GetDeltaInfo)Marshal.GetDelegateForFunctionPointer(infoPointer, typeof(GetDeltaInfo));
                    IntPtr resourceModule = LoadLibraryExW(dictionary, IntPtr.Zero, 0x2 | 0x20);
                    if (resourceModule == IntPtr.Zero) ThrowLastError("Originale Windows-Manifestbasis lesen");
                    try
                    {
                        IntPtr resource = FindResourceW(resourceModule, new IntPtr(1), new IntPtr(614));
                        if (resource == IntPtr.Zero) ThrowLastError("Windows-Manifestbasis finden");
                        uint size = SizeofResource(resourceModule, resource);
                        if (size == 0 || size > MaxManifestBytes) throw new InvalidDataException("Windows-Manifestbasis hat eine unzulässige Größe.");
                        IntPtr basis = LockResource(LoadResource(resourceModule, resource));
                        if (basis == IntPtr.Zero) ThrowLastError("Windows-Manifestbasis öffnen");
                        byte[] delta = new byte[bytes.Length - 4]; Buffer.BlockCopy(bytes, 4, delta, 0, delta.Length);
                        GCHandle handle = GCHandle.Alloc(delta, GCHandleType.Pinned);
                        try
                        {
                            DeltaInput input = new DeltaInput { Start = handle.AddrOfPinnedObject(), Size = new UIntPtr((uint)delta.Length) };
                            DeltaHeader header;
                            if (!info(input, out header)) ThrowLastError("Größe des originalen Windows-Dienstmanifests prüfen");
                            if (header.TargetSize.ToUInt64() == 0 || header.TargetSize.ToUInt64() > MaxManifestBytes)
                                throw new InvalidDataException("Entpacktes Windows-Dienstmanifest überschreitet die erlaubte Größe.");
                            DeltaInput source = new DeltaInput { Start = basis, Size = new UIntPtr(size) }; DeltaOutput output;
                            if (!apply(0, source, input, out output)) ThrowLastError("Originales Windows-Dienstmanifest entpacken");
                            try
                            {
                                ulong length = output.Size.ToUInt64();
                                if (length == 0 || length > MaxManifestBytes) throw new InvalidDataException("Entpacktes Windows-Dienstmanifest hat eine unzulässige Größe.");
                                byte[] plain = new byte[(int)length]; Marshal.Copy(output.Start, plain, 0, plain.Length); return plain;
                            }
                            finally { free(output.Start); }
                        }
                        finally { handle.Free(); }
                    }
                    finally { FreeLibrary(resourceModule); }
                }
                finally { FreeLibrary(module); }
            }
        }
        static void SetDescription(IntPtr service, string description)
        {
            using (NativeAllocations allocations = new NativeAllocations())
                SetConfig(service, 1, allocations.Structure(new DescriptionInfo { Description = allocations.String(description) }));
        }
        static void SetPrivileges(IntPtr service, string[] privileges)
        {
            using (NativeAllocations allocations = new NativeAllocations())
                SetConfig(service, 6, allocations.Structure(new PrivilegesInfo { RequiredPrivileges = allocations.String(MultiString(privileges)) }));
        }
        static void SetSidType(IntPtr service, uint type)
        {
            using (NativeAllocations allocations = new NativeAllocations()) SetConfig(service, 5, allocations.Structure(new SidInfo { Type = type }));
        }
        static void SetFailures(IntPtr service, FailurePlan plan)
        {
            if (plan == null) return;
            using (NativeAllocations allocations = new NativeAllocations())
            {
                IntPtr actions = allocations.Array(plan.Actions.Select(action => new NativeFailureAction { Type = action.Type, Delay = action.Delay }).ToArray());
                SetConfig(service, 2, allocations.Structure(new FailureInfo { ResetPeriod = plan.ResetPeriod, Count = (uint)plan.Actions.Count, Actions = actions }));
            }
        }
        static void SetTriggers(IntPtr service, List<TriggerPlan> plan)
        {
            if (plan.Count == 0) return;
            using (NativeAllocations allocations = new NativeAllocations())
            {
                List<NativeTrigger> triggers = new List<NativeTrigger>();
                foreach (TriggerPlan item in plan)
                {
                    List<NativeTriggerData> data = new List<NativeTriggerData>();
                    foreach (TriggerDataPlan value in item.Data)
                    {
                        byte[] bytes = Encoding.Unicode.GetBytes(value.Value + "\0");
                        data.Add(new NativeTriggerData { Type = value.Type, Size = (uint)bytes.Length, Data = allocations.Bytes(bytes) });
                    }
                    triggers.Add(new NativeTrigger { Type = item.Type, Action = item.Action, Subtype = allocations.Structure(new Guid(item.Subtype)),
                        Count = (uint)data.Count, Data = allocations.Array(data.ToArray()) });
                }
                SetConfig(service, 8, allocations.Structure(new TriggerInfo { Count = (uint)triggers.Count, Triggers = allocations.Array(triggers.ToArray()) }));
            }
        }
        static void SetConfig(IntPtr service, uint level, IntPtr value)
        {
            if (!ChangeServiceConfig2W(service, level, value)) ThrowLastError("Optionale Windows-Dienstkonfiguration wiederherstellen (" + level + ")");
        }
        static string MultiString(string[] values) { return String.Join("\0", values) + "\0\0"; }
        static string[] SplitList(string value) { return value.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(item => item.Trim()).ToArray(); }
        static uint ParseUnsigned(string value) { return UInt32.Parse(value, System.Globalization.CultureInfo.InvariantCulture); }
        static int ParseDword(string value) { return value.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? unchecked((int)Convert.ToUInt32(value.Substring(2), 16)) : Int32.Parse(value, System.Globalization.CultureInfo.InvariantCulture); }
        static byte[] ParseHex(string value)
        {
            if (value.Length % 2 != 0 || value.Length > 65536) throw new InvalidDataException("Ungültige Windows-Sicherheitsdefinition.");
            byte[] bytes = new byte[value.Length / 2]; for (int i = 0; i < bytes.Length; i++) bytes[i] = Convert.ToByte(value.Substring(i * 2, 2), 16); return bytes;
        }
        static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", ""); }
        static void ThrowLastError(string message) { throw new Win32Exception(Marshal.GetLastWin32Error(), message); }

        public sealed class RecoveryPlan
        {
            public string Name { get; set; } public string ManifestPath { get; set; } public string DictionaryPath { get; set; }
            public string DllPath { get; set; } public string DllHash { get; set; } public List<RegistryValuePlan> RegistryValues { get; set; }
            public string ServiceSecurity { get; set; } public List<RegistrySecurityPlan> RegistrySecurity { get; set; }
            public ServiceBaseConfiguration Configuration { get; set; } public FailurePlan FailureActions { get; set; }
            public List<TriggerPlan> ServiceTriggers { get; set; }
        }
        public sealed class ServerMetadata
        {
            public bool ParametersKeyExists { get; set; }
            public List<ServerMetadataValue> Values { get; set; }
        }
        public sealed class ServerMetadataValue
        {
            public string Name { get; set; } public bool Exists { get; set; } public string Kind { get; set; }
            public string Text { get; set; } public string[] Strings { get; set; } public long Number { get; set; }
            public string Binary { get; set; }
        }
        public sealed class ServerMetadataRestore
        {
            public List<string> Restored { get; set; } public List<string> Preserved { get; set; }
            public bool ParametersKeyRemoved { get; set; }
        }
        public sealed class RegistryValuePlan { public string Path { get; set; } public string Name { get; set; } public string Kind { get; set; } public object Value { get; set; } }
        public sealed class RegistrySecurityPlan { public string Path { get; set; } public string Sddl { get; set; } }
        public sealed class ServiceBaseConfiguration
        {
            public uint Type { get; set; } public uint Start { get; set; } public uint ErrorControl { get; set; } public uint SidType { get; set; }
            public string ImagePath { get; set; } public string DisplayName { get; set; } public string Description { get; set; }
            public string ObjectName { get; set; } public string[] DependOnService { get; set; } public string[] RequiredPrivileges { get; set; }
        }
        public sealed class FailurePlan { public uint ResetPeriod { get; set; } public List<FailureActionPlan> Actions { get; set; } }
        public sealed class FailureActionPlan { public uint Type { get; set; } public uint Delay { get; set; } }
        public sealed class TriggerPlan { public uint Type { get; set; } public uint Action { get; set; } public string Subtype { get; set; } public List<TriggerDataPlan> Data { get; set; } }
        public sealed class TriggerDataPlan { public uint Type { get; set; } public string Value { get; set; } }
        sealed class NativeAllocations : IDisposable
        {
            readonly List<IntPtr> pointers = new List<IntPtr>();
            public IntPtr String(string value) { IntPtr pointer = Marshal.StringToHGlobalUni(value ?? ""); pointers.Add(pointer); return pointer; }
            public IntPtr Bytes(byte[] value) { IntPtr pointer = Marshal.AllocHGlobal(value.Length); pointers.Add(pointer); Marshal.Copy(value, 0, pointer, value.Length); return pointer; }
            public IntPtr Structure<T>(T value) where T : struct
            {
                IntPtr pointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(T))); pointers.Add(pointer); Marshal.StructureToPtr(value, pointer, false); return pointer;
            }
            public IntPtr Array<T>(T[] values) where T : struct
            {
                if (values.Length == 0) return IntPtr.Zero; int size = Marshal.SizeOf(typeof(T)); IntPtr pointer = Marshal.AllocHGlobal(checked(size * values.Length)); pointers.Add(pointer);
                for (int i = 0; i < values.Length; i++) Marshal.StructureToPtr(values[i], IntPtr.Add(pointer, i * size), false); return pointer;
            }
            public void Dispose() { for (int i = pointers.Count - 1; i >= 0; i--) Marshal.FreeHGlobal(pointers[i]); pointers.Clear(); }
        }
        [StructLayout(LayoutKind.Sequential)] struct DeltaInput { public IntPtr Start; public UIntPtr Size; [MarshalAs(UnmanagedType.Bool)] public bool Editable; }
        [StructLayout(LayoutKind.Sequential)] struct DeltaOutput { public IntPtr Start; public UIntPtr Size; }
        [StructLayout(LayoutKind.Sequential)] struct DeltaHeader
        {
            public long FileTypeSet; public long FileType; public long Flags; public UIntPtr TargetSize;
            public uint TargetFileTimeLow; public uint TargetFileTimeHigh; public uint TargetHashAlgorithm; public uint HashSize;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] HashValue;
        }
        [UnmanagedFunctionPointer(CallingConvention.Winapi, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] delegate bool ApplyDelta(long flags, DeltaInput source, DeltaInput delta, out DeltaOutput output);
        [UnmanagedFunctionPointer(CallingConvention.Winapi, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] delegate bool FreeDelta(IntPtr data);
        [UnmanagedFunctionPointer(CallingConvention.Winapi, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] delegate bool GetDeltaInfo(DeltaInput delta, out DeltaHeader header);
        [StructLayout(LayoutKind.Sequential)] struct DescriptionInfo { public IntPtr Description; }
        [StructLayout(LayoutKind.Sequential)] struct PrivilegesInfo { public IntPtr RequiredPrivileges; }
        [StructLayout(LayoutKind.Sequential)] struct SidInfo { public uint Type; }
        [StructLayout(LayoutKind.Sequential)] struct NativeFailureAction { public uint Type; public uint Delay; }
        [StructLayout(LayoutKind.Sequential)] struct FailureInfo { public uint ResetPeriod; public IntPtr RebootMessage; public IntPtr Command; public uint Count; public IntPtr Actions; }
        [StructLayout(LayoutKind.Sequential)] struct NativeTriggerData { public uint Type; public uint Size; public IntPtr Data; }
        [StructLayout(LayoutKind.Sequential)] struct NativeTrigger { public uint Type; public uint Action; public IntPtr Subtype; public uint Count; public IntPtr Data; }
        [StructLayout(LayoutKind.Sequential)] struct TriggerInfo { public uint Count; public IntPtr Triggers; public IntPtr Reserved; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)] static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint SizeofResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr LockResource(IntPtr resource);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool FreeLibrary(IntPtr module);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenSCManagerW(string computer, string database, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr OpenServiceW(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateServiceW(IntPtr manager, string name, string displayName, uint access, uint type, uint start, uint error, string binary, string group, IntPtr tag, string dependencies, string account, string password);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool ChangeServiceConfigW(IntPtr service, uint type, uint start, uint error, string binary, string group, IntPtr tag, string dependencies, string account, string password, string displayName);
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool ChangeServiceConfig2W(IntPtr service, uint level, IntPtr data);
        [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool SetServiceObjectSecurity(IntPtr service, uint information, byte[] descriptor);
        [DllImport("advapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool CloseServiceHandle(IntPtr handle);
    }
}
