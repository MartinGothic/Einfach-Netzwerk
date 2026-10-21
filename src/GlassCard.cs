using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace EinfachNetzwerk
{
    internal sealed class GlassCard : TableLayoutPanel
    {
        internal GlassCard()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = SystemInformation.HighContrast ? SystemColors.Window : Color.Transparent;
        }
        protected override void OnPaintBackground(PaintEventArgs e)
        {
            base.OnPaintBackground(e);
            GlassPainter.DrawSurface(e.Graphics, ClientRectangle);
        }
    }
}
