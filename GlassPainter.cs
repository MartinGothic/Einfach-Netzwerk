using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    // Static glass adds depth without repainting any child text on idle ticks.
    internal static class GlassPainter
    {
        internal static void DrawSurface(Graphics graphics, Rectangle bounds)
        {
            if (bounds.Width < 2 || bounds.Height < 2) return;
            if (SystemInformation.HighContrast)
            {
                using (SolidBrush system = new SolidBrush(SystemColors.Window)) graphics.FillRectangle(system, bounds);
                using (Pen border = new Pen(SystemColors.WindowText)) graphics.DrawRectangle(border, bounds.X, bounds.Y, bounds.Width - 1, bounds.Height - 1);
                return;
            }
            GraphicsState state = graphics.Save();
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF area = new RectangleF(bounds.X + .5f, bounds.Y + .5f, bounds.Width - 1.5f, bounds.Height - 2f);
            using (GraphicsPath surface = AeroTheme.Round(area, 7))
            {
                using (LinearGradientBrush body = new LinearGradientBrush(area, Color.FromArgb(249, 254, 255), Color.FromArgb(207, 235, 249), 90f))
                {
                    body.InterpolationColors = new ColorBlend
                    {
                        Colors = new[] { Color.FromArgb(252, 255, 255), Color.FromArgb(238, 249, 254), Color.FromArgb(227, 244, 253), Color.FromArgb(209, 236, 250) },
                        Positions = new[] { 0f, .32f, .72f, 1f }
                    };
                    graphics.FillPath(body, surface);
                }
                graphics.SetClip(surface, CombineMode.Intersect);
                using (SolidBrush shine = new SolidBrush(Color.FromArgb(94, Color.White))) graphics.FillEllipse(shine, area.X - area.Width * .28f, area.Y - area.Height * .76f, area.Width * 1.35f, area.Height * 1.13f);
                using (SolidBrush diagonal = new SolidBrush(Color.FromArgb(29, Color.White))) graphics.FillPolygon(diagonal, new[] { new PointF(area.Right - 90, area.Top), new PointF(area.Right - 35, area.Top), new PointF(area.X + area.Width * .48f, area.Bottom), new PointF(area.X + area.Width * .33f, area.Bottom) });
                graphics.Restore(state);
                state = graphics.Save();
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (Pen edge = new Pen(Color.FromArgb(126, 174, 204))) graphics.DrawPath(edge, surface);
                RectangleF inner = new RectangleF(area.X + 1.2f, area.Y + 1.2f, area.Width - 2.4f, area.Height - 2.4f);
                if (inner.Width > 1 && inner.Height > 1)
                    using (GraphicsPath bevel = AeroTheme.Round(inner, 5.5f))
                    using (Pen light = new Pen(Color.FromArgb(225, Color.White))) graphics.DrawPath(light, bevel);
            }
            graphics.Restore(state);
        }
    }
}
