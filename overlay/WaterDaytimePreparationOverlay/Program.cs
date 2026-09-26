using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;

namespace WaterDaytimePreparationOverlay;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var options = Options.Parse(args);
        if (options.SelfTest)
        {
            SelfTest.Run();
            return;
        }
        if (options.Preview is not null)
        {
            var snapshot = Snapshot.Preview();
            if (File.Exists(options.StatePath) && Snapshot.TryParse(File.ReadAllText(options.StatePath), out var parsed))
                snapshot = parsed;
            var size = options.PreviewSize ?? new Size(400, 70);
            using var bitmap = new Bitmap(size.Width, size.Height);
            using var graphics = Graphics.FromImage(bitmap);
            graphics.Clear(Color.FromArgb(62, 58, 52));
            Renderer.Draw(graphics, new Rectangle(Point.Empty, size), snapshot, Hit.None);
            bitmap.Save(options.Preview);
            return;
        }
        using var mutex = new Mutex(true, "WaterDaytimePreparationOverlay.v1", out var owns);
        if (!owns) return;
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.Run(new OverlayForm(options));
    }
}

internal sealed record Options(string StatePath, string CommandPath, string? Preview,
    Size? PreviewSize, bool SelfTest)
{
    public static Options Parse(string[] args)
    {
        string? state = null, command = null, preview = null;
        Size? size = null;
        var selfTest = false;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i].Equals("--state", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) state = args[++i];
            else if (args[i].Equals("--command", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) command = args[++i];
            else if (args[i].Equals("--preview", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) preview = args[++i];
            else if (args[i].Equals("--size", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                var parts = args[++i].Split('x');
                if (parts.Length == 2) size = new Size(int.Parse(parts[0]), int.Parse(parts[1]));
            }
            else if (args[i].Equals("--self-test", StringComparison.OrdinalIgnoreCase)) selfTest = true;
        }
        var root = Path.Combine(ResolveLocalApplicationData(),
            "ForeverWinter", "Saved", "Water4", "v1", "WaterDaytimePreparation");
        state ??= Path.Combine(root, "presentation-v1.txt");
        command ??= Path.Combine(root, "command-v1.txt");
        return new Options(Path.GetFullPath(state), Path.GetFullPath(command),
            preview is null ? null : Path.GetFullPath(preview), size, selfTest);
    }

    internal static string ResolveLocalApplicationData()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(local)) local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (string.IsNullOrWhiteSpace(local) || !Path.IsPathFullyQualified(local))
            throw new InvalidOperationException("LocalApplicationData is unavailable");
        return Path.GetFullPath(local);
    }
}

internal sealed record Snapshot(int Revision, string SessionId, bool ReadyRoomVisible,
    bool ExactHub, bool MapKnown, string MapId, string MapName, string SpawnName,
    string Tier, string Mode, bool WaterKnown, int WaterBalance, int WaterCost,
    double ProbabilityBefore, double ProbabilityAfter, int Multiplier,
    bool CommandEnabled, bool ControlsEnabled, string Status, string StatusMessage,
    string IntentStage, string IntentMapId, string IntentMode)
{
    public static Snapshot Waiting() => new(0, "", false, false, false, "", "SELECT A SECTOR", "",
        "", "off", false, 0, 0, 0, 0, 4, false, false, "hidden", "READY ROOM CLOSED", "none", "", "");

    public static Snapshot Preview() => new(12, "wdp-preview", true, true, true,
        "scorched_enclave", "Scorched Enclave", "Point1", "A", "nighttime", true,
        64, 2, 1d / 6d, 4d / 9d, 4, true, true, "ready",
        "ONE-USE INFLUENCE READY TO ARM", "consumed", "scorched_enclave", "nighttime");

    public static bool TryParse(string payload, out Snapshot snapshot)
    {
        snapshot = Waiting();
        if (payload.Length > 32768) return false;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in payload.Replace("\r", "").Split('\n'))
        {
            var index = line.IndexOf('=');
            if (index < 1) continue;
            var key = line[..index];
            if (!values.TryAdd(key, Decode(line[(index + 1)..]))) return false;
        }
        if (!Get(values, "format").Equals("wdp.presentation.v1", StringComparison.Ordinal)
            || Get(values, "complete") != "1") return false;
        if (!Int(values, "revision", 1, out var revision)) return false;
        var session = Get(values, "session_id");
        if (session.Length is 0 or > 128) return false;
        if (!Int(values, "water_balance", 0, out var water)
            || !Int(values, "water_cost", 0, out var cost)
            || !Int(values, "multiplier", 1, out var multiplier)) return false;
        if (!Double(values, "probability_before", out var before)
            || !Double(values, "probability_after", out var after)) return false;
        var mode = Get(values, "mode");
        if (mode is not ("off" or "nighttime" or "daytime")) return false;
        snapshot = new Snapshot(revision, session, Bool(values, "ready_room_visible"),
            Bool(values, "exact_hub"), Bool(values, "map_known"), Get(values, "map_id"),
            Get(values, "map_name"), Get(values, "spawn_name"), Get(values, "tier"), mode,
            Bool(values, "water_known"), water, cost, before, after, multiplier,
            Bool(values, "command_enabled"), Bool(values, "controls_enabled"),
            Get(values, "status"), Get(values, "status_message"), Get(values, "intent_stage"),
            Get(values, "intent_map_id"), Get(values, "intent_mode"));
        return true;
    }

    private static string Get(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? value : "";
    private static bool Bool(Dictionary<string, string> values, string key) => Get(values, key) == "1";
    private static bool Int(Dictionary<string, string> values, string key, int minimum, out int result) =>
        int.TryParse(Get(values, key), NumberStyles.Integer, CultureInfo.InvariantCulture, out result) && result >= minimum;
    private static bool Double(Dictionary<string, string> values, string key, out double result) =>
        double.TryParse(Get(values, key), NumberStyles.Float, CultureInfo.InvariantCulture, out result)
        && double.IsFinite(result) && result >= 0 && result <= 1;
    private static string Decode(string value) => value.Replace("%0A", "\n").Replace("%0D", "\r")
        .Replace("%3D", "=").Replace("%25", "%");
}

