using System;

namespace EinfachNetzwerk
{
    // Discovery's legacy percentage weights phases differently. The counted
    // presenter instead needs real phase items and one reserved UI confirmation.
    public sealed class DiscoveryWorkProgress
    {
        private readonly object gate = new object();
        private string phase;
        private int total, completed;
        private bool observedWork, accepted;

        public WorkProgress Report(DiscoveryProgress value)
        {
            if (value == null || (value.Phase != "scan" && value.Phase != "details") ||
                value.Total <= 0 || value.Total == Int32.MaxValue || value.Completed < 0 || value.Completed > value.Total)
                return null;
            lock (gate)
            {
                if (accepted) return null;
                bool begin = !String.Equals(phase, value.Phase, StringComparison.Ordinal);
                if (begin)
                {
                    // Real discovery processes addresses before their details.
                    // A delayed earlier callback must not reopen the old phase.
                    if (phase == "details" || (phase == "scan" && completed != total)) return null;
                    phase = value.Phase;
                    total = value.Total;
                    completed = value.Completed;
                }
                else
                {
                    if (value.Total != total || value.Completed <= completed) return null;
                    completed = value.Completed;
                }
                observedWork = true;
                int countedTotal = total + 1;
                return new WorkProgress
                {
                    Text = phase == "scan" ? "Computer und Freigaben im Heimnetz suchen …" : "Freigaben prüfen",
                    Completed = completed,
                    Total = countedTotal,
                    Percent = (int)((long)completed * 100 / countedTotal),
                    PhaseStart = begin
                };
            }
        }

        public WorkProgress Accept(DiscoveryResult result)
        {
            lock (gate)
            {
                if (accepted) return null;
                accepted = true;
                // With no candidate/detail work, accepting the actual empty
                // result is one completed item, followed by UI confirmation.
                if (observedWork || !IsComplete(result) || result.CandidateCount != 0) return null;
                return new WorkProgress { Text = "Heimnetzsuche", Completed = 1, Total = 2, Percent = 50, PhaseStart = true };
            }
        }

        public static bool IsComplete(DiscoveryResult result)
        {
            if (result == null || result.Cancelled || result.TimedOut || result.CandidateCount < 0 ||
                result.CompletedCount < 0 || result.CompletedCount != result.CandidateCount) return false;
            foreach (string error in result.Errors ?? new System.Collections.Generic.List<string>())
            {
                if (error != null && (error.StartsWith("DISCOVERY_NETWORK_CHANGED", StringComparison.OrdinalIgnoreCase) ||
                    error.StartsWith("NETWORK_INVENTORY", StringComparison.OrdinalIgnoreCase))) return false;
            }
            // A completely processed bounded plan may still warn that further
            // addresses or details were outside the explicitly chosen scope.
            return true;
        }
    }
}
