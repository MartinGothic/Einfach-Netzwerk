using System;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace EinfachNetzwerk
{
    // A private TCP connection tests the same SMB2 login and folder operations as a phone.
    // It does not use or change the Windows SMB client's guest/signing policy or mappings.
    public static class SmbConnectionProbe
    {
        public sealed class ProbeResult
        {
            public bool Success { get; set; }
            public bool TcpReachable { get; set; }
            public bool LoginSucceeded { get; set; }
            public bool TreeConnected { get; set; }
            public bool DirectoryListed { get; set; }
            public int EntryCount { get; set; }
            public bool ListingTruncated { get; set; }
            public bool GuestSession { get; set; }
            public bool SigningRequired { get; set; }
            public string Dialect { get; set; }
            public string AuthenticationProtocol { get; set; }
            public string Stage { get; set; }
            public string StatusCode { get; set; }
            public string Error { get; set; }
        }

        public static string ProbeJson(string ip, string shareName, string userName, string password)
        {
            return new JavaScriptSerializer().Serialize(Probe(ip, shareName, userName, password));
        }

        public static ProbeResult Probe(string ip, string shareName, string userName, string password)
        {
            ProbeResult result = new ProbeResult { Stage = "Input", Dialect = "SMB 2.1", StatusCode = "", Error = "" };
            try
            {
                IPAddress address;
                if (!IPAddress.TryParse(ip, out address) || address.AddressFamily != AddressFamily.InterNetwork || !IsPrivateLocal(address))
                    throw new ArgumentException("Die SMB-Prüfung ist auf die private IPv4-Adresse dieses Computers beschränkt.");
                if (String.IsNullOrWhiteSpace(shareName) || shareName.Length > 80 || shareName.IndexOfAny(new[] { '\\', '/', ':', '\0' }) >= 0)
                    throw new ArgumentException("Der Freigabename ist ungültig.");
                if ((userName ?? "").Length > 256 || (password ?? "").Length > 1024)
                    throw new ArgumentException("Die Anmeldedaten sind zu lang.");
                using (SmbWire wire = new SmbWire(address, result))
                using (NtlmContext auth = new NtlmContext(userName ?? "", password ?? ""))
                {
                    wire.Connect();
                    wire.Negotiate();
                    wire.Login(auth);
                    wire.TreeConnect(shareName);
                    wire.ListDirectory();
                    result.Success = true;
                    result.Stage = "Complete";
                    result.StatusCode = "0x00000000";
                }
            }
            catch (SmbStatusException e) { result.StatusCode = "0x" + e.Status.ToString("X8"); result.Error = StatusExplanation(e.Status); }
            catch (SspiException e) { result.StatusCode = "0x" + e.Status.ToString("X8"); result.Error = "Die NTLM-Anmeldung konnte nicht aufgebaut werden (" + result.StatusCode + ")."; }
            catch (TimeoutException) { result.StatusCode = "TIMEOUT"; result.Error = "Die SMB-Prüfung hat innerhalb des Zeitlimits keine Antwort erhalten."; }
            catch (SocketException e) { result.StatusCode = "SOCKET_" + e.SocketErrorCode.ToString(); result.Error = "Port 445 ist nicht erreichbar oder die Verbindung wurde unterbrochen."; }
            catch (Exception e) { result.StatusCode = "PROBE_ERROR"; result.Error = e is ArgumentException || e is InvalidDataException ? e.Message : "Die SMB-Prüfung konnte nicht abgeschlossen werden (" + e.GetType().Name + ")."; }
            return result;
        }

        private static bool IsPrivateLocal(IPAddress address)
        {
            byte[] b = address.GetAddressBytes();
            bool home = b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
            if (!home) return false;
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
                foreach (UnicastIPAddressInformation item in nic.GetIPProperties().UnicastAddresses)
                    if (address.Equals(item.Address)) return true;
            return false;
        }

        private static string StatusExplanation(uint status)
        {
            switch (status)
            {
                case 0xC0000022: return "Der SMB-Server verweigert diesen Zugriff (STATUS_ACCESS_DENIED).";
                case 0xC000006D: return "Der SMB-Server lehnt die Anmeldung ab (STATUS_LOGON_FAILURE).";
                case 0xC000006A: return "Das Passwort wird vom SMB-Server abgelehnt (STATUS_WRONG_PASSWORD).";
                case 0xC0000072: return "Das Anmeldekonto ist deaktiviert (STATUS_ACCOUNT_DISABLED).";
                case 0xC000006E: return "Eine Kontorichtlinie verhindert die Anmeldung (STATUS_ACCOUNT_RESTRICTION).";
                case 0xC000015B: return "Das Konto hat kein Netzwerk-Anmelderecht (STATUS_LOGON_TYPE_NOT_GRANTED).";
                case 0xC00000CC: return "Die angegebene Freigabe ist auf dem Server nicht vorhanden (STATUS_BAD_NETWORK_NAME).";
                case 0xC0000043: return "Der Freigabeordner ist derzeit gesperrt (STATUS_SHARING_VIOLATION).";
                case 0xC00000BB: return "Der Server unterstützt den angeforderten SMB-Vorgang nicht (STATUS_NOT_SUPPORTED).";
                default: return "Der SMB-Server meldet Status 0x" + status.ToString("X8") + ".";
            }
        }

        private sealed class SmbStatusException : Exception
        {
            internal readonly uint Status;
            internal SmbStatusException(uint status) { Status = status; }
        }
        private sealed class SspiException : Exception
        {
            internal readonly uint Status;
            internal SspiException(int status) { Status = unchecked((uint)status); }
        }

        private sealed class SmbWire : IDisposable
        {
            private readonly IPAddress address;
            private readonly ProbeResult result;
            private readonly DateTime deadline = DateTime.UtcNow.AddSeconds(18);
            private Socket socket;
            private ulong messageId;
            private ulong sessionId;
            private uint treeId;
            private byte[] sessionKey;
            private byte[] fileId;
            private bool signedSession;
            internal SmbWire(IPAddress address, ProbeResult result) { this.address = address; this.result = result; }

            internal void Connect()
            {
                result.Stage = "Connect";
                socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                socket.NoDelay = true;
                IAsyncResult pending = socket.BeginConnect(new IPEndPoint(address, 445), null, null);
                using (System.Threading.WaitHandle wait = pending.AsyncWaitHandle)
                {
                    if (!wait.WaitOne(3000)) throw new TimeoutException();
                    socket.EndConnect(pending);
                }
                result.TcpReachable = true;
            }

            internal void Negotiate()
            {
                result.Stage = "Negotiate";
                byte[] body = new byte[38];
                U16(body, 0, 36); U16(body, 2, 1); U16(body, 4, 1);
                Buffer.BlockCopy(Guid.NewGuid().ToByteArray(), 0, body, 12, 16);
                U16(body, 36, 0x0210);
                byte[] response = Exchange(0, body, false);
                RequireSuccess(response);
                RequireLength(response, 128);
                if (R16(response, 64) != 65 || R16(response, 68) != 0x0210)
                    throw new InvalidDataException("Der Server hat SMB 2.1 nicht bestätigt.");
                result.SigningRequired = (R16(response, 66) & 2) != 0;
            }

            internal void Login(NtlmContext auth)
            {
                result.Stage = "Login";
                byte[] token = auth.Next(null, address.ToString());
                byte[] response = null;
                // The Negotiate SSPI provider handles SPNEGO, NTLM and a possible
                // final mechanism-list MIC without hand-building authentication.
                // An IPv4 target with explicit local credentials selects NTLM.
                for (int round = 0; round < 4; round++)
                {
                    response = Exchange(1, SessionBody(token), false);
                    sessionId = R64(response, 40);
                    uint status = R32(response, 8);
                    if (status != 0xC0000016) { RequireSuccess(response); break; }
                    RequireLength(response, 72);
                    int offset = R16(response, 68), length = R16(response, 70);
                    CheckRange(response, offset, length);
                    byte[] incoming = new byte[length]; Buffer.BlockCopy(response, offset, incoming, 0, length);
                    token = auth.Next(incoming, address.ToString());
                    if (token.Length == 0) throw new InvalidDataException("Der weitere SMB-Anmeldeschritt hat keinen Antworttoken erzeugt.");
                }
                RequireSuccess(response);
                RequireLength(response, 72);
                int finalOffset = R16(response, 68), finalLength = R16(response, 70);
                if (finalLength != 0)
                {
                    CheckRange(response, finalOffset, finalLength);
                    byte[] finalToken = new byte[finalLength]; Buffer.BlockCopy(response, finalOffset, finalToken, 0, finalLength);
                    byte[] finalReply = auth.Next(finalToken, address.ToString());
                    if (finalReply.Length != 0) throw new InvalidDataException("Die SMB-Anmeldung verlangt nach der Serverbestätigung einen weiteren Token.");
                }
                if (!auth.Complete) throw new InvalidDataException("Der Sicherheitsanbieter hat die SMB-Anmeldung nicht abgeschlossen.");
                result.AuthenticationProtocol = auth.Protocol();
                sessionId = R64(response, 40);
                ushort flags = R16(response, 66);
                result.GuestSession = (flags & 1) != 0;
                if ((flags & 4) != 0) throw new InvalidDataException("Der Server verlangt SMB-Verschlüsselung. Die SMB-2.1-Prüfung kann diesen Modus nicht bestätigen.");
                result.LoginSucceeded = true;
                bool anonymousOrGuest = (flags & 3) != 0;
                if (result.SigningRequired && anonymousOrGuest)
                    throw new InvalidDataException("Der Server verlangt SMB-Signaturen, die mit dieser Gastanmeldung nicht verwendet werden können.");
                if (!anonymousOrGuest)
                {
                    sessionKey = auth.SessionKey();
                    signedSession = sessionKey != null && sessionKey.Length != 0;
                    if (result.SigningRequired && !signedSession) throw new InvalidDataException("Der SMB-Sitzungsschlüssel für die erforderliche Signatur fehlt.");
                }
            }

            private static byte[] SessionBody(byte[] token)
            {
                byte[] body = new byte[24 + token.Length];
                U16(body, 0, 25); body[3] = 1;
                U16(body, 12, 88); U16(body, 14, (ushort)token.Length);
                Buffer.BlockCopy(token, 0, body, 24, token.Length);
                return body;
            }

            internal void TreeConnect(string name)
            {
                result.Stage = "TreeConnect";
                byte[] path = Encoding.Unicode.GetBytes("\\\\" + address + "\\" + name);
                byte[] body = new byte[8 + path.Length];
                U16(body, 0, 9); U16(body, 4, 72); U16(body, 6, (ushort)path.Length);
                Buffer.BlockCopy(path, 0, body, 8, path.Length);
                byte[] response = Exchange(3, body, true);
                RequireSuccess(response); RequireLength(response, 80);
                treeId = R32(response, 36);
                if ((R32(response, 68) & 0x8000) != 0)
                    throw new InvalidDataException("Die Freigabe verlangt SMB-Verschlüsselung; eine SMB-2.1-Verbindung ist dafür nicht geeignet.");
                result.TreeConnected = true;
            }

            internal void ListDirectory()
            {
                result.Stage = "OpenDirectory";
                byte[] body = new byte[57];
                U16(body, 0, 57); U32(body, 4, 2); U32(body, 24, 0x00100081);
                U32(body, 28, 0x10); U32(body, 32, 7); U32(body, 36, 1); U32(body, 40, 1); U16(body, 44, 120);
                byte[] response = Exchange(5, body, true);
                RequireSuccess(response); RequireLength(response, 152);
                fileId = new byte[16]; Buffer.BlockCopy(response, 128, fileId, 0, 16);
                result.Stage = "ListDirectory";
                for (int page = 0; page < 32; page++)
                {
                    byte[] query = new byte[34];
                    U16(query, 0, 33); query[2] = 1; query[3] = (byte)(page == 0 ? 1 : 0);
                    Buffer.BlockCopy(fileId, 0, query, 8, 16);
                    U16(query, 24, 96); U16(query, 26, 2); U32(query, 28, 65536); query[32] = (byte)'*';
                    response = Exchange(14, query, true);
                    uint status = R32(response, 8);
                    if (status == 0x80000006) { result.DirectoryListed = true; return; }
                    if (status != 0 && status != 0x80000005) throw new SmbStatusException(status);
                    RequireLength(response, 72);
                    int offset = R16(response, 66); uint wireLength = R32(response, 68);
                    if (wireLength > 1024 * 1024) throw new InvalidDataException("Die Verzeichnisantwort ist zu groß.");
                    int length = (int)wireLength; CheckRange(response, offset, length);
                    int pos = offset, end = offset + length;
                    if (length == 0) { result.DirectoryListed = true; return; }
                    while (pos < end)
                    {
                        if (end - pos < 64) throw new InvalidDataException("Die SMB-Verzeichnisantwort ist unvollständig.");
                        uint nextOffset = R32(response, pos), nameLength = R32(response, pos + 60);
                        if (nameLength > (uint)(end - pos - 64) || (nameLength & 1) != 0)
                            throw new InvalidDataException("Die SMB-Verzeichnisantwort enthält eine ungültige Länge.");
                        bool dot = nameLength == 2 && response[pos + 64] == 46 && response[pos + 65] == 0;
                        bool dotDot = nameLength == 4 && response[pos + 64] == 46 && response[pos + 65] == 0 && response[pos + 66] == 46 && response[pos + 67] == 0;
                        if (!dot && !dotDot) result.EntryCount++;
                        if (nextOffset == 0) break;
                        if (nextOffset < 64 + nameLength || nextOffset > (uint)(end - pos))
                            throw new InvalidDataException("Die SMB-Verzeichnisantwort enthält einen ungültigen Folgeeintrag.");
                        pos += (int)nextOffset;
                    }
                    result.DirectoryListed = true;
                    if (result.EntryCount >= 10000) { result.ListingTruncated = true; return; }
                }
                result.ListingTruncated = true;
            }

            private byte[] Exchange(ushort command, byte[] body, bool maySign)
            {
                RemainingTimeout();
                byte[] packet = new byte[64 + body.Length];
                packet[0] = 0xFE; packet[1] = (byte)'S'; packet[2] = (byte)'M'; packet[3] = (byte)'B';
                U16(packet, 4, 64); U16(packet, 6, 1); U16(packet, 12, command); U16(packet, 14, 1);
                ulong expectedId = messageId++;
                U64(packet, 24, expectedId); U32(packet, 32, 0xFEFF); U32(packet, 36, treeId); U64(packet, 40, sessionId);
                Buffer.BlockCopy(body, 0, packet, 64, body.Length);
                if (maySign && signedSession)
                {
                    U32(packet, 16, 8);
                    using (HMACSHA256 hmac = new HMACSHA256(sessionKey)) Buffer.BlockCopy(hmac.ComputeHash(packet), 0, packet, 48, 16);
                }
                byte[] prefix = new byte[] { 0, (byte)(packet.Length >> 16), (byte)(packet.Length >> 8), (byte)packet.Length };
                SendAll(prefix); SendAll(packet);
                prefix = ReceiveExact(4);
                if (prefix[0] != 0) throw new InvalidDataException("Die SMB-Transportantwort ist ungültig.");
                int length = prefix[1] * 65536 + prefix[2] * 256 + prefix[3];
                if (length < 64 || length > 1024 * 1024) throw new InvalidDataException("Die SMB-Antwort hat eine ungültige Länge.");
                byte[] response = ReceiveExact(length);
                if (response[0] != 0xFE || response[1] != 'S' || response[2] != 'M' || response[3] != 'B' || R16(response, 4) != 64 || R16(response, 12) != command || R64(response, 24) != expectedId || (R32(response, 16) & 1) == 0 || R32(response, 20) != 0)
                    throw new InvalidDataException("Die SMB-Antwort passt nicht zur angefragten Operation.");
                if (maySign && signedSession && (R32(response, 16) & 8) != 0)
                {
                    byte[] signature = new byte[16]; Buffer.BlockCopy(response, 48, signature, 0, 16);
                    Array.Clear(response, 48, 16);
                    byte[] expected;
                    using (HMACSHA256 hmac = new HMACSHA256(sessionKey)) expected = hmac.ComputeHash(response);
                    int difference = 0; for (int n = 0; n < 16; n++) difference |= signature[n] ^ expected[n];
                    if (difference != 0) throw new InvalidDataException("Die Signatur der SMB-Antwort ist ungültig.");
                    Buffer.BlockCopy(signature, 0, response, 48, 16);
                }
                else if (maySign && result.SigningRequired && signedSession)
                    throw new InvalidDataException("Die erforderliche SMB-Antwortsignatur fehlt.");
                return response;
            }

            private void RemainingTimeout()
            {
                int remaining = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
                if (remaining <= 0) throw new TimeoutException();
                socket.SendTimeout = socket.ReceiveTimeout = Math.Min(remaining, 4000);
            }
            private void SendAll(byte[] bytes)
            {
                int offset = 0;
                while (offset < bytes.Length) { RemainingTimeout(); int count = socket.Send(bytes, offset, bytes.Length - offset, SocketFlags.None); if (count == 0) throw new IOException(); offset += count; }
            }
            private byte[] ReceiveExact(int length)
            {
                byte[] bytes = new byte[length]; int offset = 0;
                while (offset < length) { RemainingTimeout(); int count = socket.Receive(bytes, offset, length - offset, SocketFlags.None); if (count == 0) throw new IOException(); offset += count; }
                return bytes;
            }
            public void Dispose()
            {
                if (socket != null)
                {
                    try { if (fileId != null) { byte[] close = new byte[24]; U16(close, 0, 24); Buffer.BlockCopy(fileId, 0, close, 8, 16); Exchange(6, close, true); } } catch { }
                    try { if (treeId != 0) { byte[] disconnect = new byte[4]; U16(disconnect, 0, 4); Exchange(4, disconnect, true); treeId = 0; } } catch { }
                    try { if (sessionId != 0) { byte[] logoff = new byte[4]; U16(logoff, 0, 4); Exchange(2, logoff, true); } } catch { }
                    socket.Dispose(); socket = null;
                }
                if (sessionKey != null) Array.Clear(sessionKey, 0, sessionKey.Length);
                if (fileId != null) Array.Clear(fileId, 0, fileId.Length);
            }
        }

        private sealed class NtlmContext : IDisposable
        {
            private SecHandle credential;
            private SecHandle context;
            private bool hasCredential, hasContext, anonymous;
            internal bool Complete { get; private set; }
            internal NtlmContext(string name, string password)
            {
                string user = name, domain = "";
                int separator = name.IndexOf('\\');
                if (separator >= 0) { domain = name.Substring(0, separator); user = name.Substring(separator + 1); }
                anonymous = user.Length == 0;
                if (anonymous && password.Length != 0) throw new ArgumentException("Eine anonyme Anmeldung darf kein Passwort enthalten.");
                AuthIdentity identity = new AuthIdentity();
                try
                {
                    identity.User = Marshal.StringToHGlobalUni(user); identity.UserLength = user.Length;
                    identity.Domain = Marshal.StringToHGlobalUni(domain); identity.DomainLength = domain.Length;
                    identity.Password = Marshal.StringToHGlobalUni(password); identity.PasswordLength = password.Length; identity.Flags = 2;
                    long expiry;
                    int status = AcquireCredentialsHandle(null, "Negotiate", 2, IntPtr.Zero, ref identity, IntPtr.Zero, IntPtr.Zero, out credential, out expiry);
                    if (status != 0) throw new SspiException(status);
                    hasCredential = true;
                }
                finally
                {
                    if (identity.Password != IntPtr.Zero) { for (int n = 0; n <= password.Length; n++) Marshal.WriteInt16(identity.Password, n * 2, 0); Marshal.FreeHGlobal(identity.Password); }
                    if (identity.User != IntPtr.Zero) Marshal.FreeHGlobal(identity.User);
                    if (identity.Domain != IntPtr.Zero) Marshal.FreeHGlobal(identity.Domain);
                }
            }

            internal byte[] Next(byte[] input, string host)
            {
                using (TokenBuffer output = new TokenBuffer(new byte[65536]))
                using (TokenBuffer incoming = input == null ? null : new TokenBuffer(input))
                {
                    uint attributes; long expiry;
                    uint flags = 0x0001080C; // Connection, integrity, replay and sequence protection.
                    if (anonymous) flags |= 0x00040000; // ISC_REQ_NULL_SESSION, never default user credentials.
                    int status;
                    if (!hasContext)
                        status = InitializeFirst(ref credential, IntPtr.Zero, "cifs/" + host, flags, 0, 0x10, IntPtr.Zero, 0, out context, ref output.Descriptor, out attributes, out expiry);
                    else
                        status = InitializeNext(ref credential, ref context, "cifs/" + host, flags, 0, 0x10, ref incoming.Descriptor, 0, out context, ref output.Descriptor, out attributes, out expiry);
                    if (status < 0) throw new SspiException(status);
                    hasContext = true;
                    if (status == 0x00090313 || status == 0x00090314)
                    {
                        int complete = CompleteAuthToken(ref context, ref output.Descriptor);
                        if (complete < 0) throw new SspiException(complete);
                    }
                    Complete = status == 0 || status == 0x00090313;
                    return output.Read();
                }
            }

            internal byte[] SessionKey()
            {
                ContextSessionKey key;
                int status = QueryContextAttributes(ref context, 9, out key);
                if (status != 0) throw new SspiException(status);
                try
                {
                    if (key.Length < 0 || key.Length > 1024) throw new InvalidDataException("Der NTLM-Sitzungsschlüssel hat eine ungültige Länge.");
                    byte[] bytes = new byte[key.Length]; if (key.Length != 0) Marshal.Copy(key.Key, bytes, 0, key.Length); return bytes;
                }
                finally { if (key.Key != IntPtr.Zero) FreeContextBuffer(key.Key); }
            }

            internal string Protocol()
            {
                NegotiationInfo info;
                int status = QueryNegotiationInfo(ref context, 12, out info);
                if (status != 0) throw new SspiException(status);
                try
                {
                    if (info.PackageInfo == IntPtr.Zero) throw new InvalidDataException("Der Sicherheitsanbieter hat kein Anmeldeprotokoll bestätigt.");
                    PackageInfo package = (PackageInfo)Marshal.PtrToStructure(info.PackageInfo, typeof(PackageInfo));
                    return Marshal.PtrToStringUni(package.Name) ?? "";
                }
                finally { if (info.PackageInfo != IntPtr.Zero) FreeContextBuffer(info.PackageInfo); }
            }

            public void Dispose()
            {
                if (hasContext) { DeleteSecurityContext(ref context); hasContext = false; }
                if (hasCredential) { FreeCredentialsHandle(ref credential); hasCredential = false; }
            }
        }

        private sealed class TokenBuffer : IDisposable
        {
            internal SecBufferDesc Descriptor;
            private IntPtr data, buffer;
            private int allocation;
            internal TokenBuffer(byte[] bytes)
            {
                allocation = bytes.Length; data = Marshal.AllocHGlobal(Math.Max(1, allocation));
                if (allocation != 0) Marshal.Copy(bytes, 0, data, allocation);
                SecBuffer value = new SecBuffer { Count = allocation, Type = 2, Pointer = data };
                buffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SecBuffer))); Marshal.StructureToPtr(value, buffer, false);
                Descriptor = new SecBufferDesc { Version = 0, Count = 1, Buffers = buffer };
            }
            internal byte[] Read()
            {
                SecBuffer value = (SecBuffer)Marshal.PtrToStructure(buffer, typeof(SecBuffer));
                if (value.Count < 0 || value.Count > allocation || value.Pointer != data) throw new InvalidDataException("Die NTLM-Antwort hat eine ungültige Länge.");
                byte[] bytes = new byte[value.Count]; if (value.Count != 0) Marshal.Copy(data, bytes, 0, value.Count); return bytes;
            }
            public void Dispose()
            {
                if (data != IntPtr.Zero) { byte[] empty = new byte[allocation]; if (allocation != 0) Marshal.Copy(empty, 0, data, allocation); Marshal.FreeHGlobal(data); data = IntPtr.Zero; }
                if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero; }
            }
        }

        [StructLayout(LayoutKind.Sequential)] private struct SecHandle { internal IntPtr Lower; internal IntPtr Upper; }
        [StructLayout(LayoutKind.Sequential)] private struct AuthIdentity { internal IntPtr User; internal int UserLength; internal IntPtr Domain; internal int DomainLength; internal IntPtr Password; internal int PasswordLength; internal int Flags; }
        [StructLayout(LayoutKind.Sequential)] private struct SecBuffer { internal int Count; internal int Type; internal IntPtr Pointer; }
        [StructLayout(LayoutKind.Sequential)] private struct SecBufferDesc { internal int Version; internal int Count; internal IntPtr Buffers; }
        [StructLayout(LayoutKind.Sequential)] private struct ContextSessionKey { internal int Length; internal IntPtr Key; }
        [StructLayout(LayoutKind.Sequential)] private struct NegotiationInfo { internal IntPtr PackageInfo; internal uint State; }
        [StructLayout(LayoutKind.Sequential)] private struct PackageInfo { internal uint Capabilities; internal ushort Version; internal ushort RpcId; internal uint MaxToken; internal IntPtr Name; internal IntPtr Comment; }
        [DllImport("secur32.dll", EntryPoint = "AcquireCredentialsHandleW", CharSet = CharSet.Unicode)] private static extern int AcquireCredentialsHandle(string principal, string package, uint use, IntPtr logonId, ref AuthIdentity identity, IntPtr callback, IntPtr callbackArgument, out SecHandle handle, out long expiry);
        [DllImport("secur32.dll", EntryPoint = "InitializeSecurityContextW", CharSet = CharSet.Unicode)] private static extern int InitializeFirst(ref SecHandle credential, IntPtr oldContext, string target, uint flags, uint reserved, uint representation, IntPtr input, uint reserved2, out SecHandle context, ref SecBufferDesc output, out uint attributes, out long expiry);
        [DllImport("secur32.dll", EntryPoint = "InitializeSecurityContextW", CharSet = CharSet.Unicode)] private static extern int InitializeNext(ref SecHandle credential, ref SecHandle oldContext, string target, uint flags, uint reserved, uint representation, ref SecBufferDesc input, uint reserved2, out SecHandle context, ref SecBufferDesc output, out uint attributes, out long expiry);
        [DllImport("secur32.dll")] private static extern int CompleteAuthToken(ref SecHandle context, ref SecBufferDesc token);
        [DllImport("secur32.dll", EntryPoint = "QueryContextAttributesW")] private static extern int QueryContextAttributes(ref SecHandle context, uint attribute, out ContextSessionKey key);
        [DllImport("secur32.dll", EntryPoint = "QueryContextAttributesW")] private static extern int QueryNegotiationInfo(ref SecHandle context, uint attribute, out NegotiationInfo info);
        [DllImport("secur32.dll")] private static extern int FreeContextBuffer(IntPtr pointer);
        [DllImport("secur32.dll")] private static extern int DeleteSecurityContext(ref SecHandle context);
        [DllImport("secur32.dll")] private static extern int FreeCredentialsHandle(ref SecHandle credential);
        private static void RequireSuccess(byte[] response) { uint status = R32(response, 8); if (status != 0) throw new SmbStatusException(status); }
        private static void RequireLength(byte[] bytes, int length) { if (bytes.Length < length) throw new InvalidDataException("Die SMB-Antwort ist unvollständig."); }
        private static void CheckRange(byte[] bytes, int offset, int length) { if (offset < 64 || length < 0 || offset > bytes.Length - length) throw new InvalidDataException("Die SMB-Antwort enthält einen ungültigen Datenbereich."); }
        private static ushort R16(byte[] b, int o) { return (ushort)(b[o] | b[o + 1] << 8); }
        private static uint R32(byte[] b, int o) { return (uint)(b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24); }
        private static ulong R64(byte[] b, int o) { return R32(b, o) | (ulong)R32(b, o + 4) << 32; }
        private static void U16(byte[] b, int o, ushort v) { b[o] = (byte)v; b[o + 1] = (byte)(v >> 8); }
        private static void U32(byte[] b, int o, uint v) { for (int n = 0; n < 4; n++) b[o + n] = (byte)(v >> (8 * n)); }
        private static void U64(byte[] b, int o, ulong v) { for (int n = 0; n < 8; n++) b[o + n] = (byte)(v >> (8 * n)); }
    }
}