internal enum Hit { None, Left, Right, Prepare }

internal readonly record struct WindowUpdatePlan(bool Show, bool Hide, bool Position);

internal static class WindowUpdatePolicy
{
    // Form.Opacity below1 retains WinForms' layered-window path. Alpha254
    // keeps the approved opaque artwork visually the same to within1/255.
    internal const double LayeredOpacity = 254d / 255d;
    internal static WindowUpdatePlan Plan(bool visible, Rectangle current, bool shouldShow, Rectangle target)
    {
        shouldShow = shouldShow && target.Width > 0 && target.Height > 0;
        if (!shouldShow) return new(false, visible, false);
        return new(!visible, false, !visible || current != target);
    }
    internal static bool CanReuseWindow(bool exists, uint cachedProcessId, uint observedProcessId) =>
        exists && cachedProcessId != 0 && cachedProcessId == observedProcessId;
}

internal sealed class OverlayForm : Form
{
    private readonly Options _options;
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 100 };
    private Snapshot _snapshot = Snapshot.Waiting();
    private string _lastPayload = "";
    private IntPtr _gameWindow;
    private uint _gameProcessId;
    private Hit _hover;
    private int _commandSequence;
    private string _commandSession = "";
    private readonly CompanionDiagnostics _diagnostics;

    public OverlayForm(Options options)
    {
        _options = options;
        _diagnostics = new CompanionDiagnostics(options.StatePath);
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.Black;
        Opacity = WindowUpdatePolicy.LayeredOpacity;
        DoubleBuffered = true;
        _timer.Tick += (_, _) => Poll();
        _timer.Start();
        MouseMove += (_, e) => { var hit = HitAt(e.Location); if (hit != _hover) { _hover = hit; Invalidate(); } };
        MouseLeave += (_, _) => { _hover = Hit.None; Invalidate(); };
        MouseDown += (_, e) => { if (e.Button == MouseButtons.Left) Dispatch(HitAt(e.Location)); };
    }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080; return cp; }
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        var started = Stopwatch.GetTimestamp();
        try { Renderer.Draw(e.Graphics, ClientRectangle, _snapshot, _hover); }
        finally { _diagnostics.Paint(Stopwatch.GetElapsedTime(started).TotalMilliseconds); }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _timer.Stop();
        _diagnostics.Close();
        base.OnFormClosed(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _timer.Stop();
            _timer.Dispose();
            _diagnostics.Close();
        }
        base.Dispose(disposing);
    }

    private void Poll()
    {
        var started = Stopwatch.GetTimestamp();
        try { PollCore(); }
        finally { _diagnostics.Poll(Stopwatch.GetElapsedTime(started).TotalMilliseconds, Visible); }
    }

    private void PollCore()
    {
        if (!GameWindowCacheValid())
        {
            _diagnostics.Discovery();
            _gameWindow = FindGameWindow(out _gameProcessId);
        }
        if (_gameWindow == IntPtr.Zero)
        {
            Hide();
            Close();
            return;
        }
        var game = GameClientBounds(_gameWindow);
        Snapshot? next = null;
        try
        {
            if (File.Exists(_options.StatePath))
            {
                using var stream = new FileStream(_options.StatePath, FileMode.Open, FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream, Encoding.UTF8, true);
                var payload = reader.ReadToEnd();
                if (payload != _lastPayload && Snapshot.TryParse(payload, out var parsed))
                {
                    _lastPayload = payload; next = parsed;
                }
            }
        }
        catch { }
        if (next is not null)
        {
            if (!next.SessionId.Equals(_commandSession, StringComparison.Ordinal))
            {
                _commandSession = next.SessionId;
                _commandSequence = ReadCommandSequence(_options.CommandPath, _commandSession);
            }
            _snapshot = next; Invalidate();
        }
        var foreground = GetForegroundWindow();
        var shouldShow = _gameWindow != IntPtr.Zero && !game.IsEmpty && _snapshot.ReadyRoomVisible
            && (foreground == _gameWindow || foreground == Handle);
        var bounds = shouldShow ? WaterDaytimePreparationOverlay.Layout.BoundsFor(game) : Rectangle.Empty;
        var update = WindowUpdatePolicy.Plan(Visible, Bounds, shouldShow, bounds);
        if (update.Hide)
        {
            Hide();
            _diagnostics.Transition("hidden", Bounds);
        }
        if (!update.Position) return;
        if (Bounds != bounds) Bounds = bounds;
        if (update.Show) Show();
        var positioned = SetWindowPos(Handle, new IntPtr(-1), bounds.X, bounds.Y, bounds.Width, bounds.Height,
            0x0010 | 0x0040);
        _diagnostics.Position(positioned);
        _diagnostics.Transition(update.Show ? "shown" : "moved_or_resized", bounds);
    }

    private Hit HitAt(Point point)
    {
        var hits = WaterDaytimePreparationOverlay.Layout.Hits(ClientRectangle);
        if (hits.Left.Contains(point)) return Hit.Left;
        if (hits.Right.Contains(point)) return Hit.Right;
        if (hits.Prepare.Contains(point)) return Hit.Prepare;
        return Hit.None;
    }

    private void Dispatch(Hit hit)
    {
        var command = hit switch { Hit.Left => "cycle_left", Hit.Right => "cycle_right", Hit.Prepare => "prepare", _ => "" };
        if (command.Length == 0) return;
        if ((hit == Hit.Prepare && !_snapshot.CommandEnabled) || (hit != Hit.Prepare && !_snapshot.ControlsEnabled)) return;
        _commandSequence++;
        var payload = string.Join('\n', new[] {
            "format=wdp.command.v1", $"session_id={Encode(_snapshot.SessionId)}", $"sequence={_commandSequence}",
            $"command={command}", $"expected_revision={_snapshot.Revision}",
            $"expected_map_id={_snapshot.MapId}", $"expected_mode={_snapshot.Mode}",
            $"expected_cost={_snapshot.WaterCost}", $"expected_water={_snapshot.WaterBalance}",
            "complete=1", ""
        });
        AtomicWrite(_options.CommandPath, payload);
    }

    private static void AtomicWrite(string path, string payload)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp." + Environment.ProcessId;
        using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
        { writer.Write(payload); writer.Flush(); stream.Flush(true); }
        File.Move(temporary, path, true);
    }
    private static int ReadCommandSequence(string path, string session)
    {
        try
        {
            if (!File.Exists(path)) return 0;
            var values = File.ReadAllLines(path)
                .Select(line => line.Split('=', 2))
                .Where(parts => parts.Length == 2)
                .ToDictionary(parts => parts[0], parts => parts[1], StringComparer.Ordinal);
            if (values.GetValueOrDefault("format") != "wdp.command.v1"
                || values.GetValueOrDefault("session_id") != Encode(session)
                || values.GetValueOrDefault("complete") != "1") return 0;
            return int.TryParse(values.GetValueOrDefault("sequence"), out var sequence)
                && sequence > 0 ? sequence : 0;
        }
        catch { return 0; }
    }
    private static string Encode(string value) => value.Replace("%", "%25").Replace("=", "%3D").Replace("\r", "%0D").Replace("\n", "%0A");

    private bool GameWindowCacheValid()
    {
        if (_gameWindow == IntPtr.Zero || !IsWindow(_gameWindow)) return false;
        GetWindowThreadProcessId(_gameWindow, out var owner);
        return WindowUpdatePolicy.CanReuseWindow(true, _gameProcessId, owner);
    }

    private static IntPtr FindGameWindow(out uint owner)
    {
        owner = 0;
        foreach (var name in new[] { "ForeverWinter-Win64-Shipping", "ForeverWinter" })
        {
            var processes = Process.GetProcessesByName(name);
            try
            {
                foreach (var process in processes)
                {
                    try
                    {
                        var window = process.MainWindowHandle;
                        if (window != IntPtr.Zero)
                        {
                            GetWindowThreadProcessId(window, out var windowOwner);
                            if (windowOwner == (uint)process.Id)
                            {
                                owner = windowOwner;
                                return window;
                            }
                        }
                    }
                    catch (InvalidOperationException) { }
                }
            }
            finally { foreach (var process in processes) process.Dispose(); }
        }
        return IntPtr.Zero;
    }
    private static Rectangle GameClientBounds(IntPtr window)
    {
        if (window == IntPtr.Zero || !GetClientRect(window, out var rect)) return Rectangle.Empty;
        var point = new NativePoint();
        if (!ClientToScreen(window, ref point)) return Rectangle.Empty;
        return new Rectangle(point.X, point.Y, rect.Right - rect.Left, rect.Bottom - rect.Top);
    }

    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr window, ref NativePoint point);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);
}

