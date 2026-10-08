param([string]$AssemblyPath='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($AssemblyPath)){$AssemblyPath=Join-Path $PSScriptRoot 'dist\Einfach-Netzwerk.exe'}
$AssemblyPath=[IO.Path]::GetFullPath($AssemblyPath)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$taskDiscoveryProgressAssembly=[Reflection.Assembly]::LoadFile($AssemblyPath)
$taskDiscoveryProgressSource=''
if($null -eq $taskDiscoveryProgressAssembly.GetType('EinfachNetzwerk.DiscoveryWorkProgress')){
    # Allow an isolated helper check before the final app is rebuilt. Compile
    # the exact saved production helper against unchanged model/presenter types.
    $taskDiscoveryProgressSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'DiscoveryWorkProgress.cs'))
}
$taskDiscoveryProgressQa=@'
namespace DiscoveryProgressQa
{
    using System;
    using System.Collections.Generic;
    using System.Reflection;
    using System.Threading;
    using System.Threading.Tasks;
    using System.Windows.Forms;
    using EinfachNetzwerk;

    public static class Tests
    {
        private static int assertions;
        private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); assertions++; }
        private static DiscoveryProgress Item(string phase, int completed, int total, int legacyPercent)
        { return new DiscoveryProgress { Phase = phase, Completed = completed, Total = total, Percent = legacyPercent }; }
        private static DiscoveryResult Result(int completed, int total)
        { return new DiscoveryResult { CompletedCount = completed, CandidateCount = total }; }
        private static void Count(WorkProgress value, int completed, int total, bool begin)
        {
            Require(value != null, "A real discovery work unit was discarded.");
            Require(value.Completed == completed && value.Total == total, "A legacy weighted percentage replaced real discovery item counts.");
            Require(value.Percent == (int)((long)completed * 100 / total), "The converted count is rejected by the counted presenter.");
            Require(value.PhaseStart == begin, "A real phase change was not distinguished from an update.");
            Require(value.Percent < 100, "Discovery claimed the final UI confirmation.");
        }
        private static void Presenter(WorkProgress work, bool completedInspection, int expected)
        {
            Type type = typeof(WorkProgress).Assembly.GetType("EinfachNetzwerk.CountedProgressPresenter", true);
            BindingFlags hidden = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
            using (ProgressBar bar = new ProgressBar())
            using (Label label = new Label())
            {
                object value = Activator.CreateInstance(type, hidden, null, new object[] { bar, label }, null);
                try
                {
                    type.GetMethod("Begin", hidden).Invoke(value, new object[0]);
                    type.GetMethod("Report", hidden).Invoke(value, new object[] { work });
                    Require((int)type.GetProperty("TargetPercent", hidden).GetValue(value, null) == work.Percent, "The production presenter rejected actual converted discovery counts.");
                    Task task = completedInspection ? (Task)type.GetMethod("FinishInspectionAsync", hidden).Invoke(value, new object[0]) : (Task)type.GetMethod("FinishAsync", hidden).Invoke(value, new object[] { false });
                    DateTime deadline = DateTime.UtcNow.AddSeconds(5);
                    while (!task.IsCompleted && DateTime.UtcNow < deadline) { Application.DoEvents(); Thread.Sleep(5); }
                    Require(task.IsCompleted, "The production progress presenter did not finish within its isolated deadline.");
                    task.GetAwaiter().GetResult();
                    Require((int)type.GetProperty("DisplayedPercent", hidden).GetValue(value, null) == expected, "Completed discovery remains below100 or incomplete discovery falsely reaches100.");
                }
                finally { ((IDisposable)value).Dispose(); }
            }
        }
        public static string Run()
        {
            SynchronizationContext prior = SynchronizationContext.Current;
            bool auto = WindowsFormsSynchronizationContext.AutoInstall;
            WindowsFormsSynchronizationContext context = new WindowsFormsSynchronizationContext();
            WindowsFormsSynchronizationContext.AutoInstall = false;
            SynchronizationContext.SetSynchronizationContext(context);
            try
            {
                DiscoveryWorkProgress converter = new DiscoveryWorkProgress();
                Count(converter.Report(Item("scan", 0, 10, 0)), 0, 11, true);
                Count(converter.Report(Item("scan", 3, 10, 21)), 3, 11, false);
                Require(converter.Report(Item("scan", 3, 10, 99)) == null, "Duplicate work was counted twice.");
                Require(converter.Report(Item("scan", 2, 10, 14)) == null, "A delayed callback moved a phase backwards.");
                Require(converter.Report(Item("scan", 4, 11, 25)) == null, "A changed discovery work plan was treated as the original phase.");
                Count(converter.Report(Item("scan", 10, 10, 70)), 10, 11, false);
                Require(converter.Report(Item("details", 0, 0, 70)) == null, "An empty details phase erased completed address work.");
                Count(converter.Report(Item("details", 0, 2, 70)), 0, 3, true);
                Count(converter.Report(Item("details", 1, 2, 85)), 1, 3, false);
                WorkProgress last = converter.Report(Item("details", 2, 2, 100)); Count(last, 2, 3, false);
                Require(converter.Report(Item("scan", 10, 10, 70)) == null, "A late address callback reopened a completed earlier phase.");
                Require(converter.Report(Item("complete", 10, 10, 100)) == null, "A weighted terminal event replaced the actual last-phase count.");
                Require(converter.Accept(Result(10, 10)) == null, "Accepting a nonempty result manufactured a work unit.");
                Require(converter.Report(Item("details", 2, 2, 100)) == null, "Work was accepted after the final discovery result.");
                Presenter(last, true, 100);

                converter = new DiscoveryWorkProgress();
                Count(converter.Report(Item("scan", 0, 1, -999)), 0, 2, true);
                last = converter.Report(Item("scan", 1, 1, 999)); Count(last, 1, 2, false);
                Require(converter.Report(Item("details", 0, 0, 70)) == null, "A no-host discovery added fictitious details.");
                converter.Accept(Result(1, 1)); Presenter(last, true, 100);
                converter = new DiscoveryWorkProgress();
                Require(converter.Report(Item("peer", 7, 0, 0)) == null, "Peer announcements without a work plan were counted as scan completion.");
                Require(converter.Report(Item("complete", 0, 0, 100)) == null, "An empty terminal event invented100percent.");
                last = converter.Accept(Result(0, 0)); Count(last, 1, 2, true);
                Require(converter.Accept(Result(0, 0)) == null, "An empty result was accepted twice."); Presenter(last, true, 100);

                foreach (DiscoveryProgress invalid in new[] { null, Item("unknown", 1, 2, 50), Item("scan", -1, 2, 0), Item("scan", 3, 2, 100), Item("scan", 0, 0, 0), Item("scan", 1, Int32.MaxValue, 0) })
                    Require(new DiscoveryWorkProgress().Report(invalid) == null, "Invalid discovery work reached the presenter.");
                converter = new DiscoveryWorkProgress();
                converter.Report(Item("scan", 1, 3, 23));
                Require(converter.Report(Item("details", 0, 1, 70)) == null, "Details began before the actual address phase completed.");

                Require(!DiscoveryWorkProgress.IsComplete(null), "A missing result was marked complete.");
                Require(!DiscoveryWorkProgress.IsComplete(Result(-1, 1)) && !DiscoveryWorkProgress.IsComplete(Result(2, 1)) && !DiscoveryWorkProgress.IsComplete(Result(1, 2)), "Invalid/incomplete candidate counts were marked complete.");
                Require(DiscoveryWorkProgress.IsComplete(Result(0, 0)), "An accepted empty discovery result was left unfinished.");
                DiscoveryResult bounded = Result(2, 2); bounded.Truncated = true;
                Require(DiscoveryWorkProgress.IsComplete(bounded), "A fully processed bounded plan was confused with a cancelled search.");
                bounded.Errors.Add("DISCOVERY_PEER: optional peer responder did not answer");
                Require(DiscoveryWorkProgress.IsComplete(bounded), "An optional peer hint failure erased completed address processing.");
                foreach (string error in new[] { "DISCOVERY_NETWORK_CHANGED: private adapter lost", "network_inventory: provider failed" })
                {
                    DiscoveryResult failed = Result(0, 0); failed.Errors.Add(error);
                    Require(!DiscoveryWorkProgress.IsComplete(failed), "A missing or changed private network was marked complete.");
                    Require(new DiscoveryWorkProgress().Accept(failed) == null, "Failed inventory received a fabricated empty-result work unit.");
                }
                foreach (string kind in new[] { "timeout", "cancelled" })
                {
                    DiscoveryResult failed = Result(2, 2); failed.TimedOut = kind == "timeout"; failed.Cancelled = kind == "cancelled";
                    Require(!DiscoveryWorkProgress.IsComplete(failed), "A stopped details phase was marked complete merely because addresses finished.");
                    converter = new DiscoveryWorkProgress(); converter.Report(Item("scan", 0, 2, 0)); last = converter.Report(Item("scan", 2, 2, 70));
                    Require(converter.Accept(failed) == null, "A stopped search gained a confirmation work unit.");
                    Presenter(last, false, last.Percent);
                }
            }
            finally { SynchronizationContext.SetSynchronizationContext(prior); WindowsFormsSynchronizationContext.AutoInstall = auto; context.Dispose(); }
            return JsonData.Serialize(new { Assertions = assertions, ActualPresenter = true, CountedPhases = "Real addresses/details plus final UI confirmation", Isolation = "In-memory discovery reports and hidden progress controls only; no network scan, worker, credentials or Windows changes" });
        }
    }
}
'@
$taskDiscoveryProgressCompiler=New-Object CodeDom.Compiler.CompilerParameters
foreach($taskDiscoveryProgressReference in @($AssemblyPath,'System.dll','System.Core.dll','System.Windows.Forms.dll','System.Drawing.dll','System.Web.Extensions.dll')){[void]$taskDiscoveryProgressCompiler.ReferencedAssemblies.Add($taskDiscoveryProgressReference)}
Add-Type -TypeDefinition ($taskDiscoveryProgressSource+[Environment]::NewLine+$taskDiscoveryProgressQa) -CompilerParameters $taskDiscoveryProgressCompiler
[DiscoveryProgressQa.Tests]::Run()
