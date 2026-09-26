using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;

namespace WaterDaytimePreparationOverlay;

internal static class Layout
{
    // WBP_MenuMaster: centered 1920x1080 SizeBox inside a down-only ScaleBox.
    // WBP_ReadyRoom: bottom-center map card 400x50, bottom padding 12.
    // These are authored geometry, not a live GetCachedGeometry observation.
    internal const float CardWidth = 400, CardHeight = 50, CardBottom = 12;
    internal const float PanelHeight = 70, CardGap = 8;

    internal static float ScaleFor(Rectangle game) => Math.Min(game.Width / 1920f, game.Height / 1080f);

    public static Rectangle NativeMapCardFor(Rectangle game)
    {
        var scale = ScaleFor(game);
        var rootHeight = 1080 * scale;
        var rootBottom = game.Top + (game.Height + rootHeight) / 2f;
        var width = (int)Math.Round(CardWidth * scale);
        var height = (int)Math.Round(CardHeight * scale);
        return new Rectangle(game.Left + (game.Width - width) / 2,
            (int)Math.Round(rootBottom - (CardBottom + CardHeight) * scale), width, height);
    }

    public static Size SizeFor(Rectangle game) => new(NativeMapCardFor(game).Width,
        (int)Math.Round(PanelHeight * ScaleFor(game)));

    public static Rectangle BoundsFor(Rectangle game)
    {
        var card = NativeMapCardFor(game);
        var size = SizeFor(game);
        var gap = (int)Math.Ceiling(CardGap * ScaleFor(game));
        return new Rectangle(card.Left, card.Top - gap - size.Height, size.Width, size.Height);
    }

    public static (Rectangle Left, Rectangle Right, Rectangle Prepare) Hits(Rectangle client)
    {
        var scale = client.Width / CardWidth;
        int U(float value) => (int)Math.Round(value * scale);
        return (new Rectangle(client.Left + U(6), client.Top + U(6), U(26), U(36)),
            new Rectangle(client.Left + U(217), client.Top + U(6), U(26), U(36)),
            new Rectangle(client.Left + U(249), client.Top + U(6), U(145), U(36)));
    }
}

internal static class Renderer
{
    private static readonly Color Orange = Color.FromArgb(239, 79, 42);
    private static readonly Color Pale = Color.FromArgb(229, 235, 218);
    private static readonly Color Yellow = Color.FromArgb(238, 226, 75);
    private static readonly Color Muted = Color.FromArgb(148, 158, 148);
    private static readonly Color Dark = Color.FromArgb(21, 28, 27);
    private static readonly Lazy<Bitmap?> NativeWaterIcon = new(LoadNativeWaterIcon);
    public static bool NativeWaterIconAvailable => NativeWaterIcon.Value is not null;

