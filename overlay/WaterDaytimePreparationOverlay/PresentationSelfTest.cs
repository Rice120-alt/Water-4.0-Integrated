using System.Drawing.Imaging;
using System.Security.Cryptography;
using System.Text.Json;

namespace WaterDaytimePreparationOverlay;

// Exercise the production layout and renderer at actual client sizes. In
// particular, the old percentage-of-screen placement drifted on ultrawide.
internal static class PresentationSelfTest
{
    private sealed record LayoutCase(string Name, Rectangle Game, Rectangle? ExpectedPanel);
    private sealed record StateCase(string Name, Snapshot Snapshot);

    public static void Run()
    {
        var cases = new[]
        {
            new LayoutCase("1280x720", new Rectangle(0, 0, 1280, 720), new Rectangle(506, 626, 267, 47)),
            new LayoutCase("1920x1080", new Rectangle(0, 0, 1920, 1080), new Rectangle(760, 940, 400, 70)),
            new LayoutCase("2560x1440", new Rectangle(0, 0, 2560, 1440), new Rectangle(1013, 1253, 533, 93)),
            new LayoutCase("3440x1440", new Rectangle(0, 0, 3440, 1440), new Rectangle(1453, 1253, 533, 93)),
            new LayoutCase("5120x1440", new Rectangle(0, 0, 5120, 1440), new Rectangle(2293, 1253, 533, 93)),
            new LayoutCase("3840x2160", new Rectangle(0, 0, 3840, 2160), new Rectangle(1520, 1880, 800, 140)),
            new LayoutCase("3840x1080", new Rectangle(0, 0, 3840, 1080), new Rectangle(1720, 940, 400, 70)),
            new LayoutCase("1920x1200", new Rectangle(0, 0, 1920, 1200), null),
            new LayoutCase("negative-origin", new Rectangle(-2600, -300, 2560, 1440), new Rectangle(-1587, 953, 533, 93)),
        };
        var output = Path.GetFullPath(Path.Combine("work", "daytime-presentation-v023", "previews"));
        Directory.CreateDirectory(output);
        var records = new List<object>();
        foreach (var test in cases)
        {
            var panel = Layout.BoundsFor(test.Game);
            var card = Layout.NativeMapCardFor(test.Game);
            Require(test.Game.Contains(panel) && test.Game.Contains(card), test.Name + ": outside game client");
            Require(panel.Width > 0 && panel.Height > 0 && card.Width > 0 && card.Height > 0,
                test.Name + ": nonpositive surface");
            Require(Math.Abs(2L * panel.Left + panel.Width - (2L * test.Game.Left + test.Game.Width)) <= 1,
                test.Name + ": strip is not horizontally centered");
            Require(panel.Left == card.Left && panel.Width == card.Width,
                test.Name + ": strip does not share native card edges");
            var minimumGap = (int)Math.Ceiling(8d * Math.Min(test.Game.Width / 1920d, test.Game.Height / 1080d));
            Require(card.Top - panel.Bottom == minimumGap && !panel.IntersectsWith(card),
                test.Name + ": strip overlaps or drifts from native map card");
            if (test.ExpectedPanel.HasValue)
                Require(panel == test.ExpectedPanel.Value, test.Name + ": unexpected authored bounds " + panel);

            var client = new Rectangle(Point.Empty, panel.Size);
            var hits = Layout.Hits(client);
            foreach (var hit in new[] { hits.Left, hits.Right, hits.Prepare })
                Require(hit.Width > 0 && hit.Height > 0 && client.Contains(hit),
                    test.Name + ": clipped or empty click target");
            Require(hits.Left.Right < hits.Right.Left && hits.Right.Right < hits.Prepare.Left &&
                !hits.Left.IntersectsWith(hits.Prepare), test.Name + ": click targets overlap or selector has no room");
            records.Add(new { test.Name, Game = Rect(test.Game), Panel = Rect(panel), NativeMapCard = Rect(card),
                Gap = card.Top - panel.Bottom, Left = Rect(hits.Left), Right = Rect(hits.Right), Prepare = Rect(hits.Prepare) });

            // This neutral composition is geometry evidence, not a screenshot
            // or a claim about the actual native Ready Room's appearance.
            using var composed = new Bitmap(test.Game.Width, test.Game.Height);
            using var graphics = Graphics.FromImage(composed);
            graphics.Clear(Color.FromArgb(35, 37, 35));
            var localPanel = new Rectangle(panel.Left - test.Game.Left, panel.Top - test.Game.Top, panel.Width, panel.Height);
            var localCard = new Rectangle(card.Left - test.Game.Left, card.Top - test.Game.Top, card.Width, card.Height);
            using var cardFill = new SolidBrush(Color.FromArgb(62, 65, 59));
            using var cardOutline = new Pen(Color.FromArgb(180, 184, 173));
            graphics.FillRectangle(cardFill, localCard);
            graphics.DrawRectangle(cardOutline, localCard);
            using var captionFont = new Font("Segoe UI", Math.Max(9f, card.Height * .19f), FontStyle.Regular, GraphicsUnit.Pixel);
            using var captionBrush = new SolidBrush(Color.FromArgb(223, 226, 215));
            graphics.DrawString("NATIVE MAP CARD · GEOMETRY REFERENCE", captionFont, captionBrush, localCard.Left + 6, localCard.Top + 5);
            var transform = graphics.Save();
            graphics.TranslateTransform(localPanel.Left, localPanel.Top);
            Renderer.Draw(graphics, client, Snapshot.Preview(), Hit.None);
            graphics.Restore(transform);
            composed.Save(Path.Combine(output, "layout-" + test.Name + ".png"), ImageFormat.Png);
        }
        Require(Layout.BoundsFor(cases[2].Game).Size == Layout.BoundsFor(cases[3].Game).Size &&
            Layout.BoundsFor(cases[3].Game).Size == Layout.BoundsFor(cases[4].Game).Size,
            "ultrawide expanded the strip despite unchanged vertical resolution");
        Require(Layout.BoundsFor(cases[1].Game).Size == Layout.BoundsFor(cases[6].Game).Size,
            "double-width 1080p expanded the strip");
        Require(Renderer.NativeWaterIconAvailable, "embedded current-build native WaterBarrels icon missing");
        using (var icon = typeof(Renderer).Assembly.GetManifestResourceStream("WaterDaytimePreparationOverlay.WaterCurrency.png"))
        {
            Require(icon is not null && Convert.ToHexString(SHA256.HashData(icon)) ==
                "BCB6D8D2527538BB6AA51EC66ABB4A3C29F9223A0223A46C9CBDF05DCC5F9AC5",
                "embedded Water icon differs from the current-build source PNG");
        }

        var ready = Snapshot.Preview() with { MapId = "underground_cemetery", MapName = "Underground Cemetery",
            IntentMapId = "underground_cemetery", Tier = "D", WaterBalance = 64000, WaterCost = 4 };
        var states = new[]
        {
            new StateCase("off", ready with { Mode = "off", Status = "off", CommandEnabled = false, WaterCost = 0 }),
            new StateCase("nighttime", ready),
            new StateCase("daytime", ready with { Mode = "daytime", WaterCost = 3, ProbabilityBefore = 5d / 6d, ProbabilityAfter = 20d / 21d }),
            new StateCase("armed", ready with { Status = "armed", IntentStage = "armed", ControlsEnabled = false, CommandEnabled = false,
                StatusMessage = "NIGHTTIME ARMED FOR UNDERGROUND CEMETERY" }),
            new StateCase("insufficient", ready with { Status = "insufficient", WaterBalance = 1, CommandEnabled = false }),
            new StateCase("processing", ready with { Status = "processing", ControlsEnabled = false, CommandEnabled = false }),
            new StateCase("blocked", ready with { Status = "blocked", ControlsEnabled = false, CommandEnabled = false,
                StatusMessage = "Saved preparation state could not be verified" }),
            new StateCase("uncertain", ready with { Status = "uncertain", IntentStage = "debit_dispatched", ControlsEnabled = false,
                CommandEnabled = false, StatusMessage = "Payment result is uncertain; preserve logs for review" }),
        };
        var sampleWidths = new[] { 1280, 1920, 5120 };
        var sampleHeights = new[] { 720, 1080, 1440 };
        using var contact = new Bitmap(1260, states.Length * 128 + 36);
        using var contactGraphics = Graphics.FromImage(contact);
        contactGraphics.Clear(Color.FromArgb(60, 62, 59));
        using var labelFont = new Font("Segoe UI", 12f, FontStyle.Regular, GraphicsUnit.Pixel);
        using var labelBrush = new SolidBrush(Color.WhiteSmoke);
        var columnLeft = new[] { 12, 294, 709 };
        for (var column = 0; column < sampleWidths.Length; column++)
        {
            var client = new Rectangle(Point.Empty, Layout.BoundsFor(new Rectangle(0, 0, sampleWidths[column], sampleHeights[column])).Size);
            contactGraphics.DrawString(sampleWidths[column] + "×" + sampleHeights[column] + " · actual strip pixels", labelFont, labelBrush, columnLeft[column], 6);
            for (var row = 0; row < states.Length; row++)
            {
                var state = states[row];
                using var bitmap = new Bitmap(client.Width, client.Height);
                using var graphics = Graphics.FromImage(bitmap);
                graphics.Clear(Color.FromArgb(61, 64, 59));
                Renderer.Draw(graphics, client, state.Snapshot, state.Snapshot.CommandEnabled ? Hit.Prepare : Hit.None);
                bitmap.Save(Path.Combine(output, "state-" + state.Name + "-" + sampleWidths[column] + "x" + sampleHeights[column] + ".png"), ImageFormat.Png);
                contactGraphics.DrawString(state.Name, labelFont, labelBrush, columnLeft[column], 34 + row * 128);
                contactGraphics.DrawImageUnscaled(bitmap, columnLeft[column], 52 + row * 128);
            }
        }
        contact.Save(Path.Combine(output, "states-contact-sheet.png"), ImageFormat.Png);
        File.WriteAllText(Path.Combine(output, "layout-measurements.json"),
            JsonSerializer.Serialize(records, new JsonSerializerOptions { WriteIndented = true }));
        File.WriteAllText(Path.Combine(output, "presentation-self-test.txt"),
            "PASS actual production layout: 9 client rectangles; 24 state renders; centered native-card alignment; " +
            "scaled gap; no overlaps; window-origin translation; ultrawide width stability; embedded native Water icon.\n" +
            "Offline presentation evidence only. Native placement and paid behavior require attended verification.\n");
    }

    private static object Rect(Rectangle rect) => new { rect.X, rect.Y, rect.Width, rect.Height };
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("daytime_presentation: " + message);
    }
}
