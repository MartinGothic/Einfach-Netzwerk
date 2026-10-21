using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal sealed class AeroButton : Button
    {
        private readonly Timer animation = new Timer { Interval = 25 };
        private readonly Stopwatch animationWatch = new Stopwatch();
        private float glow;
        private float pressDepth;
        private float sheen = 1;
        private float ripple = 1;
        private PointF pointer;
        private PointF rippleOrigin;
        private bool hover;
        private bool mousePressed;
        private bool keyboardPressed;
        private bool defaultButton;
        private bool primary;
        private Form observedForm;
        private bool effectsDisposed;

        internal bool Primary
        {
            get { return primary; }
            set { if (primary != value) { primary = value; Invalidate(); } }
        }

        internal AeroButton()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            ApplyContrastStyle();
            Cursor = Cursors.Hand;
            Font = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            animation.Tick += AnimationTick;
            AeroTheme.AnimationChanged += AnimationSettingChanged;
        }

        private bool Pressed { get { return Enabled && (keyboardPressed || (mousePressed && hover)); } }
        private bool CanAnimate { get { return !effectsDisposed && IsHandleCreated && Enabled && AeroTheme.CanAnimate(this); } }
        private bool NeedsFrames { get { return Math.Abs(glow - (hover ? 1 : 0)) > .008f || Math.Abs(pressDepth - (Pressed ? 1 : 0)) > .008f || sheen < 1 || ripple < 1; } }

        private void AnimationTick(object sender, EventArgs e)
        {
            if (!CanAnimate) { StopAnimation(true); return; }
            float seconds = Math.Min(.08f, Math.Max(.001f, (float)animationWatch.Elapsed.TotalSeconds));
            animationWatch.Restart();
            float factor = 1 - (float)Math.Exp(-seconds * 15);
            float targetGlow = hover ? 1 : 0;
            float targetPress = Pressed ? 1 : 0;
            glow += (targetGlow - glow) * factor;
            pressDepth += (targetPress - pressDepth) * factor;
            if (Math.Abs(targetGlow - glow) < .008f) glow = targetGlow;
            if (Math.Abs(targetPress - pressDepth) < .008f) pressDepth = targetPress;
            sheen = Math.Min(1, sheen + seconds / .82f);
            ripple = Math.Min(1, ripple + seconds / .64f);
            // Every effect stays in this button's double buffer. Text is painted once,
            // at a fixed position, after all moving light layers have been composited.
            Invalidate();
            if (glow == targetGlow && pressDepth == targetPress && sheen >= 1 && ripple >= 1)
            {
                animation.Stop();
                animationWatch.Reset();
            }
        }

        private void Animate()
        {
            if (effectsDisposed) return;
            ObserveForm();
            if (CanAnimate && NeedsFrames)
            {
                if (!animation.Enabled) { animationWatch.Restart(); animation.Start(); }
            }
            else StopAnimation(!CanAnimate);
            Invalidate();
        }

        private void StopAnimation(bool settle)
        {
            animation.Stop();
            animationWatch.Reset();
            if (!settle) return;
            glow = hover && Enabled ? 1 : 0;
            pressDepth = Pressed ? 1 : 0;
            sheen = 1;
            ripple = 1;
        }

        private void ObserveForm()
        {
            Form next = FindForm();
            if (next == observedForm) return;
            if (observedForm != null)
            {
                observedForm.Resize -= OwnerVisibilityChanged;
                observedForm.VisibleChanged -= OwnerVisibilityChanged;
                observedForm.EnabledChanged -= OwnerVisibilityChanged;
            }
            observedForm = next;
            if (observedForm != null)
            {
                observedForm.Resize += OwnerVisibilityChanged;
                observedForm.VisibleChanged += OwnerVisibilityChanged;
                observedForm.EnabledChanged += OwnerVisibilityChanged;
            }
        }

        private void OwnerVisibilityChanged(object sender, EventArgs e)
        {
            if (!CanAnimate) { StopAnimation(true); return; }
            if (NeedsFrames) Animate();
        }

        private void AnimationSettingChanged(object sender, EventArgs e) { Animate(); }
        private void ApplyContrastStyle()
        {
            bool contrast = SystemInformation.HighContrast;
            FlatStyle = contrast ? FlatStyle.Standard : FlatStyle.Flat;
            FlatAppearance.BorderSize = contrast ? 1 : 0;
            UseVisualStyleBackColor = contrast;
            BackColor = contrast ? SystemColors.Control : Color.Transparent;
            if (contrast) ForeColor = SystemColors.ControlText;
            // Keep this after all ButtonBase style/color setters. Otherwise native
            // WM_PAINT skips the parent background and exposes black square corners.
            SetStyle(ControlStyles.Opaque, false);
        }

        protected override void OnParentChanged(EventArgs e) { base.OnParentChanged(e); if (effectsDisposed) return; ObserveForm(); if (!CanAnimate) StopAnimation(true); }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); ObserveForm(); }
        protected override void OnHandleDestroyed(EventArgs e) { if (!effectsDisposed) StopAnimation(true); base.OnHandleDestroyed(e); }
        protected override void OnSystemColorsChanged(EventArgs e) { ApplyContrastStyle(); Animate(); base.OnSystemColorsChanged(e); }
        protected override void OnMouseEnter(EventArgs e)
        {
            hover = true;
            pointer = new PointF(Width / 2f, Height / 2f);
            if (CanAnimate) sheen = 0;
            Animate();
            base.OnMouseEnter(e);
        }
        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (hover && CanAnimate) { pointer = e.Location; Invalidate(); }
            base.OnMouseMove(e);
        }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Animate(); base.OnMouseLeave(e); }
        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); if (!effectsDisposed && !CanAnimate) StopAnimation(true); }
        protected override void OnEnabledChanged(EventArgs e)
        {
            if (!Enabled) { mousePressed = false; keyboardPressed = false; }
            Animate();
            base.OnEnabledChanged(e);
        }
        private void StartRipple(PointF origin)
        {
            rippleOrigin = origin;
            if (CanAnimate) ripple = 0;
            Animate();
        }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) { mousePressed = true; StartRipple(e.Location); }
            base.OnMouseDown(e);
        }
        protected override void OnMouseUp(MouseEventArgs e) { mousePressed = false; Animate(); base.OnMouseUp(e); }
        protected override void OnMouseCaptureChanged(EventArgs e) { if (!Capture) { mousePressed = false; Animate(); } base.OnMouseCaptureChanged(e); }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space && !e.Alt && !keyboardPressed)
            {
                keyboardPressed = true;
                StartRipple(new PointF(Width / 2f, Height / 2f));
            }
            base.OnKeyDown(e);
        }
        protected override void OnKeyUp(KeyEventArgs e) { if (e.KeyCode == Keys.Space) { keyboardPressed = false; Animate(); } base.OnKeyUp(e); }
        protected override void OnClick(EventArgs e)
        {
            if (CanAnimate)
            {
                sheen = 0;
                pressDepth = Math.Max(pressDepth, .65f);
                if (ripple >= 1) { ripple = 0; rippleOrigin = new PointF(Width / 2f, Height / 2f); }
                Animate();
            }
            base.OnClick(e);
        }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { keyboardPressed = false; Animate(); base.OnLostFocus(e); }
        public override void NotifyDefault(bool value) { defaultButton = value; base.NotifyDefault(value); Invalidate(); }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            if (SystemInformation.HighContrast) { base.OnPaintBackground(e); return; }
            if (Parent == null) { e.Graphics.Clear(SystemColors.Control); return; }
            GraphicsState state = e.Graphics.Save();
            try
            {
                e.Graphics.TranslateTransform(-Left, -Top);
                Rectangle clip = e.ClipRectangle;
                clip.Offset(Left, Top);
                using (PaintEventArgs parentPaint = new PaintEventArgs(e.Graphics, clip))
                {
                    InvokePaintBackground(Parent, parentPaint);
                    InvokePaint(Parent, parentPaint);
                }
            }
            finally { e.Graphics.Restore(state); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            if (SystemInformation.HighContrast) { base.OnPaint(e); return; }
            if (Width < 4 || Height < 4) return;
            DrawAeroSurface(e.Graphics);
            TextFormatFlags flags = TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine | TextFormatFlags.PreserveGraphicsClipping;
            if (!ShowKeyboardCues) flags |= TextFormatFlags.HidePrefix;
            TextRenderer.DrawText(e.Graphics, Text, Font, new Rectangle(7, 2, Math.Max(1, Width - 14), Math.Max(1, Height - 4)), Enabled ? AeroTheme.Ink : SystemColors.GrayText, flags);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(7, 6, Math.Max(1, Width - 14), Math.Max(1, Height - 12)), AeroTheme.Ink, Primary ? Color.FromArgb(112, 183, 221) : Color.FromArgb(231, 244, 251));
        }

        private static Color Mix(Color start, Color end, float amount)
        {
            amount = Math.Max(0, Math.Min(1, amount));
            return Color.FromArgb((int)(start.A + (end.A - start.A) * amount), (int)(start.R + (end.R - start.R) * amount), (int)(start.G + (end.G - start.G) * amount), (int)(start.B + (end.B - start.B) * amount));
        }

        private void DrawAeroSurface(Graphics graphics)
        {
            float highlight = Enabled ? glow : 0;
            bool blue = Primary && Enabled;
            RectangleF area = new RectangleF(1.5f, 1.5f, Width - 4, Height - 4);
            float radius = Math.Min(5, Math.Min(area.Width, area.Height) / 2);
            Color top = !Enabled ? Color.FromArgb(244, 247, 248) : blue ? Color.FromArgb(226, 249, 255) : Color.FromArgb(255, 255, 255);
            Color middle = !Enabled ? Color.FromArgb(233, 237, 239) : blue ? Color.FromArgb(163, 224, 251) : Color.FromArgb(239, 251, 255);
            Color lower = !Enabled ? Color.FromArgb(228, 233, 236) : blue ? Color.FromArgb(115, 199, 237) : Color.FromArgb(207, 235, 249);
            Color bottom = !Enabled ? Color.FromArgb(217, 225, 231) : blue ? Color.FromArgb(40, 137, 196) : Color.FromArgb(165, 208, 234);
            Color edge = !Enabled ? Color.FromArgb(175, 189, 199) : blue || defaultButton ? Color.FromArgb(29, 108, 158) : Color.FromArgb(100, 150, 182);
            if (Enabled && pressDepth > 0)
            {
                top = Mix(top, blue ? Color.FromArgb(90, 175, 218) : Color.FromArgb(168, 208, 232), pressDepth);
                middle = Mix(middle, blue ? Color.FromArgb(120, 203, 239) : Color.FromArgb(193, 225, 243), pressDepth);
                lower = Mix(lower, blue ? Color.FromArgb(88, 179, 225) : Color.FromArgb(173, 211, 235), pressDepth);
                bottom = Mix(bottom, blue ? Color.FromArgb(62, 150, 200) : Color.FromArgb(215, 237, 249), pressDepth);
            }
            GraphicsState state = graphics.Save();
            try
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (GraphicsPath rounded = AeroTheme.Round(area, radius))
                {
                    using (LinearGradientBrush fill = new LinearGradientBrush(area, top, bottom, 90f))
                    {
                        fill.InterpolationColors = new ColorBlend { Colors = new[] { top, middle, lower, bottom }, Positions = new[] { 0f, .46f, .48f, 1f } };
                        graphics.FillPath(fill, rounded);
                    }
                    GraphicsState lights = graphics.Save();
                    try
                    {
                        graphics.SetClip(rounded, CombineMode.Intersect);
                        // The curved lower reflection and diagonal pane remain visible
                        // when animations are disabled: this is the Aero glass material.
                        using (GraphicsPath ellipse = new GraphicsPath())
                        {
                            ellipse.AddEllipse(area.X - area.Width * .15f, area.Bottom - area.Height * .42f, area.Width * 1.3f, area.Height * .9f);
                            using (PathGradientBrush reflection = new PathGradientBrush(ellipse))
                            {
                                reflection.CenterColor = Color.FromArgb(Enabled ? 75 : 22, 223, 251, 255);
                                reflection.SurroundColors = new[] { Color.FromArgb(0, 223, 251, 255) };
                                graphics.FillPath(reflection, ellipse);
                            }
                        }
                        using (SolidBrush diagonal = new SolidBrush(Color.FromArgb(Enabled ? 29 : 12, Color.White)))
                            graphics.FillPolygon(diagonal, new[] { new PointF(area.X + area.Width * .08f, area.Y), new PointF(area.X + area.Width * .28f, area.Y), new PointF(area.X + area.Width * .44f, area.Bottom), new PointF(area.X + area.Width * .24f, area.Bottom) });
                        if (highlight > .008f)
                        {
                            using (SolidBrush wash = new SolidBrush(Color.FromArgb((int)(highlight * 40), 41, 212, 255))) graphics.FillPath(wash, rounded);
                            float radiusX = Math.Min(area.Width, Math.Max(60, area.Height * 2.4f));
                            using (GraphicsPath lamp = new GraphicsPath())
                            {
                                lamp.AddEllipse(pointer.X - radiusX, pointer.Y - area.Height * 1.5f, radiusX * 2, area.Height * 3);
                                using (PathGradientBrush bloom = new PathGradientBrush(lamp))
                                {
                                    bloom.CenterPoint = pointer;
                                    bloom.CenterColor = Color.FromArgb((int)(highlight * 118), 231, 255, 255);
                                    bloom.SurroundColors = new[] { Color.FromArgb(0, 180, 249, 255) };
                                    graphics.FillPath(bloom, lamp);
                                }
                            }
                        }
                        if (CanAnimate && sheen < 1)
                        {
                            float width = Math.Max(32, area.Height * 1.4f);
                            float x = area.Left - width * 2 + (area.Width + width * 3) * sheen;
                            using (GraphicsPath streak = new GraphicsPath())
                            {
                                streak.AddPolygon(new[] { new PointF(x, area.Top), new PointF(x + width, area.Top), new PointF(x + width * 2, area.Bottom), new PointF(x + width, area.Bottom) });
                                using (LinearGradientBrush light = new LinearGradientBrush(new RectangleF(x, area.Top, width * 2, area.Height), Color.Transparent, Color.Transparent, 0f))
                                {
                                    light.InterpolationColors = new ColorBlend { Colors = new[] { Color.FromArgb(0, Color.White), Color.FromArgb(78, Color.White), Color.FromArgb(0, Color.White) }, Positions = new[] { 0f, .5f, 1f } };
                                    graphics.FillPath(light, streak);
                                }
                            }
                        }
                        if (CanAnimate && ripple < 1)
                        {
                            float reach = (float)Math.Sqrt(area.Width * area.Width + area.Height * area.Height) * (.08f + ripple * .9f);
                            using (Pen wave = new Pen(Color.FromArgb((int)((1 - ripple) * 95), 239, 255, 255), 2.1f))
                                graphics.DrawEllipse(wave, rippleOrigin.X - reach, rippleOrigin.Y - reach, reach * 2, reach * 2);
                        }
                    }
                    finally { graphics.Restore(lights); }
                    using (Pen border = new Pen(edge)) graphics.DrawPath(border, rounded);
                    RectangleF innerArea = new RectangleF(area.X + 1, area.Y + 1, area.Width - 2, area.Height - 2);
                    if (innerArea.Width > 0 && innerArea.Height > 0)
                    {
                        using (GraphicsPath inner = AeroTheme.Round(innerArea, Math.Max(1, radius - 1)))
                        using (Pen reflection = new Pen(Color.FromArgb((int)(225 - pressDepth * 115), Color.White))) graphics.DrawPath(reflection, inner);
                    }
                    if (highlight > .008f && Enabled)
                    {
                        using (Pen brightEdge = new Pen(Color.FromArgb((int)(highlight * 220), 0, 177, 239), 1.2f)) graphics.DrawPath(brightEdge, rounded);
                    }
                }
            }
            finally { graphics.Restore(state); }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                effectsDisposed = true;
                animation.Stop();
                animation.Tick -= AnimationTick;
                animation.Dispose();
                AeroTheme.AnimationChanged -= AnimationSettingChanged;
                if (observedForm != null)
                {
                    observedForm.Resize -= OwnerVisibilityChanged;
                    observedForm.VisibleChanged -= OwnerVisibilityChanged;
                    observedForm.EnabledChanged -= OwnerVisibilityChanged;
                    observedForm = null;
                }
            }
            base.Dispose(disposing);
        }
    }
}