    public static void Draw(Graphics g, Rectangle bounds, Snapshot state, Hit hover)
    {
        var saved = g.Save();
        g.TranslateTransform(bounds.Left, bounds.Top);
        var client = new Rectangle(Point.Empty, bounds.Size);
        var scale = client.Width / Layout.CardWidth;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using var back = new SolidBrush(Color.FromArgb(28, 35, 34));
        using var border = new Pen(Color.FromArgb(157, 169, 156), Math.Max(1, scale));
        using var divider = new Pen(Color.FromArgb(71, 83, 77), Math.Max(1, scale));
        g.FillRectangle(back, client);
        g.DrawRectangle(border, .5f * scale, .5f * scale,
            client.Width - scale, client.Height - scale);
        // Subtle horizontal grain echoes the native Ready Room grid.
        using (var grain = new Pen(Color.FromArgb(8, 210, 220, 205)))
            for (var y = 3f * scale; y < client.Height; y += 4f * scale)
                g.DrawLine(grain, scale, y, client.Width - scale, y);
        g.DrawLine(divider, 6 * scale, 48 * scale, client.Width - 6 * scale, 48 * scale);

        var hits = Layout.Hits(client);
        var activeMode = state.Status is "armed" or "processing" ? state.IntentMode : state.Mode;
        var mode = activeMode switch { "nighttime" => "NIGHTTIME", "daytime" => "DAYTIME", _ => "DAY CYCLE OFF" };
        var modeRect = RectangleF.FromLTRB(hits.Left.Right + 5 * scale, hits.Left.Top,
            hits.Right.Left - 5 * scale, hits.Left.Bottom);
        using var modeFont = FontOf(17 * scale, true);
        using var small = FontOf(11.5f * scale, false);
        using var buttonFont = FontOf(14 * scale, true);

        DrawArrow(g, hits.Left, true, state.ControlsEnabled, hover == Hit.Left, scale);
        DrawArrow(g, hits.Right, false, state.ControlsEnabled, hover == Hit.Right, scale);
        Text(g, mode, modeFont, activeMode == "off" ? Pale : Yellow, modeRect);
        DrawPrepare(g, hits.Prepare, state, buttonFont, hover == Hit.Prepare, scale);

        var footer = Footer(state);
        var supplyVisible = state.Status is not ("armed" or "processing");
        var footerRight = supplyVisible ? 300 * scale : 392 * scale;
        Text(g, footer, small, state.Status is "uncertain" or "insufficient" ? Orange : Pale,
            new RectangleF(10 * scale, 50 * scale, footerRight - 10 * scale, 17 * scale), StringAlignment.Near);
        if (supplyVisible)
        {
            using var label = FontOf(10 * scale, false);
            var largeBalance = state.WaterBalance > 999;
            if (!largeBalance)
                Text(g, "SUPPLY", label, Muted, new RectangleF(305 * scale, 50 * scale, 41 * scale, 17 * scale), StringAlignment.Near);
            var amountLeft = largeBalance ? 307 : 346;
            DrawWaterAmount(g, state.WaterKnown ? state.WaterBalance : null, small, Pale,
                new RectangleF(amountLeft * scale, 49 * scale, (391 - amountLeft) * scale, 19 * scale), scale);
        }
        g.Restore(saved);
    }

    internal static string Footer(Snapshot state)
    {
        if (state.Status == "armed")
        {
            var marker = state.StatusMessage.IndexOf(" ARMED FOR ", StringComparison.Ordinal);
            var map = marker >= 0 ? state.StatusMessage[(marker + 11)..] : state.IntentMapId.Replace('_', ' ').ToUpperInvariant();
            return "ARMED FOR " + map;
        }
        if (state.Status == "processing") return "PREPARING YOUR NEXT DEPLOYMENT";
        if (state.Status == "uncertain") return "PREPARATION PAUSED";
        if (!state.MapKnown) return "SELECT A SECTOR";
        if (!state.ExactHub || state.Status == "blocked") return "PREPARATION UNAVAILABLE";
        if (state.Status == "insufficient") return "NOT ENOUGH WATER";
        if (state.Mode == "off") return "STANDARD DAY / NIGHT ODDS";
        var name = state.Mode == "nighttime" ? "NIGHT" : "DAY";
        return string.Create(CultureInfo.InvariantCulture,
            $"{name} CHANCE {state.ProbabilityBefore * 100:0.#}% > {state.ProbabilityAfter * 100:0.#}%");
    }

    private static void DrawArrow(Graphics g, Rectangle rect, bool left, bool enabled, bool hover, float scale)
    {
        using var fill = new SolidBrush(Color.FromArgb(enabled && hover ? 67 : 42, enabled && hover ? 79 : 52, enabled && hover ? 70 : 48));
        using var outline = new Pen(enabled ? Color.FromArgb(161, 176, 158) : Color.FromArgb(85, 98, 87), Math.Max(1, scale));
        g.FillRectangle(fill, rect); g.DrawRectangle(outline, rect);
        var center = new PointF(rect.Left + rect.Width / 2f, rect.Top + rect.Height / 2f);
        var direction = left ? -1 : 1;
        using var arrow = new Pen(enabled ? Pale : Muted, Math.Max(1, 1.5f * scale));
        g.DrawLines(arrow, new[] {
            new PointF(center.X - direction * 2 * scale, center.Y - 5 * scale),
            new PointF(center.X + direction * 3 * scale, center.Y),
            new PointF(center.X - direction * 2 * scale, center.Y + 5 * scale) });
    }

