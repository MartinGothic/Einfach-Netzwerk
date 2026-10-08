using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal sealed class AeroHeader : Panel
    {
        private readonly Timer animation = new Timer { Interval = 33 };
        // Moving light is confined to the illustration, before the title at
        // x155. Transparent preference controls and their text remain static.
        private static readonly Rectangle IllustrationBounds = new Rectangle(10, 4, 137, 105);
        private Form subscribedForm;
        private Bitmap staticGlass;
        private double time;
        private string heading = "Einfach Netzwerk";
        private string subtitle = "Ordner und Festplatten teilen. Schritt für Schritt.";
        internal string Heading
        {
            get { return heading; }
            set { if (heading == value) return; heading = value; ResetGlass(); }
        }
        internal string Subtitle
        {
            get { return subtitle; }
            set { if (subtitle == value) return; subtitle = value; ResetGlass(); }
        }

        internal AeroHeader()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            animation.Tick += Animate;
            AeroTheme.AnimationChanged += SettingChanged;
            I18n.Changed += LanguageChanged;
        }

        private void Animate(object sender, EventArgs e)
        {
            if (!AeroTheme.CanAnimate(this)) { animation.Stop(); return; }
            time += .033;
            Invalidate(IllustrationBounds, false);
        }

        private void AttachForm()
        {
            Form form = FindForm();
            if (form == subscribedForm) return;
            if (subscribedForm != null)
            {
                subscribedForm.Resize -= ParentStateChanged;
                subscribedForm.Activated -= ParentStateChanged;
                subscribedForm.Deactivate -= ParentStateChanged;
                subscribedForm.VisibleChanged -= ParentStateChanged;
                subscribedForm.EnabledChanged -= ParentStateChanged;
            }
            subscribedForm = form;
            if (subscribedForm != null)
            {
                subscribedForm.Resize += ParentStateChanged;
                subscribedForm.Activated += ParentStateChanged;
                subscribedForm.Deactivate += ParentStateChanged;
                subscribedForm.VisibleChanged += ParentStateChanged;
                subscribedForm.EnabledChanged += ParentStateChanged;
            }
        }

        protected override void OnParentChanged(EventArgs e) { base.OnParentChanged(e); AttachForm(); UpdateTimer(); }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); AttachForm(); UpdateTimer(); }
        protected override void OnHandleDestroyed(EventArgs e) { animation.Stop(); base.OnHandleDestroyed(e); }
        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); UpdateTimer(); }
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); ResetGlass(); }
        private void ParentStateChanged(object sender, EventArgs e) { UpdateTimer(); }
        private void SettingChanged(object sender, EventArgs e) { UpdateTimer(); ResetGlass(); }
        private void LanguageChanged(object sender, EventArgs e) { ResetGlass(); }
        private void UpdateTimer() { if (AeroTheme.CanAnimate(this)) animation.Start(); else animation.Stop(); }

        private void ResetGlass()
        {
            if (staticGlass != null) { staticGlass.Dispose(); staticGlass = null; }
            Invalidate();
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            // Cached opaque glass also serves transparent children's requests
            // for the parent background; no text layout occurs on a timer tick.
            EnsureGlass();
            if (staticGlass != null) e.Graphics.DrawImageUnscaled(staticGlass, 0, 0);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            EnsureGlass();
            if (staticGlass == null) return;
            e.Graphics.DrawImageUnscaled(staticGlass, 0, 0);
            if (!SystemInformation.HighContrast && e.ClipRectangle.IntersectsWith(IllustrationBounds))
            {
                GraphicsState state = e.Graphics.Save();
                e.Graphics.SetClip(IllustrationBounds, CombineMode.Intersect);
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                DrawMovingLight(e.Graphics, AeroTheme.Animations ? time : 0);
                e.Graphics.Restore(state);
            }
            base.OnPaint(e);
        }

        private void EnsureGlass()
        {
            if (Width < 5 || Height < 5) return;
            if (staticGlass != null && staticGlass.Width == Width && staticGlass.Height == Height) return;
            if (staticGlass != null) staticGlass.Dispose();
            staticGlass = new Bitmap(Width, Height, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
            using (Graphics graphics = Graphics.FromImage(staticGlass))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
                DrawGlassBackground(graphics);
                DrawNetwork(graphics);
                DrawTitle(graphics);
            }
        }

        private void DrawGlassBackground(Graphics graphics)
        {
            if (SystemInformation.HighContrast) { graphics.Clear(SystemColors.Window); return; }
            using (LinearGradientBrush sky = new LinearGradientBrush(ClientRectangle, Color.FromArgb(230, 251, 255), Color.FromArgb(20, 132, 197), 90f))
            {
                sky.InterpolationColors = new ColorBlend
                {
                    Colors = new[] { Color.FromArgb(222, 248, 255), Color.FromArgb(151, 220, 249), Color.FromArgb(91, 184, 224), Color.FromArgb(29, 144, 199) },
                    Positions = new[] { 0f, .42f, .63f, 1f }
                };
                graphics.FillRectangle(sky, ClientRectangle);
            }
            using (SolidBrush glass = new SolidBrush(Color.FromArgb(123, Color.White))) graphics.FillEllipse(glass, -150, -152, Width + 230, Height + 193);
            using (SolidBrush lens = new SolidBrush(Color.FromArgb(53, 232, 255, 255)))
            {
                graphics.FillEllipse(lens, Width / 3, -197, Width, Height + 216);
                graphics.FillEllipse(lens, -165, Height - 35, Width + 330, Height + 77);
            }
            using (GraphicsPath reflection = new GraphicsPath())
            {
                reflection.AddPolygon(new[] { new Point(Width * 2 / 3, -1), new Point(Width * 3 / 4, -1), new Point(Width / 3, Height), new Point(Width / 4, Height) });
                using (SolidBrush beam = new SolidBrush(Color.FromArgb(26, Color.White))) graphics.FillPath(beam, reflection);
            }
            using (Pen ribbon = new Pen(Color.FromArgb(110, Color.White), 2f)) graphics.DrawBezier(ribbon, -20, Height - 22, Width / 5, Height + 24, Width / 2, Height - 40, Width + 15, 9);
            using (Pen ribbon = new Pen(Color.FromArgb(65, 215, 255, 255), 3f)) graphics.DrawBezier(ribbon, -20, Height - 5, Width / 3, Height - 10, Width / 2, Height + 22, Width + 15, Height - 27);
            using (Pen edge = new Pen(Color.FromArgb(120, Color.White))) graphics.DrawLine(edge, 0, 0, Width, 0);
            using (Pen edge = new Pen(Color.FromArgb(24, 114, 168))) graphics.DrawLine(edge, 0, Height - 1, Width, Height - 1);
            using (Pen light = new Pen(Color.FromArgb(178, 196, 242, 255))) graphics.DrawLine(light, 0, Height - 2, Width, Height - 2);
        }

        private void DrawTitle(Graphics graphics)
        {
            const int left = 155;
            using (Font titleFont = new Font("Segoe UI", 25, FontStyle.Regular))
            {
                if (!SystemInformation.HighContrast)
                {
                    using (SolidBrush glow = new SolidBrush(Color.FromArgb(130, Color.White)))
                    {
                        graphics.DrawString(I18n.T(Heading), titleFont, glow, left - 1, 19);
                        graphics.DrawString(I18n.T(Heading), titleFont, glow, left + 1, 20);
                        graphics.DrawString(I18n.T(Heading), titleFont, glow, left, 21);
                    }
                }
                using (SolidBrush ink = new SolidBrush(SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(10, 51, 86))) graphics.DrawString(I18n.T(Heading), titleFont, ink, left, 19);
            }
            using (Font subtitleFont = new Font("Segoe UI", 10))
            using (SolidBrush ink = new SolidBrush(SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(19, 66, 100))) graphics.DrawString(I18n.T(Subtitle), subtitleFont, ink, new RectangleF(left + 2, 64, Math.Max(80, Width - left - 240), 41));
        }

        private void DrawNetwork(Graphics graphics)
        {
            GraphicsState state = graphics.Save();
            graphics.TranslateTransform(17, 13);
            if (SystemInformation.HighContrast)
            {
                using (Pen outline = new Pen(SystemColors.WindowText, 2))
                {
                    graphics.DrawRectangle(outline, 10, 2, 73, 45);
                    graphics.DrawRectangle(outline, 87, 24, 31, 57);
                    graphics.DrawRectangle(outline, 0, 74, 49, 18);
                    graphics.DrawLine(outline, 47, 48, 47, 65);
                    graphics.DrawLine(outline, 23, 65, 96, 65);
                    graphics.DrawLine(outline, 23, 65, 23, 74);
                }
                graphics.Restore(state);
                return;
            }
            using (SolidBrush aura = new SolidBrush(Color.FromArgb(29, 12, 95, 153))) graphics.FillEllipse(aura, -4, 77, 128, 18);
            using (Pen shadow = new Pen(Color.FromArgb(65, 17, 95, 150), 5)) DrawWires(graphics, shadow);
            using (Pen wire = new Pen(Color.FromArgb(212, 237, 255, 255), 2)) DrawWires(graphics, wire);
            AeroTheme.FillGlass(graphics, new Rectangle(10, 2, 73, 45), true, .65f);
            Rectangle screenArea = new Rectangle(17, 9, 58, 30);
            using (GraphicsPath screenShape = AeroTheme.Round(screenArea, 2))
            using (LinearGradientBrush screen = new LinearGradientBrush(screenArea, Color.FromArgb(3, 73, 124), Color.FromArgb(76, 222, 255), 45f)) graphics.FillPath(screen, screenShape);
            using (SolidBrush reflection = new SolidBrush(Color.FromArgb(58, Color.White))) graphics.FillPolygon(reflection, new[] { new Point(18, 10), new Point(54, 10), new Point(38, 38), new Point(18, 38) });
            using (Pen shine = new Pen(Color.FromArgb(224, Color.White))) graphics.DrawLine(shine, 19, 11, 72, 11);
            AeroTheme.FillGlass(graphics, new Rectangle(0, 74, 49, 18), false, .65f);
            AeroTheme.FillGlass(graphics, new Rectangle(87, 24, 31, 57), false, .65f);
            Rectangle phoneArea = new Rectangle(93, 30, 18, 40);
            using (LinearGradientBrush screen = new LinearGradientBrush(phoneArea, Color.FromArgb(12, 101, 165), Color.FromArgb(77, 223, 248), 90f)) graphics.FillRectangle(screen, phoneArea);
            using (SolidBrush reflection = new SolidBrush(Color.FromArgb(87, Color.White))) graphics.FillPolygon(reflection, new[] { new Point(93, 30), new Point(110, 30), new Point(95, 58), new Point(93, 58) });
            using (SolidBrush light = new SolidBrush(Color.FromArgb(140, 54, 189, 228))) for (int i = 0; i < 3; i++) graphics.FillEllipse(light, 8 + i * 8, 80, 3, 3);
            using (SolidBrush light = new SolidBrush(Color.FromArgb(188, Color.White))) graphics.FillEllipse(light, 100, 74, 3, 3);
            graphics.Restore(state);
        }

        private static void DrawWires(Graphics graphics, Pen wire)
        {
            graphics.DrawLine(wire, 47, 44, 47, 65);
            graphics.DrawLine(wire, 23, 65, 96, 65);
            graphics.DrawLine(wire, 23, 65, 23, 75);
            graphics.DrawLine(wire, 96, 65, 96, 47);
        }

        private void DrawMovingLight(Graphics graphics, double clock)
        {
            GraphicsState state = graphics.Save();
            graphics.TranslateTransform(17, 13);
            for (int i = 0; i < 3; i++)
            {
                double distance = ((clock * .28 + i / 3.0) % 1.0) * 94;
                float x = distance < 21 ? 47 : 47 + (float)(distance - 21) * (i == 1 ? -24f / 73f : 49f / 73f);
                float y = distance < 21 ? 44 + (float)distance : 65;
                DrawGlow(graphics, x, y, 7, .68f);
            }
            DrawGlow(graphics, 47, 65, 10, .55f + .3f * (float)Math.Sin(clock * 2.2));
            float shimmer = (float)((clock * .16) % 1.0);
            GraphicsState clipped = graphics.Save();
            graphics.SetClip(new Rectangle(17, 9, 58, 30), CombineMode.Intersect);
            float glint = 10 + shimmer * 91;
            using (LinearGradientBrush reflection = new LinearGradientBrush(new RectangleF(glint - 12, 9, 24, 31), Color.FromArgb(0, Color.White), Color.FromArgb(0, Color.White), 0f))
            {
                reflection.InterpolationColors = new ColorBlend { Colors = new[] { Color.FromArgb(0, Color.White), Color.FromArgb(116, Color.White), Color.FromArgb(0, Color.White) }, Positions = new[] { 0f, .5f, 1f } };
                graphics.FillPolygon(reflection, new[] { new PointF(glint - 11, 9), new PointF(glint + 8, 9), new PointF(glint - 6, 40), new PointF(glint - 25, 40) });
            }
            graphics.Restore(clipped);
            float sparkle = .35f + .28f * (float)Math.Sin(clock * 2.8 + 1.4);
            DrawSparkle(graphics, 79, 6, sparkle);
            DrawSparkle(graphics, 114, 29, 1f - sparkle);
            graphics.Restore(state);
        }

        private static void DrawGlow(Graphics graphics, float x, float y, float radius, float strength)
        {
            using (GraphicsPath halo = new GraphicsPath())
            {
                halo.AddEllipse(x - radius, y - radius, radius * 2, radius * 2);
                using (PathGradientBrush light = new PathGradientBrush(halo))
                {
                    light.CenterColor = Color.FromArgb((int)(180 * strength), 210, 255, 250);
                    light.SurroundColors = new[] { Color.FromArgb(0, 153, 247, 255) };
                    graphics.FillPath(light, halo);
                }
            }
            using (SolidBrush core = new SolidBrush(Color.FromArgb((int)(226 * strength), Color.White))) graphics.FillEllipse(core, x - 1.5f, y - 1.5f, 3, 3);
        }

        private static void DrawSparkle(Graphics graphics, float x, float y, float strength)
        {
            DrawGlow(graphics, x, y, 6, strength);
            using (Pen ray = new Pen(Color.FromArgb((int)(158 * strength), Color.White)))
            {
                graphics.DrawLine(ray, x - 4, y, x + 4, y);
                graphics.DrawLine(ray, x, y - 4, x, y + 4);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                animation.Dispose();
                AeroTheme.AnimationChanged -= SettingChanged;
                I18n.Changed -= LanguageChanged;
                if (staticGlass != null) { staticGlass.Dispose(); staticGlass = null; }
                if (subscribedForm != null)
                {
                    subscribedForm.Resize -= ParentStateChanged;
                    subscribedForm.Activated -= ParentStateChanged;
                    subscribedForm.Deactivate -= ParentStateChanged;
                    subscribedForm.VisibleChanged -= ParentStateChanged;
                    subscribedForm.EnabledChanged -= ParentStateChanged;
                    subscribedForm = null;
                }
            }
            base.Dispose(disposing);
        }
    }
}
