using System;
using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace EinfachNetzwerk
{
    internal enum ConnectionSummaryState { Unchecked, Confirmed, Problem }

    // Only immutable, scoped conclusions survive the operation. This model
    // reads worker evidence; it does not probe a network or change Windows.
    internal sealed class ConnectionSummarySnapshot
    {
        internal string ContextKey;
        internal ConnectionSummaryState Local, Computer, Folder;
        internal string LocalHint = "Die lokale Vorbereitung wurde für diese Anmeldung noch nicht bestätigt.";
        internal string ComputerHint = "Der ausgewählte Computer wurde noch nicht geprüft.";
        internal string FolderHint = "Ein echter Windows-Zugriff auf den ausgewählten Ordner ist noch ungeprüft.";
    }

    internal static class ConnectionSummaryEvidence
    {
        internal static ConnectionSummarySnapshot Unknown(string contextKey)
        {
            return new ConnectionSummarySnapshot { ContextKey = contextKey };
        }

        internal static ConnectionSummarySnapshot Evaluate(WorkerResult result, ShareRequest request,
            string action, string contextKey, string localComputer, bool fresh,
            ConnectionSummarySnapshot previous)
        {
            ConnectionSummarySnapshot summary = Unknown(contextKey);
            if (!fresh || result == null || request == null || request.DryRun || result.InspectionIncomplete ||
                !String.Equals(request.Action, action, StringComparison.Ordinal) || action == "RestoreClient" ||
                !String.Equals(result.ComputerName, localComputer, StringComparison.OrdinalIgnoreCase)) return summary;
            bool localAction = action == "InspectClient" || action == "PrepareClient";
            bool remoteAction = action == "InspectRemote" || action == "ConnectRemote" || action == "RepairClient" || action == "EnumerateComputer";
            if (!localAction && !remoteAction) return summary;
            bool guest = String.Equals(request.Mode, "Guest", StringComparison.OrdinalIgnoreCase);
            bool password = String.Equals(request.Mode, "Password", StringComparison.OrdinalIgnoreCase);
            if (!guest && !password) return summary;

            if (remoteAction && previous != null && String.Equals(previous.ContextKey, contextKey, StringComparison.Ordinal))
            {
                // A read-only remote test cannot turn known local readiness into
                // a folder proof. Input edits discard the complete snapshot.
                summary.Local = previous.Local; summary.LocalHint = previous.LocalHint;
            }
            if (Has(result, "SERVICE_WORKSTATION_NOT_RUNNING", "error"))
            {
                summary.Local = ConnectionSummaryState.Problem;
                summary.LocalHint = "Der Windows-Dienst für den Zugriff auf andere Computer läuft nicht.";
            }
            else if (guest && (Has(result, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", "warning") || Has(result, "CLIENT_GUEST_COMPATIBILITY_REQUIRED", "error")))
            {
                summary.Local = ConnectionSummaryState.Problem;
                summary.LocalHint = "Windows-Einstellungen dieses PCs blockieren den gewählten Zugriff ohne Passwort.";
            }
            if (localAction)
            {
                // This worker's preparation test concerns guest access only.
                if (guest && result.Success && String.Equals(result.ComputerName, localComputer, StringComparison.OrdinalIgnoreCase) &&
                    Has(result, "CLIENT_PREPARATION_READY", "ok") && Has(result, "SERVICE_WORKSTATION_READY", "ok") &&
                    Has(result, "CLIENT_PRIVATE_LAN_READY", "ok") && (action == "PrepareClient" || !HasProblem(result)))
                {
                    summary.Local = ConnectionSummaryState.Confirmed;
                    summary.LocalHint = "Windows-Dienst und Einstellungen für den Zugriff ohne Passwort wurden bestätigt.";
                }
                return summary;
            }

            // Remote flags alone do not identify a target, share or account.
            if (!TargetMatches(result, request, action)) return summary;
            if (Has(result, "REMOTE_PORT_REACHABLE", "ok") ||
                (result.Success && result.RemoteComputerEnumerationVerified && Has(result, "REMOTE_COMPUTER_ENUMERATION_VERIFIED", "ok")))
            {
                summary.Computer = ConnectionSummaryState.Confirmed;
                summary.ComputerHint = "SMB-Port 445 antwortet. Das bestätigt noch keinen Ordnerzugriff.";
            }
            else if (Has(result, "REMOTE_PORT_UNREACHABLE", "error"))
            {
                summary.Computer = ConnectionSummaryState.Problem;
                summary.ComputerHint = "SMB-Port 445 antwortet nicht. Die Details zeigen den nächsten Schritt.";
            }
            bool folderAction = action == "InspectRemote" || action == "ConnectRemote" || action == "RepairClient";
            if (folderAction && NativeFolderMatches(result, request))
            {
                summary.Local = summary.Computer = summary.Folder = ConnectionSummaryState.Confirmed;
                summary.LocalHint = "Die gewählte Anmeldung funktioniert mit diesem Windows-Client.";
                summary.ComputerHint = "Der ausgewählte Computer hat den Windows-Zugriff beantwortet.";
                summary.FolderHint = "Windows hat die Anmeldung und die Ordnerliste dieser Freigabe bestätigt.";
            }
            else if (folderAction && HasNativeFailure(result))
            {
                summary.Folder = ConnectionSummaryState.Problem;
                summary.FolderHint = "Windows hat den Ordnerzugriff abgelehnt. Ursache und passende Hilfe stehen darunter.";
                if (guest && Regex.IsMatch(result.ErrorCode ?? String.Empty, @"^(?:Win32:\s*)?(?:1272|-1067646973|-1067646972)(?:$|[;\s])", RegexOptions.CultureInvariant))
                {
                    summary.Local = ConnectionSummaryState.Problem;
                    summary.LocalHint = "Windows-Einstellungen dieses PCs blockieren den gewählten Zugriff ohne Passwort.";
                }
            }
            else if (RemoteAccessDialog.IsAnonymousListLimitation(result, request, action) && previous != null &&
                String.Equals(previous.ContextKey, contextKey, StringComparison.Ordinal))
            {
                // A later anonymous-list refusal says nothing about the exact
                // folder/account already checked in this unchanged context.
                summary.Folder = previous.Folder; summary.FolderHint = previous.FolderHint;
            }
            return summary;
        }

        private static bool TargetMatches(WorkerResult result, ShareRequest request, string action)
        {
            IPAddress address;
            if (String.IsNullOrWhiteSpace(request.RemoteHost) ||
                !IPAddress.TryParse(result.RemoteAddress ?? String.Empty, out address) || address.AddressFamily != AddressFamily.InterNetwork ||
                !String.Equals(address.ToString(), result.RemoteAddress, StringComparison.Ordinal) || !Has(result, "REMOTE_LAN_TARGET", "ok")) return false;
            byte[] bytes = address.GetAddressBytes();
            if (!(bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168))) return false;
            IPAddress requested;
            bool explicitAddress = IPAddress.TryParse(request.RemoteHost, out requested);
            if (explicitAddress && !requested.Equals(address)) return false;
            if (String.Equals(result.RemoteComputerName, request.RemoteHost, StringComparison.OrdinalIgnoreCase)) return true;
            // Successful native enumeration replaces RemoteComputerName with
            // the server's actual short name. Keep the pinned request/IP proof;
            // never treat the changed display name as an unrelated target.
            if (!explicitAddress || !String.Equals(request.RemoteHost, requested.ToString(), StringComparison.Ordinal) ||
                action != "EnumerateComputer" || !result.Success || !result.RemoteComputerEnumerationVerified ||
                !Has(result, "REMOTE_COMPUTER_ENUMERATION_VERIFIED", "ok") ||
                !String.Equals(result.RemoteComputerName, result.RemoteName, StringComparison.OrdinalIgnoreCase) ||
                !Regex.IsMatch(result.RemoteName ?? String.Empty, @"^(?=.{1,15}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", RegexOptions.CultureInvariant) ||
                Regex.IsMatch(result.RemoteName ?? String.Empty, @"^[0-9]+$", RegexOptions.CultureInvariant)) return false;
            return true;
        }
        private static bool NativeFolderMatches(WorkerResult result, ShareRequest request)
        {
            return result.Success && result.ConnectionVerified && result.NativeConnectionVerified &&
                !String.IsNullOrWhiteSpace(request.RemoteShareName) && !String.IsNullOrWhiteSpace(request.RemoteUserName) &&
                String.Equals(result.RemoteShareName, request.RemoteShareName, StringComparison.OrdinalIgnoreCase) &&
                String.Equals(result.LoginUserName, request.RemoteUserName, StringComparison.OrdinalIgnoreCase) &&
                String.Equals(result.SharePath, @"\\" + result.RemoteAddress + @"\" + request.RemoteShareName, StringComparison.OrdinalIgnoreCase) &&
                Has(result, "WINDOWS_NATIVE_ACCESS_VERIFIED", "ok") && !HasNativeFailure(result);
        }
        private static bool Has(WorkerResult result, string code, string state)
        {
            foreach (CheckItem item in result.Checks ?? new CheckItem[0])
                if (item != null && String.Equals(item.Code, code, StringComparison.Ordinal) && String.Equals(item.State, state, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
        private static bool HasNativeFailure(WorkerResult result)
        {
            foreach (CheckItem item in result.Checks ?? new CheckItem[0])
                if (item != null && String.Equals(item.Name, "Echter Windows-Client-Zugriff", StringComparison.Ordinal) && String.Equals(item.State, "error", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
        private static bool HasProblem(WorkerResult result)
        {
            foreach (CheckItem item in result.Checks ?? new CheckItem[0])
                if (item != null && (String.Equals(item.State, "error", StringComparison.OrdinalIgnoreCase) || String.Equals(item.State, "warning", StringComparison.OrdinalIgnoreCase))) return true;
            return false;
        }
    }
}
