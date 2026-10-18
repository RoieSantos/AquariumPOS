using System;
using System.Collections.Generic;
using System.Drawing;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Windows.Forms;

namespace AquariumPOS
{
    /// <summary>
    /// How a button should look. Auto = decided from the colour the code gave it (green -> Success,
    /// red -> Danger, orange/brown -> Warning, blue/purple/teal -> Primary, grey -> Neutral, none -> Secondary).
    /// </summary>
    public enum UiRole { Auto, Primary, Success, Danger, Warning, Neutral, Secondary, Tile, DangerSoft, Nav }

    /// <summary>
    /// One look for the whole POS, copied from the web portal (docs/css/styles.css :root + bc-list.css):
    /// navy primary, soft blue-grey page, white panels with light borders, Segoe UI.
    ///
    /// The forms were built with ~1,000 hard-coded colours (DarkBlue, DarkOrange, MediumPurple, ...).
    /// Instead of editing each one, Apply() walks a form and remaps every colour to the few portal roles
    /// above by its hue, so the MEANING stays (green pay, red void, amber post) but the rainbow goes.
    /// It also hooks ControlAdded / BackColorChanged / ForeColorChanged / FontChanged, so controls and
    /// colours set later at runtime (rebuilt button grids, checkout state colours) are themed too.
    /// Every form gets it via ThemedForm (see ThemedForm.cs).
    /// </summary>
    internal static class UiTheme
    {
        // --- Portal tokens -------------------------------------------------------------------------
        public static readonly Color PageBg = Hex(0xf4f7fb);
        public static readonly Color PanelBg = Color.White;
        public static readonly Color PanelBorder = Hex(0xd7e0ef);
        public static readonly Color InputBorder = Hex(0xc7d3e6);
        public static readonly Color TextMain = Hex(0x1b355e);
        public static readonly Color TextMuted = Hex(0x61738f);
        public static readonly Color Primary = Hex(0x1d4f91);
        public static readonly Color PrimaryStrong = Hex(0x173f74);
        public static readonly Color Success = Hex(0x1e9a59);
        public static readonly Color SuccessStrong = Hex(0x17804a);
        public static readonly Color Danger = Hex(0xc0392b);
        public static readonly Color DangerStrong = Hex(0xa23125);
        public static readonly Color Warning = Hex(0xb45309);
        public static readonly Color WarningStrong = Hex(0x92400e);
        public static readonly Color Neutral = Hex(0x7b8596);
        public static readonly Color NeutralStrong = Hex(0x646d7d);
        public static readonly Color HeaderTint = Hex(0xeef3fb);   // table header / tinted panel
        public static readonly Color HoverTint = Hex(0xe0ebfa);
        public static readonly Color Selected = Hex(0xe3eefa);
        public static readonly Color RowAlt = Hex(0xf8fafd);
        public static readonly Color WarnBg = Hex(0xfff4ce);
        public static readonly Color SuccessBg = Hex(0xe8f5ee);
        public static readonly Color DangerBg = Hex(0xfbeceb);
        public static readonly Color DangerBgHover = Hex(0xf6d9d6);
        public static readonly Color DangerBorder = Hex(0xefc2bd);
        // Portal top nav: links are #dce8fb on navy; "button" = white at 10% / 18% over navy.
        public static readonly Color NavText = Hex(0xdce8fb);
        public static readonly Color NavButton = Hex(0x34619c);
        public static readonly Color NavButtonHover = Hex(0x466fa5);

        public const string FontFamily = "Segoe UI";

        private static readonly HashSet<int> PaletteArgb = new();
        private static readonly HashSet<string> ReplacedFonts = new(StringComparer.OrdinalIgnoreCase)
        {
            "Arial", "Microsoft Sans Serif", "Tahoma", "Verdana", "Courier New"
        };

