using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace EinfachNetzwerk
{
    public sealed class DiscoveryPeerShare
    {
        public string Name { get; set; }
        public string Remark { get; set; }
    }
    public sealed class DiscoveryPeerAdvertisement
    {
        public string Address { get; set; }
        public string ComputerName { get; set; }
        public DiscoveryPeerShare[] Shares { get; set; }
    }

    // This optional running-app responder publishes public connection hints.
    // It never authenticates, opens files, changes Windows or confirms SMB access.
    public sealed class DiscoveryPeerService : IDisposable
    {
        public const int Port = 41671;
        const string Protocol = "EN-DISCOVER-1";
        const int DatagramLimit = 8192, ShareLimit = 32, PeerLimit = 128;
        readonly object gate = new object();
        readonly Func<IList<NetworkItem>> readNetworks;
        readonly Func<DiscoveryPeerShare[]> readShares;
        readonly Func<DateTime> now;
        readonly string computer;
        Dictionary<string, string> inventory = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        DiscoveryPeerShare[] cachedShares = new DiscoveryPeerShare[0];
        DateTime cacheTime = DateTime.MinValue;
        Task<DiscoveryPeerShare[]> pendingShares;
        Socket listener;
        Thread listenerThread;
        volatile bool stopping;
        public bool IsListening { get { return listener != null && !stopping; } }
        public string ErrorMessage { get; private set; }
        public string ErrorCode { get; private set; }

        internal DiscoveryPeerService(Func<IList<NetworkItem>> networks, Func<DiscoveryPeerShare[]> shares, Func<DateTime> clock, string name)
        { readNetworks = networks; readShares = shares; now = clock; computer = name; }

        public static DiscoveryPeerService Start()
        {
            DiscoveryPeerService service = new DiscoveryPeerService(ReadNetworks, ReadLocalShares, delegate { return DateTime.UtcNow; }, Environment.MachineName);
            try
            {
                service.listener = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                service.listener.ExclusiveAddressUse = true;
                service.listener.ReceiveTimeout = 250;
                service.listener.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.PacketInformation, true);
                service.listener.Bind(new IPEndPoint(IPAddress.Any, Port));
                service.listenerThread = new Thread(service.Listen) { IsBackground = true, Name = "EinfachNetzwerk discovery responder" };
                service.listenerThread.Start();
            }
            catch (Exception error)
            {
                service.ErrorMessage = error.Message;
                System.ComponentModel.Win32Exception native = error as System.ComponentModel.Win32Exception;
                service.ErrorCode = native == null ? "HRESULT: 0x" + error.HResult.ToString("X8") : "Win32: " + native.NativeErrorCode;
                if (service.listener != null) service.listener.Dispose();
                service.listener = null;
            }
            return service;
        }

        public void UpdateInventory(ShareItem[] ownInventory)
        {
            Dictionary<string, string> copy = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (ShareItem share in (ownInventory ?? new ShareItem[0]).Take(256))
            {
                if (share == null || !share.Managed || !share.Available || !ValidShare(share.Name) || !ValidAccount(share.UserName)) continue;
                if (share.Mode != "Guest" && share.Mode != "Password") continue;
                copy[share.Name] = MakeRemark(share.Mode, computer, share.UserName);
            }
            lock (gate) { inventory = copy; cachedShares = new DiscoveryPeerShare[0]; cacheTime = DateTime.MinValue; }
        }

        internal DiscoveryPeerShare[] GetPublishedShares()
        {
            DateTime current = now();
            Task<DiscoveryPeerShare[]> pending;
            lock (gate)
            {
                if (current >= cacheTime && (current - cacheTime).TotalSeconds < 5) return cachedShares.ToArray();
                if (pendingShares == null) pendingShares = Task.Run(readShares);
                pending = pendingShares;
            }
            try { if (!pending.Wait(500)) return new DiscoveryPeerShare[0]; }
            catch (AggregateException) { lock (gate) { if (pendingShares == pending) pendingShares = null; } return new DiscoveryPeerShare[0]; }
            DiscoveryPeerShare[] result = new DiscoveryPeerShare[0];
            lock (gate)
            {
                List<DiscoveryPeerShare> accepted = new List<DiscoveryPeerShare>();
                foreach (DiscoveryPeerShare share in (pending.Result ?? new DiscoveryPeerShare[0]).Take(256))
                {
                    if (share == null || !ValidShare(share.Name)) continue;
                    string mode, account, remark = share.Remark;
                    if (remark == "EinfachNetzwerk-v1")
                    {
                        if (!inventory.TryGetValue(share.Name, out remark)) continue;
                    }
                    if (!TryParseRemark(remark, computer, out mode, out account)) continue;
                    if (accepted.Any(item => String.Equals(item.Name, share.Name, StringComparison.OrdinalIgnoreCase))) continue;
                    accepted.Add(new DiscoveryPeerShare { Name = share.Name, Remark = remark });
                    if (accepted.Count == ShareLimit) break;
                }
                result = accepted.ToArray(); cachedShares = result; cacheTime = now();
                if (pendingShares == pending) pendingShares = null;
            }
            return result.ToArray();
        }

        void Listen()
        {
            byte[] buffer = new byte[DatagramLimit + 1];
            Dictionary<string, DateTime> recent = new Dictionary<string, DateTime>();
            DateTime window = DateTime.UtcNow; int replied = 0;
            while (!stopping)
            {
                try
                {
                    EndPoint endpoint = new IPEndPoint(IPAddress.Any, 0);
                    SocketFlags flags = SocketFlags.None; IPPacketInformation packet;
                    int length = listener.ReceiveMessageFrom(buffer, 0, buffer.Length, ref flags, ref endpoint, out packet);
                    if (length <= 0 || length > DatagramLimit || flags != SocketFlags.None) continue;
                    IPEndPoint sender = (IPEndPoint)endpoint;
                    byte[] request = new byte[length]; Buffer.BlockCopy(buffer, 0, request, 0, length);
                    if (!ValidRequest(request)) continue;
                    DateTime current = now(); DateTime previous;
                    if ((current - window).TotalSeconds >= 1 || current < window) { replied = 0; window = current; }
                    if (replied >= 8 || (recent.TryGetValue(sender.Address.ToString(), out previous) && (current - previous).TotalMilliseconds < 250)) continue;
                    // Refresh physical/private profiles before every response.
                    IList<NetworkItem> networks = readNetworks();
                    if (!EligibleSender(sender.Address, networks, packet.Interface)) continue;
                    byte[] response = BuildResponse(request, sender, packet.Interface, networks, GetPublishedShares(), computer);
                    if (response == null) continue;
                    listener.SendTo(response, sender); replied++;
                    recent[sender.Address.ToString()] = current;
                    if (recent.Count > PeerLimit) recent.Clear();
                }
                catch (SocketException error) { if (stopping) break; if (error.SocketErrorCode != SocketError.TimedOut && error.SocketErrorCode != SocketError.Interrupted) Thread.Sleep(25); }
                catch (ObjectDisposedException) { break; }
                catch (Exception) { if (!stopping) Thread.Sleep(25); }
            }
        }

        public void Dispose()
        {
            stopping = true;
            Socket socket = listener;
            if (socket != null) socket.Dispose();
            if (listenerThread != null && listenerThread != Thread.CurrentThread) listenerThread.Join(800);
            listener = null;
        }

        public static DiscoveryPeerAdvertisement[] DiscoverPeers(IList<NetworkItem> networks, CancellationToken cancellation)
        { return DiscoverCore(networks, cancellation, ReadNetworks, Exchange); }

        internal sealed class Datagram { internal byte[] Data; internal IPEndPoint Sender; }
        internal static DiscoveryPeerAdvertisement[] DiscoverCore(IList<NetworkItem> requested, CancellationToken cancellation,
            Func<IList<NetworkItem>> freshNetworks, Func<IList<NetworkItem>, string, CancellationToken, IEnumerable<Datagram>> exchange)
        {
            cancellation.ThrowIfCancellationRequested();
            IList<NetworkItem> confirmed;
            try { confirmed = MatchNetworks(requested, freshNetworks()); } catch (Exception) { return new DiscoveryPeerAdvertisement[0]; }
            if (confirmed.Count == 0) return new DiscoveryPeerAdvertisement[0];
            string nonce = Guid.NewGuid().ToString("N");
            Dictionary<string, DiscoveryPeerAdvertisement> result = new Dictionary<string, DiscoveryPeerAdvertisement>(StringComparer.OrdinalIgnoreCase);
            foreach (Datagram message in exchange(confirmed, nonce, cancellation))
            {
                cancellation.ThrowIfCancellationRequested();
                IList<NetworkItem> current;
                try { current = MatchNetworks(confirmed, freshNetworks()); } catch (Exception) { continue; }
                if (message == null) continue;
                DiscoveryPeerAdvertisement peer = ParseResponse(message.Data, message.Sender, nonce, current);
                if (peer == null || result.ContainsKey(peer.Address)) continue;
                result.Add(peer.Address, peer);
                if (result.Count >= PeerLimit) break;
            }
            return result.Values.ToArray();
        }

        static IEnumerable<Datagram> Exchange(IList<NetworkItem> networks, string nonce, CancellationToken cancellation)
        {
            List<Socket> sockets = new List<Socket>(); List<Datagram> messages = new List<Datagram>();
            try
            {
                byte[] request = Encoding.ASCII.GetBytes(Protocol + " " + nonce);
                foreach (NetworkItem network in networks.Take(8))
                {
                    cancellation.ThrowIfCancellationRequested();
                    Socket socket = null;
                    try
                    {
                        IPAddress source = IPAddress.Parse(network.Address); uint mask; uint subnet; int prefix;
                        if (!TrySubnet(network, out subnet, out mask, out prefix)) continue;
                        socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                        socket.EnableBroadcast = true; socket.ReceiveTimeout = 50;
                        socket.Bind(new IPEndPoint(source, 0));
                        socket.SendTo(request, new IPEndPoint(FromNumber(subnet | ~mask), Port)); sockets.Add(socket); socket = null;
                    }
                    catch (SocketException) { }
                    finally { if (socket != null) socket.Dispose(); }
                }
                Stopwatch deadline = Stopwatch.StartNew(); byte[] buffer = new byte[DatagramLimit + 1];
                while (deadline.ElapsedMilliseconds < 900 && messages.Count < PeerLimit * 2 && sockets.Count > 0)
                {
                    cancellation.ThrowIfCancellationRequested();
                    foreach (Socket socket in sockets)
                    {
                        if (!socket.Poll(0, SelectMode.SelectRead)) continue;
                        try
                        {
                            EndPoint sender = new IPEndPoint(IPAddress.Any, 0); int length = socket.ReceiveFrom(buffer, ref sender);
                            if (length > 0 && length <= DatagramLimit)
                            { byte[] data = new byte[length]; Buffer.BlockCopy(buffer, 0, data, 0, length); messages.Add(new Datagram { Data = data, Sender = (IPEndPoint)sender }); }
                        }
                        catch (SocketException) { }
                    }
                    if (cancellation.WaitHandle.WaitOne(10)) cancellation.ThrowIfCancellationRequested();
                }
                return messages;
            }
            finally { foreach (Socket socket in sockets) socket.Dispose(); }
        }

        internal static byte[] BuildResponse(byte[] request, IPEndPoint sender, int interfaceIndex, IList<NetworkItem> networks, DiscoveryPeerShare[] shares, string name)
        {
            if (!ValidRequest(request) || sender == null || sender.Port < 1 || !ValidComputer(name) || !EligibleSender(sender.Address, networks, interfaceIndex)) return null;
            string text = Encoding.ASCII.GetString(request); string nonce = text.Substring(Protocol.Length + 1);
            List<DiscoveryPeerShare> accepted = new List<DiscoveryPeerShare>();
            foreach (DiscoveryPeerShare share in (shares ?? new DiscoveryPeerShare[0]).Take(256))
            {
                string mode, account;
                if (share == null || !ValidShare(share.Name) || !TryParseRemark(share.Remark, name, out mode, out account) || accepted.Any(item => item.Name.Equals(share.Name, StringComparison.OrdinalIgnoreCase))) continue;
                accepted.Add(new DiscoveryPeerShare { Name = share.Name, Remark = share.Remark });
                if (accepted.Count == ShareLimit) break;
            }
            if (accepted.Count == 0) return null;
            JavaScriptSerializer json = Serializer();
            while (accepted.Count > 0)
            {
                byte[] bytes = Encoding.UTF8.GetBytes(json.Serialize(new { Protocol = Protocol, Nonce = nonce, ComputerName = name, Shares = accepted.ToArray() }));
                if (bytes.Length <= DatagramLimit) return bytes;
                accepted.RemoveAt(accepted.Count - 1);
            }
            return null;
        }

        static bool ValidRequest(byte[] request)
        {
            if (request == null || request.Length != Protocol.Length + 1 + 32 || request.Any(value => value > 127)) return false;
            string text = Encoding.ASCII.GetString(request);
            return text.StartsWith(Protocol + " ", StringComparison.Ordinal) && Regex.IsMatch(text.Substring(Protocol.Length + 1), "^[0-9a-f]{32}$");
        }

        internal static DiscoveryPeerAdvertisement ParseResponse(byte[] data, IPEndPoint sender, string nonce, IList<NetworkItem> networks)
        {
            if (data == null || data.Length < 1 || data.Length > DatagramLimit || sender == null || sender.Port != Port || !EligibleSender(sender.Address, networks, 0)) return null;
            try
            {
                Dictionary<string, object> packet = Serializer().DeserializeObject(new UTF8Encoding(false, true).GetString(data)) as Dictionary<string, object>;
                if (packet == null || packet.Count != 4 || Text(packet, "Protocol") != Protocol || Text(packet, "Nonce") != nonce) return null;
                string name = Text(packet, "ComputerName");
                object raw; if (!ValidComputer(name) || !packet.TryGetValue("Shares", out raw)) return null;
                object[] array = raw as object[];
                if (array == null || array.Length < 1 || array.Length > ShareLimit) return null;
                List<DiscoveryPeerShare> shares = new List<DiscoveryPeerShare>();
                foreach (object item in array)
                {
                    Dictionary<string, object> share = item as Dictionary<string, object>;
                    string mode, user;
                    if (share == null || share.Count != 2 || !ValidShare(Text(share, "Name")) || !TryParseRemark(Text(share, "Remark"), name, out mode, out user)) return null;
                    if (shares.Any(old => old.Name.Equals(Text(share, "Name"), StringComparison.OrdinalIgnoreCase))) return null;
                    shares.Add(new DiscoveryPeerShare { Name = Text(share, "Name"), Remark = Text(share, "Remark") });
                }
                return new DiscoveryPeerAdvertisement { Address = sender.Address.ToString(), ComputerName = name, Shares = shares.ToArray() };
            }
            catch (Exception) { return null; }
        }

        static string Text(Dictionary<string, object> value, string key) { object result; return value.TryGetValue(key, out result) ? result as string : null; }
        static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = DatagramLimit, RecursionLimit = 8 }; }
        internal static string MakeRemark(string mode, string name, string account)
        { return "[EinfachNetzwerk:1;mode=" + Uri.EscapeDataString(mode) + ";computer=" + Uri.EscapeDataString(name) + ";user=" + Uri.EscapeDataString(account) + "]"; }
        internal static bool TryParseRemark(string remark, string name, out string mode, out string account)
        {
            mode = account = null;
            if (String.IsNullOrEmpty(remark) || remark.Length > 512 || !ValidComputer(name)) return false;
            Match match = Regex.Match(remark, @"^\[EinfachNetzwerk:1;mode=([^;\]\r\n]+);computer=([^;\]\r\n]+);user=([^;\]\r\n]+)\]$");
            if (!match.Success) return false;
            try
            {
                foreach (Group group in match.Groups.Cast<Group>().Skip(1)) if (Regex.IsMatch(group.Value, "%(?![0-9a-fA-F]{2})")) return false;
                mode = Uri.UnescapeDataString(match.Groups[1].Value);
                string reported = Uri.UnescapeDataString(match.Groups[2].Value); account = Uri.UnescapeDataString(match.Groups[3].Value);
                if ((mode != "Guest" && mode != "Password") || !reported.Equals(name, StringComparison.OrdinalIgnoreCase) || !ValidAccount(account)) { mode = account = null; return false; }
                return true;
            }
            catch (Exception) { mode = account = null; return false; }
        }
        static bool ValidComputer(string name)
        { return name != null && Regex.IsMatch(name, "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$") && !Regex.IsMatch(name, "^[0-9]+$"); }
        static bool ValidAccount(string account)
        { return !String.IsNullOrWhiteSpace(account) && account.Length <= 20 && account == account.Trim() && account != "." && account != ".." && !Regex.IsMatch(account, @"[\\/\[\]:;|=,+*?<>""\x00-\x1f\x7f]"); }
        static bool ValidShare(string name)
        { return !String.IsNullOrWhiteSpace(name) && name.Length <= 80 && name == name.Trim() && !name.EndsWith(".", StringComparison.Ordinal) && name.IndexOf('$') < 0 && !Regex.IsMatch(name, @"[\\/\[\]:;|=,+*?<>""\x00-\x1f\x7f]") && !Regex.IsMatch(name, "^(ADMIN|IPC|PRINT)$", RegexOptions.IgnoreCase); }
        static IList<NetworkItem> ReadNetworks()
        { return new JavaScriptSerializer().Deserialize<NetworkItem[]>(NativeHomeNetworks.ReadJson()) ?? new NetworkItem[0]; }
        static IList<NetworkItem> MatchNetworks(IList<NetworkItem> requested, IList<NetworkItem> fresh)
        {
            return (fresh ?? new NetworkItem[0]).Where(item => item != null && item.Category == "Private" && (requested ?? new NetworkItem[0]).Any(old => old != null && old.Category == "Private" && old.Id == item.Id && old.Address == item.Address && old.Subnet == item.Subnet)).Take(8).ToArray();
        }
        internal static bool EligibleSender(IPAddress sender, IList<NetworkItem> networks, int interfaceIndex)
        {
            if (!PrivateAddress(sender)) return false;
            uint address = Number(sender);
            foreach (NetworkItem network in networks ?? new NetworkItem[0])
            {
                uint subnet, mask; int prefix; IPAddress local;
                if (network == null || network.Category != "Private" || network.Id <= 0 || (interfaceIndex != 0 && interfaceIndex != network.Id) || !IPAddress.TryParse(network.Address, out local) || !TrySubnet(network, out subnet, out mask, out prefix)) continue;
                if ((address & mask) == subnet && address != subnet && address != (subnet | ~mask) && address != Number(local)) return true;
            }
            return false;
        }
        static bool TrySubnet(NetworkItem network, out uint subnet, out uint mask, out int prefix)
        {
            subnet = mask = 0; prefix = 0; IPAddress local, baseAddress;
            string[] parts = (network.Subnet ?? "").Split('/');
            if (parts.Length != 2 || !Int32.TryParse(parts[1], out prefix) || prefix < 8 || prefix > 30 || !IPAddress.TryParse(parts[0], out baseAddress) || !IPAddress.TryParse(network.Address, out local) || !PrivateAddress(baseAddress) || !PrivateAddress(local)) return false;
            byte first = local.GetAddressBytes()[0]; int minimum = first == 10 ? 8 : first == 172 ? 12 : 16;
            if (prefix < minimum) return false;
            mask = UInt32.MaxValue << (32 - prefix); subnet = Number(baseAddress);
            return (subnet & mask) == subnet && (Number(local) & mask) == subnet && Number(local) != subnet && Number(local) != (subnet | ~mask);
        }
        static bool PrivateAddress(IPAddress address)
        { if (address == null || address.AddressFamily != AddressFamily.InterNetwork) return false; byte[] a = address.GetAddressBytes(); return a[0] == 10 || (a[0] == 172 && a[1] >= 16 && a[1] <= 31) || (a[0] == 192 && a[1] == 168); }
        static uint Number(IPAddress address) { byte[] a = address.GetAddressBytes(); return ((uint)a[0] << 24) | ((uint)a[1] << 16) | ((uint)a[2] << 8) | a[3]; }
        static IPAddress FromNumber(uint number) { return new IPAddress(new byte[] { (byte)(number >> 24), (byte)(number >> 16), (byte)(number >> 8), (byte)number }); }

        static DiscoveryPeerShare[] ReadLocalShares()
        {
            List<DiscoveryPeerShare> result = new List<DiscoveryPeerShare>(); uint resume = 0;
            for (int page = 0; page < 8; page++)
            {
                IntPtr buffer = IntPtr.Zero; uint read, total;
                try
                {
                    uint status = NetShareEnum(null, 1, out buffer, 16384, out read, out total, ref resume);
                    if (status != 0 && status != 234) return new DiscoveryPeerShare[0];
                    if (read > 256 || (read > 0 && buffer == IntPtr.Zero)) return new DiscoveryPeerShare[0];
                    int size = Marshal.SizeOf(typeof(ShareInfo1));
                    for (uint index = 0; index < read; index++)
                    {
                        ShareInfo1 share = (ShareInfo1)Marshal.PtrToStructure(IntPtr.Add(buffer, checked((int)index * size)), typeof(ShareInfo1));
                        if (share.Type != 0) continue;
                        string name = Marshal.PtrToStringUni(share.Name); string remark = Marshal.PtrToStringUni(share.Remark);
                        if (ValidShare(name) && remark != null && remark.Length <= 512) result.Add(new DiscoveryPeerShare { Name = name, Remark = remark });
                        if (result.Count >= 256) return result.ToArray();
                    }
                    if (status == 0) return result.ToArray();
                }
                finally { if (buffer != IntPtr.Zero) NetApiBufferFree(buffer); }
            }
            return new DiscoveryPeerShare[0];
        }
        [StructLayout(LayoutKind.Sequential)] struct ShareInfo1 { public IntPtr Name; public uint Type; public IntPtr Remark; }
        [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] static extern uint NetShareEnum(string server, uint level, out IntPtr buffer, uint preferredMaximum, out uint read, out uint total, ref uint resume);
        [DllImport("netapi32.dll")] static extern uint NetApiBufferFree(IntPtr buffer);
    }
}
