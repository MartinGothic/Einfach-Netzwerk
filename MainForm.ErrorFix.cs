using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    public sealed partial class MainForm
    {
        private void LoadLocalDrives()
        {
            if (drivesLoaded) return;
            drivesLoaded = true;
            foreach (DriveInfo drive in DriveInfo.GetDrives())
            {
                try
                {
                    if ((drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable) || !drive.IsReady) continue;
                    string name = drive.Name + "  " + (String.IsNullOrEmpty(drive.VolumeLabel) ? I18n.T("Datenlaufwerk") : drive.VolumeLabel);
                    if (IsSystemDrive(drive.RootDirectory.FullName)) name += I18n.T("  (Windows-Laufwerk: Unterordner wählen)");
                    drives.Items.Add(new DriveChoice(drive.RootDirectory.FullName, name));
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        private async Task OpenErrorFixWindow(bool showRemembered = false)
        {
            if (busy) return;
            ErrorFixAction action;
            CheckItem check;
            using (ErrorFixDialog dialog = new ErrorFixDialog(preview, InspectAllErrors, OpenNetworkReset))
            {
                if (showRemembered || ProblemMemory.Snapshot().Length > 0) dialog.ShowKnownProblems(ProblemMemory.AsResult());
                dialog.ShowDialog(this);
                action = dialog.RequestedAction;
                check = dialog.RequestedCheck;
            }
            await RouteErrorFix(action, check);
        }

        private async Task RouteErrorFix(ErrorFixAction action, CheckItem check)
        {
            if (action == ErrorFixAction.Services) OpenServiceRepair();
            else if (action == ErrorFixAction.ClientPreparation) OpenRemoteAccess(true, true);
            else if (action == ErrorFixAction.Reset) await OpenNetworkReset(this);
            else if (action == ErrorFixAction.Receiver || action == ErrorFixAction.ShareList || action == ErrorFixAction.NameAccess)
            {
                if (check != null && !String.IsNullOrWhiteSpace(check.RemoteHost))
                { rememberedRemoteHost = check.RemoteHost; rememberedRemoteShare = null; rememberedRemoteUser = null; }
                OpenRemoteAccess(true);
            }
            else if (action == ErrorFixAction.Share || action == ErrorFixAction.Discovery || action == ErrorFixAction.Permissions)
                await RepairSelectedSavedShare(check);
        }

        private Task OpenNetworkReset(IWin32Window owner)
        {
            if (busy) return Task.FromResult(false);
            using (ResetNetworkDialog dialog = new ResetNetworkDialog(preview,
                PrepareNetworkReset,
                ExecuteNetworkReset, null, PrepareAndRepairNetworkReset))
                dialog.ShowDialog(owner);
            return Task.FromResult(true);
        }

        private async Task<ResetNetworkPlan> PrepareNetworkReset(Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            string auditDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EinfachNetzwerk", "ResetPlans");
            ResetNetworkPlan plan = await ResetNetworkWorkflow.PrepareAsync(RunResetRequest, auditDirectory, phaseSink, countedSink);
            if (plan != null) DiagnosticReports.Current.RecordOperation("Rücksetzungsplan", null, plan.DiagnosticResult);
            return plan;
        }

        private async Task<WorkerResult> ExecuteNetworkReset(ResetNetworkPlan plan, Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            WorkerResult result = await ResetNetworkWorkflow.ExecuteAsync(plan, RunResetRequest, phaseSink, countedSink);
            DiagnosticReports.Current.RecordOperation("Netzwerk zurücksetzen", null, result);
            if (result != null && result.Success)
            {
                restoreName = restoreFolder = restoreBackup = currentBackup = String.Empty;
                ShowResult(result);
                if (discoveryPeer != null) { discoveryPeer.Dispose(); discoveryPeer = null; }
                status.Text = I18n.TranslatePhase(result.Message ?? String.Empty);
            }
            return result;
        }

        private async Task<ResetNetworkPlan> PrepareAndRepairNetworkReset(Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            string auditDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EinfachNetzwerk", "ResetPlans");
            ResetNetworkPlan plan = await ResetPreparationRepairWorkflow.PrepareAsync(RunResetRequest, auditDirectory, phaseSink, countedSink);
            if (plan != null) DiagnosticReports.Current.RecordOperation("Rücksetzung automatisch vorbereiten", null, plan.DiagnosticResult);
            return plan;
        }

        private async Task<WorkerResult> RunResetRequest(ShareRequest request, Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            if (busy || preview) throw new InvalidOperationException(I18n.T("Vorgang läuft"));
            bool mutate = WorkerAuthorization.RequiresAdministrator(request);
            SetBusy(true);
            try
            {
                WorkerResult result = await BackendClient.RunAsync(request, mutate,
                    delegate(string text) { UpdatePhase(text); if (phaseSink != null) phaseSink(I18n.TranslatePhase(text)); },
                    delegate(WorkProgress value) { UpdateCountedProgress(value); if (countedSink != null) countedSink(value); });
                if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen."));
                DiagnosticReports.Current.RecordOperation(request.Action, request, result);
                if (request.Action == "Inspect") ShowResult(result);
                else if (request.Action == "InspectServices" || request.Action == "RestoreServices" || request.Action == "RepairServices") lastServiceResult = result;
                else if (request.Action == "InspectClient" || request.Action == "RestoreClient") lastRemoteResult = result;
                if (mutate) await countedProgress.FinishAsync(result.Success); else await countedProgress.FinishInspectionAsync();
                phase = I18n.TranslatePhase(result.Message ?? String.Empty);
                return result;
            }
            catch (Exception error) { countedProgress.Stop(); DiagnosticReports.Current.RecordException(request.Action, error, request); throw; }
            finally { SetBusy(false); status.Text = phase; }
        }

        private async Task RepairSelectedSavedShare(CheckItem check)
        {
            WorkerResult previous = lastRawResult;
            await RunOperation("Inspect");
            if (preview || lastRawResult == null || Object.ReferenceEquals(previous, lastRawResult)) return;
            if (HasServiceFailure()) { OpenServiceRepair(); return; }
            if (!lastRawResult.Success && (lastRawResult.Checks ?? new CheckItem[0]).Any(item => item != null && item.State == "error" && (item.Code ?? "").IndexOf("INVENTORY", StringComparison.OrdinalIgnoreCase) >= 0))
                return;
            ShareItem[] available = (lastRawResult.Shares ?? new ShareItem[0]).Where(item => item != null && item.Managed && item.Available).ToArray();
            if (!lastRawResult.Success && (lastRawResult.Shares ?? new ShareItem[0]).Length == 0) return;
            ShareItem selected = check == null || String.IsNullOrWhiteSpace(check.TargetShare) ? null : available.FirstOrDefault(item => String.Equals(item.Name, check.TargetShare, StringComparison.OrdinalIgnoreCase));
            if (check != null && !String.IsNullOrWhiteSpace(check.TargetShare) && selected == null)
            { status.Text = I18n.T("Die ausgewählte Freigabe ist nicht mehr vorhanden. Bitte die Übersicht aktualisieren."); return; }
            if (selected == null && available.Length == 1) selected = available[0];
            if (selected == null && available.Length > 1)
            {
                using (AeroGlassForm chooser = new AeroGlassForm { Text = I18n.T("Freigabe auswählen"), Font = Font, ClientSize = new Size(590, 205), StartPosition = FormStartPosition.CenterParent, ShowInTaskbar = false, MinimizeBox = false, MaximizeBox = false })
                {
                    AeroTheme.ApplyWindowIcon(chooser);
                    Label hint = new Label { Text = I18n.T("Welche gespeicherte Freigabe möchtest du reparieren?"), Bounds = new Rectangle(18, 18, 550, 40) };
                    ComboBox options = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Bounds = new Rectangle(18, 68, 550, 30) };
                    options.Items.AddRange(available); options.SelectedIndex = 0;
                    Button repair = ActionButton("Automatisch reparieren", 240, true); repair.Location = new Point(18, 143); repair.DialogResult = DialogResult.OK;
                    Button cancel = ActionButton("Abbrechen", 140, false); cancel.Location = new Point(428, 143); cancel.DialogResult = DialogResult.Cancel;
                    chooser.Controls.AddRange(new Control[] { hint, options, repair, cancel }); chooser.AcceptButton = repair; chooser.CancelButton = cancel;
                    if (chooser.ShowDialog(this) == DialogResult.OK) selected = options.SelectedItem as ShareItem;
                }
            }
            if (selected == null)
            {
                if (available.Length == 0) { status.Text = I18n.T("Noch keine gespeicherte Freigabe vorhanden. Richte sie mit dem Assistenten ein."); OpenWizard(); }
                return;
            }
            for (int i = 0; i < existingShares.Items.Count; i++)
            {
                ShareChoice item = existingShares.Items[i] as ShareChoice;
                if (item != null && String.Equals(item.Item.Name, selected.Name, StringComparison.OrdinalIgnoreCase)) { existingShares.SelectedIndex = i; break; }
            }
            // Repair creates its request from this fresh, selected inventory and
            // retains the existing concrete confirmation and transaction backup.
            await RunOperation("Repair");
        }

        private async Task<WorkerResult> InspectAllErrors(Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            if (busy || preview) throw new InvalidOperationException(I18n.T("Vorgang läuft"));
            SetBusy(true);
            try
            {
                WorkerResult local = await RunErrorInspection(new ShareRequest { Action = "Inspect" }, phaseSink, countedSink);
                ShowResult(local);
                WorkerResult services = await RunErrorInspection(new ShareRequest { Action = "InspectServices" }, phaseSink, countedSink);
                lastServiceResult = services;
                NetworkChoice selected = networks.SelectedItem as NetworkChoice;
                WorkerResult client = await RunErrorInspection(new ShareRequest { Action = "InspectClient", Mode = guestMode.Checked ? "Guest" : "Password", AdapterId = selected == null ? 0 : selected.Item.Id }, phaseSink, countedSink);
                lastRemoteResult = client;
                List<CheckItem> collected = new List<CheckItem>();
                foreach (WorkerResult item in new[] { local, services, client })
                    AddInspectionChecks(collected, item);
                DiscoveryWorkProgress discoveryCounts = new DiscoveryWorkProgress();
                phase = I18n.T("Computer und Freigaben im Heimnetz suchen …"); if (phaseSink != null) phaseSink(phase); UpdateStatus();
                DiscoveryResult found = await Task.Run(delegate
                {
                    return NetworkDiscovery.Scan(delegate(DiscoveryProgress value)
                    {
                        lock (discoveryCounts)
                        {
                            WorkProgress count = discoveryCounts.Report(value);
                            if (count == null || IsDisposed || !IsHandleCreated) return;
                            BeginInvoke(new Action(delegate { UpdatePhase(count.Text); if (phaseSink != null) phaseSink(I18n.TranslatePhase(count.Text)); UpdateCountedProgress(count); if (countedSink != null) countedSink(count); }));
                        }
                    }, CancellationToken.None);
                });
                WorkProgress accepted = discoveryCounts.Accept(found);
                if (accepted != null) { UpdateCountedProgress(accepted); if (countedSink != null) countedSink(accepted); }
                discoveredComputerCount = found.Computers.Count;
                discoverySummary.Text = I18n.Format("{0} Computer im Heimnetz gefunden. Öffne „Andere Computer“, um Freigaben auszuwählen.", discoveredComputerCount);
                collected.Add(new CheckItem { Name = I18n.T("Heimnetzsuche"), State = found.Errors.Count > 0 || found.Truncated || found.TimedOut ? "warning" : "info", Code = found.Errors.Count > 0 || found.Truncated || found.TimedOut ? "DISCOVERY_INCOMPLETE" : "DISCOVERY_COMPLETE", Detail = discoverySummary.Text + (found.Truncated || found.TimedOut ? " " + I18n.T("Die Suche war begrenzt; weitere Geräte können fehlen.") : "") + (found.Errors.Count > 0 ? " " + String.Join("; ", found.Errors.ToArray()) : "") });
                foreach (DiscoveredComputer computer in found.Computers)
                    collected.Add(new CheckItem { Name = computer.ToString(), RemoteHost = computer.Address, State = computer.Port445Open ? "info" : "warning", Code = computer.Port445Open ? "REMOTE_ACCESS_NOT_CHECKED" : "REMOTE_PORT_UNREACHABLE", Detail = I18n.T(computer.Port445Open ? "Port 445 antwortet. Ordnerzugriff und Anmeldung müssen separat geprüft werden." : "Port 445 antwortet nicht. Prüfe den Netzwerkzugriff und ob der Computer wach ist."), Fixable = !computer.Port445Open });
                WorkerResult combined = JsonData.Parse<WorkerResult>(JsonData.Serialize(local));
                combined.InspectionIncomplete = !DiscoveryWorkProgress.IsComplete(found);
                combined.Checks = collected.Where(item => item != null).GroupBy(item => (item.Name ?? "") + "\n" + (item.Code ?? "") + "\n" + (item.Detail ?? "")).Select(group => group.First()).ToArray();
                combined.Success = local.Success && services.Success && client.Success && !combined.Checks.Any(item => item.State == "error");
                combined.ErrorCode = new[] { local, services, client }.Where(item => !item.Success && !String.IsNullOrWhiteSpace(item.ErrorCode)).Select(item => item.ErrorCode).FirstOrDefault() ?? String.Empty;
                combined.Message = I18n.T("Gesamtprüfung: Einstellungen und Dienste dieses PCs. Andere Computer werden gesucht; ihr Ordnerzugriff wird separat geprüft.");
                combined.ClientBackupPath = client.ClientBackupPath; combined.ClientRepairAvailable = client.ClientRepairAvailable;
                DiagnosticReports.Current.RecordOperation("Gesamtprüfung", null, combined);
                if (combined.InspectionIncomplete) await countedProgress.FinishAsync(false); else await countedProgress.FinishInspectionAsync();
                phase = combined.Message;
                return combined;
            }
            catch (Exception error) { countedProgress.Stop(); DiagnosticReports.Current.RecordException("Gesamtprüfung", error); throw; }
            finally { SetBusy(false); status.Text = phase; }
        }

        private static void AddInspectionChecks(List<CheckItem> collected, WorkerResult result)
        {
            CheckItem[] checks = (result.Checks ?? new CheckItem[0]).Where(check => check != null).ToArray();
            collected.AddRange(checks);
            // Preserve the concrete warning and its repairability. A second
            // generic error would hide it and could never match a fresh check.
            if (!result.Success && !result.AnonymousShareListDenied && !checks.Any(check => check.State == "error" || check.State == "warning"))
                collected.Add(new CheckItem { Name = "Prüfung", State = "error", Code = result.ErrorCode ?? "INSPECTION_FAILED", Detail = result.Message, Fixable = false });
        }

        private async Task<WorkerResult> RunErrorInspection(ShareRequest request, Action<string> phaseSink, Action<WorkProgress> countedSink)
        {
            bool first = true;
            WorkerResult result = await BackendClient.RunAsync(request, false,
                delegate(string text) { UpdatePhase(text); if (phaseSink != null) phaseSink(I18n.TranslatePhase(text)); },
                delegate(WorkProgress value)
                {
                    value.PhaseStart = first; first = false;
                    UpdateCountedProgress(value); if (countedSink != null) countedSink(value);
                });
            if (result == null) throw new InvalidOperationException(I18n.T("Windows hat kein Ergebnis zurückgegeben. Bitte erneut prüfen."));
            DiagnosticReports.Current.RecordOperation(request.Action, request, result);
            return result;
        }
    }
}
