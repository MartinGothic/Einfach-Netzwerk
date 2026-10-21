using System;
using System.Collections.Generic;
using System.ComponentModel;
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
    public sealed class DiscoveryResult
    {
        public List<DiscoveredComputer> Computers { get; set; }
        public List<string> Errors { get; set; }
        public int CandidateCount { get; set; }
        public int CompletedCount { get; set; }
        public bool Truncated { get; set; }
        public bool Cancelled { get; set; }
        public bool TimedOut { get; set; }
        public DiscoveryResult() { Computers = new List<DiscoveredComputer>(); Errors = new List<string>(); }
    }
    public sealed class DiscoveryProgress
    {
        public int Completed { get; set; }
        public int Total { get; set; }
        public int Percent { get; set; }
        public string Phase { get; set; }
        public DiscoveredComputer Computer { get; set; }
    }
    public sealed class DiscoveredComputer
    {
        public string Address { get; set; }
        public string ComputerName { get; set; }
        public string DisplayName { get; set; }
        public int AdapterId { get; set; }
        public bool Port445Open { get; set; }
        public bool Port445Checked { get; set; }
        public bool IdentityVerified { get; set; }
        public int IdentityCode { get; set; }
        public int ShareCode { get; set; }
        public bool SharesComplete { get; set; }
        public bool ReportedIdentity { get; set; }
        public string MetadataContext { get; set; }
        public string ConnectionUserName { get; set; }
        public bool ConnectionUserNameVerified { get; set; }
        public string ErrorCode { get; set; }
        public string ErrorMessage { get; set; }
        public List<DiscoveredShare> Shares { get; set; }
        public DiscoveredComputer() { ComputerName = DisplayName = ErrorCode = ErrorMessage = MetadataContext = ConnectionUserName = ""; Shares = new List<DiscoveredShare>(); }
        public override string ToString() { return String.IsNullOrEmpty(ComputerName) ? Address : ComputerName + " · " + Address; }
    }
    public sealed class DiscoveredShare
    {
        public string Name { get; set; }
        public string Remark { get; set; }
        public string SuggestedUserName { get; set; }
        public string AccessMode { get; set; }
        // Validated public advertisement, not proof that the account can log on.
        public bool MetadataVerified { get; set; }
        public DiscoveredShare() { Name = Remark = SuggestedUserName = AccessMode = ""; }
        public override string ToString() { return Name; }
    }

    // Discovery never calls WNetAddConnection, changes client/server settings,
    // reads passwords, or guesses accounts. The ordinary Windows context may
    // already have a connection; metadata enumeration uses that same context.
    public static class NetworkDiscovery
    {
        const int MaximumCandidates = 1024, MaximumMetadataHosts = 64;
        static readonly SemaphoreSlim NativeSlots = new SemaphoreSlim(8, 8);
        sealed class Candidate
        {
            public string Address;
            public string Source;
            public string Subnet;
            public int AdapterId;
        }
        sealed class ScanScope
        {
            readonly object gate = new object();
            readonly Func<List<NativeHomeNetworks.HomeNetwork>> read;
            List<NativeHomeNetworks.HomeNetwork> fresh;
            DateTime expires;
            public volatile bool Changed;
            public ScanScope() : this(delegate { return new JavaScriptSerializer().Deserialize<List<NativeHomeNetworks.HomeNetwork>>(NativeHomeNetworks.ReadJson()); }) { }
            public ScanScope(Func<List<NativeHomeNetworks.HomeNetwork>> inventory) { read = inventory; }
            public bool Eligible(Candidate target, bool force)
            {
                lock (gate)
                {
                    if (Changed) return false;
                    if (force || fresh == null || DateTime.UtcNow >= expires)
                    {
                        try { fresh = read() ?? new List<NativeHomeNetworks.HomeNetwork>(); }
                        catch (Exception) { fresh = new List<NativeHomeNetworks.HomeNetwork>(); }
                        expires = DateTime.UtcNow.AddMilliseconds(1000);
                    }
                    bool eligible = fresh.Any(item => ValidNetwork(item) && item.Id == target.AdapterId && item.Address == target.Source
                        && item.Subnet == target.Subnet && EligibleAddress(target.Address, item.Subnet));
                    if (!eligible) Changed = true;
                    return eligible;
                }
            }
        }
        sealed class Plan
        {
            public List<Candidate> Candidates = new List<Candidate>();
            public bool Truncated;
        }
        sealed class NativeResult
        {
            public int Code;
            public string Name = "", ErrorCode = "", ErrorMessage = "";
            public List<DiscoveredShare> Shares = new List<DiscoveredShare>();
            public List<ExistingConnection> Connections = new List<ExistingConnection>();
            public bool Complete;
        }
        sealed class ExistingConnection
        {
            public string Host, RemotePath, UserName;
        }
        public static DiscoveryResult Scan(Action<DiscoveryProgress> progress, CancellationToken cancellation)
        {
            var result = new DiscoveryResult();
            if (cancellation.IsCancellationRequested) { result.Cancelled = true; return result; }
            List<NativeHomeNetworks.HomeNetwork> networks;
            try
            {
                networks = new JavaScriptSerializer().Deserialize<List<NativeHomeNetworks.HomeNetwork>>(NativeHomeNetworks.ReadJson());
            }
            catch (Exception error)
            {
                result.Errors.Add("NETWORK_INVENTORY: " + error.Message); return result;
            }
            var neighbors = ReadNeighbors();
            try
            {
                var peerNetworks = networks.Select(item => new NetworkItem { Id = item.Id, Name = item.Name, Address = item.Address,
                    Subnet = item.Subnet, Category = item.Category }).ToList();
                foreach (var peer in DiscoveryPeerService.DiscoverPeers(peerNetworks, cancellation))
                {
                    var network = networks.FirstOrDefault(item => ValidNetwork(item) && EligibleAddress(peer.Address, item.Subnet)
                        && peer.Address != item.Address && !networks.Any(local => local.Address == peer.Address));
                    if (network == null || !ValidComputerName(peer.ComputerName) || result.Computers.Any(item => item.Address == peer.Address)) continue;
                    var reported = new DiscoveredComputer { Address = peer.Address, ComputerName = peer.ComputerName,
                        DisplayName = peer.ComputerName + " · " + peer.Address, AdapterId = network.Id, ReportedIdentity = true };
                    foreach (var item in peer.Shares)
                    {
                        if (!ValidShareName(item.Name)) continue;
                        var share = new DiscoveredShare { Name = item.Name, Remark = item.Remark };
                        ReadAdvertisement(share, reported.ComputerName, true);
                        if (share.MetadataVerified) reported.Shares.Add(share);
                    }
                    result.Computers.Add(reported);
                    List<string> hints; if (!neighbors.TryGetValue(network.Id, out hints)) { hints = new List<string>(); neighbors[network.Id] = hints; }
                    hints.Insert(0, peer.Address);
                    Publish(progress, "peer", result.Computers.Count, 0, 0, reported);
                }
            }
            catch (OperationCanceledException) { result.Cancelled = true; return result; }
            catch (Exception error) { result.Errors.Add("DISCOVERY_PEER: " + error.Message); }
            var plan = PlanCandidates(networks, neighbors, MaximumCandidates, LocalAddresses());
            result.CandidateCount = plan.Candidates.Count;
            result.Truncated = plan.Truncated;
            if (plan.Candidates.Count == 0) { Publish(progress, "complete", 0, 0, 100, null); return result; }
            using (var deadline = new CancellationTokenSource(60000))
            using (var combined = CancellationTokenSource.CreateLinkedTokenSource(cancellation, deadline.Token))
            {
                try { ScanCore(plan, result, progress, combined.Token).GetAwaiter().GetResult(); }
                catch (OperationCanceledException) { }
                result.Cancelled = cancellation.IsCancellationRequested;
                result.TimedOut = deadline.IsCancellationRequested && !result.Cancelled;
                if (result.Cancelled || result.TimedOut) result.Truncated = true;
            }
            result.Computers = result.Computers.OrderBy(item => item.ComputerName.Length == 0 ? item.Address : item.ComputerName, StringComparer.OrdinalIgnoreCase).ToList();
            bool unfinished = result.Cancelled || result.TimedOut || result.CompletedCount < result.CandidateCount;
            Publish(progress, result.Cancelled ? "cancelled" : result.TimedOut ? "timeout" : unfinished ? "incomplete" : "complete", result.CompletedCount, result.CandidateCount,
                unfinished ? Math.Min(99, result.CandidateCount == 0 ? 0 : result.CompletedCount * 70 / result.CandidateCount) : 100, null);
            return result;
        }
        static async Task ScanCore(Plan plan, DiscoveryResult result, Action<DiscoveryProgress> progress, CancellationToken cancellation)
        {
            object sync = new object(); int next = -1; var scope = new ScanScope();
            var workers = new List<Task>();
            Publish(progress, "scan", 0, plan.Candidates.Count, 0, null);
            for (int worker = 0; worker < Math.Min(24, plan.Candidates.Count); worker++)
                workers.Add(Task.Run(async delegate
                {
                    while (!cancellation.IsCancellationRequested && !scope.Changed)
                    {
                        int index = Interlocked.Increment(ref next); if (index >= plan.Candidates.Count) break;
                        Candidate candidate = plan.Candidates[index];
                        if (!scope.Eligible(candidate, false)) break;
                        bool open = await PortOpen(candidate, cancellation).ConfigureAwait(false);
                        cancellation.ThrowIfCancellationRequested();
                        DiscoveredComputer computer = null;
                        lock (sync)
                        {
                            computer = result.Computers.FirstOrDefault(item => item.Address == candidate.Address);
                            if (computer == null && open)
                            {
                                computer = new DiscoveredComputer { Address = candidate.Address, DisplayName = candidate.Address,
                                    AdapterId = candidate.AdapterId, Port445Open = true, Port445Checked = true };
                                result.Computers.Add(computer);
                            }
                            if (computer != null)
                            {
                                computer.Port445Open = open;
                                computer.Port445Checked = true;
                                if (!open) { computer.ErrorCode = "DISCOVERY_PORT_445_UNAVAILABLE"; computer.ErrorMessage = "Das Gerät wurde gefunden, antwortet aber momentan nicht auf SMB-Port 445."; }
                            }
                            result.CompletedCount++;
                            Publish(progress, "scan", result.CompletedCount, plan.Candidates.Count, result.CompletedCount * 70 / plan.Candidates.Count, computer);
                        }
                    }
                }, cancellation));
            await Task.WhenAll(workers).ConfigureAwait(false);
            cancellation.ThrowIfCancellationRequested();
            if (scope.Changed)
            {
                result.Truncated = true; result.Errors.Add("DISCOVERY_NETWORK_CHANGED: Die private physische Heimnetzverbindung ist nicht mehr bestätigt. Die Suche wurde beendet.");
                return;
            }
            var targets = result.Computers.Where(item => item.Port445Open).Take(MaximumMetadataHosts).ToList();
            NativeResult known = Bounded(ReadConnectedResources, 2000, cancellation);
            if (targets.Count < result.Computers.Count(item => item.Port445Open))
            {
                result.Truncated = true;
                foreach (var skipped in result.Computers.Where(item => item.Port445Open).Skip(MaximumMetadataHosts))
                { skipped.ErrorCode = "DISCOVERY_METADATA_LIMIT"; skipped.ErrorMessage = "Die Detailprüfung ist auf 64 SMB-Geräte pro Suche begrenzt. Das Gerät bleibt auswählbar."; }
            }
            int detailNext = -1, detailDone = 0; workers.Clear();
            Publish(progress, "details", 0, targets.Count, 70, null);
            for (int worker = 0; worker < Math.Min(4, targets.Count); worker++)
                workers.Add(Task.Run(delegate
                {
                    while (!cancellation.IsCancellationRequested && !scope.Changed)
                    {
                        int index = Interlocked.Increment(ref detailNext); if (index >= targets.Count) break;
                        var target = targets[index];
                        var source = plan.Candidates.First(item => item.Address == target.Address);
                        ReadDetails(target, source, scope, known.Connections, cancellation);
                        if (cancellation.IsCancellationRequested) return;
                        lock (sync)
                        {
                            detailDone++;
                            Publish(progress, "details", detailDone, targets.Count, targets.Count == 0 ? 100 : 70 + detailDone * 30 / targets.Count, target);
                        }
                    }
                }, cancellation));
            await Task.WhenAll(workers).ConfigureAwait(false);
            if (scope.Changed) { result.Truncated = true; result.Errors.Add("DISCOVERY_NETWORK_CHANGED: Die private physische Heimnetzverbindung ist nicht mehr bestätigt. Die Detailprüfung wurde beendet."); }
        }
        static void Publish(Action<DiscoveryProgress> progress, string phase, int completed, int total, int percent, DiscoveredComputer computer)
        {
            if (progress != null) progress(new DiscoveryProgress { Phase = phase, Completed = completed, Total = total, Percent = percent, Computer = Snapshot(computer) });
        }
        static DiscoveredComputer Snapshot(DiscoveredComputer source)
        {
            if (source == null) return null;
            return new DiscoveredComputer { Address = source.Address, ComputerName = source.ComputerName, DisplayName = source.DisplayName,
                AdapterId = source.AdapterId, Port445Open = source.Port445Open, Port445Checked = source.Port445Checked, IdentityVerified = source.IdentityVerified,
                IdentityCode = source.IdentityCode, ShareCode = source.ShareCode, SharesComplete = source.SharesComplete, ReportedIdentity = source.ReportedIdentity, MetadataContext = source.MetadataContext,
                ErrorCode = source.ErrorCode, ErrorMessage = source.ErrorMessage,
                ConnectionUserName = source.ConnectionUserName, ConnectionUserNameVerified = source.ConnectionUserNameVerified,
                Shares = source.Shares.Select(item => new DiscoveredShare { Name = item.Name, Remark = item.Remark, SuggestedUserName = item.SuggestedUserName,
                    AccessMode = item.AccessMode, MetadataVerified = item.MetadataVerified }).ToList() };
        }
        static async Task<bool> PortOpen(Candidate candidate, CancellationToken cancellation)
        {
            using (var client = new TcpClient(new IPEndPoint(IPAddress.Parse(candidate.Source), 0)))
            {
                try
                {
                    Task connect = client.ConnectAsync(IPAddress.Parse(candidate.Address), 445);
                    Task wait = Task.Delay(750, cancellation);
                    if (await Task.WhenAny(connect, wait).ConfigureAwait(false) != connect)
                    {
                        // Dispose closes the pending socket. Observe any eventual fault.
                        ObserveFailure(connect);
                        return false;
                    }
                    await connect.ConfigureAwait(false); return client.Connected;
                }
                catch (SocketException) { return false; }
                catch (ObjectDisposedException) { return false; }
            }
        }
        static void ObserveFailure(Task task) { task.ContinueWith(completed => { var ignored = completed.Exception; }, TaskContinuationOptions.OnlyOnFaulted); }
        static Plan PlanCandidates(IEnumerable<NativeHomeNetworks.HomeNetwork> networks, Dictionary<int, List<string>> neighbors, int limit, IEnumerable<string> otherLocal)
        {
            var plan = new Plan();
            var entries = (networks ?? Enumerable.Empty<NativeHomeNetworks.HomeNetwork>()).Where(ValidNetwork).ToList();
            var local = new HashSet<string>(entries.Select(item => item.Address), StringComparer.Ordinal);
            if (otherLocal != null) foreach (string address in otherLocal) local.Add(address);
            var seen = new HashSet<string>(StringComparer.Ordinal);
            limit = Math.Min(MaximumCandidates, Math.Max(1, limit));
            foreach (var network in entries)
            {
                List<string> hints;
                if (neighbors != null && neighbors.TryGetValue(network.Id, out hints))
                    foreach (string address in hints) AddCandidate(plan, network, address, local, seen, limit);
            }
            // Prioritize the source /24 on larger subnets, then continue through
            // the actual subnet. The limit is always reported; no /16 is called complete.
            foreach (var network in entries)
            {
                uint source = Number(IPAddress.Parse(network.Address)); uint nearby = source & 0xffffff00;
                for (uint item = nearby + 1; item < nearby + 255; item++) AddCandidate(plan, network, Text(item), local, seen, limit);
            }
            foreach (var network in entries)
            {
                string[] parts = network.Subnet.Split('/'); int prefix = Int32.Parse(parts[1]); uint start = Number(IPAddress.Parse(parts[0]));
                uint mask = UInt32.MaxValue << (32 - prefix); ulong end = ((ulong)start | (UInt32.MaxValue ^ mask));
                for (ulong item = (ulong)start + 1; item < end; item++)
                {
                    AddCandidate(plan, network, Text((uint)item), local, seen, limit);
                    if (plan.Truncated) break;
                }
            }
            return plan;
        }
        static void AddCandidate(Plan plan, NativeHomeNetworks.HomeNetwork network, string address, HashSet<string> local, HashSet<string> seen, int limit)
        {
            if (local.Contains(address) || !EligibleAddress(address, network.Subnet) || seen.Contains(address)) return;
            if (plan.Candidates.Count >= limit) { plan.Truncated = true; return; }
            seen.Add(address); plan.Candidates.Add(new Candidate { Address = address, Source = network.Address, Subnet = network.Subnet, AdapterId = network.Id });
        }
        static bool ValidNetwork(NativeHomeNetworks.HomeNetwork network)
        {
            if (network == null || network.Id <= 0 || network.Category != "Private" || !PrivateAddress(network.Address)) return false;
            string[] parts = (network.Subnet ?? "").Split('/'); int prefix; IPAddress subnet;
            if (parts.Length != 2 || !Int32.TryParse(parts[1], out prefix) || !IPAddress.TryParse(parts[0], out subnet)
                || subnet.AddressFamily != AddressFamily.InterNetwork || prefix < 8 || prefix > 30) return false;
            byte first = IPAddress.Parse(network.Address).GetAddressBytes()[0]; int minimum = first == 10 ? 8 : first == 172 ? 12 : 16;
            uint mask = UInt32.MaxValue << (32 - prefix);
            return prefix >= minimum && (Number(subnet) & mask) == Number(subnet)
                && EligibleAddress(network.Address, network.Subnet) && EligibleAddress(network.Gateway, network.Subnet);
        }
        static bool EligibleAddress(string address, string subnet)
        {
            if (!PrivateAddress(address)) return false;
            string[] parts = (subnet ?? "").Split('/'); int prefix; IPAddress start;
            if (parts.Length != 2 || !Int32.TryParse(parts[1], out prefix) || prefix < 8 || prefix > 30
                || !IPAddress.TryParse(parts[0], out start) || start.AddressFamily != AddressFamily.InterNetwork) return false;
            uint number = Number(IPAddress.Parse(address)), network = Number(start), mask = UInt32.MaxValue << (32 - prefix);
            return (number & mask) == network && number != network && number != (network | ~mask);
        }
        static bool PrivateAddress(string address)
        {
            IPAddress parsed; if (!IPAddress.TryParse(address, out parsed) || parsed.AddressFamily != AddressFamily.InterNetwork || parsed.ToString() != address) return false;
            byte[] bytes = parsed.GetAddressBytes(); return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168);
        }
        static uint Number(IPAddress address) { byte[] b = address.GetAddressBytes(); return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3]; }
        static string Text(uint number) { return new IPAddress(new byte[] { (byte)(number >> 24), (byte)(number >> 16), (byte)(number >> 8), (byte)number }).ToString(); }
        static Dictionary<int, List<string>> ReadNeighbors()
        {
            var result = new Dictionary<int, List<string>>(); IntPtr buffer = IntPtr.Zero;
            try
            {
                uint length = 0; uint code = GetIpNetTable(IntPtr.Zero, ref length, false);
                if (code != 122 || length < 4 || length > 1024 * 1024) return result;
                buffer = Marshal.AllocHGlobal(checked((int)length)); code = GetIpNetTable(buffer, ref length, false);
                if (code != 0 || length < 4) return result;
                int count = Marshal.ReadInt32(buffer); if (count < 0 || count > (length - 4) / 24) return result;
                for (int item = 0; item < count; item++)
                {
                    IntPtr row = IntPtr.Add(buffer, 4 + item * 24); int index = Marshal.ReadInt32(row), type = Marshal.ReadInt32(row, 20);
                    if (type != 3 && type != 4) continue;
                    byte[] address = new byte[4]; Marshal.Copy(IntPtr.Add(row, 16), address, 0, 4);
                    List<string> list; if (!result.TryGetValue(index, out list)) { list = new List<string>(); result[index] = list; }
                    list.Add(new IPAddress(address).ToString());
                }
            }
            catch (Exception) { /* Neighbor hints are optional; subnet scan remains available. */ }
            finally { if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer); }
            return result;
        }
        static IEnumerable<string> LocalAddresses()
        {
            return System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .SelectMany(item => item.GetIPProperties().UnicastAddresses).Where(item => item.Address.AddressFamily == AddressFamily.InterNetwork)
                .Select(item => item.Address.ToString()).ToArray();
        }
        static void ReadDetails(DiscoveredComputer target, Candidate source, ScanScope scope, List<ExistingConnection> known, CancellationToken cancellation)
        {
            if (!scope.Eligible(source, true)) { SetChangedNetwork(target); return; }
            if (UsesPeerPreset(target))
            {
                target.MetadataContext = "PublicPeerPreset";
                // Net API metadata calls can implicitly establish IPC$ with the
                // default Windows login. Do not introduce that connection before
                // the user selects this advertised Guest/Password account.
                return;
            }
            ExistingConnection existing = FindExisting(target.Address, known, cancellation);
            if (existing == null)
            {
                target.MetadataContext = "NoExistingWindowsConnection";
                target.ErrorCode = "DISCOVERY_LOGIN_NOT_KNOWN";
                target.ErrorMessage = "SMB ist erreichbar. Freigaben und Anmeldung sind noch unbekannt. Öffne Einfach Netzwerk auf dem anderen Computer oder übernimm dessen angezeigte Verbindung.";
                SetDisplayHint(target, cancellation);
                return;
            }
            ReadKnownDetails(target, existing.Host, delegate { return StillConnected(existing, target.Address, cancellation) && scope.Eligible(source, true); },
                delegate(string host) { return Bounded(delegate { return ReadIdentity(host); }, 2500, cancellation); },
                delegate(string host) { return Bounded(delegate { return ReadShares(host); }, 4000, cancellation); });
            SetExistingAccountSuggestion(target, existing.UserName,
                scope.Eligible(source, true) && StillConnected(existing, target.Address, cancellation));
        }
        static bool UsesPeerPreset(DiscoveredComputer target)
        {
            return target.ReportedIdentity && target.Shares.Any(item => item.MetadataVerified && !String.IsNullOrEmpty(item.SuggestedUserName));
        }
        static void ReadKnownDetails(DiscoveredComputer target, string host, Func<bool> stillConnected,
            Func<string, NativeResult> readIdentity, Func<string, NativeResult> readShares)
        {
            if (UsesPeerPreset(target)) { target.MetadataContext = "PublicPeerPreset"; return; }
            if (String.IsNullOrEmpty(host) || !stillConnected()) { SetUnknownConnection(target); return; }
            target.MetadataContext = "ExistingWindowsConnection";
            NativeResult identity = readIdentity(host);
            if (!stillConnected()) { SetUnknownConnection(target); return; }
            NativeResult shares = readShares(host);
            if (!stillConnected()) { SetUnknownConnection(target); return; }
            ApplyDetails(target, identity, shares);
        }
        static bool ValidConnectionUser(string user)
        {
            return !String.IsNullOrWhiteSpace(user) && user.Length <= 256 && user == user.Trim()
                && !Regex.IsMatch(user, @"[/\x00-\x1f\x7f]") && Regex.IsMatch(user, @"^[^\\]+(?:\\[^\\]+)?$");
        }
        static void SetExistingAccountSuggestion(DiscoveredComputer target, string user, bool current)
        {
            target.ConnectionUserName = ""; target.ConnectionUserNameVerified = false;
            if (!current || target.MetadataContext != "ExistingWindowsConnection" || !target.Port445Open
                || !target.IdentityVerified || !ValidComputerName(target.ComputerName) || !ValidConnectionUser(user)) return;
            // This is an actual account returned for an existing exact SMB
            // resource. It conveys no password or Guest/Password access mode.
            target.ConnectionUserName = user; target.ConnectionUserNameVerified = true;
        }
        static void SetUnknownConnection(DiscoveredComputer target)
        {
            target.ConnectionUserName = ""; target.ConnectionUserNameVerified = false;
            target.MetadataContext = "NoExistingWindowsConnection";
            target.ErrorCode = "DISCOVERY_EXISTING_CONNECTION_CHANGED";
            target.ErrorMessage = "Die bereits vorhandene Windows-Verbindung ist nicht mehr bestätigt. Es wurde keine andere Anmeldung ausprobiert.";
        }
        static ExistingConnection FindExisting(string address, List<ExistingConnection> connections, CancellationToken cancellation)
        {
            foreach (var item in connections.Where(entry => entry.Host == address)) if (StillConnected(item, address, cancellation)) return item;
            foreach (var item in connections.Where(entry => entry.Host != address))
                if (ExistingAliasMatches(item.Host, address, cancellation) && StillConnected(item, address, cancellation)) return item;
            return null;
        }
        static bool ExistingAliasMatches(string alias, string address, CancellationToken cancellation)
        {
            if (alias == address) return true;
            IPAddress parsed;
            if (IPAddress.TryParse(alias, out parsed)) return false;
            NativeResult resolve = Bounded(delegate
            {
                string[] ipv4 = Dns.GetHostAddresses(alias).Where(item => item.AddressFamily == AddressFamily.InterNetwork).Select(item => item.ToString()).Distinct().ToArray();
                return new NativeResult { Name = ipv4.Length == 1 ? ipv4[0] : "" };
            }, 1000, cancellation);
            return String.IsNullOrEmpty(resolve.ErrorCode) && resolve.Name == address;
        }
        static bool StillConnected(ExistingConnection existing, string address, CancellationToken cancellation)
        {
            if (!ExistingAliasMatches(existing.Host, address, cancellation)) return false;
            NativeResult current = Bounded(ReadConnectedResources, 1500, cancellation);
            return current.Connections.Any(item => SameExistingConnection(existing, item));
        }
        static bool SameExistingConnection(ExistingConnection expected, ExistingConnection current)
        {
            return expected != null && current != null && ValidConnectionUser(expected.UserName) && ValidConnectionUser(current.UserName)
                && String.Equals(current.Host, expected.Host, StringComparison.OrdinalIgnoreCase)
                && String.Equals(current.RemotePath, expected.RemotePath, StringComparison.OrdinalIgnoreCase)
                && String.Equals(current.UserName, expected.UserName, StringComparison.Ordinal);
        }
        static void SetDisplayHint(DiscoveredComputer target, CancellationToken cancellation)
        {
            NativeResult lookup = Bounded(delegate { return new NativeResult { Name = Dns.GetHostEntry(target.Address).HostName ?? "" }; }, 750, cancellation);
            if (String.IsNullOrEmpty(lookup.ErrorCode) && Regex.IsMatch(lookup.Name, @"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"))
                target.DisplayName = lookup.Name + " · " + target.Address;
        }
        static NativeResult ReadConnectedResources()
        {
            var result = new NativeResult(); IntPtr enumeration = IntPtr.Zero, buffer = IntPtr.Zero;
            try
            {
                var microsoftProvider = new StringBuilder(513); uint providerLength = 513;
                result.Code = WNetGetProviderName(0x00020000, microsoftProvider, ref providerLength); // WNNC_NET_LANMAN
                if (result.Code != 0 || microsoftProvider.Length == 0) return result;
                result.Code = WNetOpenEnum(1, 1, 0, IntPtr.Zero, out enumeration);
                if (result.Code != 0) return result;
                int capacity = 65536, size = Marshal.SizeOf(typeof(NETRESOURCE)); buffer = Marshal.AllocHGlobal(capacity);
                for (int page = 0; page < 32; page++)
                {
                    uint count = UInt32.MaxValue, bytes = (uint)capacity;
                    int code = WNetEnumResource(enumeration, ref count, buffer, ref bytes);
                    if (code == 259) { result.Code = 0; result.Complete = true; return result; }
                    if (code == 234 && bytes > capacity && bytes <= 1024 * 1024)
                    { Marshal.FreeHGlobal(buffer); capacity = checked((int)bytes); buffer = Marshal.AllocHGlobal(capacity); continue; }
                    if (code != 0 || count > capacity / size) { result.Code = code == 0 ? 13 : code; return result; }
                    for (uint item = 0; item < count; item++)
                    {
                        var resource = (NETRESOURCE)Marshal.PtrToStructure(IntPtr.Add(buffer, checked((int)item * size)), typeof(NETRESOURCE));
                        if (!ConfirmedSmbProvider(resource.Type, resource.Provider, microsoftProvider.ToString())) continue;
                        string path = resource.RemoteName ?? ""; string alias = ExistingAlias(path);
                        if (alias.Length == 0) continue;
                        var user = new StringBuilder(513); uint length = 513;
                        // This is the exact already-enumerated connected resource,
                        // never a fabricated IPC$ path, new account or credential.
                        if (WNetGetUser(path, user, ref length) != 0 || !ValidConnectionUser(user.ToString())) continue;
                        result.Connections.Add(new ExistingConnection { Host = alias, RemotePath = path, UserName = user.ToString() });
                        if (result.Connections.Count >= 1024) { result.Code = 234; return result; }
                    }
                }
                result.Code = 234; return result;
            }
            finally { if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer); if (enumeration != IntPtr.Zero) WNetCloseEnum(enumeration); }
        }
        static bool ConfirmedSmbProvider(uint type, string actual, string expected)
        {
            return type == 1 && !String.IsNullOrEmpty(actual) && !String.IsNullOrEmpty(expected) && String.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);
        }
        static string ExistingAlias(string path)
        {
            if (String.IsNullOrEmpty(path) || !path.StartsWith("\\\\", StringComparison.Ordinal)) return "";
            string[] parts = path.Substring(2).Split('\\');
            if (parts.Length != 2 || parts[1].Length == 0 || parts[1].IndexOfAny(new[] { '/', '\0', '\r', '\n' }) >= 0) return "";
            string alias = parts[0]; IPAddress parsed;
            if (IPAddress.TryParse(alias, out parsed)) return parsed.AddressFamily == AddressFamily.InterNetwork && parsed.ToString() == alias ? alias : "";
            return Regex.IsMatch(alias, @"^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$") && !alias.Contains("..") ? alias : "";
        }
        static void ApplyDetails(DiscoveredComputer target, NativeResult identity, NativeResult shares)
        {
            string reportedName = target.ComputerName;
            var reportedShares = target.Shares;
            target.IdentityCode = identity.Code;
            target.IdentityVerified = identity.Code == 0 && ValidComputerName(identity.Name);
            if (target.IdentityVerified) target.ComputerName = identity.Name;
            target.ShareCode = shares.Code; target.SharesComplete = shares.Complete;
            target.Shares = shares.Shares.Select(item => new DiscoveredShare { Name = item.Name, Remark = item.Remark }).ToList();
            bool reportedMatches = target.ReportedIdentity && (!target.IdentityVerified || String.Equals(reportedName, target.ComputerName, StringComparison.OrdinalIgnoreCase));
            if (reportedMatches)
                foreach (var report in reportedShares)
                {
                    var actual = target.Shares.FirstOrDefault(item => String.Equals(item.Name, report.Name, StringComparison.OrdinalIgnoreCase));
                    if (actual == null) { if (!shares.Complete) target.Shares.Add(report); }
                    else if (String.IsNullOrEmpty(actual.Remark) || !actual.Remark.StartsWith("[EinfachNetzwerk:", StringComparison.Ordinal)) actual.Remark = report.Remark;
                }
            foreach (var share in target.Shares) ReadAdvertisement(share, target.ComputerName, target.IdentityVerified || reportedMatches);
            target.DisplayName = target.ToString();
            if (!String.IsNullOrEmpty(shares.ErrorCode)) { target.ErrorCode = shares.ErrorCode; target.ErrorMessage = shares.ErrorMessage; }
            else if (shares.Code != 0) { target.ErrorCode = "Win32: " + unchecked((uint)shares.Code).ToString(); target.ErrorMessage = new Win32Exception(shares.Code).Message; }
            else if (!target.IdentityVerified)
            {
                target.ErrorCode = String.IsNullOrEmpty(identity.ErrorCode) ? "Win32: " + unchecked((uint)identity.Code).ToString() : identity.ErrorCode;
                target.ErrorMessage = String.IsNullOrEmpty(identity.ErrorMessage) ? new Win32Exception(identity.Code).Message : identity.ErrorMessage;
            }
        }
        static void SetChangedNetwork(DiscoveredComputer target)
        {
            target.ConnectionUserName = ""; target.ConnectionUserNameVerified = false;
            target.ErrorCode = "DISCOVERY_NETWORK_CHANGED";
            target.ErrorMessage = "Die private physische Heimnetzverbindung ist nicht mehr bestätigt. Die Detailprüfung wurde beendet.";
        }
        static NativeResult Bounded(Func<NativeResult> action, int milliseconds, CancellationToken cancellation)
        {
            if (cancellation.IsCancellationRequested) return new NativeResult { ErrorCode = "DISCOVERY_CANCELLED" };
            if (!NativeSlots.Wait(0)) return new NativeResult { ErrorCode = "DISCOVERY_NATIVE_BUSY", ErrorMessage = "Eine frühere Windows-Netzwerkabfrage läuft noch. Das Gerät kann direkt geprüft werden." };
            NativeResult finished = null;
            var thread = new Thread(delegate()
            {
                try { finished = action(); }
                catch (Exception error) { finished = new NativeResult { ErrorCode = "HRESULT: 0x" + error.HResult.ToString("X8"), ErrorMessage = error.Message }; }
                finally { NativeSlots.Release(); }
            });
            thread.IsBackground = true; thread.Start();
            int elapsed = 0;
            while (elapsed < milliseconds && !cancellation.IsCancellationRequested)
            { int slice = Math.Min(100, milliseconds - elapsed); if (thread.Join(slice)) return finished; elapsed += slice; }
            // The action owns/free its native buffers; it cannot later mutate
            // an already published timeout result or the user's selected row.
            return new NativeResult { ErrorCode = cancellation.IsCancellationRequested ? "DISCOVERY_CANCELLED" : "DISCOVERY_TIMEOUT",
                ErrorMessage = "Die lesende Windows-Netzwerkabfrage hat ihr Zeitlimit erreicht. Das Gerät bleibt auswählbar." };
        }
        static bool ValidComputerName(string name)
        {
            return !String.IsNullOrEmpty(name) && Regex.IsMatch(name, @"^(?=.{1,15}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$")
                && !Regex.IsMatch(name, @"^[0-9]+$");
        }
        static bool ValidShareName(string name)
        {
            return !String.IsNullOrEmpty(name) && name.Length <= 80 && name.IndexOf('$') < 0 && !name.EndsWith(".", StringComparison.Ordinal)
                && name != "." && name != ".." && name.Trim() == name && !Regex.IsMatch(name, @"[\\/\x00-\x1f\x7f\[\]:;|=,+*?<>\""]")
                && !Regex.IsMatch(name, @"^(IPC|ADMIN|PRINT)$", RegexOptions.IgnoreCase);
        }
        static NativeResult ReadIdentity(string address)
        {
            var result = new NativeResult(); IntPtr buffer = IntPtr.Zero;
            try
            {
                result.Code = NetWkstaGetInfo("\\\\" + address, 100, out buffer);
                if (result.Code == 0 && buffer != IntPtr.Zero)
                {
                    var info = (WKSTA_INFO_100)Marshal.PtrToStructure(buffer, typeof(WKSTA_INFO_100));
                    result.Name = info.Name ?? "";
                    if (!ValidComputerName(result.Name)) { result.ErrorCode = "DISCOVERY_IDENTITY_INVALID"; result.ErrorMessage = "Windows hat keinen verwendbaren tatsächlichen Computernamen geliefert."; }
                }
                else if (result.Code == 0) { result.Code = 13; }
            }
            finally { if (buffer != IntPtr.Zero) NetApiBufferFree(buffer); }
            return result;
        }
        static NativeResult ReadShares(string address)
        {
            var result = new NativeResult(); uint resume = 0; var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int size = Marshal.SizeOf(typeof(SHARE_INFO_1));
            for (int page = 0; page < 16; page++)
            {
                IntPtr buffer = IntPtr.Zero; uint read, total, prior = resume;
                try
                {
                    result.Code = NetShareEnum("\\\\" + address, 1, out buffer, 65536, out read, out total, ref resume);
                    if (result.Code != 0 && result.Code != 234) return result;
                    if (read > 4096 || (read > 0 && buffer == IntPtr.Zero)) { result.Code = 13; return result; }
                    for (uint item = 0; item < read; item++)
                    {
                        var info = (SHARE_INFO_1)Marshal.PtrToStructure(IntPtr.Add(buffer, checked((int)item * size)), typeof(SHARE_INFO_1));
                        if ((info.Type & 0xff) != 0 || !ValidShareName(info.Name) || !seen.Add(info.Name)) continue;
                        if (result.Shares.Count >= 512) { result.Code = 234; return result; }
                        result.Shares.Add(new DiscoveredShare { Name = info.Name, Remark = (info.Remark ?? "").Length > 1024 ? (info.Remark ?? "").Substring(0, 1024) : info.Remark ?? "" });
                    }
                    if (result.Code == 0) { result.Complete = true; return result; }
                    if (read == 0 && resume == prior) return result;
                }
                finally { if (buffer != IntPtr.Zero) NetApiBufferFree(buffer); }
            }
            result.Code = 234; return result;
        }
        static void ReadAdvertisement(DiscoveredShare share, string computerName, bool identityVerified)
        {
            // Only a versioned, exact app remark may supply an account. This is
            // advertised configuration; the existing access test still proves it.
            if (!identityVerified || !ValidComputerName(computerName) || !ValidShareName(share.Name)) return;
            string mode, login;
            if (!TryParseMetadata(share.Remark, computerName, out mode, out login)) return;
            share.AccessMode = mode; share.SuggestedUserName = login;
            share.MetadataVerified = true;
        }
        public static bool TryParseMetadata(string remark, string canonicalName, out string mode, out string userName)
        {
            mode = userName = "";
            if (String.IsNullOrEmpty(remark) || remark.Length > 1600 || !ValidComputerName(canonicalName)) return false;
            Match marker = Regex.Match(remark, @"^\[EinfachNetzwerk:1;mode=(Guest|Password);computer=([^;\[\]\x00-\x20]+);user=([^;\[\]\x00-\x20]+)\]$");
            if (!marker.Success || !ValidEscapes(marker.Groups[2].Value) || !ValidEscapes(marker.Groups[3].Value)) return false;
            string computer, account;
            try { computer = Uri.UnescapeDataString(marker.Groups[2].Value); account = Uri.UnescapeDataString(marker.Groups[3].Value); }
            catch (UriFormatException) { return false; }
            if (!ValidComputerName(computer) || !String.Equals(computer, canonicalName, StringComparison.OrdinalIgnoreCase)
                || account.Length == 0 || account.Length > 20 || account.Trim() != account || account == "." || account == ".."
                || Regex.IsMatch(account, @"[\\/\x00-\x1f\x7f\[\]:;|=,+*?<>\""]")) return false;
            mode = marker.Groups[1].Value; userName = canonicalName + "\\" + account; return true;
        }
        static bool ValidEscapes(string value) { return !Regex.IsMatch(value, @"%(?![0-9A-Fa-f]{2})"); }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct NETRESOURCE
        {
            public uint Scope, Type, DisplayType, Usage;
            [MarshalAs(UnmanagedType.LPWStr)] public string LocalName;
            [MarshalAs(UnmanagedType.LPWStr)] public string RemoteName;
            [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
            [MarshalAs(UnmanagedType.LPWStr)] public string Provider;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WKSTA_INFO_100
        {
            public uint Platform;
            [MarshalAs(UnmanagedType.LPWStr)] public string Name;
            [MarshalAs(UnmanagedType.LPWStr)] public string Group;
            public uint Major, Minor;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHARE_INFO_1
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string Name;
            public uint Type;
            [MarshalAs(UnmanagedType.LPWStr)] public string Remark;
        }
        [DllImport("iphlpapi.dll")] static extern uint GetIpNetTable(IntPtr table, ref uint size, bool order);
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)] static extern int WNetOpenEnum(uint scope, uint type, uint usage, IntPtr resource, out IntPtr enumeration);
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)] static extern int WNetEnumResource(IntPtr enumeration, ref uint count, IntPtr buffer, ref uint bufferSize);
        [DllImport("mpr.dll")] static extern int WNetCloseEnum(IntPtr enumeration);
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)] static extern int WNetGetUser(string name, StringBuilder user, ref uint length);
        [DllImport("mpr.dll", CharSet = CharSet.Unicode)] static extern int WNetGetProviderName(uint networkType, StringBuilder name, ref uint length);
        [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] static extern int NetWkstaGetInfo(string server, uint level, out IntPtr buffer);
        [DllImport("netapi32.dll", CharSet = CharSet.Unicode)] static extern int NetShareEnum(string server, uint level, out IntPtr buffer, uint maximumLength, out uint entriesRead, out uint totalEntries, ref uint resume);
        [DllImport("netapi32.dll")] static extern int NetApiBufferFree(IntPtr buffer);
    }
}
