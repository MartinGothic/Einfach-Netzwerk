using System;
using System.Globalization;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    public sealed class WorkProgress
    {
        public string Text { get; set; }
        public int Completed { get; set; }
        public int Total { get; set; }
        public int Percent { get; set; }
        public bool PhaseStart { get; set; }
        // Only the in-process client can set this after reading the result file.
        // It is not a worker JSON claim or an elapsed-time estimate.
        internal bool ResultAccepted { get; set; }

        // Counts come from the worker. Never infer progress from elapsed time or phase names.
        internal int CompletedPercent
        {
            get
            {
                if (Total <= 0 || Completed < 0 || Completed > Total) return 0;
                return (int)((long)Completed * 100 / Total);
            }
        }
        internal static WorkProgress Read(string value)
        {
            if (String.IsNullOrWhiteSpace(value) || !value.TrimStart().StartsWith("{", StringComparison.Ordinal)) return null;
            try
            {
                WorkProgress result = JsonData.Parse<WorkProgress>(value);
                if (result == null || result.Total <= 0 || result.Completed < 0 || result.Completed > result.Total ||
                    result.Percent != result.CompletedPercent) return null;
                return result;
            }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }
    }

    internal sealed class CountedProgressPresenter : IDisposable
    {
        private readonly ProgressBar bar;
        private readonly Label percentage;
        private readonly Timer timer = new Timer { Interval = 20 };
        private TaskCompletionSource<bool> completion;
        private bool disposed;
        private int lastWorkCompleted;
        private int lastWorkTotal;
        private bool lastResultAccepted;
        internal int DisplayedPercent { get; private set; }
        internal int TargetPercent { get; private set; }

        internal CountedProgressPresenter(ProgressBar bar, Label percentage)
        {
            if (bar == null || percentage == null) throw new ArgumentNullException();
            this.bar = bar;
            this.percentage = percentage;
            bar.Minimum = 0;
            bar.Maximum = 100;
            bar.Style = ProgressBarStyle.Continuous;
            timer.Tick += Tick;
            PaintValue();
        }
        internal void Begin()
        {
            if (disposed) return;
            timer.Stop();
            if (completion != null) completion.TrySetResult(false);
            completion = null;
            lastWorkCompleted = lastWorkTotal = 0;
            lastResultAccepted = false;
            DisplayedPercent = TargetPercent = 0;
            bar.Visible = percentage.Visible = true;
            SetWorking(true);
            PaintValue();
        }
        internal void Report(WorkProgress progress)
        {
            if (disposed || progress == null) return;
            if (progress.Total <= 0 || progress.Completed < 0 || progress.Completed > progress.Total ||
                progress.Percent != progress.CompletedPercent) return;
            lastWorkCompleted = progress.Completed;
            lastWorkTotal = progress.Total;
            lastResultAccepted = progress.ResultAccepted && progress.Completed == progress.Total;
            // Even a worker reporting all its steps cannot certify the result file itself.
            // The client accepts the result before either successful work or a fully
            // completed read-only inspection can reach 100%.
            TargetPercent = Math.Max(TargetPercent, Math.Min(99, progress.CompletedPercent));
            if (DisplayedPercent < TargetPercent) timer.Start();
        }
        internal Task FinishInspectionAsync()
        {
            // Call only after accepting a read-only inspection result. A problem found
            // by a completed inspection is a result, not unfinished inspection work.
            // The worker reserves one final unit; BackendClient may already have
            // acknowledged it after reading a successful result file. Raw worker
            // counts cannot grant this acknowledgement. Early failures and
            // missing/invalid progress cannot earn that final unit.
            return FinishAsync((lastResultAccepted && lastWorkTotal > 0 && lastWorkCompleted == lastWorkTotal) ||
                (lastWorkTotal > 1 && lastWorkCompleted == lastWorkTotal - 1));
        }
        internal async Task FinishAsync(bool success)
        {
            if (disposed) return;
            TargetPercent = success ? 100 : Math.Min(99, TargetPercent);
            if (DisplayedPercent < TargetPercent)
            {
                completion = new TaskCompletionSource<bool>();
                timer.Start();
                await completion.Task;
            }
            // Give the last confirmed frame time to paint before a wizard changes its page.
            // This pause never generates work or percentages.
            if (success && !disposed) await Task.Delay(150);
            SetWorking(false);
        }
        internal void Stop()
        {
            timer.Stop();
            SetWorking(false);
            lastWorkCompleted = lastWorkTotal = 0;
            lastResultAccepted = false;
            TargetPercent = DisplayedPercent;
            if (completion != null) { completion.TrySetResult(false); completion = null; }
        }
        private void Tick(object sender, EventArgs args)
        {
            if (disposed) return;
            // This only smooths work already confirmed; it never advances past that work.
            if (DisplayedPercent < TargetPercent) { DisplayedPercent++; PaintValue(); }
            if (DisplayedPercent >= TargetPercent)
            {
                timer.Stop();
                if (completion != null) { completion.TrySetResult(true); completion = null; }
            }
        }
        private void PaintValue()
        {
            if (bar.IsDisposed || percentage.IsDisposed) return;
            bar.Value = DisplayedPercent;
            bar.Invalidate();
            percentage.Text = DisplayedPercent.ToString(CultureInfo.CurrentCulture) + " %";
            bar.AccessibleName = I18n.T("Fortschritt");
            bar.AccessibleDescription = percentage.Text;
        }
        private void SetWorking(bool value)
        {
            AeroProgressBar glass = bar as AeroProgressBar;
            if (glass != null && !glass.IsDisposed) glass.Working = value;
        }
        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            SetWorking(false);
            timer.Stop();
            timer.Dispose();
            if (completion != null) { completion.TrySetResult(false); completion = null; }
        }
    }
}