    private static void DrawPrepare(Graphics g, Rectangle rect, Snapshot state, Font font, bool hover, float scale)
    {
        var enabled = state.CommandEnabled;
        var armed = state.Status == "armed";
        var fill = enabled ? (hover ? Color.FromArgb(255, 109, 57) : Orange)
            : armed ? Color.FromArgb(70, 89, 65) : Color.FromArgb(45, 54, 48);
        var ink = enabled ? Dark : armed ? Pale : Muted;
        using var background = new SolidBrush(fill);
        using var border = new Pen(enabled ? Color.FromArgb(247, 149, 100) : Color.FromArgb(129, 145, 122), Math.Max(1, scale));
        g.FillRectangle(background, rect); g.DrawRectangle(border, rect);
        var label = state.Status switch {
            "armed" => "ARMED", "processing" => "PREPARING", "uncertain" => "PAUSED",
            "insufficient" => "LOW WATER", "off" => "OFF", _ => enabled ? "PREPARE" : "UNAVAILABLE"
        };
        if (state.WaterCost > 0 && state.Status is "ready" or "insufficient")
        {
            Text(g, label, font, ink, new RectangleF(rect.Left + 8 * scale, rect.Top,
                rect.Width - 52 * scale, rect.Height), StringAlignment.Near);
            DrawWaterAmount(g, state.WaterCost, font, ink,
                new RectangleF(rect.Right - 45 * scale, rect.Top + 6 * scale, 39 * scale, 24 * scale), scale);
        }
        else Text(g, label, font, ink, rect);
    }

    private static void DrawWaterAmount(Graphics g, int? amount, Font font, Color ink, RectangleF rect, float scale)
    {
        var iconSide = Math.Min(rect.Height, 23 * scale);
        var iconRect = new RectangleF(rect.Right - iconSide, rect.Top + (rect.Height - iconSide) / 2f, iconSide, iconSide);
        Text(g, amount?.ToString(CultureInfo.InvariantCulture) ?? "--", font, ink,
            new RectangleF(rect.Left, rect.Top, rect.Width - iconSide - scale, rect.Height), StringAlignment.Far);
        DrawWaterIcon(g, iconRect, ink);
    }

    private static void DrawWaterIcon(Graphics g, RectangleF target, Color color)
    {
        var icon = NativeWaterIcon.Value;
        if (icon is null) return; // Embedded resource presence is required by self-test/package validation.
        using var attributes = new ImageAttributes();
        attributes.SetColorMatrix(new ColorMatrix(new[] {
            new[] { color.R / 255f, 0, 0, 0, 0 }, new[] { 0, color.G / 255f, 0, 0, 0 },
            new[] { 0, 0, color.B / 255f, 0, 0 }, new[] { 0, 0, 0, 1f, 0 }, new[] { 0, 0, 0, 0, 1f } }));
        g.DrawImage(icon, Rectangle.Round(target), 0, 0, icon.Width, icon.Height, GraphicsUnit.Pixel, attributes);
    }

    private static Bitmap? LoadNativeWaterIcon()
    {
        using var stream = typeof(Renderer).Assembly.GetManifestResourceStream("WaterDaytimePreparationOverlay.WaterCurrency.png");
        if (stream is null) return null;
        using var bitmap = new Bitmap(stream);
        return new Bitmap(bitmap);
    }

    private static Font FontOf(float size, bool bold) => new("Consolas", Math.Max(7, size),
        bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);

    private static void Text(Graphics g, string text, Font font, Color color, RectangleF rect,
        StringAlignment align = StringAlignment.Center)
    {
        using var brush = new SolidBrush(color);
        using var format = new StringFormat(StringFormatFlags.NoWrap) { Alignment = align,
            LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter };
        g.DrawString(text, font, brush, rect, format);
    }
}