internal sealed class CompanionDiagnostics
{
    private readonly Channel<string> _lines = Channel.CreateBounded<string>(new BoundedChannelOptions(32)
        { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.DropWrite });
    private readonly Process _process = Process.GetCurrentProcess();
    private readonly Stopwatch _elapsed = Stopwatch.StartNew();
    private double _lastReportSeconds, _lastCpuSeconds;
    private long _polls, _paints, _positions, _positionFailures, _discoveries;
    private double _pollMilliseconds, _paintMilliseconds, _maxPollMilliseconds, _maxPaintMilliseconds;
    private int _lineCount;
    private bool _closed;

    internal CompanionDiagnostics(string statePath)
    {
        var path = Path.Combine(Path.GetDirectoryName(statePath)!,
            "companion-" + Environment.ProcessId.ToString(CultureInfo.InvariantCulture) + ".log");
        _ = Task.Run(async () =>
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                await using var stream = new FileStream(path, FileMode.Create, FileAccess.Write,
                    FileShare.ReadWrite | FileShare.Delete, 4096, true);
                await using var writer = new StreamWriter(stream, new UTF8Encoding(false));
                await foreach (var line in _lines.Reader.ReadAllAsync())
                {
                    await writer.WriteLineAsync(line);
                    await writer.FlushAsync();
                }
            }
            catch { /* Diagnostics must never block or fail the companion. */ }
        });
        _lastCpuSeconds = CpuSeconds();
        Write("START version=0.2.4 poll_ms=100 layered_alpha=254 idle_positioning=false cached_game_window=true " +
            "diagnostics_interval_seconds=30 diagnostics_max_lines=512 log_io=background renderer=v0.2.3_unchanged");
    }

    internal void Paint(double milliseconds)
    {
        _paints++; _paintMilliseconds += milliseconds; _maxPaintMilliseconds = Math.Max(_maxPaintMilliseconds, milliseconds);
    }
    internal void Discovery() => _discoveries++;
    internal void Position(bool success) { _positions++; if (!success) _positionFailures++; }
    internal void Transition(string state, Rectangle bounds) => Write(string.Create(CultureInfo.InvariantCulture,
        $"SURFACE state={state} x={bounds.X} y={bounds.Y} width={bounds.Width} height={bounds.Height}"));
    internal void Poll(double milliseconds, bool visible)
    {
        if (_closed) return;
        _polls++; _pollMilliseconds += milliseconds; _maxPollMilliseconds = Math.Max(_maxPollMilliseconds, milliseconds);
        if (_elapsed.Elapsed.TotalSeconds - _lastReportSeconds >= 30) Report("interval", visible);
    }
    internal void Close()
    {
        if (_closed) return;
        Report("closed", false);
        _closed = true;
        _lines.Writer.TryComplete();
        _process.Dispose();
        // No synchronous wait for diagnostics I/O during window/game teardown.
    }
    private double CpuSeconds()
    {
        try { return _process.TotalProcessorTime.TotalSeconds; }
        catch { return _lastCpuSeconds; }
    }
    private void Report(string reason, bool visible)
    {
        var now = _elapsed.Elapsed.TotalSeconds;
        var seconds = Math.Max(.001, now - _lastReportSeconds);
        var cpu = CpuSeconds();
        Write(string.Create(CultureInfo.InvariantCulture,
            $"PERFORMANCE reason={reason} interval_seconds={seconds:0.000} visible={visible} polls={_polls} paints={_paints} " +
            $"positions={_positions} position_failures={_positionFailures} discoveries={_discoveries} " +
            $"poll_mean_ms={(_polls == 0 ? 0 : _pollMilliseconds / _polls):0.000} poll_max_ms={_maxPollMilliseconds:0.000} " +
            $"paint_mean_ms={(_paints == 0 ? 0 : _paintMilliseconds / _paints):0.000} paint_max_ms={_maxPaintMilliseconds:0.000} " +
            $"cpu_seconds={Math.Max(0, cpu - _lastCpuSeconds):0.000} cpu_one_core_percent={Math.Max(0, cpu - _lastCpuSeconds) / seconds * 100:0.00}"));
        _lastReportSeconds = now; _lastCpuSeconds = cpu;
        _polls = _paints = _positions = _positionFailures = _discoveries = 0;
        _pollMilliseconds = _paintMilliseconds = _maxPollMilliseconds = _maxPaintMilliseconds = 0;
    }
    private void Write(string message)
    {
        if (_closed || _lineCount >= 512) return;
        _lineCount++;
        _lines.Writer.TryWrite(DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture) + " " + message);
    }
}

