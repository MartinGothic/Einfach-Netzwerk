using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace EinfachNetzwerk
{
    // Readonly native network selection for service recovery. It uses IP Helper
    // and Network List Manager, so a broken WMI provider cannot block recovery.
    public static class NativeHomeNetworks
    {
        public static string ReadJson()
        {
            HashSet<Guid> privateAdapters = ReadPrivateAdapters();
            List<HomeNetwork> result = new List<HomeNetwork>();
            foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                Guid id;
                if (!Guid.TryParse(adapter.Id, out id) || !privateAdapters.Contains(id)
                    || adapter.OperationalStatus != OperationalStatus.Up
                    || (adapter.NetworkInterfaceType != NetworkInterfaceType.Ethernet && adapter.NetworkInterfaceType != NetworkInterfaceType.Wireless80211)
                    || Regex.IsMatch(adapter.Description ?? "", "VPN|TAP-|TUN|WireGuard|Virtual|Hyper-V|VMware|VirtualBox|Bluetooth", RegexOptions.IgnoreCase)) continue;
                IPInterfaceProperties properties = adapter.GetIPProperties();
                IPv4InterfaceProperties ipv4 = properties.GetIPv4Properties();
                if (ipv4 == null || !IsPhysicalAdapter(ipv4.Index, id)) continue;
                foreach (UnicastIPAddressInformation address in properties.UnicastAddresses)
                {
                    if (!PrivateIPv4(address.Address) || address.DuplicateAddressDetectionState != DuplicateAddressDetectionState.Preferred) continue;
                    int prefix = PrefixLength(address.IPv4Mask);
                    IPAddress gateway = properties.GatewayAddresses.Select(item => item.Address)
                        .FirstOrDefault(item => EligibleAddress(address.Address, prefix, item));
                    if (gateway == null) continue;
                    string subnet = Subnet(address.Address, prefix);
                    result.Add(new HomeNetwork { Id = ipv4.Index, Name = adapter.Name, Address = address.Address.ToString(),
                        Subnet = subnet, Category = "Private", Gateway = gateway.ToString() });
                    // Keep one unambiguous source address per physical adapter.
                    break;
                }
            }
            return new JavaScriptSerializer().Serialize(result);
        }

        static bool PrivateIPv4(IPAddress address)
        {
            if (address == null || address.AddressFamily != AddressFamily.InterNetwork) return false;
            byte[] bytes = address.GetAddressBytes();
            return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168);
        }
        static int PrefixLength(IPAddress mask)
        {
            if (mask == null || mask.AddressFamily != AddressFamily.InterNetwork) return -1;
            int prefix = 0; bool zeroSeen = false;
            foreach (byte item in mask.GetAddressBytes())
                for (int bit = 7; bit >= 0; bit--)
                {
                    bool set = (item & (1 << bit)) != 0;
                    if (set && zeroSeen) return -1;
                    if (set) prefix++; else zeroSeen = true;
                }
            return prefix;
        }
        static string Subnet(IPAddress address, int prefix)
        {
            byte[] bytes = address.GetAddressBytes();
            for (int index = 0; index < bytes.Length; index++)
            {
                int bits = Math.Min(8, Math.Max(0, prefix - index * 8));
                bytes[index] = (byte)(bytes[index] & (bits == 0 ? 0 : (0xff << (8 - bits))));
            }
            return new IPAddress(bytes).ToString() + "/" + prefix;
        }
        static bool EligibleProfile(bool connected, int domain, int category) { return connected && domain == 0 && category == 1; }
        static bool EligibleAddress(IPAddress address, int prefix, IPAddress gateway)
        {
            if (!PrivateIPv4(address) || !PrivateIPv4(gateway)) return false;
            byte first = address.GetAddressBytes()[0];
            int minimum = first == 10 ? 8 : first == 172 ? 12 : 16;
            return prefix >= minimum && prefix <= 30 && Subnet(address, prefix) == Subnet(gateway, prefix);
        }
        static bool EligiblePhysical(Guid actual, Guid expected, int actualIndex, int expectedIndex,
            uint type, uint tunnel, uint physical, byte flags, uint state)
        {
            return actual == expected && actualIndex == expectedIndex && (type == 6 || type == 71)
                && tunnel == 0 && (physical == 0 || physical == 1 || physical == 9 || physical == 14)
                && (flags & 1) != 0 && (flags & (2 | 16 | 32 | 128)) == 0 && state == 1;
        }
        static bool IsPhysicalAdapter(int index, Guid adapter)
        {
            // MIB_IF_ROW2 has fixed-width fields and no native pointers. The
            // offsets below follow netioapi.h on x86 and x64. The allocation is
            // deliberately larger than the complete 1,352-byte SDK structure.
            IntPtr row = Marshal.AllocHGlobal(4096);
            try
            {
                for (int offset = 0; offset < 4096; offset += 8) Marshal.WriteInt64(row, offset, 0);
                Marshal.WriteInt32(row, 8, index);
                uint error = GetIfEntry2(row);
                if (error != 0) throw new Win32Exception(unchecked((int)error), "Physische Netzwerkverbindung lesen");
                Guid actual = (Guid)Marshal.PtrToStructure(IntPtr.Add(row, 12), typeof(Guid));
                uint type = unchecked((uint)Marshal.ReadInt32(row, 1128));
                uint tunnel = unchecked((uint)Marshal.ReadInt32(row, 1132));
                uint physical = unchecked((uint)Marshal.ReadInt32(row, 1140));
                byte flags = Marshal.ReadByte(row, 1152);
                uint state = unchecked((uint)Marshal.ReadInt32(row, 1156));
                return EligiblePhysical(actual, adapter, Marshal.ReadInt32(row, 8), index, type, tunnel, physical, flags, state);
            }
            finally { Marshal.FreeHGlobal(row); }
        }
        static HashSet<Guid> ReadPrivateAdapters()
        {
            object managerObject = null; IEnumConnections connections = null;
            Dictionary<Guid, bool> decisions = new Dictionary<Guid, bool>();
            try
            {
                Type managerType = Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B"), true);
                managerObject = Activator.CreateInstance(managerType);
                connections = ((INetworkListManager)managerObject).GetNetworkConnections();
                for (int count = 0; count < 256; count++)
                {
                    INetworkConnection connection; uint fetched;
                    int status = connections.Next(1, out connection, out fetched);
                    if (status < 0) Marshal.ThrowExceptionForHR(status);
                    if (fetched == 0) break;
                    INetwork network = null;
                    try
                    {
                        Guid adapter = connection.GetAdapterId();
                        network = connection.GetNetwork();
                        bool isPrivate = EligibleProfile(connection.IsConnected(), connection.GetDomainType(), network.GetCategory());
                        bool prior;
                        decisions[adapter] = !decisions.TryGetValue(adapter, out prior) ? isPrivate : prior && isPrivate;
                    }
                    finally { Release(network); Release(connection); }
                }
                return new HashSet<Guid>(decisions.Where(item => item.Value).Select(item => item.Key));
            }
            finally { Release(connections); Release(managerObject); }
        }
        static void Release(object value) { if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }

        public sealed class HomeNetwork
        {
            public int Id { get; set; } public string Name { get; set; } public string Address { get; set; }
            public string Subnet { get; set; } public string Category { get; set; } public string Gateway { get; set; }
        }
        [DllImport("iphlpapi.dll")] static extern uint GetIfEntry2(IntPtr row);
        // Method order and dual-interface inheritance come directly from the
        // Microsoft Windows SDK netlistmgr.h; no profile setters are called.
        [ComImport, Guid("DCB00000-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
        interface INetworkListManager
        {
            [return: MarshalAs(UnmanagedType.Interface)] object GetNetworks(int flags);
            INetwork GetNetwork(Guid id);
            IEnumConnections GetNetworkConnections();
        }
        [ComImport, Guid("DCB00006-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
        interface IEnumConnections
        {
            [return: MarshalAs(UnmanagedType.Interface)] object NewEnum();
            [PreserveSig] int Next(uint count, out INetworkConnection connection, out uint fetched);
        }
        [ComImport, Guid("DCB00005-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
        interface INetworkConnection
        {
            INetwork GetNetwork();
            [return: MarshalAs(UnmanagedType.VariantBool)] bool IsConnectedToInternet();
            [return: MarshalAs(UnmanagedType.VariantBool)] bool IsConnected();
            int GetConnectivity();
            Guid GetConnectionId();
            Guid GetAdapterId();
            int GetDomainType();
        }
        [ComImport, Guid("DCB00002-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
        interface INetwork
        {
            [return: MarshalAs(UnmanagedType.BStr)] string GetName();
            void SetName([MarshalAs(UnmanagedType.BStr)] string name);
            [return: MarshalAs(UnmanagedType.BStr)] string GetDescription();
            void SetDescription([MarshalAs(UnmanagedType.BStr)] string description);
            Guid GetNetworkId();
            int GetDomainType();
            IEnumConnections GetNetworkConnections();
            void GetTimeCreatedAndConnected(out uint createdLow, out uint createdHigh, out uint connectedLow, out uint connectedHigh);
            [return: MarshalAs(UnmanagedType.VariantBool)] bool IsConnectedToInternet();
            [return: MarshalAs(UnmanagedType.VariantBool)] bool IsConnected();
            int GetConnectivity();
            int GetCategory();
        }
    }
}