        private static readonly ConditionalWeakTable<Control, object> Hooked = new();
        private static readonly ConditionalWeakTable<Control, StrongBox<UiRole>> Roles = new();
        private static readonly Dictionary<(float, FontStyle), Font> FontCache = new();
        private static readonly Dictionary<int, Color> SurfaceCache = new();
        private static readonly Dictionary<int, Color> TextCache = new();
        private static bool _busy;

        static UiTheme()
        {
            foreach (var f in typeof(UiTheme).GetFields(BindingFlags.Public | BindingFlags.Static))
                if (f.FieldType == typeof(Color) && f.GetValue(null) is Color c) PaletteArgb.Add(c.ToArgb());
        }

        private static Color Hex(int rgb) => Color.FromArgb(255, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
        private static bool IsPalette(Color c) => PaletteArgb.Contains(c.ToArgb());

        /// <summary>Called once at startup: portal-coloured menus / context menus.</summary>
        public static void Init()
        {
            ToolStripManager.Renderer = new ToolStripProfessionalRenderer(new PortalColorTable()) { RoundedEdges = false };
        }

        /// <summary>Pin a button's look instead of deriving it from its colour (e.g. category tiles).</summary>
        public static void SetRole(Control c, UiRole role)
        {
            Roles.AddOrUpdate(c, new StrongBox<UiRole>(role));
            if (c is ButtonBase b) StyleButton(b);
        }

        // --- Walk + hooks ------------------------------------------------------------------------------
        public static void Apply(Control root)
        {
            if (root == null || root.IsDisposed) return;
            ApplyOne(root);
            foreach (Control child in root.Controls) Apply(child);
        }

        private static void ApplyOne(Control c)
        {
            if (_busy) return;
            _busy = true;
            try
            {
                ThemeFont(c);
                switch (c)
                {
                    case Form f: StyleForm(f); break;
                    case ButtonBase b when b is Button || (b is CheckBox cb && cb.Appearance == Appearance.Button)
                                         || (b is RadioButton rb && rb.Appearance == Appearance.Button):
                        StyleButtonCore(b); break;
                    case DataGridView g: StyleGrid(g); break;
                    case ListView lv: StyleListView(lv); break;
                    case TextBox tb: StyleTextBox(tb); break;
                    case Panel p: StyleContainer(p); StylePanelBorder(p); break;   // incl. TabPage, Flow/TableLayoutPanel
                    case GroupBox gb: StyleContainer(gb); break;
                    case Label or CheckBox or RadioButton: StyleTextControl(c); break;
                    default: StyleText(c); break;
                }
            }
            catch { /* theming must never break a screen */ }
            finally { _busy = false; }

            if (!Hooked.TryGetValue(c, out _))
            {
                Hooked.Add(c, new object());
                c.ControlAdded += (s, e) => { if (e.Control != null) Apply(e.Control); };
                c.BackColorChanged += (s, e) => { if (s is Control x) ApplyOne(x); };
                c.ForeColorChanged += (s, e) => { if (s is Control x) ApplyOne(x); };
                c.FontChanged += (s, e) => { if (s is Control x && !_busy) { _busy = true; try { ThemeFont(x); } catch { } finally { _busy = false; } } };
            }
        }

        // --- Fonts -------------------------------------------------------------------------------------
        private static void ThemeFont(Control c)
        {
            if (c.Parent != null && ReferenceEquals(c.Font, c.Parent.Font)) return; // inherited
            var mapped = MapFont(c.Font);
            if (!ReferenceEquals(mapped, c.Font)) c.Font = mapped;
        }

        public static Font MapFont(Font f)
        {
            if (f == null || !ReplacedFonts.Contains(f.Name)) return f!;
            if (f.Name.Equals("Courier New", StringComparison.OrdinalIgnoreCase))
                return GetFont("Consolas", f.Size, f.Style);
            return UiFont(f.Size, f.Style);
        }

        public static Font UiFont(float size, FontStyle style = FontStyle.Regular) => GetFont(FontFamily, size, style);

        private static Font GetFont(string family, float size, FontStyle style)
        {
            if (family != FontFamily) return new Font(family, size, style);
            var key = (size, style);
            if (!FontCache.TryGetValue(key, out var font))
            {
                font = new Font(FontFamily, size, style);
                FontCache[key] = font;
            }
            return font;
        }

        // --- Colour mapping ------------------------------------------------------------------------------
        private enum Hue { Grey, Red, Orange, Green, Blue }

        private static Hue HueOf(Color c)
        {
            if (c.GetSaturation() < 0.15f || (c.R == c.G && c.G == c.B)) return Hue.Grey;
            float h = c.GetHue();
            if (h < 12 || h >= 340) return Hue.Red;
            if (h < 75) return Hue.Orange;   // orange, brown, sienna, gold, olive
            if (h < 170) return Hue.Green;   // greens, sea greens
            return Hue.Blue;                 // cyan, teal, blue, indigo, purple, violet
        }

        private static float Lum(Color c) => (0.299f * c.R + 0.587f * c.G + 0.114f * c.B) / 255f;

        /// <summary>A filled (dark/saturated) background -> one of the portal's solid colours.</summary>
        private static UiRole FillRole(Color c)
        {
            switch (HueOf(c))
            {
                case Hue.Red: return UiRole.Danger;
                case Hue.Orange: return UiRole.Warning;
                case Hue.Green: return UiRole.Success;
                case Hue.Blue: return UiRole.Primary;
                default: return Lum(c) < 0.25f ? UiRole.Primary : UiRole.Neutral;
            }
        }

        private static Color FillColor(UiRole r) => r switch
        {
            UiRole.Danger => Danger,
            UiRole.Warning => Warning,
            UiRole.Success => Success,
            UiRole.Neutral => Neutral,
            _ => Primary
        };

        private static Color StrongColor(UiRole r) => r switch
        {
            UiRole.Danger => DangerStrong,
            UiRole.Warning => WarningStrong,
            UiRole.Success => SuccessStrong,
            UiRole.Neutral => NeutralStrong,
            _ => PrimaryStrong
        };

        /// <summary>Panel / form / label / cell background.</summary>
        public static Color MapSurface(Color c)
        {
            if (c.A == 0 || IsPalette(c)) return c;
            if (c.IsSystemColor) c = Color.FromArgb(c.ToArgb());
            int key = c.ToArgb();
            if (SurfaceCache.TryGetValue(key, out var m)) return m;

            if (Lum(c) < 0.55f)
                m = FillColor(FillRole(c));   // a dark status strip etc. keeps being "filled"
            else if (c.R > 250 && c.G > 250 && c.B > 250)
                m = PanelBg;
            else
                m = HueOf(c) switch
                {
                    Hue.Red => DangerBg,
                    Hue.Orange => WarnBg,
                    Hue.Green => SuccessBg,
                    Hue.Blue => HeaderTint,
                    _ => PageBg
                };
            SurfaceCache[key] = m;
            return m;
        }

        /// <summary>Text colour.</summary>
        public static Color MapText(Color c)
        {
            if (c.A == 0 || IsPalette(c)) return c;
            if (c.IsSystemColor) c = Color.FromArgb(c.ToArgb());
            int key = c.ToArgb();
            if (TextCache.TryGetValue(key, out var m)) return m;

            float lum = Lum(c);
            if (lum > 0.85f) m = c;                       // white / light text sits on a fill - keep
            else
                m = HueOf(c) switch
                {
                    Hue.Red => Danger,
                    Hue.Orange => Warning,
                    Hue.Green => Success,
                    Hue.Blue => lum < 0.3f ? TextMain : Primary,
                    _ => lum < 0.3f ? TextMain : TextMuted
                };
            TextCache[key] = m;
            return m;
        }

        private static bool InheritsBack(Control c) =>
            c.Parent != null && c.BackColor.ToArgb() == c.Parent.BackColor.ToArgb() && !(c is Form);

        private static bool InheritsFore(Control c) =>
            c.Parent != null && c.ForeColor.ToArgb() == c.Parent.ForeColor.ToArgb() && !(c is Form);

        private static void SetBack(Control c, Color col) { if (c.BackColor.ToArgb() != col.ToArgb() || c.BackColor.IsSystemColor) c.BackColor = col; }
        private static void SetFore(Control c, Color col) { if (c.ForeColor.ToArgb() != col.ToArgb() || c.ForeColor.IsSystemColor) c.ForeColor = col; }

        // --- Per-control styles -------------------------------------------------------------------------------
        private static void StyleForm(Form f)
        {
            var back = f.BackColor;
            SetBack(f, back.IsSystemColor || Lum(back) > 0.55f ? (back.ToArgb() == Color.White.ToArgb() ? PanelBg : PageBg) : MapSurface(back));
            SetFore(f, MapText(f.ForeColor));
        }

        private static void StyleContainer(Control c)
        {
            if (c.BackColor.A != 0 && !InheritsBack(c)) SetBack(c, MapSurface(c.BackColor));
            if (!InheritsFore(c)) SetFore(c, MapText(c.ForeColor));
        }

        private static void StyleText(Control c)
        {
            if (c.BackColor.A != 0 && !InheritsBack(c) && !(c is TextBoxBase || c is ComboBox || c is ListBox || c is NumericUpDown || c is DateTimePicker))
                SetBack(c, MapSurface(c.BackColor));
            if (!InheritsFore(c)) SetFore(c, MapText(c.ForeColor));
        }

        private static void StyleTextControl(Control c)
        {
            if (c.BackColor.A != 0 && !InheritsBack(c)) SetBack(c, MapSurface(c.BackColor));
            if (!InheritsFore(c)) SetFore(c, MapText(c.ForeColor));
        }

        private static void StyleTextBox(TextBox tb)
        {
            if (tb.BorderStyle == BorderStyle.Fixed3D) tb.BorderStyle = BorderStyle.FixedSingle;
            if (!tb.ReadOnly && tb.BackColor.ToArgb() != SystemColors.Window.ToArgb() && !tb.BackColor.IsSystemColor)
                SetBack(tb, MapSurface(tb.BackColor));
            if (!tb.ForeColor.IsSystemColor) SetFore(tb, MapText(tb.ForeColor));
            else SetFore(tb, TextMain);
        }

        /// <summary>Hard black FixedSingle/3D borders -> a 1px portal border painted by us.</summary>
        private static void StylePanelBorder(Panel p)
        {
            if (p.BorderStyle == BorderStyle.None) return;
            p.BorderStyle = BorderStyle.None;
            if (p.AutoScroll) return; // a painted border smears while scrolling - just drop the hard one
            if (p.Padding == Padding.Empty) p.Padding = new Padding(1);
            p.Paint += (s, e) =>
            {
                using var pen = new Pen(PanelBorder);
                e.Graphics.DrawRectangle(pen, 0, 0, p.Width - 1, p.Height - 1);
            };
            p.Invalidate();
        }

        /// <summary>
        /// Portal ".card": a white rounded box (8px radius, #d7e0ef border, soft navy shadow) floating on the
        /// page background. The panel keeps its bounds/docking; the card is painted `inset` px inside it so
        /// neighbouring cards get a gap, and children are padded inside the card. Children that would show
        /// the page colour (inherited back) are switched to the card's white, including ones added later.
        /// </summary>
        public static void MakeCard(Panel p, int inset = 10, int radius = 8)
        {
            p.BorderStyle = BorderStyle.None;
            p.BackColor = PageBg;
            p.Padding = new Padding(inset + 3);   // +3 keeps square child corners inside the rounded corner
            typeof(Control).GetProperty("DoubleBuffered", BindingFlags.Instance | BindingFlags.NonPublic)?.SetValue(p, true);

            void Whiten(Control child)
            {
                if (child.BackColor.ToArgb() == p.BackColor.ToArgb()) child.BackColor = PanelBg;
            }
            foreach (Control child in p.Controls) Whiten(child);
            p.ControlAdded += (s, e) => { if (e.Control != null) Whiten(e.Control); };

            p.Paint += (s, e) =>
            {
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                var card = new Rectangle(inset, inset, p.ClientSize.Width - 2 * inset - 1, p.ClientSize.Height - 2 * inset - 1);
                if (card.Width < 2 * radius || card.Height < 2 * radius) return;

                // Soft shadow (portal: 0 8px 24px rgba(21,52,94,.08)) - stacked faint rings, shifted down.
                for (int i = Math.Min(6, inset - 1); i >= 1; i--)
                {
                    var r = Rectangle.Inflate(card, i, i);
                    r.Offset(0, 2);
                    using var sp = RoundedRect(r, radius + i);
                    using var sb = new SolidBrush(Color.FromArgb(5, 21, 52, 94));
                    g.FillPath(sb, sp);
                }

                using var path = RoundedRect(card, radius);
                using (var fill = new SolidBrush(PanelBg)) g.FillPath(fill, path);
                using (var pen = new Pen(PanelBorder)) g.DrawPath(pen, path);
            };
            // Re-paint the whole card when it resizes or scrolls (otherwise the edges smear).
            p.Resize += (s, e) => p.Invalidate();
            p.Scroll += (s, e) => p.Invalidate();
            p.MouseWheel += (s, e) => p.Invalidate();
            p.Invalidate();
        }

        private static System.Drawing.Drawing2D.GraphicsPath RoundedRect(Rectangle r, int radius)
        {
            int d = radius * 2;
            var path = new System.Drawing.Drawing2D.GraphicsPath();
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void StyleButton(ButtonBase b)
        {
            if (_busy) { StyleButtonCore(b); return; }
            _busy = true;
            try { StyleButtonCore(b); } catch { } finally { _busy = false; }
        }

        private static void StyleButtonCore(ButtonBase b)
        {
            UiRole role = Roles.TryGetValue(b, out var box) ? box.Value : UiRole.Auto;
            if (role == UiRole.Auto)
            {
                var back = b.BackColor;
                if (back.A == 0) return; // transparent/icon buttons keep their look
                if (back.IsSystemColor || InheritsBack(b) || Lum(back) > 0.8f)
                    role = Lum(back) > 0.8f && !back.IsSystemColor && HueOf(back) == Hue.Red ? UiRole.DangerSoft : UiRole.Secondary;
                else if (IsPalette(back))
                    role = PaletteRole(back);
                else
                    role = FillRole(back);
            }

            b.FlatStyle = FlatStyle.Flat;
            if (b is Button btn) btn.UseVisualStyleBackColor = false;
            b.Cursor = Cursors.Hand;
            var fa = b.FlatAppearance;

            switch (role)
            {
                case UiRole.Secondary:
                    SetBack(b, PanelBg); SetFore(b, TextMain);
                    fa.BorderSize = 1; fa.BorderColor = InputBorder;
                    fa.MouseOverBackColor = HeaderTint; fa.MouseDownBackColor = HoverTint;
                    break;
                case UiRole.Tile:
                    SetBack(b, HeaderTint); SetFore(b, Primary);
                    fa.BorderSize = 1; fa.BorderColor = PanelBorder;
                    fa.MouseOverBackColor = HoverTint; fa.MouseDownBackColor = Selected;
                    break;
                case UiRole.DangerSoft:
                    SetBack(b, DangerBg); SetFore(b, Danger);
                    fa.BorderSize = 1; fa.BorderColor = DangerBorder;
                    fa.MouseOverBackColor = DangerBgHover; fa.MouseDownBackColor = DangerBorder;
                    break;
                case UiRole.Nav:
                    SetBack(b, NavButton); SetFore(b, Color.White);
                    fa.BorderSize = 0;
                    fa.MouseOverBackColor = NavButtonHover; fa.MouseDownBackColor = PrimaryStrong;
                    break;
                default:
                    SetBack(b, FillColor(role)); SetFore(b, Color.White);
                    fa.BorderSize = 0;
                    fa.MouseOverBackColor = StrongColor(role);
                    fa.MouseDownBackColor = StrongColor(role);
                    break;
            }
        }

        private static UiRole PaletteRole(Color c)
        {
            int a = c.ToArgb();
            if (a == Success.ToArgb() || a == SuccessStrong.ToArgb()) return UiRole.Success;
            if (a == Danger.ToArgb() || a == DangerStrong.ToArgb()) return UiRole.Danger;
            if (a == Warning.ToArgb() || a == WarningStrong.ToArgb()) return UiRole.Warning;
            if (a == Neutral.ToArgb() || a == NeutralStrong.ToArgb()) return UiRole.Neutral;
            if (a == NavButton.ToArgb() || a == NavButtonHover.ToArgb()) return UiRole.Nav;
            if (a == HeaderTint.ToArgb()) return UiRole.Tile;
            if (a == DangerBg.ToArgb()) return UiRole.DangerSoft;
            if (a == PanelBg.ToArgb()) return UiRole.Secondary;
            return UiRole.Primary;
        }

        private static void StyleGrid(DataGridView g)
        {
            g.BorderStyle = BorderStyle.None;
            g.BackgroundColor = PanelBg;
            g.GridColor = PanelBorder;
            g.EnableHeadersVisualStyles = false;
            if (g.CellBorderStyle == DataGridViewCellBorderStyle.Single)
                g.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
            g.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.Single;

            var h = g.ColumnHeadersDefaultCellStyle;
            h.BackColor = HeaderTint;
            h.ForeColor = TextMain;
            h.SelectionBackColor = HeaderTint;
            h.SelectionForeColor = TextMain;
            h.Font = UiFont(Math.Max(9f, h.Font?.Size ?? 9f), FontStyle.Bold);
            if (g.ColumnHeadersHeightSizeMode != DataGridViewColumnHeadersHeightSizeMode.AutoSize)
                g.ColumnHeadersHeight = Math.Max(g.ColumnHeadersHeight, 34);

            var d = g.DefaultCellStyle;
            d.ForeColor = TextMain;
            d.BackColor = PanelBg;
            d.SelectionBackColor = Selected;
            d.SelectionForeColor = TextMain;
            if (d.Font != null) d.Font = MapFont(d.Font);
            if (g.AlternatingRowsDefaultCellStyle.BackColor.IsEmpty)
                g.AlternatingRowsDefaultCellStyle.BackColor = RowAlt;

            g.RowHeadersDefaultCellStyle.BackColor = HeaderTint;
            g.RowHeadersDefaultCellStyle.SelectionBackColor = Selected;
            g.RowHeadersBorderStyle = DataGridViewHeaderBorderStyle.Single;
            g.RowTemplate.Height = Math.Max(g.RowTemplate.Height, 30);

            // Row/cell colours set by the code (status highlights) keep their meaning, in portal shades.
            g.CellFormatting += (s, e) =>
            {
                var cs = e.CellStyle;
                if (cs == null) return;
                if (!cs.BackColor.IsEmpty && cs.BackColor.ToArgb() != PanelBg.ToArgb() && !IsPalette(cs.BackColor))
                {
                    var nb = MapSurface(cs.BackColor);
                    cs.BackColor = nb;
                    if (Lum(nb) < 0.55f) cs.ForeColor = Color.White;
                }
                if (!cs.ForeColor.IsEmpty && !IsPalette(cs.ForeColor)) cs.ForeColor = MapText(cs.ForeColor);
                if (cs.Font != null && ReplacedFonts.Contains(cs.Font.Name)) cs.Font = MapFont(cs.Font);
            };
        }

        private static void StyleListView(ListView lv)
        {
            lv.GridLines = false;
            if (lv.BorderStyle == BorderStyle.Fixed3D) lv.BorderStyle = BorderStyle.FixedSingle;
            if (!lv.BackColor.IsSystemColor) SetBack(lv, MapSurface(lv.BackColor));
            SetFore(lv, lv.ForeColor.IsSystemColor ? TextMain : MapText(lv.ForeColor));
            if (lv.View != View.Details) return;

            // Taller rows (the classic SmallImageList trick) - only when the list has no icons of its own.
            if (lv.SmallImageList == null)
                lv.SmallImageList = new ImageList { ImageSize = new Size(1, Math.Max(26, lv.Font.Height + 12)) };

            // Portal-style column header: tinted, bold, a light rule underneath.
            if (!lv.OwnerDraw)
            {
                typeof(Control).GetProperty("DoubleBuffered", BindingFlags.Instance | BindingFlags.NonPublic)?.SetValue(lv, true);
                lv.OwnerDraw = true;
                lv.DrawItem += (s, e) => e.DrawDefault = true;
                lv.DrawSubItem += (s, e) => e.DrawDefault = true;
                // Known owner-draw ListView bug: hovering a Details row repaints only part of it.
                lv.MouseMove += (s, e) => { var it = lv.GetItemAt(e.X, e.Y); if (it != null) lv.Invalidate(it.Bounds); };
                lv.DrawColumnHeader += (s, e) =>
                {
                    using (var bg = new SolidBrush(HeaderTint)) e.Graphics.FillRectangle(bg, e.Bounds);
                    using (var pen = new Pen(PanelBorder))
                    {
                        e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1);
                        e.Graphics.DrawLine(pen, e.Bounds.Right - 1, e.Bounds.Top + 6, e.Bounds.Right - 1, e.Bounds.Bottom - 7);
                    }
                    var flags = TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.SingleLine;
                    var align = e.Header?.TextAlign ?? HorizontalAlignment.Left;
                    flags |= align == HorizontalAlignment.Right ? TextFormatFlags.Right
                           : align == HorizontalAlignment.Center ? TextFormatFlags.HorizontalCenter : TextFormatFlags.Left;
                    var r = Rectangle.Inflate(e.Bounds, -8, 0);
                    TextRenderer.DrawText(e.Graphics, e.Header?.Text ?? "", UiFont(lv.Font.Size, FontStyle.Bold), r, TextMain, flags);
                };
            }
        }

        private sealed class PortalColorTable : ProfessionalColorTable
        {
            public override Color MenuItemSelected => HeaderTint;
            public override Color MenuItemBorder => PanelBorder;
            public override Color MenuBorder => PanelBorder;
            public override Color MenuItemSelectedGradientBegin => HeaderTint;
            public override Color MenuItemSelectedGradientEnd => HeaderTint;
            public override Color MenuItemPressedGradientBegin => HoverTint;
            public override Color MenuItemPressedGradientEnd => HoverTint;
            public override Color ToolStripDropDownBackground => PanelBg;
            public override Color ImageMarginGradientBegin => PanelBg;
            public override Color ImageMarginGradientMiddle => PanelBg;
            public override Color ImageMarginGradientEnd => PanelBg;
            public override Color SeparatorDark => PanelBorder;
            public override Color ToolStripBorder => PanelBorder;
            public override Color ToolStripGradientBegin => PanelBg;
            public override Color ToolStripGradientMiddle => PanelBg;
            public override Color ToolStripGradientEnd => PanelBg;
            public override Color MenuStripGradientBegin => PanelBg;
            public override Color MenuStripGradientEnd => PanelBg;
            public override Color StatusStripGradientBegin => PageBg;
            public override Color StatusStripGradientEnd => PageBg;
            public override Color ButtonSelectedHighlight => HeaderTint;
            public override Color ButtonSelectedGradientBegin => HeaderTint;
            public override Color ButtonSelectedGradientEnd => HeaderTint;
            public override Color ButtonPressedGradientBegin => HoverTint;
            public override Color ButtonPressedGradientEnd => HoverTint;
            public override Color ButtonSelectedBorder => PanelBorder;
        }
    }
}
