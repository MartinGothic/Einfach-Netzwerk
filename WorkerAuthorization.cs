using System;
using System.Collections.Generic;

namespace EinfachNetzwerk
{
    // Validate the request with RequestRules before authorizing execution.
    // These actions inspect Windows or establish a user SMB connection; they
    // do not change machine-wide network configuration and need no elevation.
    internal static class WorkerAuthorization
    {
        private static readonly HashSet<string> NonElevatedActions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Inspect", "InspectRemote", "ConnectRemote", "InspectServices",
            "InspectClient", "EnumerateComputer", "InspectResetShares"
        };

        internal static bool IsNonElevatedAction(string action)
        {
            return action != null && NonElevatedActions.Contains(action);
        }

        internal static bool RequiresAdministrator(ShareRequest request)
        {
            return request == null || (!request.DryRun && !IsNonElevatedAction(request.Action));
        }
    }
}
