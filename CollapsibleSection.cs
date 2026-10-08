using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    // Paint a single cached image while revealing. Native list views, labels
    // and text boxes return at rest, without being laid out/repainted per frame.
    internal sealed class CollapsibleSection : TableLayoutPanel
    {
        private readonly SectionHeaderButton header;
        private readonly RevealPanel viewport;
        private readonly ToolTip hint = new ToolTip();
        private readonly Timer animation = new Timer { Interval = 15 };
        private readonly Stopwatch motion = new Stopwatch();
        private bool expanded, layingOut, animating;
        private int shownHeight, fullHeight, widthMeasured;
        private float fromHeight, toHeight, fromAngle, reveal;
        private int duration;
        private Size windowSizeAtStart;
        private TableLayoutPanel motionParent;
        private readonly Dictionary<Control, Rectangle> siblingBounds = new Dictionary<Control, Rectangle>();
        private int initialParentHeight, initialSectionHeight;
        private bool contentSuspended;
        private bool prepared, preparationQueued;
        internal TableLayoutPanel Content { get; private set; }
        internal Button ToggleButton { get { return header; } }
        internal bool Expanded
        {
            get { return expanded; }
            set
            {
                if (expanded == value) return;
                // A single stack must not run two competing manual layouts.
                if (Parent != null)
                    foreach (Control sibling in Parent.Controls)
                    {
                        CollapsibleSection other = sibling as CollapsibleSection;
                        if (other != null && other != this && other.animating) other.FinishReveal();
                    }
                if (!value && Content.ContainsFocus) header.Focus();
                expanded = value;
                UpdateHint();
                // Visibility/layout events must not apply the final height
                // before the first animation frame has had a chance to run.
                animating = true;
                if (!viewport.HasSnapshot)
                {
                    Content.Visible = true;
                    viewport.Visible = true;
                    MeasureContent();
                }
                if (!AeroTheme.CanAnimate(this) || fullHeight == 0) { FinishReveal(); return; }
                if (!viewport.HasSnapshot)
                {
                    if (!viewport.CaptureContent(Content, new Size(widthMeasured, fullHeight))) { FinishReveal(); return; }
                    Content.Visible = false;
                    Content.SuspendLayout(); viewport.SuspendLayout();
                    contentSuspended = true;
                    BeginParentMotion();
                }
                viewport.Visible = true;
                fromHeight = shownHeight;
                toHeight = expanded ? fullHeight : 0;
                fromAngle = reveal;
                duration = 220 + (int)(Math.Min(250, Math.Abs(toHeight - fromHeight)) * .24);
                Form form = FindForm();
                windowSizeAtStart = form == null ? Size.Empty : form.ClientSize;
                motion.Restart();
                animation.Start();
            }
        }

        internal CollapsibleSection(string title)
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            ColumnCount = 1;
            RowCount = 2;
            Dock = DockStyle.Top;
            Padding = new Padding(15, 10, 15, 13);
            Margin = new Padding(0, 0, 0, 12);
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.Transparent;
            ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            RowStyles.Add(new RowStyle(SizeType.AutoSize));
            RowStyles.Add(new RowStyle(SizeType.Absolute, 0));
            header = new SectionHeaderButton { Text = I18n.T(title), Dock = DockStyle.Top, Margin = Padding.Empty, Height = 32 };
            header.Click += delegate { Expanded = !Expanded; };
            Controls.Add(header, 0, 0);
            viewport = new RevealPanel { Dock = DockStyle.Fill, Margin = Padding.Empty, Padding = Padding.Empty, BackColor = Color.Transparent, Visible = false, TabStop = false };
            Content = new GlassContentPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Dock = DockStyle.Top, GrowStyle = TableLayoutPanelGrowStyle.AddRows, Margin = Padding.Empty, Padding = Padding.Empty, BackColor = Color.Transparent, Visible = false };
            Content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            viewport.Controls.Add(Content);
            Controls.Add(viewport, 0, 1);
            Content.Layout += ContentLayout;
            animation.Tick += AnimateReveal;
            I18n.Changed += LanguageChanged;
            AeroTheme.AnimationChanged += AnimationChanged;
            UpdateHint();
        }

        private void MeasureContent()
        {
            if (layingOut || Content == null) return;
            layingOut = true;
            try
            {
                int width = Math.Max(1, ClientSize.Width - Padding.Horizontal);
                widthMeasured = width;
                Content.Width = width;
                Content.PerformLayout();
                fullHeight = Math.Max(0, Content.GetPreferredSize(new Size(width, 0)).Height);
            }
            finally { layingOut = false; }
        }

        private void ContentLayout(object sender, LayoutEventArgs e)
        {
            if (layingOut || animating || !expanded) return;
            MeasureContent();
            SetRevealHeight(fullHeight);
        }

        protected override void OnLayout(LayoutEventArgs e)
        {
            base.OnLayout(e);
            if (Content == null || layingOut || animating || widthMeasured == Math.Max(1, ClientSize.Width - Padding.Horizontal)) return;
            MeasureContent();
            if (expanded) SetRevealHeight(fullHeight);
        }

        private void AnimateReveal(object sender, EventArgs e)
        {
            Form form = FindForm();
            if (!AeroTheme.CanAnimate(this) || (form != null && form.ClientSize != windowSizeAtStart)) { FinishReveal(); return; }
            float time = Math.Min(1f, (float)motion.Elapsed.TotalMilliseconds / duration);
            // Zero velocity at both ends avoids the old large first-frame jump.
            float ease = time * time * (3f - 2f * time);
            reveal = fromAngle + ((expanded ? 1f : 0f) - fromAngle) * ease;
            header.Reveal = reveal;
            SetRevealHeight((int)Math.Round(fromHeight + (toHeight - fromHeight) * ease));
            if (time >= 1f) FinishReveal();
        }

        private void SetRevealHeight(int height)
        {
            height = Math.Max(0, height);
            if (height == shownHeight) return;
            shownHeight = height;
            // Changing the absolute row already triggers WinForms layout and
            // its AutoSize parent. Explicit self/parent layout tripled that work.
            RowStyles[1].Height = height;
            if (motionParent != null)
            {
                int delta = Height - initialSectionHeight;
                foreach (KeyValuePair<Control, Rectangle> item in siblingBounds)
                {
                    if (item.Key.IsDisposed) continue;
                    Rectangle original = item.Value;
                    item.Key.SetBounds(original.X, original.Y + delta, original.Width, original.Height, BoundsSpecified.Location);
                }
                motionParent.Height = Math.Max(0, initialParentHeight + delta);
            }
        }

        private void BeginParentMotion()
        {
            TableLayoutPanel stack = Parent as TableLayoutPanel;
            if (stack == null || stack.ColumnCount != 1 || !stack.AutoSize || stack.Dock != DockStyle.Top) return;
            motionParent = stack;
            initialParentHeight = stack.Height; initialSectionHeight = Height;
            siblingBounds.Clear();
            int row = stack.GetPositionFromControl(this).Row;
            foreach (Control sibling in stack.Controls)
                if (sibling != this && sibling.Visible && stack.GetPositionFromControl(sibling).Row > row) siblingBounds.Add(sibling, sibling.Bounds);
            stack.SuspendLayout();
            stack.AutoSize = false;
        }

        private void EndParentMotion()
        {
            if (motionParent == null) return;
            TableLayoutPanel stack = motionParent; motionParent = null;
            siblingBounds.Clear();
            if (stack.IsDisposed) return;
            stack.AutoSize = true;
            stack.ResumeLayout(true);
        }

        private void FinishReveal()
        {
            animation.Stop();
            motion.Stop();
            reveal = expanded ? 1f : 0f;
            header.Reveal = reveal;
            SetRevealHeight(expanded ? fullHeight : 0);
            viewport.ClearSnapshot();
            if (contentSuspended)
            {
                contentSuspended = false;
                viewport.ResumeLayout(false); Content.ResumeLayout(false);
            }
            Content.Visible = expanded;
            viewport.Visible = expanded;
            EndParentMotion();
            if (expanded)
            {
                // A scrollbar or resize may have changed width during motion.
                // Re-measure once after the native controls become visible.
                MeasureContent();
                SetRevealHeight(fullHeight);
            }
            animating = false;
        }

        private void AnimationChanged(object sender, EventArgs e)
        {
            if (animating && !AeroTheme.CanAnimate(this)) FinishReveal();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            if (animating && !Visible) FinishReveal();
            QueuePreparation();
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            QueuePreparation();
        }

        private void QueuePreparation()
        {
            if (prepared || preparationQueued || !IsHandleCreated || !Visible || Content == null) return;
            preparationQueued = true;
            BeginInvoke((Action)delegate
            {
                preparationQueued = false;
                if (IsDisposed || Content == null || !Visible || animating) return;
                prepared = true;
                // Create native handles once while idle, before the first click.
                // The eventual snapshot still captures the current field values.
                layingOut = true;
                try { PrepareHandles(Content); }
                finally { layingOut = false; }
                MeasureContent();
            });
        }

        private static void PrepareHandles(Control control)
        {
            IntPtr handle = control.Handle;
            foreach (Control child in control.Controls) PrepareHandles(child);
        }

        private void LanguageChanged(object sender, EventArgs e)
        {
            UpdateHint();
            // Never keep a bitmap with a previous language or stale field data.
            if (animating) FinishReveal();
            MeasureContent();
            if (expanded) SetRevealHeight(fullHeight);
        }
        private void UpdateHint()
        {
            string action = I18n.T(expanded ? "Bereich einklappen" : "Bereich ausklappen");
            header.AccessibleDescription = action;
            hint.SetToolTip(header, action);
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            GlassPainter.DrawSurface(e.Graphics, ClientRectangle);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                animation.Stop(); animation.Tick -= AnimateReveal; animation.Dispose();
                EndParentMotion();
                I18n.Changed -= LanguageChanged;
                AeroTheme.AnimationChanged -= AnimationChanged;
                if (Content != null) Content.Layout -= ContentLayout;
                hint.Dispose();
            }
            base.Dispose(disposing);
        }

        private sealed class RevealPanel : Panel
        {
            private Bitmap snapshot;
            internal bool HasSnapshot { get { return snapshot != null; } }
            internal RevealPanel()
            {
                SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            }
            internal bool CaptureContent(Control content, Size size)
            {
                ClearSnapshot();
                if (size.Width < 1 || size.Height < 1 || size.Width > 16384 || size.Height > 16384 || (long)size.Width * size.Height > 16000000) return false;
                GlassContentPanel glassContent = content as GlassContentPanel;
                Bitmap backdrop = null;
                try
                {
                    CollapsibleSection owner = Parent as CollapsibleSection;
                    if (glassContent != null && owner != null)
                    {
                        // Transparent native controls otherwise ask their parent
                        // to paint a still-collapsed card into the full snapshot.
                        // Supply the exact final glass surface at fixed coordinates.
                        backdrop = new Bitmap(size.Width, size.Height);
                        using (Graphics graphics = Graphics.FromImage(backdrop))
                            GlassPainter.DrawSurface(graphics, new Rectangle(-owner.Padding.Left, -owner.Padding.Top - owner.header.Height, owner.ClientSize.Width, size.Height + owner.Padding.Vertical + owner.header.Height));
                        glassContent.CaptureBackdrop = backdrop;
                    }
                    snapshot = new Bitmap(size.Width, size.Height);
                    content.DrawToBitmap(snapshot, new Rectangle(Point.Empty, size));
                    return true;
                }
                catch (ArgumentException) { ClearSnapshot(); return false; }
                catch (System.Runtime.InteropServices.ExternalException) { ClearSnapshot(); return false; }
                finally
                {
                    if (glassContent != null) glassContent.CaptureBackdrop = null;
                    if (backdrop != null) backdrop.Dispose();
                }
            }
            internal void ClearSnapshot()
            {
                if (snapshot == null) return;
                snapshot.Dispose(); snapshot = null;
                Invalidate();
            }
            protected override void OnPaint(PaintEventArgs e)
            {
                base.OnPaint(e);
                if (snapshot != null) e.Graphics.DrawImageUnscaled(snapshot, Point.Empty);
            }
            protected override void Dispose(bool disposing)
            {
                if (disposing) ClearSnapshot();
                base.Dispose(disposing);
            }
        }

        private sealed class GlassContentPanel : TableLayoutPanel
        {
            internal Bitmap CaptureBackdrop { get; set; }
            internal GlassContentPanel()
            {
                SetStyle(ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.SupportsTransparentBackColor, true);
            }
            protected override void OnPaintBackground(PaintEventArgs e)
            {
                if (CaptureBackdrop == null) base.OnPaintBackground(e);
                else e.Graphics.DrawImageUnscaled(CaptureBackdrop, Point.Empty);
            }
        }

        private sealed class SectionHeaderButton : Button
        {
            private readonly Timer glowTimer = new Timer { Interval = 16 };
            private readonly Stopwatch glowMotion = new Stopwatch();
            private bool hover;
            private float glow, reveal, fromGlow, glowTarget;
            internal float Reveal { get { return reveal; } set { reveal = value; Invalidate(new Rectangle(0, 0, 22, Height)); } }
            internal SectionHeaderButton()
            {
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
                SetStyle(ControlStyles.Opaque, false);
                FlatStyle = FlatStyle.Flat;
                FlatAppearance.BorderSize = 0;
                UseVisualStyleBackColor = false;
                BackColor = Color.Transparent;
                ForeColor = AeroTheme.Ink;
                Font = new Font("Segoe UI", 12, FontStyle.Bold);
                TextAlign = ContentAlignment.MiddleLeft;
                Cursor = Cursors.Hand;
                UseMnemonic = false;
                // These setters can restore ButtonBase's opaque style.
                SetStyle(ControlStyles.Opaque, false);
                glowTimer.Tick += AnimateGlow;
                AeroTheme.AnimationChanged += AnimationChanged;
            }
            private void UpdateGlow()
            {
                glowTarget = hover ? 1f : 0f;
                if (!AeroTheme.CanAnimate(this)) { glowTimer.Stop(); glowMotion.Stop(); glow = glowTarget; Invalidate(); }
                else if (Math.Abs(glowTarget - glow) > .001f) { fromGlow = glow; glowMotion.Restart(); glowTimer.Start(); }
                else glowTimer.Stop();
            }
            private void AnimateGlow(object sender, EventArgs e)
            {
                if (!AeroTheme.CanAnimate(this)) { UpdateGlow(); return; }
                float time = Math.Min(1f, (float)glowMotion.Elapsed.TotalMilliseconds / 180f);
                float ease = 1f - (float)Math.Pow(1f - time, 3);
                glow = fromGlow + (glowTarget - fromGlow) * ease;
                if (time >= 1f) { glow = glowTarget; glowTimer.Stop(); glowMotion.Stop(); }
                Invalidate();
            }
            private void AnimationChanged(object sender, EventArgs e) { UpdateGlow(); }
            protected override void OnMouseEnter(EventArgs e) { hover = true; UpdateGlow(); base.OnMouseEnter(e); }
            protected override void OnMouseLeave(EventArgs e) { hover = false; UpdateGlow(); base.OnMouseLeave(e); }
            protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); if (!Visible) glowTimer.Stop(); }
            protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
            protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
            protected override bool ProcessDialogKey(Keys keyData)
            {
                if (keyData == Keys.Enter) { PerformClick(); return true; }
                return base.ProcessDialogKey(keyData);
            }
            protected override void OnPaint(PaintEventArgs e)
            {
                Graphics graphics = e.Graphics;
                if (Width < 4 || Height < 4) return;
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                if (glow > .01f && !SystemInformation.HighContrast)
                {
                    RectangleF area = new RectangleF(.5f, .5f, Width - 1, Height - 1);
                    using (GraphicsPath rounded = AeroTheme.Round(area, 5))
                    {
                        using (LinearGradientBrush light = new LinearGradientBrush(area, Color.FromArgb((int)(glow * 85), 255, 255, 255), Color.FromArgb((int)(glow * 50), 43, 171, 238), 90f)) graphics.FillPath(light, rounded);
                        using (Pen edge = new Pen(Color.FromArgb((int)(glow * 95), 93, 177, 223))) graphics.DrawPath(edge, rounded);
                        using (Pen shine = new Pen(Color.FromArgb((int)(glow * 155), Color.White))) graphics.DrawLine(shine, 6, 1, Width - 7, 1);
                    }
                }
                Color ink = Enabled ? (SystemInformation.HighContrast ? SystemColors.WindowText : AeroTheme.Ink) : SystemColors.GrayText;
                float middle = Height / 2f;
                double angle = reveal * Math.PI / 2;
                PointF[] arrow = new[] { Rotate(7, middle, -3, -5, angle), Rotate(7, middle, -3, 5, angle), Rotate(7, middle, 3, 0, angle) };
                using (SolidBrush brush = new SolidBrush(ink)) graphics.FillPolygon(brush, arrow);
                TextRenderer.DrawText(graphics, Text, Font, new Rectangle(25, 0, Math.Max(1, Width - 28), Height), ink,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.PreserveGraphicsClipping);
                if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(graphics, new Rectangle(1, 1, Width - 3, Height - 3), ink, SystemInformation.HighContrast ? SystemColors.Window : Color.White);
            }
            private static PointF Rotate(float x, float y, float dx, float dy, double angle)
            {
                return new PointF(x + (float)(dx * Math.Cos(angle) - dy * Math.Sin(angle)), y + (float)(dx * Math.Sin(angle) + dy * Math.Cos(angle)));
            }
            protected override void Dispose(bool disposing)
            {
                if (disposing) { glowTimer.Stop(); glowTimer.Tick -= AnimateGlow; glowTimer.Dispose(); AeroTheme.AnimationChanged -= AnimationChanged; }
                base.Dispose(disposing);
            }
        }
    }
}