internal static class SelfTest
{
    public static void Run()
    {
        var local = Options.ResolveLocalApplicationData();
        var expectedRoot = Path.Combine(local, "ForeverWinter", "Saved", "Water4", "v1",
            "WaterDaytimePreparation");
        var defaults = Options.Parse(Array.Empty<string>());
        if (!defaults.StatePath.StartsWith(expectedRoot, StringComparison.OrdinalIgnoreCase) ||
            defaults.StatePath.Contains("ChatGPT", StringComparison.OrdinalIgnoreCase) ||
            defaults.StatePath.Contains("My Documents", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"portable_default_state_path_self_test_failed expected={expectedRoot} actual={defaults.StatePath}");
        var fixtureRoot = Path.Combine(Path.GetTempPath(), $"WaterDaytimeOptions-{Guid.NewGuid():N}");
        var state = Path.Combine(fixtureRoot, "state.txt");
        var command = Path.Combine(fixtureRoot, "command.txt");
        var explicitOptions = Options.Parse(new[] { "--state", state, "--command", command });
        if (explicitOptions.StatePath != Path.GetFullPath(state) ||
            explicitOptions.CommandPath != Path.GetFullPath(command))
            throw new InvalidOperationException("explicit_path_precedence_self_test_failed");

        var valid = string.Join('\n', new[] {
            "format=wdp.presentation.v1", "revision=7", "session_id=test", "ready_room_visible=1",
            "exact_hub=1", "map_known=1", "map_id=scrapyard_nexus", "map_name=Scrapyard Nexus",
            "spawn_name=Point1", "tier=B", "mode=nighttime", "water_known=1", "water_balance=64",
            "water_cost=2", "probability_before=0.583333", "probability_after=0.848485", "multiplier=4",
            "command_enabled=1", "controls_enabled=1", "status=ready", "status_message=READY",
            "intent_stage=consumed", "intent_map_id=scorched_enclave", "intent_mode=nighttime",
            "last_reason=test", "complete=1", ""
        });
        if (!Snapshot.TryParse(valid, out var parsed) || parsed.WaterCost != 2 || parsed.Tier != "B")
            throw new InvalidOperationException("valid snapshot rejected");
        if (Snapshot.TryParse(valid.Replace("complete=1", "complete=0"), out _))
            throw new InvalidOperationException("incomplete snapshot accepted");
        PresentationSelfTest.Run();
        WindowPlanningSelfTest.Run();
        Console.WriteLine("WaterDaytimePreparationOverlay v0.2.4 self-test passed");
    }
}
