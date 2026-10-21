using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    public class AeroGlassForm : Form
    {
        private Bitmap glassBackdrop;
        public AeroGlassForm()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            if (ClientSize.Width < 1 || ClientSize.Height < 1) return;
            if (SystemInformation.HighContrast) { e.Graphics.Clear(SystemColors.Window); return; }
            if (glassBackdrop == null || glassBackdrop.Size != ClientSize)
            {
                ReleaseBackdrop();
                glassBackdrop = new Bitmap(ClientSize.Width, ClientSize.Height);
                using (Graphics graphics = Graphics.FromImage(glassBackdrop)) DrawBackdrop(graphics, new Rectangle(Point.Empty, ClientSize));
            }
            // Transparent child controls reuse a static raster. No moving light is
            // painted behind text, and hover paints never rebuild the backdrop.
            e.Graphics.DrawImageUnscaled(glassBackdrop, 0, 0);
        }
        private static void DrawBackdrop(Graphics graphics, Rectangle area)
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (LinearGradientBrush baseGlass = new LinearGradientBrush(area, Color.FromArgb(162, 221, 247), Color.FromArgb(199, 239, 252), 40f))
            {
                baseGlass.InterpolationColors = new ColorBlend { Colors = new[] { Color.FromArgb(122, 195, 232), Color.FromArgb(219, 249, 255), Color.FromArgb(160, 220, 246), Color.FromArgb(194, 238, 253) }, Positions = new[] { 0f, .38f, .72f, 1f } };
                graphics.FillRectangle(baseGlass, area);
            }
            using (GraphicsPath ambient = new GraphicsPath())
            {
                ambient.AddEllipse(-area.Width / 3, -area.Height / 3, area.Width, area.Height);
                using (PathGradientBrush light = new PathGradientBrush(ambient))
                {
                    light.CenterColor = Color.FromArgb(150, Color.White);
                    light.SurroundColors = new[] { Color.FromArgb(0, Color.White) };
                    graphics.FillPath(light, ambient);
                }
            }
            PointF[] beam = { new PointF(area.Width * .58f, 0), new PointF(area.Width * .81f, 0), new PointF(area.Width * .29f, area.Height), new PointF(area.Width * .05f, area.Height) };
            using (SolidBrush reflection = new SolidBrush(Color.FromArgb(24, Color.White))) graphics.FillPolygon(reflection, beam);
            using (Pen edge = new Pen(Color.FromArgb(65, Color.White), 2)) graphics.DrawLine(edge, area.Width * .58f, 0, area.Width * .05f, area.Height);
            using (Pen curve = new Pen(Color.FromArgb(45, Color.White), 3)) graphics.DrawBezier(curve, 0, area.Height * .62f, area.Width * .36f, area.Height * .33f, area.Width * .65f, area.Height * .97f, area.Width, area.Height * .49f);
            using (Pen inner = new Pen(Color.FromArgb(155, Color.White))) graphics.DrawRectangle(inner, 0, 0, Math.Max(0, area.Width - 1), Math.Max(0, area.Height - 1));
        }
        protected override void OnShown(EventArgs e) { AeroTheme.StyleGlassChildren(this); base.OnShown(e); }
        protected override void OnSystemColorsChanged(EventArgs e) { ReleaseBackdrop(); base.OnSystemColorsChanged(e); Invalidate(true); }
        protected override void OnSizeChanged(EventArgs e) { ReleaseBackdrop(); base.OnSizeChanged(e); }
        private void ReleaseBackdrop() { if (glassBackdrop != null) { glassBackdrop.Dispose(); glassBackdrop = null; } }
        protected override void Dispose(bool disposing) { if (disposing) ReleaseBackdrop(); base.Dispose(disposing); }
    }
}
