using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal static class AeroTheme
    {
        internal static readonly Color Ink = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(22, 53, 83);
        internal static readonly Color Accent = SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(16, 100, 164);
        private static bool requested = true;
        internal static event EventHandler AnimationChanged;
        internal static bool Animations
        {
            get { return requested && SystemInformation.IsMenuAnimationEnabled && SystemInformation.UIEffectsEnabled && !SystemInformation.HighContrast; }
            set { requested = value; if (AnimationChanged != null) AnimationChanged(null, EventArgs.Empty); }
        }
        internal static bool CanAnimate(Control control)
        {
            if (!Animations || control == null || control.IsDisposed || !control.Visible || !control.Enabled) return false;
            Form form = control.FindForm();
            return form != null && !form.IsDisposed && form.Visible && form.Enabled && form.WindowState != FormWindowState.Minimized;
        }
        internal static void StyleGlassChildren(Control root)
        {
            foreach (Control child in root.Controls)
            {
                bool text = child is Label || child is CheckBox || child is RadioButton;
                bool container = child is Panel || child is TableLayoutPanel || child is FlowLayoutPanel || child is GroupBox;
                if (text || (container && !(child is AeroHeader) && !(child is GlassCard) && !(child is CollapsibleSection)))
                    child.BackColor = Color.Transparent;
                StyleGlassChildren(child);
            }
        }
        internal static void ApplyWindowIcon(Form form)
        {
            if (form == null) return;
            try
            {
                // Use our assembly, including when a QA host owns Application.ExecutablePath.
                using (Icon source = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location))
                {
                    if (source == null) return;
                    Icon owned = (Icon)source.Clone();
                    form.Icon = owned;
                    form.Disposed += delegate { owned.Dispose(); };
                }
            }
            catch (ArgumentException) { }
            catch (System.IO.IOException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
        internal static void GlassFrame(Form form)
        {
            if (SystemInformation.HighContrast) return;
            try
            {
                bool enabled;
                if (DwmIsCompositionEnabled(out enabled) == 0 && enabled)
                {
                    Margins margins = new Margins { Left = 5, Right = 5, Top = 5, Bottom = 5 };
                    DwmExtendFrameIntoClientArea(form.Handle, ref margins);
                }
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }
        [StructLayout(LayoutKind.Sequential)] private struct Margins { public int Left, Right, Top, Bottom; }
        [DllImport("dwmapi.dll")] private static extern int DwmIsCompositionEnabled(out bool enabled);
        [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
        internal static GraphicsPath Round(RectangleF rectangle, float radius)
        {
            GraphicsPath path = new GraphicsPath();
            float d = radius * 2;
            if (rectangle.Width < d || rectangle.Height < d) { path.AddRectangle(rectangle); return path; }
            path.AddArc(rectangle.X, rectangle.Y, d, d, 180, 90);
            path.AddArc(rectangle.Right - d, rectangle.Y, d, d, 270, 90);
            path.AddArc(rectangle.Right - d, rectangle.Bottom - d, d, d, 0, 90);
            path.AddArc(rectangle.X, rectangle.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
        internal static void FillGlass(Graphics graphics, Rectangle bounds, bool primary, float glow)
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            RectangleF area = new RectangleF(bounds.X + 1, bounds.Y + 1, Math.Max(1, bounds.Width - 3), Math.Max(1, bounds.Height - 3));
            using (GraphicsPath rounded = Round(area, 6))
            {
                Color top = primary ? Color.FromArgb(135, 216, 252) : Color.FromArgb(255, 255, 255);
                Color bottom = primary ? Color.FromArgb(16, 105 + (int)(glow * 25), 175 + (int)(glow * 20)) : Color.FromArgb(216, 236 + (int)(glow * 8), 249);
                using (LinearGradientBrush fill = new LinearGradientBrush(area, top, bottom, 90f)) graphics.FillPath(fill, rounded);
                GraphicsState state = graphics.Save();
                graphics.SetClip(rounded);
                using (LinearGradientBrush shine = new LinearGradientBrush(new RectangleF(area.X, area.Y, area.Width, area.Height / 2), Color.FromArgb(135, Color.White), Color.FromArgb(25, Color.White), 90f))
                    graphics.FillRectangle(shine, area.X, area.Y, area.Width, area.Height / 2);
                if (glow > 0.02f)
                {
                    using (SolidBrush light = new SolidBrush(Color.FromArgb((int)(glow * 80), 183, 242, 255))) graphics.FillEllipse(light, area.X - 4, area.Bottom - area.Height * .65f, area.Width + 8, area.Height);
                }
                graphics.Restore(state);
                using (Pen edge = new Pen(primary ? Color.FromArgb(42, 106, 151) : Color.FromArgb(137, 177, 202))) graphics.DrawPath(edge, rounded);
                using (GraphicsPath inner = Round(new RectangleF(area.X + 1, area.Y + 1, area.Width - 2, area.Height - 2), 5))
                using (Pen reflection = new Pen(Color.FromArgb(185, Color.White))) graphics.DrawPath(reflection, inner);
            }
        }
    }
}
