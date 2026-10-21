using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal sealed class AeroProgressBar : ProgressBar
    {
        private readonly Timer shimmer = new Timer { Interval = 35 };
        private readonly Stopwatch shimmerWatch = new Stopwatch();
        private float shimmerPosition;
        private Form observedForm;
        private bool paintDisposed;
        private bool working;

        internal bool Working
        {
            get { return working; }
            set { if (working != value) { working = value; UpdateShimmer(); Invalidate(); } }
        }

        internal AeroProgressBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Style = ProgressBarStyle.Continuous;
            shimmer.Tick += ShimmerTick;
            AeroTheme.AnimationChanged += AnimationSettingChanged;
        }

        private bool CanShimmer { get { return !paintDisposed && working && IsHandleCreated && Enabled && Value > Minimum && Value < Maximum && Style != ProgressBarStyle.Marquee && AeroTheme.CanAnimate(this); } }

        private void ShimmerTick(object sender, EventArgs e)
        {
            if (!CanShimmer) { UpdateShimmer(); return; }
            float seconds = Math.Min(.1f, Math.Max(.001f, (float)shimmerWatch.Elapsed.TotalSeconds));
            shimmerWatch.Restart();
            shimmerPosition = (shimmerPosition + seconds / 1.85f) % 1f;
            // No value changes are allowed here: light only traverses the already
            // counted fill, so the displayed percentage and its edge remain exact.
            int insideWidth = Math.Max(0, Width - 2);
            int fillWidth = (int)((long)insideWidth * (Value - Minimum) / Math.Max(1, Maximum - Minimum));
            if (fillWidth > 0) Invalidate(new Rectangle(1, 1, fillWidth, Math.Max(0, Height - 2)));
        }

        private void UpdateShimmer()
        {
            if (paintDisposed) return;
            ObserveForm();
            if (CanShimmer)
            {
                if (!shimmer.Enabled) { shimmerWatch.Restart(); shimmer.Start(); }
            }
            else
            {
                shimmer.Stop();
                shimmerWatch.Reset();
                shimmerPosition = 0;
            }
        }

        private void ObserveForm()
        {
            Form next = FindForm();
            if (next == observedForm) return;
            if (observedForm != null)
            {
                observedForm.Resize -= OwnerStateChanged;
                observedForm.VisibleChanged -= OwnerStateChanged;
                observedForm.EnabledChanged -= OwnerStateChanged;
            }
            observedForm = next;
            if (observedForm != null)
            {
                observedForm.Resize += OwnerStateChanged;
                observedForm.VisibleChanged += OwnerStateChanged;
                observedForm.EnabledChanged += OwnerStateChanged;
            }
        }

        private void AnimationSettingChanged(object sender, EventArgs e) { UpdateShimmer(); Invalidate(); }
        private void OwnerStateChanged(object sender, EventArgs e) { UpdateShimmer(); }
        protected override void OnParentChanged(EventArgs e) { base.OnParentChanged(e); UpdateShimmer(); }
        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); UpdateShimmer(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); UpdateShimmer(); }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); UpdateShimmer(); }
        protected override void OnHandleDestroyed(EventArgs e) { if (!paintDisposed) { shimmer.Stop(); shimmerWatch.Reset(); } base.OnHandleDestroyed(e); }
        protected override void OnSystemColorsChanged(EventArgs e) { base.OnSystemColorsChanged(e); UpdateShimmer(); Invalidate(); }

        protected override void WndProc(ref Message message)
        {
            base.WndProc(ref message);
            // ProgressBar.Value is not virtual and the presenter holds ProgressBar.
            // Its normal native position/range messages cover every actual setter.
            if (message.Msg == 0x402 || message.Msg == 0x404 || message.Msg == 0x406)
            {
                UpdateShimmer();
                Invalidate();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Rectangle track = ClientRectangle;
            if (track.Width < 3 || track.Height < 3) return;
            e.Graphics.Clear(SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(215, 231, 240));
            using (Pen border = new Pen(SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(119, 151, 173)))
                e.Graphics.DrawRectangle(border, 0, 0, track.Width - 1, track.Height - 1);
            Rectangle inside = new Rectangle(1, 1, track.Width - 2, track.Height - 2);
            int span = Math.Max(1, Maximum - Minimum);
            int width = (int)((long)inside.Width * (Value - Minimum) / span);
            if (width <= 0) return;
            Rectangle fill = new Rectangle(inside.X, inside.Y, width, inside.Height);
            if (SystemInformation.HighContrast)
            {
                using (SolidBrush brush = new SolidBrush(SystemColors.Highlight)) e.Graphics.FillRectangle(brush, fill);
                return;
            }
            GraphicsState state = e.Graphics.Save();
            try
            {
                // All animated gloss is clipped to counted progress, including at 1%.
                e.Graphics.SetClip(fill, CombineMode.Intersect);
                using (LinearGradientBrush green = new LinearGradientBrush(inside, Color.FromArgb(204, 255, 213), Color.FromArgb(11, 140, 64), 90f))
                {
                    green.InterpolationColors = new ColorBlend { Colors = new[] { Color.FromArgb(212, 255, 221), Color.FromArgb(134, 230, 159), Color.FromArgb(56, 184, 104), Color.FromArgb(14, 144, 68) }, Positions = new[] { 0f, .43f, .46f, 1f } };
                    e.Graphics.FillRectangle(green, fill);
                }
                Rectangle gloss = new Rectangle(fill.X, fill.Y, fill.Width, Math.Max(1, fill.Height / 2));
                using (LinearGradientBrush light = new LinearGradientBrush(gloss, Color.FromArgb(120, Color.White), Color.FromArgb(20, Color.White), 90f)) e.Graphics.FillRectangle(light, gloss);
                if (CanShimmer)
                {
                    float band = Math.Max(30, Math.Min(95, Width * .14f));
                    float x = inside.Left - band + (inside.Width + band * 2) * shimmerPosition;
                    using (LinearGradientBrush shine = new LinearGradientBrush(new RectangleF(x, inside.Top, band, inside.Height), Color.Transparent, Color.Transparent, 0f))
                    {
                        shine.InterpolationColors = new ColorBlend { Colors = new[] { Color.FromArgb(0, Color.White), Color.FromArgb(170, Color.White), Color.FromArgb(0, Color.White) }, Positions = new[] { 0f, .5f, 1f } };
                        e.Graphics.FillRectangle(shine, x, inside.Top, band, inside.Height);
                    }
                }
                using (Pen edge = new Pen(Color.FromArgb(205, 255, 220))) e.Graphics.DrawLine(edge, fill.Left, fill.Top, fill.Right - 1, fill.Top);
            }
            finally { e.Graphics.Restore(state); }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                paintDisposed = true;
                shimmer.Stop();
                shimmer.Tick -= ShimmerTick;
                shimmer.Dispose();
                AeroTheme.AnimationChanged -= AnimationSettingChanged;
                if (observedForm != null)
                {
                    observedForm.Resize -= OwnerStateChanged;
                    observedForm.VisibleChanged -= OwnerStateChanged;
                    observedForm.EnabledChanged -= OwnerStateChanged;
                    observedForm = null;
                }
            }
            base.Dispose(disposing);
        }
    }
}
