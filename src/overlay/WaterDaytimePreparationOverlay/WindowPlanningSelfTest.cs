using System.Runtime.InteropServices;

namespace WaterDaytimePreparationOverlay;

internal static class WindowPlanningSelfTest
{
    public static void Run()
    {
        var current = new Rectangle(2293, 1253, 533, 93);
        var plan = WindowUpdatePolicy.Plan(false, current, true, current);
        Require(plan.Show && plan.Position && !plan.Hide, "first reveal must position and show");
        for (var i = 0; i < 36000; i++)
        {
            plan = WindowUpdatePolicy.Plan(true, current, true, current);
            Require(!plan.Show && !plan.Hide && !plan.Position, "idle polls must not reposition or show");
        }
        var moved = new Rectangle(-1587, 953, 533, 93);
        plan = WindowUpdatePolicy.Plan(true, current, true, moved);
        Require(plan.Position && !plan.Show && !plan.Hide, "window move must position once");
        plan = WindowUpdatePolicy.Plan(true, moved, true, moved);
        Require(!plan.Position, "window move must settle");
        var resized = new Rectangle(760, 940, 400, 70);
        plan = WindowUpdatePolicy.Plan(true, moved, true, resized);
        Require(plan.Position && !plan.Show, "resolution change must position once");
        plan = WindowUpdatePolicy.Plan(true, resized, false, Rectangle.Empty);
        Require(plan.Hide && !plan.Position && !plan.Show, "leaving Ready Room must hide without positioning");
        plan = WindowUpdatePolicy.Plan(false, resized, false, Rectangle.Empty);
        Require(!plan.Hide && !plan.Position && !plan.Show, "hidden idle must remain idle");
        plan = WindowUpdatePolicy.Plan(false, resized, true, resized);
        Require(plan.Show && plan.Position, "return from alt-tab or hidden room must restore once");
        plan = WindowUpdatePolicy.Plan(true, resized, true, Rectangle.Empty);
        Require(plan.Hide && !plan.Position, "invalid viewport must not move a visible strip to zero size");
        Require(WindowUpdatePolicy.LayeredOpacity < 1d && WindowUpdatePolicy.LayeredOpacity > .995d &&
            (int)(WindowUpdatePolicy.LayeredOpacity * 255) == 254,
            "layered window must retain near-opaque alpha254");
        Require(WindowUpdatePolicy.CanReuseWindow(true, 123, 123) &&
            !WindowUpdatePolicy.CanReuseWindow(false, 123, 123) &&
            !WindowUpdatePolicy.CanReuseWindow(true, 123, 124) &&
            !WindowUpdatePolicy.CanReuseWindow(true, 0, 0),
            "cached HWND must remain valid and belong to the original game process");
        // Construct only our own hidden window. Without Show or a message pump,
        // its polling timer cannot run and no game window is discovered.
        var testDirectory = Path.GetFullPath(Path.Combine("work", "daytime-performance-v024", "test-only"));
        var options = new Options(Path.Combine(testDirectory, "nonexistent-state.txt"),
            Path.Combine(testDirectory, "nonexistent-command.txt"), null, null, false);
        using (var form = new OverlayForm(options))
        {
            var handle = form.Handle;
            var style = GetWindowLongPtr(handle, -20).ToInt64();
            Require(!IsWindowVisible(handle), "display-mode self-test must never show its window");
            Require((style & 0x00080000) != 0 && (style & 0x08000000) != 0,
                "actual WinForms window must be layered and no-activate");
            Require(GetLayeredWindowAttributes(handle, out _, out var alpha, out var flags) &&
                alpha == 254 && (flags & 2) != 0, "actual layered window alpha must be254");
        }
        Console.WriteLine("DAYTIME_WINDOW_PLANNING_TESTS_OK idle_polls=36000 idle_positions=0 reveal_move_resize_hide=true " +
            "cached_owner_guard=true actual_hidden_layered_window=true native_alpha=254 no_game_lookup=true");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException("daytime_window_planning: " + message);
    }
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")]
    private static extern bool GetLayeredWindowAttributes(IntPtr window, out uint colorKey, out byte alpha, out uint flags);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
}
