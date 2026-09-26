using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace FWQuestOverlay;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var options = OverlayOptions.Parse(args);
        if (options.SelfTest)
        {
            ContractBoardRotationSelfTest.Run();
            ContractExpansionSelfTest.Run();
            OverlaySelfTest.Run();
            WaterBrokerContentSelfTest.Run();
            return;
        }
        if (options.PreviewPath is not null)
        {
            var preview = options.VendorOnly
                ? QuestSnapshot.Waiting()
                : options.PreviewHub ? QuestSnapshot.Preview() : QuestSnapshot.PreviewRaid();
            if (args.Contains("--state") && File.Exists(options.StatePath) &&
                QuestSnapshot.TryParse(File.ReadAllText(options.StatePath), out var fixture)) preview = fixture;
            var selectArg = Array.IndexOf(args, "--preview-contract");
            if (selectArg >= 0 && selectArg + 1 < args.Length) preview = preview.SelectIndex(int.Parse(args[selectArg + 1]));
            var vendorPreview = options.ContractsOnly
                ? WaterVendorSnapshot.Waiting()
                : WaterVendorSnapshot.Preview();
            if (previewModeIsTrader(args) && File.Exists(options.VendorStatePath) &&
                WaterVendorSnapshot.TryParse(File.ReadAllText(options.VendorStatePath),
                    out var vendorFixture))
                vendorPreview = vendorFixture;
            var previewMode = options.PreviewTrader
                ? OverlayMode.WaterTrader
                : options.PreviewBoard
                    ? OverlayMode.ContractBoard
                    : options.PreviewHub ? OverlayMode.HubLauncher : OverlayMode.RaidTracker;
            var previewSize = previewMode == OverlayMode.HubLauncher
                ? HubLauncherLayout.WindowSize(1f, preview.HasContractBoard,
                    !string.IsNullOrWhiteSpace(vendorPreview.SessionId))
                : OverlayLayout.WindowSize(previewMode, 1f);
            if (previewMode == OverlayMode.RaidTracker) previewSize = QuestPanelLayout.WindowSize(preview);
            var sizeArg = Array.IndexOf(args, "--preview-size");
            if (sizeArg >= 0 && sizeArg + 1 < args.Length)
            {
                var parts = args[sizeArg + 1].Split('x');
                previewSize = new Size(int.Parse(parts[0]), int.Parse(parts[1]));
            }
            using var bitmap = new Bitmap(previewSize.Width, previewSize.Height);
            using var graphics = Graphics.FromImage(bitmap);
            graphics.Clear(Color.FromArgb(73, 69, 60));
            using (var haze = new LinearGradientBrush(
                new Rectangle(Point.Empty, previewSize),
                Color.FromArgb(61, 58, 51), Color.FromArgb(31, 36, 35), 8f))
                graphics.FillRectangle(haze, new Rectangle(Point.Empty, previewSize));
            using var overlayLayer = new Bitmap(previewSize.Width, previewSize.Height,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var overlayGraphics = Graphics.FromImage(overlayLayer))
            {
                overlayGraphics.Clear(Color.Transparent);
                var previewConfirmation = previewMode == OverlayMode.WaterTrader &&
                    vendorPreview.MaximumPurchaseUnits() >= 1
                    ? WaterPurchaseConfirmation.Create(vendorPreview,
                        Math.Min(3, vendorPreview.MaximumPurchaseUnits()))
                    : null;
                OverlayRenderer.Draw(overlayGraphics, previewMode, previewSize, preview, vendorPreview,
                    false, OverlayHitTarget.None, previewConfirmation, false);
            }
            graphics.DrawImageUnscaled(overlayLayer, Point.Empty);
            bitmap.Save(options.PreviewPath, System.Drawing.Imaging.ImageFormat.Png);
            return;
        }

        using var mutex = new Mutex(true, "FWIndependentFrameworkQuestOverlay", out var ownsMutex);
        if (!ownsMutex) return;

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new OverlayForm(options));
    }

    private static bool previewModeIsTrader(string[] args) =>
        args.Any(value => value.Equals("--render-trader-preview",
            StringComparison.OrdinalIgnoreCase));
}

internal sealed record OverlayOptions(string StatePath, string CommandPath,
    string VendorStatePath, string VendorCommandPath, string VendorInputPath, string? PreviewPath,
    bool PreviewHub, bool PreviewBoard, bool PreviewTrader, bool VendorOnly,
    bool ContractsOnly, bool SelfTest)
{
    public static OverlayOptions Parse(string[] args)
    {
        string? state = null;
        string? command = null;
        string? vendorState = null;
        string? vendorCommand = null;
        string? vendorInput = null;
        string? preview = null;
        var previewHub = false;
        var previewBoard = false;
        var previewTrader = false;
        var vendorOnly = false;
        var contractsOnly = false;
        var selfTest = false;
        for (var i = 0; i < args.Length; i++)
        {
            if (args[i].Equals("--state", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                state = args[++i];
            else if (args[i].Equals("--command", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                command = args[++i];
            else if (args[i].Equals("--vendor-state", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                vendorState = args[++i];
            else if (args[i].Equals("--vendor-command", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                vendorCommand = args[++i];
            else if (args[i].Equals("--vendor-input", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                vendorInput = args[++i];
            else if (args[i].Equals("--render-preview", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                preview = args[++i];
            else if (args[i].Equals("--render-hub-preview", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                preview = args[++i];
                previewHub = true;
            }
            else if (args[i].Equals("--render-board-preview", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                preview = args[++i];
                previewHub = true;
                previewBoard = true;
            }
            else if (args[i].Equals("--render-trader-preview", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
            {
                preview = args[++i];
                previewHub = true;
                previewTrader = true;
            }
            else if (args[i].Equals("--self-test", StringComparison.OrdinalIgnoreCase))
                selfTest = true;
            else if (args[i].Equals("--vendor-only", StringComparison.OrdinalIgnoreCase))
                vendorOnly = true;
            else if (args[i].Equals("--contracts-only", StringComparison.OrdinalIgnoreCase))
                contractsOnly = true;
        }

        var root = Path.Combine(
            ResolveLocalApplicationData(),
            "ForeverWinter", "Saved", "Water4", "v1", "FWIndependentFramework");
        state ??= Path.Combine(root, "quest-overlay-v2.txt");
        var statePath = Path.GetFullPath(state);
        var stateIsVendor = IsWaterVendorStatePath(statePath);
        vendorOnly |= stateIsVendor;
        if (vendorOnly && contractsOnly)
            throw new ArgumentException("--vendor-only and --contracts-only are mutually exclusive");
        command ??= Path.Combine(Path.GetDirectoryName(statePath) ?? ".",
            stateIsVendor ? "command-v1.txt" : "quest-command-v1.txt");
        var commandPath = Path.GetFullPath(command);
        vendorState ??= stateIsVendor
            ? statePath
            : Path.Combine(Path.GetDirectoryName(statePath) ?? ".", "water-trader", "overlay-v1.txt");
        var vendorStatePath = Path.GetFullPath(vendorState);
        vendorCommand ??= stateIsVendor ? commandPath
            : Path.Combine(Path.GetDirectoryName(vendorStatePath) ?? ".", "command-v1.txt");
        vendorInput ??= Path.Combine(Path.GetDirectoryName(vendorStatePath) ?? ".",
            "water-broker-input-v1.txt");
        return new OverlayOptions(statePath, commandPath, vendorStatePath,
            Path.GetFullPath(vendorCommand), Path.GetFullPath(vendorInput),
            preview is null ? null : Path.GetFullPath(preview),
            previewHub, previewBoard, previewTrader, vendorOnly, contractsOnly, selfTest);
    }

    internal static string ResolveLocalApplicationData()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(local)) local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (string.IsNullOrWhiteSpace(local) || !Path.IsPathFullyQualified(local))
            throw new InvalidOperationException("LocalApplicationData is unavailable");
        return Path.GetFullPath(local);
    }

    private static bool IsWaterVendorStatePath(string statePath)
    {
        if (Path.GetFileName(statePath).Equals("overlay-v1.txt", StringComparison.OrdinalIgnoreCase) &&
            new DirectoryInfo(Path.GetDirectoryName(statePath) ?? ".").Name.Equals(
                "water-trader", StringComparison.OrdinalIgnoreCase)) return true;
        try
        {
            if (!File.Exists(statePath)) return false;
            using var stream = new FileStream(statePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            return reader.ReadLine() is "format=fwif.water_vendor.overlay.v1" or
                "format=fwif.water_vendor.overlay.v2";
        }
        catch
        {
            return false;
        }
    }
}

internal sealed class OverlayForm : Form
{
    private const int ToggleHotkeyId = 0x4657;
    private const int AcceptHotkeyId = 0x4658;
    private const int DeclineHotkeyId = 0x4659;
    private const int BoardHotkeyId = 0x465A;
    private const int BrokerHotkeyId = 0x465B;
    private const int WmHotkey = 0x0312;
    private const int WmHubEscape = 0x8517;
    private const int WhKeyboardLl = 13;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const uint ModNoRepeat = 0x4000;
    private const uint VkF10 = 0x79;
    private const uint VkF9 = 0x78;
    private const uint VkF8 = 0x77;
    private const uint VkF7 = 0x76;
    private const uint VkF6 = 0x75;
    private static readonly TimeSpan HotkeyDebounce = TimeSpan.FromMilliseconds(350);
    private static readonly TimeSpan StatePollInterval = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan BoardInputHeartbeat = TimeSpan.FromSeconds(1);
    // v0.30.4 performance: when no surface is showing the overlay idles its
    // timer and slows the state-file polling, and the game window handle is
    // cached instead of re-enumerating every process 10x/second.
    private static readonly TimeSpan GameWindowScanInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan IdleStatePollInterval = TimeSpan.FromMilliseconds(500);
    private const int ActiveTickMs = 25;
    private const int IdleTickMs = 200;
    private const int GwlExStyle = -20;

    private readonly OverlayOptions _options;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly string _logPath;
    private bool _logDirectoryReady;
    private readonly string _boardInputPath;
    private readonly string _vendorInputPath;
    private QuestSnapshot _snapshot = QuestSnapshot.Waiting();
    private WaterVendorSnapshot _vendorSnapshot = WaterVendorSnapshot.Waiting();
    private long _lastRevision = -1;
    private long _lastVendorRevision = -1;
    private string _lastVendorSession = "";
    private bool _userHidden;
    private bool _sawGame;
    private bool _reportedVisible;
    private DateTime _started = DateTime.UtcNow;
    private DateTime? _gameMissingSince;
    private IntPtr _gameWindow;
    private Rectangle _lastPlacement = Rectangle.Empty;
    private Rectangle _lastRenderedPlacement = Rectangle.Empty;
    private long _lastRenderedRevision = -1;
    private long _lastRenderedVendorCountdownSecond = long.MinValue;
    private OverlayMode _mode = OverlayMode.Hidden;
    private OverlayMode _lastRenderedMode = OverlayMode.Hidden;
    private OverlayHitTarget _hoveredTarget = OverlayHitTarget.None;
    private bool _visualDirty = true;
    private HubSurface _hubSurface = HubSurface.None;
    private WaterPurchaseConfirmation? _purchaseConfirmation;
    private long? _vendorCommandAwaitingRevision;
    private string _commandSession = "";
    private long _commandSequence;
    private long _boardInputSequence;
    private DateTime _lastBoardInputWriteAt = DateTime.MinValue;
    private long _vendorInputSequence;
    private DateTime _lastVendorInputWriteAt = DateTime.MinValue;
    private DateTime _lastStatePollAt = DateTime.MinValue;
    private DateTime _lastGameWindowScanAt = DateTime.MinValue;
    private DateTime _lastStateWriteUtc = DateTime.MinValue;
    private long _lastStateLength = -1;
    private DateTime _lastVendorWriteUtc = DateTime.MinValue;
    private long _lastVendorLength = -1;
    private Bitmap? _renderBitmap;
    private string _vendorCommandSession = "";
    private long _vendorCommandSequence;
    private readonly Dictionary<int, DateTime> _lastHotkeyAt = new();
    private LowLevelKeyboardProc? _hubKeyboardProc;
    private IntPtr _hubKeyboardHook;
    private bool _hubActionGuardActive;
    private bool _hubEscapeKeyDown;
    private HubSurface _actionGuardSurface;
    private int _actionGuardGeneration;
    private string ActionGuardLabel => _actionGuardSurface == HubSurface.Contracts ? "CONTRACT BOARD" : "WATER BROKER";

    public OverlayForm(OverlayOptions options)
    {
        _options = options;
        _logPath = Path.Combine(Path.GetDirectoryName(options.StatePath) ?? ".", "quest-overlay.log");
        _boardInputPath = Path.Combine(Path.GetDirectoryName(options.StatePath) ?? ".",
            "contract-board-input-v1.txt");
        _vendorInputPath = options.VendorInputPath;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.Black;
        DoubleBuffered = true;
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.Manual;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);

        _timer = new System.Windows.Forms.Timer { Interval = 25 };
        _timer.Tick += (_, _) => TickOverlay();
        _timer.Start();
        Log($"OVERLAY START version=0.30.6 state={options.StatePath} command={options.CommandPath} board_input={_boardInputPath} vendor_state={options.VendorStatePath} vendor_command={options.VendorCommandPath} vendor_input={_vendorInputPath} vendor_only={options.VendorOnly.ToString().ToLowerInvariant()} contracts_only={options.ContractsOnly.ToString().ToLowerInvariant()} hotkeys=F6_broker,F7_board,F9_accept,F8_decline,F10_hide raid_click_through=true hub_launcher_clickable=true contract_board_interactive=true contract_board_full_client=true contract_board_safe_area=height_derived_ultrawide_centered water_broker_interactive={(!options.ContractsOnly).ToString().ToLowerInvariant()} water_broker_full_client=true water_broker_safe_area=height_derived_ultrawide_centered water_broker_shopkeeper_portrait={WaterBrokerShopkeeperPortrait.Available.ToString().ToLowerInvariant()} water_broker_card_renderer=embedded_current_build_portraits water_broker_embedded_portraits={WaterBrokerOfferIcons.RequiredOfferIds.Count} water_broker_catalog=registry_configured water_broker_registered_items=55 water_broker_content_schema=1 water_broker_abundant_offers=8 water_broker_market=normal_varied_scavenger water_broker_dynamic_restriction_notice=true water_broker_wall_clock_rotation=true water_broker_weapon_routes=13 water_broker_weapon_frequency=one_of_eight_abundant_only water_broker_weapon_price=configured water_broker_rotation_countdown=true card_opens_transaction=true card_switch_without_cancel=true local_card_quote=true framework_selection_roundtrip=false compact_quote=true quote_cost_label=true latest_purchase_summary=true sold_out_snapshot_contract=true same_epoch_hidden_purchase_contract=true overlay_tick_ms=25 state_poll_ms={(int)StatePollInterval.TotalMilliseconds} quantity_controls=minus,plus,max separate_confirmation=true multi_contract_selection=true simultaneous_contracts=true contract_capacity=8 contract_board_revision=true contract_empty_board=true contract_storage_lock=true multi_item_objectives=true native_umg=false exact_hub_gate=true menu_open_detection=false input_lock=requested_via_surface_specific_session_channel input_heartbeat_ms={(int)BoardInputHeartbeat.TotalMilliseconds} input_channel_independent_from_economy_readiness=true hub_action_guard=Space,LeftCtrl,RightCtrl,C,Escape guard_surfaces=broker,contracts escape_action=close_current_surface per_pixel_alpha=true panel_alpha={QuestPanelLayout.PanelBackgroundAlpha} text_alpha=245 placement=adaptive_native_quest_close_adjacency counter_style=compact contract_fee_label=true drone_target=euruska title_fit=bounded_width inactive_raid_contracts_hidden=true show_then_render=true redraw_after_reveal=true no_activate_all_modes=true topmost_reasserted=true");
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle = OverlayWindowStyle.ForMode(parameters.ExStyle, interactive: false);
            return parameters;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        var style = GetWindowLong(Handle, GwlExStyle);
        SetWindowLong(Handle, GwlExStyle, OverlayWindowStyle.ForMode(style, interactive: false));
        var toggleRegistered = RegisterHotKey(Handle, ToggleHotkeyId, ModNoRepeat, VkF10);
        var acceptRegistered = RegisterHotKey(Handle, AcceptHotkeyId, ModNoRepeat, VkF9);
        var declineRegistered = RegisterHotKey(Handle, DeclineHotkeyId, ModNoRepeat, VkF8);
        var boardRegistered = RegisterHotKey(Handle, BoardHotkeyId, ModNoRepeat, VkF7);
        var brokerRegistered = RegisterHotKey(Handle, BrokerHotkeyId, ModNoRepeat, VkF6);
        Log($"HOTKEY REGISTER key=F10 action=toggle accepted={toggleRegistered.ToString().ToLowerInvariant()}");
        Log($"HOTKEY REGISTER key=F9 action=accept accepted={acceptRegistered.ToString().ToLowerInvariant()}");
        Log($"HOTKEY REGISTER key=F8 action=decline accepted={declineRegistered.ToString().ToLowerInvariant()}");
        Log($"HOTKEY REGISTER key=F7 action=toggle_contract_board accepted={boardRegistered.ToString().ToLowerInvariant()}");
        Log($"HOTKEY REGISTER key=F6 action=toggle_water_broker accepted={brokerRegistered.ToString().ToLowerInvariant()}");
    }

    protected override void OnHandleDestroyed(EventArgs e)
    {
        DisableHubActionGuard("handle_destroyed");
        if (IsHandleCreated)
        {
            UnregisterHotKey(Handle, ToggleHotkeyId);
            UnregisterHotKey(Handle, AcceptHotkeyId);
            UnregisterHotKey(Handle, DeclineHotkeyId);
            UnregisterHotKey(Handle, BoardHotkeyId);
            UnregisterHotKey(Handle, BrokerHotkeyId);
        }
        base.OnHandleDestroyed(e);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_hubSurface == HubSurface.Contracts)
            IssueBoardInputState(false, "overlay_exit");
        else if (_hubSurface == HubSurface.WaterTrader)
            IssueWaterBrokerInputState(false, "overlay_exit");
        DisableHubActionGuard("overlay_exit");
        _renderBitmap?.Dispose();
        _renderBitmap = null;
        base.OnFormClosing(e);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHubEscape)
        {
            if (HubActionInputPolicy.CanCloseEscape(_hubSurface, _actionGuardSurface,
                _hubActionGuardActive, _actionGuardGeneration, message.WParam.ToInt32()))
                CloseHubSurface("escape_guard");
            message.Result = IntPtr.Zero;
            return;
        }
        if (message.Msg == WmHotkey)
        {
            var hotkeyId = message.WParam.ToInt32();
            Log($"HOTKEY RECEIVED key={HotkeyName(hotkeyId)} id={hotkeyId}");
            if (!IsDebounced(hotkeyId))
            {
                if (hotkeyId == ToggleHotkeyId)
                {
                    _userHidden = !_userHidden;
                    if (_userHidden && _hubSurface != HubSurface.None) CloseHubSurface("F10");
                    Log($"VISIBILITY TOGGLED visible={(!_userHidden).ToString().ToLowerInvariant()} source=F10");
                    MarkVisualDirty();
                }
                else if (hotkeyId == AcceptHotkeyId)
                {
                    IssueCommand("accept", "F9");
                }
                else if (hotkeyId == DeclineHotkeyId)
                {
                    IssueCommand("decline", "F8");
                }
                else if (hotkeyId == BoardHotkeyId)
                {
                    ToggleBoard("F7");
                }
                else if (hotkeyId == BrokerHotkeyId)
                {
                    ToggleWaterBroker("F6");
                }
            }
        }
        base.WndProc(ref message);
    }

    private static string HotkeyName(int hotkeyId) => hotkeyId switch
    {
        ToggleHotkeyId => "F10",
        AcceptHotkeyId => "F9",
        DeclineHotkeyId => "F8",
        BoardHotkeyId => "F7",
        BrokerHotkeyId => "F6",
        _ => "unknown"
    };

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_hubSurface != HubSurface.None && keyData == Keys.Escape)
        {
            CloseHubSurface("escape");
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_mode == OverlayMode.RaidTracker || _mode == OverlayMode.Hidden) return;
        var target = OverlayHitTesting.HitTest(_mode, ClientSize, e.Location, _snapshot,
            _vendorSnapshot, _purchaseConfirmation, _vendorCommandAwaitingRevision is not null);
        if (target == _hoveredTarget) return;
        _hoveredTarget = target;
        MarkVisualDirty();
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        base.OnMouseLeave(e);
        if (_hoveredTarget == OverlayHitTarget.None) return;
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left) return;
        var target = OverlayHitTesting.HitTest(_mode, ClientSize, e.Location, _snapshot,
            _vendorSnapshot, _purchaseConfirmation, _vendorCommandAwaitingRevision is not null);
        if (target.Kind == OverlayHitKind.OpenBoard)
        {
            OpenBoard("launcher_mouse");
            return;
        }
        if (target.Kind == OverlayHitKind.OpenWaterTrader)
        {
            OpenWaterTrader("launcher_mouse");
            return;
        }
        if (_hubSurface == HubSurface.None) return;
        if (target.Kind == OverlayHitKind.CloseSurface)
            CloseHubSurface(_mode == OverlayMode.WaterTrader ? "trader_mouse" : "board_mouse");
        else if (target.Kind == OverlayHitKind.Accept)
            IssueCommand("accept", "BOARD_MOUSE");
        else if (target.Kind == OverlayHitKind.Discard)
            IssueCommand("decline", "BOARD_MOUSE");
        else if (target.Kind == OverlayHitKind.Contract && target.Index >= 0)
        {
            var index = target.Index;
            _snapshot = _snapshot.SelectIndex(index);
            _hoveredTarget = OverlayHitTarget.None;
            MarkVisualDirty();
            Log($"CONTRACT SELECTED source=BOARD_MOUSE index={index + 1} contract_id={Sanitize(_snapshot.QuestId)} status={Sanitize(_snapshot.Status)}");
        }
        else if (target.Kind == OverlayHitKind.WaterOffer && target.Index >= 0)
            SelectWaterVendorOffer(target.Index, "TRADER_MOUSE");
        else if (target.Kind == OverlayHitKind.BeginPurchase)
            BeginWaterVendorPurchase("TRADER_MOUSE");
        else if (target.Kind == OverlayHitKind.DecreasePurchaseQuantity)
            AdjustWaterVendorPurchaseQuantity(-1, "TRADER_MOUSE_MINUS");
        else if (target.Kind == OverlayHitKind.IncreasePurchaseQuantity)
            AdjustWaterVendorPurchaseQuantity(1, "TRADER_MOUSE_PLUS");
        else if (target.Kind == OverlayHitKind.MaxPurchaseQuantity)
            MaxWaterVendorPurchaseQuantity("TRADER_MOUSE_MAX");
        else if (target.Kind == OverlayHitKind.ConfirmPurchase)
            IssueWaterVendorPurchase("TRADER_MOUSE_CONFIRM");
        else if (target.Kind == OverlayHitKind.CancelPurchase)
            CancelWaterVendorPurchase("TRADER_MOUSE_CANCEL");
    }

    private void ToggleBoard(string source)
    {
        if (_hubSurface == HubSurface.Contracts)
        {
            CloseHubSurface(source);
            return;
        }
        OpenBoard(source);
    }

    private void ToggleWaterBroker(string source)
    {
        if (_hubSurface == HubSurface.WaterTrader)
        {
            CloseHubSurface(source);
            return;
        }
        OpenWaterTrader(source);
    }

    private void OpenBoard(string source)
    {
        if (_options.VendorOnly)
        {
            Log($"CONTRACT BOARD OPEN REJECTED source={source} reason=vendor_only_mode");
            return;
        }
        if (!_snapshot.HubAvailable || _snapshot.RaidInProgress)
        {
            Log($"CONTRACT BOARD OPEN REJECTED source={source} reason=exact_hub_not_available raid_in_progress={_snapshot.RaidInProgress.ToString().ToLowerInvariant()}");
            return;
        }
        if (_hubSurface != HubSurface.None) CloseHubSurface("switch_to_contracts");
        _hubSurface = HubSurface.Contracts;
        _purchaseConfirmation = null;
        _userHidden = false;
        MarkVisualDirty();
        var actionGuardEnabled = EnableHubActionGuard(source);
        var inputSignalWritten = IssueBoardInputState(true, source);
        Log($"CONTRACT BOARD OPENED source={source} contract_count={_snapshot.Contracts.Count} selected_contract={Sanitize(_snapshot.QuestId)} native_umg=false input_lock=requested input_signal_written={inputSignalWritten.ToString().ToLowerInvariant()} action_guard_enabled={actionGuardEnabled.ToString().ToLowerInvariant()}");
    }

    private void OpenWaterTrader(string source)
    {
        if (_options.ContractsOnly)
        {
            Log($"WATER BROKER OPEN REJECTED source={source} reason=contracts_only_mode");
            return;
        }
        if (!_vendorSnapshot.HubAvailable)
        {
            Log($"WATER BROKER OPEN REJECTED source={source} reason=exact_hub_not_available");
            return;
        }
        if (_hubSurface != HubSurface.None) CloseHubSurface("switch_to_broker");
        _hubSurface = HubSurface.WaterTrader;
        _purchaseConfirmation = null;
        _userHidden = false;
        MarkVisualDirty();
        var actionGuardEnabled = EnableHubActionGuard(source);
        var inputSignalWritten = IssueWaterBrokerInputState(true, source);
        Log($"WATER BROKER OPENED source={source} offer_count={_vendorSnapshot.Offers.Count} selected_offer={Sanitize(_vendorSnapshot.OfferId)} water_balance={_vendorSnapshot.WaterBalance} storefront_status={Sanitize(_vendorSnapshot.StorefrontStatus)} native_umg=false input_lock=requested input_signal_written={inputSignalWritten.ToString().ToLowerInvariant()} action_guard_enabled={actionGuardEnabled.ToString().ToLowerInvariant()}");
    }

    private void SelectWaterVendorOffer(int index, string source)
    {
        if (index < 0 || index >= _vendorSnapshot.Offers.Count) return;
        if (_vendorCommandAwaitingRevision is not null)
        {
            Log($"WATER VENDOR OFFER SELECTION REJECTED source={source} reason=command_awaiting_snapshot index={index + 1} mutation=none");
            return;
        }
        var previousConfirmation = _purchaseConfirmation;
        _vendorSnapshot = _vendorSnapshot.SelectIndex(index);
        var preserveConfirmation = previousConfirmation is not null &&
            string.Equals(previousConfirmation.OfferId, _vendorSnapshot.OfferId,
                StringComparison.Ordinal) &&
            _vendorSnapshot.Matches(previousConfirmation);
        _purchaseConfirmation = preserveConfirmation ? previousConfirmation : null;
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
        var replacedConfirmation = previousConfirmation is not null && !preserveConfirmation;
        Log($"WATER VENDOR OFFER SELECTED source={source} index={index + 1} offer_id={Sanitize(_vendorSnapshot.OfferId)} remaining={_vendorSnapshot.Selected.Remaining} purchase_ready={_vendorSnapshot.Selected.PurchaseReady.ToString().ToLowerInvariant()} local_presentation=true local_quote=true confirmation_replaced={replacedConfirmation.ToString().ToLowerInvariant()} confirmation_preserved={preserveConfirmation.ToString().ToLowerInvariant()} framework_selection_command=false mutation=none");
        if (!preserveConfirmation)
            BeginWaterVendorPurchase(source + "_CARD_LOCAL");
    }

    private void CloseHubSurface(string source)
    {
        if (_hubSurface == HubSurface.None) return;
        var closed = _hubSurface;
        var inputSignalWritten = closed == HubSurface.Contracts
            ? IssueBoardInputState(false, source)
            : IssueWaterBrokerInputState(false, source);
        DisableHubActionGuard(source);
        _hubSurface = HubSurface.None;
        _purchaseConfirmation = null;
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
        Log($"HUB SURFACE CLOSED surface={closed.ToString().ToLowerInvariant()} source={source} input_release_requested=true input_signal_written={inputSignalWritten.ToString().ToLowerInvariant()}");
        if (source is not ("switch_to_contracts" or "switch_to_broker" or
            "game_missing_or_minimized" or "hub_gate_changed"))
            QueueGameFocusHandoff(source);
    }

    private void QueueGameFocusHandoff(string source)
    {
        // OnMouseUp is still inside the overlay's mouse dispatch here. Let that
        // dispatch finish before asking Windows to return input to the game.
        // Otherwise the full-screen layered window may retain mouse capture.
        var foregroundBefore = GetForegroundWindow();
        var inScope = foregroundBefore == _gameWindow || foregroundBefore == Handle;
        var hadCapture = Capture;
        if (hadCapture) Capture = false;
        Log($"GAME FOCUS HANDOFF QUEUED source={source} game_present={(_gameWindow != IntPtr.Zero).ToString().ToLowerInvariant()} foreground_in_scope={inScope.ToString().ToLowerInvariant()} overlay_capture_released={hadCapture.ToString().ToLowerInvariant()}");
        if (!inScope || _gameWindow == IntPtr.Zero || IsIconic(_gameWindow)) return;
        BeginInvoke((Action)(() =>
        {
            if (_hubSurface != HubSurface.None || _gameWindow == IntPtr.Zero || IsIconic(_gameWindow)) return;
            var before = GetForegroundWindow();
            if (before != _gameWindow && before != Handle)
            {
                Log($"GAME FOCUS HANDOFF SKIPPED source={source} reason=foreign_foreground");
                return;
            }
            var accepted = SetForegroundWindow(_gameWindow);
            var after = GetForegroundWindow();
            Log($"GAME FOCUS HANDOFF RESULT source={source} call_accepted={accepted.ToString().ToLowerInvariant()} game_foreground={(after == _gameWindow).ToString().ToLowerInvariant()} overlay_capture={Capture.ToString().ToLowerInvariant()}");
        }));
    }

    private void BeginWaterVendorPurchase(string source)
    {
        if (_vendorCommandAwaitingRevision is not null)
        {
            Log($"WATER VENDOR CONFIRMATION REJECTED source={source} reason=command_awaiting_snapshot");
            return;
        }
        if (!_vendorSnapshot.CanPurchaseSelected(out var reason))
        {
            Log($"WATER VENDOR CONFIRMATION REJECTED source={source} reason={Sanitize(reason)} offer_id={Sanitize(_vendorSnapshot.OfferId)}");
            return;
        }
        _purchaseConfirmation = WaterPurchaseConfirmation.Create(_vendorSnapshot, 1);
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
        Log($"WATER VENDOR CONFIRMATION OPENED source={source} offer_id={Sanitize(_purchaseConfirmation.OfferId)} quantity={_purchaseConfirmation.ExpectedTotalQuantity} water_cost={_purchaseConfirmation.ExpectedTotalWaterCost} snapshot_revision={_purchaseConfirmation.SnapshotRevision} rotation_index={_purchaseConfirmation.RotationIndex} mutation=none");
    }

    private void CancelWaterVendorPurchase(string source)
    {
        if (_purchaseConfirmation is null) return;
        Log($"WATER VENDOR CONFIRMATION CANCELLED source={source} offer_id={Sanitize(_purchaseConfirmation.OfferId)} mutation=none");
        _purchaseConfirmation = null;
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
    }

    private void AdjustWaterVendorPurchaseQuantity(int delta, string source)
    {
        if (_purchaseConfirmation is null || delta == 0) return;
        var maximum = _vendorSnapshot.MaximumPurchaseUnits();
        var next = Math.Clamp(_purchaseConfirmation.PurchaseUnits + delta, 1, Math.Max(1, maximum));
        if (next == _purchaseConfirmation.PurchaseUnits) return;
        _purchaseConfirmation = WaterPurchaseConfirmation.Create(_vendorSnapshot, next);
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
        Log($"WATER VENDOR QUANTITY CHANGED source={source} offer_id={Sanitize(_purchaseConfirmation.OfferId)} purchase_units={next} total_quantity={_purchaseConfirmation.ExpectedTotalQuantity} total_water_cost={_purchaseConfirmation.ExpectedTotalWaterCost} maximum={maximum} mutation=none");
    }

    private void MaxWaterVendorPurchaseQuantity(string source)
    {
        if (_purchaseConfirmation is null) return;
        var maximum = _vendorSnapshot.MaximumPurchaseUnits();
        if (maximum < 1 || maximum == _purchaseConfirmation.PurchaseUnits) return;
        _purchaseConfirmation = WaterPurchaseConfirmation.Create(_vendorSnapshot, maximum);
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
        Log($"WATER VENDOR QUANTITY CHANGED source={source} offer_id={Sanitize(_purchaseConfirmation.OfferId)} purchase_units={maximum} total_quantity={_purchaseConfirmation.ExpectedTotalQuantity} total_water_cost={_purchaseConfirmation.ExpectedTotalWaterCost} maximum={maximum} mutation=none");
    }

    private void IssueWaterVendorPurchase(string source)
    {
        var confirmation = _purchaseConfirmation;
        if (confirmation is null)
        {
            Log($"WATER VENDOR COMMAND REJECTED source={source} reason=confirmation_required");
            return;
        }
        if (_vendorCommandAwaitingRevision is not null)
        {
            Log($"WATER VENDOR COMMAND REJECTED source={source} reason=command_awaiting_snapshot");
            return;
        }
        if (!_vendorSnapshot.CommandEnabled || string.IsNullOrWhiteSpace(_vendorCommandSession))
        {
            Log($"WATER VENDOR COMMAND REJECTED source={source} reason=command_channel_not_ready");
            return;
        }
        var foreground = GetForegroundWindow();
        if (_gameWindow == IntPtr.Zero || (foreground != _gameWindow && foreground != Handle))
        {
            Log($"WATER VENDOR COMMAND REJECTED source={source} reason=game_not_foreground");
            return;
        }
        if (!_vendorSnapshot.HubAvailable)
        {
            Log($"WATER VENDOR COMMAND REJECTED source={source} reason=exact_hub_not_available");
            return;
        }
        if (!_vendorSnapshot.Matches(confirmation))
        {
            _purchaseConfirmation = null;
            MarkVisualDirty();
            Log($"WATER VENDOR COMMAND REJECTED source={source} reason=stale_confirmation mutation=none");
            return;
        }

        var nextSequence = _vendorCommandSequence + 1;
        if (!WaterVendorCommandFile.TryWrite(_options.VendorCommandPath, _vendorCommandSession,
                nextSequence, "purchase", confirmation, out var error))
        {
            Log($"WATER VENDOR COMMAND WRITE FAILED source={source} sequence={nextSequence} error={Sanitize(error)} mutation=none");
            return;
        }
        _vendorCommandSequence = nextSequence;
        _vendorCommandAwaitingRevision = confirmation.SnapshotRevision;
        _purchaseConfirmation = null;
        _hoveredTarget = OverlayHitTarget.None;
        MarkVisualDirty();
        Log($"WATER VENDOR COMMAND WRITTEN command=purchase offer_id={Sanitize(confirmation.OfferId)} source={source} sequence={nextSequence} session={Sanitize(_vendorCommandSession)} snapshot_revision={confirmation.SnapshotRevision} rotation_index={confirmation.RotationIndex} purchase_units={confirmation.PurchaseUnits} expected_unit_water_cost={confirmation.ExpectedUnitWaterCost} expected_total_water_cost={confirmation.ExpectedTotalWaterCost} expected_grant_quantity_per_unit={confirmation.ExpectedGrantQuantityPerUnit} expected_total_quantity={confirmation.ExpectedTotalQuantity} expected_remaining={confirmation.ExpectedRemaining} expected_purchase_ready={confirmation.ExpectedPurchaseReady.ToString().ToLowerInvariant()} quote_fingerprint={Sanitize(confirmation.QuoteFingerprint)} complete_marker=true mutation=none");
    }

    private void MarkVisualDirty()
    {
        _visualDirty = true;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        // UpdateLayeredWindow owns the ARGB surface; ordinary WM_PAINT must not
        // replace it with an opaque form background.
    }

    protected override void OnPaintBackground(PaintEventArgs e) { }

    private bool IsDebounced(int hotkeyId)
    {
        var now = DateTime.UtcNow;
        if (_lastHotkeyAt.TryGetValue(hotkeyId, out var previous) && now - previous < HotkeyDebounce)
        {
            Log($"HOTKEY DEBOUNCED id={hotkeyId} elapsed_ms={(now - previous).TotalMilliseconds:F0}");
            return true;
        }
        _lastHotkeyAt[hotkeyId] = now;
        return false;
    }

    private void IssueCommand(string command, string source)
    {
        if (!_snapshot.CommandEnabled || string.IsNullOrWhiteSpace(_commandSession))
        {
            Log($"COMMAND REJECTED command={command} source={source} reason=command_channel_not_ready");
            return;
        }
        if (_snapshot.BoardLocked || _snapshot.Contracts.Count == 0)
        {
            Log($"COMMAND REJECTED command={command} source={source} reason=board_unavailable");
            return;
        }
        var foreground = GetForegroundWindow();
        if (_gameWindow == IntPtr.Zero || (foreground != _gameWindow && foreground != Handle))
        {
            Log($"COMMAND REJECTED command={command} source={source} reason=game_not_foreground");
            return;
        }
        if (!_snapshot.HubAvailable)
        {
            Log($"COMMAND REJECTED command={command} source={source} reason=exact_hub_not_available");
            return;
        }
        if (command == "accept" && _snapshot.RaidInProgress)
        {
            Log($"COMMAND REJECTED command={command} source={source} reason=raid_in_progress status={_snapshot.Status}");
            return;
        }

        var status = _snapshot.Status.ToLowerInvariant();
        var allowed = command == "accept"
            ? status is "available" or "failed" or "complete"
            : status == "accepted";
        if (!allowed)
        {
            Log($"COMMAND REJECTED command={command} source={source} reason=status_not_allowed status={status}");
            return;
        }

        var nextSequence = _commandSequence + 1;
        if (!QuestCommandFile.TryWrite(_options.CommandPath, _commandSession, nextSequence, command,
                _snapshot.QuestId, out var error, _snapshot.BoardRevision))
        {
            Log($"COMMAND WRITE FAILED command={command} source={source} sequence={nextSequence} error={Sanitize(error)}");
            return;
        }
        _commandSequence = nextSequence;
        Log($"COMMAND WRITTEN command={command} contract_id={Sanitize(_snapshot.QuestId)} source={source} sequence={nextSequence} session={_commandSession} complete_marker=true");
    }

    private bool IssueBoardInputState(bool open, string source)
    {
        _lastBoardInputWriteAt = DateTime.UtcNow;
        if (!ContractBoardInputPolicy.CanWrite(_options.VendorOnly, _snapshot.HubAvailable,
            _snapshot.RaidInProgress, _commandSession, open))
        {
            Log($"CONTRACT BOARD INPUT SIGNAL WRITE REJECTED open={open.ToString().ToLowerInvariant()} source={source} reason=channel_not_ready");
            return false;
        }
        if (open && (!_snapshot.HubAvailable || _snapshot.RaidInProgress))
        {
            Log($"CONTRACT BOARD INPUT SIGNAL WRITE REJECTED open=true source={source} reason=exact_hub_not_available raid_in_progress={_snapshot.RaidInProgress.ToString().ToLowerInvariant()}");
            return false;
        }

        var nextSequence = _boardInputSequence + 1;
        if (!ContractBoardInputFile.TryWrite(_boardInputPath, _commandSession, nextSequence,
                open, source, out var error))
        {
            Log($"CONTRACT BOARD INPUT SIGNAL WRITE FAILED open={open.ToString().ToLowerInvariant()} source={source} sequence={nextSequence} error={Sanitize(error)}");
            return false;
        }
        _boardInputSequence = nextSequence;
        Log($"CONTRACT BOARD INPUT SIGNAL WRITTEN open={open.ToString().ToLowerInvariant()} source={source} sequence={nextSequence} session={Sanitize(_commandSession)} complete_marker=true");
        return true;
    }

    private bool IssueWaterBrokerInputState(bool open, string source)
    {
        _lastVendorInputWriteAt = DateTime.UtcNow;
        if (!WaterBrokerInputPolicy.CanWrite(_options.ContractsOnly,
                _vendorSnapshot.HubAvailable, _vendorCommandSession, open, out var reason))
        {
            Log($"WATER BROKER INPUT SIGNAL WRITE REJECTED open={open.ToString().ToLowerInvariant()} source={source} reason={reason}");
            return false;
        }

        var nextSequence = _vendorInputSequence + 1;
        if (!WaterBrokerInputFile.TryWrite(_vendorInputPath, _vendorCommandSession, nextSequence,
                open, source, out var error))
        {
            Log($"WATER BROKER INPUT SIGNAL WRITE FAILED open={open.ToString().ToLowerInvariant()} source={source} sequence={nextSequence} error={Sanitize(error)}");
            return false;
        }
        _vendorInputSequence = nextSequence;
        Log($"WATER BROKER INPUT SIGNAL WRITTEN open={open.ToString().ToLowerInvariant()} source={source} sequence={nextSequence} session={Sanitize(_vendorCommandSession)} complete_marker=true");
        return true;
    }

    private bool EnableHubActionGuard(string source)
    {
        if (_hubSurface == HubSurface.None) return false;
        _actionGuardGeneration++;
        _actionGuardSurface = _hubSurface;
        _hubEscapeKeyDown = false;
        if (_hubKeyboardHook != IntPtr.Zero)
        {
            _hubActionGuardActive = true;
            Log($"{ActionGuardLabel} ACTION INPUT GUARD ENABLED source={source} hook=reused keys=Space,LeftCtrl,RightCtrl,C,Escape foreground_scope=game_or_overlay escape_action=close_current_surface");
            return true;
        }

        _hubKeyboardProc = HubKeyboardHook;
        _hubKeyboardHook = SetWindowsHookEx(WhKeyboardLl, _hubKeyboardProc,
            GetModuleHandle(null), 0);
        _hubActionGuardActive = _hubKeyboardHook != IntPtr.Zero;
        if (!_hubActionGuardActive)
        {
            var error = Marshal.GetLastWin32Error();
            _hubKeyboardProc = null;
            Log($"{ActionGuardLabel} ACTION INPUT GUARD FAILED source={source} win32_error={error} existing_controller_axis_guard=retained");
            return false;
        }
        Log($"{ActionGuardLabel} ACTION INPUT GUARD ENABLED source={source} hook=installed keys=Space,LeftCtrl,RightCtrl,C,Escape foreground_scope=game_or_overlay escape_action=close_current_surface");
        return true;
    }

    private void DisableHubActionGuard(string source)
    {
        _actionGuardGeneration++;
        _hubActionGuardActive = false;
        _hubEscapeKeyDown = false;
        if (_hubKeyboardHook == IntPtr.Zero) return;
        var removed = UnhookWindowsHookEx(_hubKeyboardHook);
        Log($"{ActionGuardLabel} ACTION INPUT GUARD RELEASED source={source} unhooked={removed.ToString().ToLowerInvariant()}");
        if (!removed) return;
        _hubKeyboardHook = IntPtr.Zero;
        _hubKeyboardProc = null;
    }

    private IntPtr HubKeyboardHook(int code, IntPtr message, IntPtr data)
    {
        if (code >= 0 && _hubActionGuardActive &&
            HubActionInputPolicy.IsForegroundInScope(
                GetForegroundWindow(), _gameWindow, Handle))
        {
            var messageId = message.ToInt32();
            var isDown = messageId is WmKeyDown or WmSysKeyDown;
            var isUp = messageId is WmKeyUp or WmSysKeyUp;
            if (isDown || isUp)
            {
                var virtualKey = unchecked((uint)Marshal.ReadInt32(data));
                if (HubActionInputPolicy.ShouldSuppress(virtualKey))
                {
                    if (virtualKey == HubActionInputPolicy.EscapeKey)
                    {
                        if (isDown && !_hubEscapeKeyDown)
                        {
                            _hubEscapeKeyDown = true;
                            PostMessage(Handle, WmHubEscape, new IntPtr(_actionGuardGeneration), IntPtr.Zero);
                        }
                        else if (isUp)
                        {
                            _hubEscapeKeyDown = false;
                        }
                    }
                    return new IntPtr(1);
                }
            }
        }
        return CallNextHookEx(_hubKeyboardHook, code, message, data);
    }

    private void ApplyInteractionStyle(bool interactive)
    {
        var before = GetWindowLong(Handle, GwlExStyle);
        var requested = OverlayWindowStyle.ForMode(before, interactive);
        SetWindowLong(Handle, GwlExStyle, requested);
        var topmostApplied = SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0,
            0x0001 | 0x0002 | 0x0010 | 0x0020);
        var after = GetWindowLong(Handle, GwlExStyle);
        Log($"WINDOW STYLE APPLIED interactive={interactive.ToString().ToLowerInvariant()} before=0x{before:X8} requested=0x{requested:X8} after=0x{after:X8} layered={OverlayWindowStyle.Has(after, OverlayWindowStyle.Layered).ToString().ToLowerInvariant()} transparent={OverlayWindowStyle.Has(after, OverlayWindowStyle.Transparent).ToString().ToLowerInvariant()} no_activate={OverlayWindowStyle.Has(after, OverlayWindowStyle.NoActivate).ToString().ToLowerInvariant()} topmost={OverlayWindowStyle.Has(after, OverlayWindowStyle.TopMost).ToString().ToLowerInvariant()} topmost_apply_ok={topmostApplied.ToString().ToLowerInvariant()}");
    }

    private void TickOverlayCore()
    {
        try
        {
            var now = DateTime.UtcNow;
            var activeSurface = _hubSurface != HubSurface.None || Visible || _mode != OverlayMode.Hidden;
            var pollInterval = activeSurface ? StatePollInterval : IdleStatePollInterval;
            if (_lastStatePollAt == DateTime.MinValue || now - _lastStatePollAt >= pollInterval)
            {
                if (!_options.VendorOnly) ReadSnapshot();
                if (!_options.ContractsOnly) ReadVendorSnapshot();
                // Cache the game window handle: only re-enumerate processes when
                // the handle is missing/invalid or the rescans interval elapses.
                if (_gameWindow == IntPtr.Zero || !IsWindow(_gameWindow) ||
                    now - _lastGameWindowScanAt >= GameWindowScanInterval)
                {
                    _gameWindow = FindGameWindow();
                    _lastGameWindowScanAt = now;
                }
                _lastStatePollAt = now;
            }
            if (_gameWindow == IntPtr.Zero || IsIconic(_gameWindow))
            {
                if (_hubSurface != HubSurface.None)
                    CloseHubSurface("game_missing_or_minimized");
                _gameMissingSince ??= DateTime.UtcNow;
                if (Visible) Hide();
                if (_reportedVisible)
                {
                    Log("VISIBILITY HIDDEN reason=game_missing_or_minimized");
                    _reportedVisible = false;
                }
                var wait = _sawGame ? TimeSpan.FromSeconds(4) : TimeSpan.FromMinutes(2);
                if (DateTime.UtcNow - _gameMissingSince >= wait)
                {
                    Log($"OVERLAY EXIT reason={(_sawGame ? "game_closed" : "game_not_found_timeout")}");
                    Close();
                }
                return;
            }

            _sawGame = true;
            _gameMissingSince = null;
            if (!TryGetClientBounds(_gameWindow, out var gameBounds)) return;
            if (_hubSurface == HubSurface.Contracts && (!_snapshot.HubAvailable || _snapshot.RaidInProgress))
                CloseHubSurface("hub_gate_changed");
            if (_hubSurface == HubSurface.WaterTrader && !_vendorSnapshot.HubAvailable)
                CloseHubSurface("hub_gate_changed");
            if (_hubSurface == HubSurface.Contracts &&
                DateTime.UtcNow - _lastBoardInputWriteAt >= BoardInputHeartbeat)
                IssueBoardInputState(true, "heartbeat");
            if (_hubSurface == HubSurface.WaterTrader &&
                DateTime.UtcNow - _lastVendorInputWriteAt >= BoardInputHeartbeat)
                IssueWaterBrokerInputState(true, "heartbeat");

            var mode = OverlayLayout.ResolveMode(_snapshot, _vendorSnapshot, _hubSurface,
                _options.VendorOnly, _options.ContractsOnly);
            if (mode == OverlayMode.Hidden)
            {
                if (Visible) Hide();
                _lastRenderedRevision = -1;
                _lastRenderedPlacement = Rectangle.Empty;
                _lastRenderedMode = OverlayMode.Hidden;
                _lastRenderedVendorCountdownSecond = long.MinValue;
                _mode = mode;
                if (_reportedVisible)
                {
                    Log("VISIBILITY HIDDEN reason=exact_hub_not_available");
                    _reportedVisible = false;
                }
                return;
            }

            if (mode != _mode)
            {
                _mode = mode;
                _hoveredTarget = OverlayHitTarget.None;
                _visualDirty = true;
                var interactive = mode is OverlayMode.HubLauncher or OverlayMode.ContractBoard or OverlayMode.WaterTrader;
                ApplyInteractionStyle(interactive);
                Log($"OVERLAY MODE CHANGED mode={OverlayLayout.Name(mode)} interactive={interactive.ToString().ToLowerInvariant()} quest_exact_hub={_snapshot.HubAvailable.ToString().ToLowerInvariant()} vendor_exact_hub={_vendorSnapshot.HubAvailable.ToString().ToLowerInvariant()} raid_in_progress={_snapshot.RaidInProgress.ToString().ToLowerInvariant()}");
            }

            var placement = OverlayLayout.Place(gameBounds, _snapshot, _vendorSnapshot, mode);
            var bounds = placement.Bounds;
            if (Bounds != bounds) Bounds = bounds;
            if (_lastPlacement != bounds)
            {
                Log($"OVERLAY PLACEMENT panel={bounds.X},{bounds.Y},{bounds.Width},{bounds.Height} game={gameBounds.X},{gameBounds.Y},{gameBounds.Width},{gameBounds.Height} native_quest_lane_reserved={placement.ReservedNativeQuestLane} gap={placement.Gap} scale={placement.Scale:F3} layout={OverlayLayout.Name(mode)} anchor={placement.Anchor}");
                _lastPlacement = bounds;
            }

            var foreground = GetForegroundWindow();
            var ownInteractiveForeground = (mode is OverlayMode.HubLauncher or OverlayMode.ContractBoard or OverlayMode.WaterTrader) &&
                                           foreground == Handle;
            var shouldShow = !_userHidden && (foreground == _gameWindow || ownInteractiveForeground);
            if (shouldShow)
            {
                // WinForms Show() can recreate/clear the visual surface of a
                // layered window. Make the managed window visible first, then
                // apply the ARGB bitmap. Every reveal forces a fresh render.
                var revealed = !Visible;
                if (revealed) Show();
                var topmostApplied = SetWindowPos(Handle, new IntPtr(-1), bounds.X, bounds.Y, bounds.Width, bounds.Height,
                    0x0010);
                var presentationRevision = CurrentPresentationRevision(mode);
                var vendorCountdownSecond = mode == OverlayMode.WaterTrader
                    ? WaterTraderRotationClock.RemainingSeconds(_vendorSnapshot.RefreshDeadline,
                        DateTimeOffset.UtcNow.ToUnixTimeSeconds())
                    : long.MinValue;
                if (vendorCountdownSecond != _lastRenderedVendorCountdownSecond)
                    _visualDirty = true;
                if (LayeredSurfaceLifecycle.ShouldRender(
                        revealed, _lastRenderedRevision, _lastRenderedPlacement, presentationRevision, bounds) ||
                    _lastRenderedMode != mode || _visualDirty)
                {
                    var rendered = RenderLayeredWindow(bounds, _snapshot, _vendorSnapshot, placement.Scale, mode,
                        out var renderError);
                    var windowStyle = GetWindowLong(Handle, GwlExStyle);
                    Log($"LAYERED RENDER {(rendered ? "APPLIED" : "FAILED")} revision={presentationRevision} mode={OverlayLayout.Name(mode)} panel={bounds.X},{bounds.Y},{bounds.Width},{bounds.Height} scale={placement.Scale:F3} per_pixel_alpha=true panel_alpha={QuestPanelLayout.PanelBackgroundAlpha} text_alpha=245 revealed={revealed.ToString().ToLowerInvariant()} show_then_render=true hover={_hoveredTarget} win32_visible={IsWindowVisible(Handle).ToString().ToLowerInvariant()} layered={OverlayWindowStyle.Has(windowStyle, OverlayWindowStyle.Layered).ToString().ToLowerInvariant()} transparent={OverlayWindowStyle.Has(windowStyle, OverlayWindowStyle.Transparent).ToString().ToLowerInvariant()} no_activate={OverlayWindowStyle.Has(windowStyle, OverlayWindowStyle.NoActivate).ToString().ToLowerInvariant()} topmost={OverlayWindowStyle.Has(windowStyle, OverlayWindowStyle.TopMost).ToString().ToLowerInvariant()} topmost_apply_ok={topmostApplied.ToString().ToLowerInvariant()} error={Sanitize(renderError)}");
                    _lastRenderedRevision = presentationRevision;
                    _lastRenderedPlacement = bounds;
                    _lastRenderedMode = mode;
                    _lastRenderedVendorCountdownSecond = vendorCountdownSecond;
                    _visualDirty = false;
                }
                if (!_reportedVisible)
                {
                    Log($"VISIBILITY SHOWN reason=game_foreground bounds={bounds.X},{bounds.Y},{bounds.Width},{bounds.Height}");
                    _reportedVisible = true;
                }
            }
            else
            {
                if (Visible) Hide();
                // The layered bitmap is not assumed to survive Hide()/Show().
                // Clearing this cache makes the next foreground/F10 reveal
                // repaint even when state and placement did not change.
                _lastRenderedRevision = -1;
                _lastRenderedPlacement = Rectangle.Empty;
                _lastRenderedMode = OverlayMode.Hidden;
                _lastRenderedVendorCountdownSecond = long.MinValue;
                if (_reportedVisible)
                {
                    Log($"VISIBILITY HIDDEN reason={(_userHidden ? "user_toggle" : "game_not_foreground")}");
                    _reportedVisible = false;
                }
            }
        }
        catch (Exception exception)
        {
            Log($"OVERLAY ERROR type={exception.GetType().Name} message={Sanitize(exception.Message)}");
        }
    }

    private void TickOverlay()
    {
        TickOverlayCore();
        UpdateTickCadence();
    }

    // v0.30.4 performance: 25 ms only while a surface is showing; otherwise the
    // overlay ticks at 200 ms so a hidden overlay costs almost nothing.
    private void UpdateTickCadence()
    {
        var active = _hubSurface != HubSurface.None || Visible || _mode != OverlayMode.Hidden;
        var interval = active ? ActiveTickMs : IdleTickMs;
        if (_timer.Interval == interval) return;
        _timer.Interval = interval;
        if (active) _lastGameWindowScanAt = DateTime.MinValue;
        Log($"OVERLAY TICK CADENCE interval_ms={interval} active={active.ToString().ToLowerInvariant()} surface={_hubSurface} mode={OverlayLayout.Name(_mode)} visible={Visible.ToString().ToLowerInvariant()}");
    }

    private long CurrentPresentationRevision(OverlayMode mode) => mode switch
    {
        OverlayMode.WaterTrader => _vendorSnapshot.Revision,
        OverlayMode.HubLauncher => Math.Max(_snapshot.Revision, _vendorSnapshot.Revision),
        _ => _snapshot.Revision,
    };

    private void ReadSnapshot()
    {
        var info = new FileInfo(_options.StatePath);
        if (!info.Exists) return;
        var writeUtc = info.LastWriteTimeUtc;
        var length = info.Length;
        if (writeUtc == _lastStateWriteUtc && length == _lastStateLength) return;
        _lastStateWriteUtc = writeUtc;
        _lastStateLength = length;
        string payload;
        try
        {
            using var stream = new FileStream(_options.StatePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            payload = reader.ReadToEnd();
        }
        catch (IOException)
        {
            return;
        }

        if (!QuestSnapshot.TryParse(payload, out var snapshot) || snapshot.Revision == _lastRevision) return;
        snapshot = snapshot.SelectById(_snapshot.QuestId);
        if (!string.Equals(snapshot.SessionId, _commandSession, StringComparison.Ordinal))
        {
            _commandSession = snapshot.SessionId;
            _commandSequence = QuestCommandFile.ReadLatestSequence(_options.CommandPath, _commandSession);
            _boardInputSequence = ContractBoardInputFile.ReadLatestSequence(
                _boardInputPath, _commandSession);
            _lastBoardInputWriteAt = DateTime.MinValue;
            Log($"COMMAND SESSION ACCEPTED session={_commandSession} starting_sequence={_commandSequence} board_input_starting_sequence={_boardInputSequence} command_enabled={snapshot.CommandEnabled.ToString().ToLowerInvariant()}");
        }
        _snapshot = snapshot;
        _lastRevision = snapshot.Revision;
        Log($"STATE ACCEPTED revision={snapshot.Revision} contract_count={snapshot.Contracts.Count} selected_contract={Sanitize(snapshot.QuestId)} status={snapshot.Status} accepted={snapshot.Accepted.ToString().ToLowerInvariant()} objective_1={snapshot.KillCurrent}/{snapshot.KillTarget} objective_2={snapshot.WaterCurrent}/{snapshot.WaterTarget} reason={snapshot.LastReason}");
        MarkVisualDirty();
    }

    private void ReadVendorSnapshot()
    {
        var info = new FileInfo(_options.VendorStatePath);
        if (!info.Exists) return;
        var writeUtc = info.LastWriteTimeUtc;
        var length = info.Length;
        if (writeUtc == _lastVendorWriteUtc && length == _lastVendorLength) return;
        _lastVendorWriteUtc = writeUtc;
        _lastVendorLength = length;
        string payload;
        try
        {
            using var stream = new FileStream(_options.VendorStatePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            payload = reader.ReadToEnd();
        }
        catch (IOException)
        {
            return;
        }

        if (!WaterVendorSnapshot.TryParse(payload, out var snapshot)) return;
        if (snapshot.Revision == _lastVendorRevision &&
            string.Equals(snapshot.SessionId, _lastVendorSession, StringComparison.Ordinal)) return;
        if (!string.Equals(snapshot.SessionId, _vendorCommandSession, StringComparison.Ordinal))
        {
            _vendorCommandSession = snapshot.SessionId;
            _vendorCommandSequence = WaterVendorCommandFile.ReadLatestSequence(
                _options.VendorCommandPath, _vendorCommandSession);
            _vendorInputSequence = WaterBrokerInputFile.ReadLatestSequence(
                _vendorInputPath, _vendorCommandSession);
            _lastVendorInputWriteAt = DateTime.MinValue;
            _vendorCommandAwaitingRevision = null;
            _purchaseConfirmation = null;
            Log($"WATER VENDOR COMMAND SESSION ACCEPTED session={Sanitize(_vendorCommandSession)} starting_sequence={_vendorCommandSequence} input_starting_sequence={_vendorInputSequence} command_enabled={snapshot.CommandEnabled.ToString().ToLowerInvariant()}");
        }
        else if (_vendorCommandAwaitingRevision is long awaited && snapshot.Revision > awaited)
        {
            _vendorCommandAwaitingRevision = null;
            Log($"WATER VENDOR COMMAND SNAPSHOT OBSERVED session={Sanitize(snapshot.SessionId)} revision={snapshot.Revision} previous_revision={awaited} transaction_status={Sanitize(snapshot.TransactionStatus)} transaction_id={Sanitize(snapshot.TransactionId)}");
        }
        if (_purchaseConfirmation is not null && !snapshot.Matches(_purchaseConfirmation))
            _purchaseConfirmation = null;
        _vendorSnapshot = snapshot;
        _lastVendorRevision = snapshot.Revision;
        _lastVendorSession = snapshot.SessionId;
        Log($"WATER VENDOR STATE ACCEPTED revision={snapshot.Revision} session={Sanitize(snapshot.SessionId)} vendor_id={Sanitize(snapshot.VendorId)} vendor_title={Sanitize(snapshot.VendorTitle)} offer_count={snapshot.Offers.Count} selected_offer={Sanitize(snapshot.OfferId)} water_known={snapshot.WaterKnown.ToString().ToLowerInvariant()} water_balance={snapshot.WaterBalance} rotation_index={snapshot.RotationIndex} stock_band_id={Sanitize(snapshot.StockBandId)} weapons_allowed={snapshot.WeaponsAllowed.ToString().ToLowerInvariant()} special_items_allowed={snapshot.SpecialItemsAllowed.ToString().ToLowerInvariant()} weapon_unlock_water={snapshot.WeaponUnlockWater} special_item_unlock_water={snapshot.SpecialItemUnlockWater} command_enabled={snapshot.CommandEnabled.ToString().ToLowerInvariant()} storefront_status={Sanitize(snapshot.StorefrontStatus)} blocking_reason={Sanitize(snapshot.BlockingReason)} transaction_status={Sanitize(snapshot.TransactionStatus)} last_result_code={Sanitize(snapshot.LastResultCode)} last_result_message={Sanitize(snapshot.LastResultMessage)} last_reason={Sanitize(snapshot.LastReason)}");
        MarkVisualDirty();
    }

    private static IntPtr FindGameWindow()
    {
        foreach (var process in Process.GetProcessesByName("ForeverWinter-Win64-Shipping"))
        {
            try
            {
                if (process.MainWindowHandle != IntPtr.Zero) return process.MainWindowHandle;
            }
            finally
            {
                process.Dispose();
            }
        }
        return IntPtr.Zero;
    }

    private static bool TryGetClientBounds(IntPtr window, out Rectangle bounds)
    {
        bounds = Rectangle.Empty;
        if (!GetClientRect(window, out var client)) return false;
        var topLeft = new PointNative { X = client.Left, Y = client.Top };
        if (!ClientToScreen(window, ref topLeft)) return false;
        var width = client.Right - client.Left;
        var height = client.Bottom - client.Top;
        if (width <= 0 || height <= 0) return false;
        bounds = new Rectangle(topLeft.X, topLeft.Y, width, height);
        return true;
    }

    private bool RenderLayeredWindow(Rectangle bounds, QuestSnapshot snapshot,
        WaterVendorSnapshot vendorSnapshot, float scale, OverlayMode mode, out string error)
    {
        error = "none";
        // Reuse the layered bitmap across renders; only reallocate on resize.
        if (_renderBitmap is null || _renderBitmap.Width != bounds.Width || _renderBitmap.Height != bounds.Height)
        {
            _renderBitmap?.Dispose();
            _renderBitmap = new Bitmap(bounds.Width, bounds.Height,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        }
        var bitmap = _renderBitmap;
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            var state = graphics.Save();
            graphics.ScaleTransform(scale, scale);
            var logicalSize = new Size(
                Math.Max(1, (int)Math.Round(bounds.Width / scale)),
                Math.Max(1, (int)Math.Round(bounds.Height / scale)));
            OverlayRenderer.Draw(graphics, mode, logicalSize, snapshot, vendorSnapshot, true,
                _hoveredTarget, _purchaseConfirmation, _vendorCommandAwaitingRevision is not null);
            graphics.Restore(state);
        }

        var screenDc = GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero)
        {
            error = "GetDC_failed";
            return false;
        }
        var memoryDc = CreateCompatibleDC(screenDc);
        if (memoryDc == IntPtr.Zero)
        {
            ReleaseDC(IntPtr.Zero, screenDc);
            error = "CreateCompatibleDC_failed";
            return false;
        }

        var bitmapHandle = bitmap.GetHbitmap(Color.FromArgb(0));
        var oldBitmap = SelectObject(memoryDc, bitmapHandle);
        try
        {
            var destination = new PointNative { X = bounds.X, Y = bounds.Y };
            var source = new PointNative { X = 0, Y = 0 };
            var size = new SizeNative { Width = bounds.Width, Height = bounds.Height };
            var blend = new BlendFunction
            {
                BlendOp = 0,
                BlendFlags = 0,
                SourceConstantAlpha = 255,
                AlphaFormat = 1,
            };
            if (UpdateLayeredWindow(Handle, screenDc, ref destination, ref size,
                    memoryDc, ref source, 0, ref blend, 0x00000002))
                return true;
            error = $"UpdateLayeredWindow_win32_{Marshal.GetLastWin32Error()}";
            return false;
        }
        finally
        {
            SelectObject(memoryDc, oldBitmap);
            DeleteObject(bitmapHandle);
            DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private void Log(string message)
    {
        try
        {
            if (!_logDirectoryReady)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_logPath) ?? ".");
                _logDirectoryReady = true;
            }
            File.AppendAllText(_logPath,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {Sanitize(message)}{Environment.NewLine}",
                Encoding.UTF8);
        }
        catch
        {
            // Presentation logging must never terminate the overlay.
        }
    }

    private static string Sanitize(string value) => value.Replace('\r', ' ').Replace('\n', ' ').Replace('|', '/');

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int hookId, LowLevelKeyboardProc callback,
        IntPtr module, uint threadId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? moduleName);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr window, out RectNative rectangle);
    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr window, ref PointNative point);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UpdateLayeredWindow(IntPtr window, IntPtr destinationDc,
        ref PointNative destination, ref SizeNative size, IntPtr sourceDc,
        ref PointNative source, int colorKey, ref BlendFunction blend, int flags);
    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr value);

    [StructLayout(LayoutKind.Sequential)]
    private struct RectNative { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct PointNative { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct SizeNative { public int Width, Height; }
    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr message, IntPtr data);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }
}

internal static class OverlayWindowStyle
{
    public const int TopMost = 0x00000008;
    public const int Transparent = 0x00000020;
    public const int ToolWindow = 0x00000080;
    public const int Layered = 0x00080000;
    public const int NoActivate = 0x08000000;

    public static int ForMode(int existingStyle, bool interactive)
    {
        // The live-visible v0.5.1 surface always retained WS_EX_NOACTIVATE.
        // Hub controls need mouse messages, not foreground activation, so only
        // WS_EX_TRANSPARENT changes between click-through and clickable modes.
        var style = existingStyle | Layered | ToolWindow | NoActivate;
        return interactive ? style & ~Transparent : style | Transparent;
    }

    public static bool Has(int style, int flag) => (style & flag) == flag;
}

internal static class QuestCommandFile
{
    private const string Format = "fwif.quest.command.v1";

    public static bool TryWrite(string path, string sessionId, long sequence, string command,
        string contractId, out string error, long? boardRevision = null)
    {
        error = "";
        if (string.IsNullOrWhiteSpace(sessionId) || sequence < 1 || command is not ("accept" or "decline") ||
            boardRevision is < 0 or > 9007199254740991L)
        {
            error = "invalid_command_fields";
            return false;
        }

        var temporaryPath = $"{path}.tmp-{Environment.ProcessId}";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
            var fields = new List<string>
            {
                $"format={Format}",
                $"session_id={Encode(sessionId)}",
                $"sequence={sequence}",
                $"command={command}",
                $"contract_id={Encode(contractId)}",
                $"issued_at_utc={DateTime.UtcNow:O}",
            };
            if (boardRevision.HasValue) fields.Add($"board_revision={boardRevision.Value}");
            fields.Add("complete=1");
            fields.Add("");
            var payload = string.Join("\n", fields);
            File.WriteAllText(temporaryPath, payload, new UTF8Encoding(false));
            File.Move(temporaryPath, path, true);
            return true;
        }
        catch (Exception exception)
        {
            error = $"{exception.GetType().Name}:{exception.Message}";
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); } catch { }
            return false;
        }
    }

    public static long ReadLatestSequence(string path, string expectedSession)
    {
        try
        {
            if (!File.Exists(path)) return 0;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            var values = ParseFields(reader.ReadToEnd());
            if (Get(values, "format") != Format || Get(values, "complete") != "1") return 0;
            if (Decode(Get(values, "session_id")) != expectedSession) return 0;
            return long.TryParse(Get(values, "sequence"), out var sequence) && sequence > 0 ? sequence : 0;
        }
        catch
        {
            return 0;
        }
    }

    private static Dictionary<string, string> ParseFields(string payload)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in payload.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = rawLine.IndexOf('=');
            if (separator <= 0) continue;
            values[rawLine[..separator].Trim()] = rawLine[(separator + 1)..].Trim();
        }
        return values;
    }

    private static string Get(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? value : "";
    private static string Encode(string value) => value.Replace("%", "%25").Replace("=", "%3D").Replace("\r", "%0D").Replace("\n", "%0A");
    private static string Decode(string value) => value.Replace("%0A", "\n").Replace("%0D", "\r").Replace("%3D", "=").Replace("%25", "%");
}

internal static class ContractBoardInputFile
{
    private const string Format = "fwif.contract_board.input.v1";

    public static bool TryWrite(string path, string sessionId, long sequence, bool open,
        string source, out string error)
    {
        error = "";
        if (string.IsNullOrWhiteSpace(sessionId) || sessionId.Length > 128 || sequence < 1)
        {
            error = "invalid_input_state_fields";
            return false;
        }

        var temporaryPath = $"{path}.tmp-{Environment.ProcessId}";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
            var payload = string.Join("\n", new[]
            {
                $"format={Format}",
                $"session_id={Encode(sessionId)}",
                $"sequence={sequence.ToString(CultureInfo.InvariantCulture)}",
                $"board_open={(open ? "1" : "0")}",
                $"source={Encode(source)}",
                $"issued_at_utc={DateTime.UtcNow:O}",
                "complete=1",
                ""
            });
            File.WriteAllText(temporaryPath, payload, new UTF8Encoding(false));
            File.Move(temporaryPath, path, true);
            return true;
        }
        catch (Exception exception)
        {
            error = $"{exception.GetType().Name}:{exception.Message}";
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); } catch { }
            return false;
        }
    }

    public static long ReadLatestSequence(string path, string expectedSession)
    {
        try
        {
            if (!File.Exists(path)) return 0;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            var values = ParseFields(reader.ReadToEnd());
            if (Get(values, "format") != Format || Get(values, "complete") != "1") return 0;
            if (Decode(Get(values, "session_id")) != expectedSession) return 0;
            if (Get(values, "board_open") is not ("0" or "1")) return 0;
            return long.TryParse(Get(values, "sequence"), NumberStyles.None,
                       CultureInfo.InvariantCulture, out var sequence) && sequence > 0
                ? sequence
                : 0;
        }
        catch
        {
            return 0;
        }
    }

    private static Dictionary<string, string> ParseFields(string payload)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in payload.Split(new[] { "\r\n", "\n" },
                     StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = rawLine.IndexOf('=');
            if (separator <= 0) continue;
            var key = rawLine[..separator].Trim();
            if (values.ContainsKey(key)) return new Dictionary<string, string>();
            values[key] = rawLine[(separator + 1)..].Trim();
        }
        return values;
    }

    private static string Get(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? value : "";
    private static string Encode(string value) => value.Replace("%", "%25").Replace("=", "%3D").Replace("\r", "%0D").Replace("\n", "%0A");
    private static string Decode(string value) => value.Replace("%0A", "\n").Replace("%0D", "\r").Replace("%3D", "=").Replace("%25", "%");
}

internal static class WaterBrokerInputFile
{
    private const string Format = "fwif.water_broker.input.v1";

    public static bool TryWrite(string path, string sessionId, long sequence, bool open,
        string source, out string error)
    {
        error = "";
        if (string.IsNullOrWhiteSpace(sessionId) || sessionId.Length > 128 || sequence < 1)
        {
            error = "invalid_input_state_fields";
            return false;
        }

        var temporaryPath = $"{path}.tmp-{Environment.ProcessId}";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
            var payload = string.Join("\n", new[]
            {
                $"format={Format}",
                $"session_id={Encode(sessionId)}",
                $"sequence={sequence.ToString(CultureInfo.InvariantCulture)}",
                $"broker_open={(open ? "1" : "0")}",
                $"source={Encode(source)}",
                $"issued_at_utc={DateTime.UtcNow:O}",
                "complete=1",
                ""
            });
            File.WriteAllText(temporaryPath, payload, new UTF8Encoding(false));
            File.Move(temporaryPath, path, true);
            return true;
        }
        catch (Exception exception)
        {
            error = $"{exception.GetType().Name}:{exception.Message}";
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); } catch { }
            return false;
        }
    }

    public static long ReadLatestSequence(string path, string expectedSession)
    {
        try
        {
            if (!File.Exists(path)) return 0;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            var values = ParseFields(reader.ReadToEnd());
            if (Get(values, "format") != Format || Get(values, "complete") != "1") return 0;
            if (Decode(Get(values, "session_id")) != expectedSession) return 0;
            if (Get(values, "broker_open") is not ("0" or "1")) return 0;
            return long.TryParse(Get(values, "sequence"), NumberStyles.None,
                       CultureInfo.InvariantCulture, out var sequence) && sequence > 0
                ? sequence
                : 0;
        }
        catch
        {
            return 0;
        }
    }

    private static Dictionary<string, string> ParseFields(string payload)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in payload.Split(new[] { "\r\n", "\n" },
                     StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = rawLine.IndexOf('=');
            if (separator <= 0) continue;
            var key = rawLine[..separator].Trim();
            if (values.ContainsKey(key)) return new Dictionary<string, string>();
            values[key] = rawLine[(separator + 1)..].Trim();
        }
        return values;
    }

    private static string Get(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? value : "";
    private static string Encode(string value) => value.Replace("%", "%25").Replace("=", "%3D").Replace("\r", "%0D").Replace("\n", "%0A");
    private static string Decode(string value) => value.Replace("%0A", "\n").Replace("%0D", "\r").Replace("%3D", "=").Replace("%25", "%");
}

internal static class WaterVendorCommandFile
{
    private const string Format = "fwif.water_vendor.command.v1";
    private static readonly HashSet<string> AllowedKeys = new(StringComparer.Ordinal)
    {
        "format", "session_id", "sequence", "command", "offer_id", "snapshot_revision",
        "rotation_index", "purchase_units", "expected_unit_water_cost", "expected_total_water_cost",
        "expected_grant_quantity_per_unit", "expected_total_quantity", "expected_remaining",
        "expected_purchase_ready", "quote_fingerprint", "issued_at_utc", "complete"
    };

    public static bool TryWrite(string path, string sessionId, long sequence, string command,
        WaterPurchaseConfirmation confirmation, out string error)
    {
        error = "";
        if (!ValidText(sessionId, 128) || sequence is < 1 or > 2_147_483_647 ||
            command is not ("select_offer" or "purchase") ||
            confirmation.SnapshotRevision is < 1 or > 2_147_483_647 ||
            confirmation.RotationIndex is < 1 or > 2_147_483_647 ||
            !ValidText(confirmation.OfferId, 160) || confirmation.PurchaseUnits is < 1 or > 999 ||
            confirmation.ExpectedUnitWaterCost is < 1 or > 1_000_000 ||
            confirmation.ExpectedTotalWaterCost is < 1 or > 1_000_000 ||
            confirmation.ExpectedGrantQuantityPerUnit is < 1 or > 1_000_000_000 ||
            confirmation.ExpectedTotalQuantity is < 1 or > 1_000_000_000 ||
            confirmation.ExpectedRemaining is < 0 or > 1_000_000_000 ||
            !ValidText(confirmation.QuoteFingerprint, 256) ||
            confirmation.ExpectedTotalWaterCost !=
                (long)confirmation.ExpectedUnitWaterCost * confirmation.PurchaseUnits ||
            confirmation.ExpectedTotalQuantity !=
                (long)confirmation.ExpectedGrantQuantityPerUnit * confirmation.PurchaseUnits ||
            command == "purchase" && (confirmation.ExpectedTotalQuantity > 999 ||
                                      !confirmation.ExpectedPurchaseReady ||
                                      confirmation.ExpectedRemaining < confirmation.PurchaseUnits))
        {
            error = "invalid_water_vendor_command_fields";
            return false;
        }

        var temporaryPath = $"{path}.tmp-{Environment.ProcessId}";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
            var payload = string.Join("\n", new[]
            {
                $"format={Format}",
                $"session_id={WaterVendorWire.Encode(sessionId)}",
                $"sequence={sequence.ToString(CultureInfo.InvariantCulture)}",
                $"command={command}",
                $"offer_id={WaterVendorWire.Encode(confirmation.OfferId)}",
                $"snapshot_revision={confirmation.SnapshotRevision.ToString(CultureInfo.InvariantCulture)}",
                $"rotation_index={confirmation.RotationIndex.ToString(CultureInfo.InvariantCulture)}",
                $"purchase_units={confirmation.PurchaseUnits.ToString(CultureInfo.InvariantCulture)}",
                $"expected_unit_water_cost={confirmation.ExpectedUnitWaterCost.ToString(CultureInfo.InvariantCulture)}",
                $"expected_total_water_cost={confirmation.ExpectedTotalWaterCost.ToString(CultureInfo.InvariantCulture)}",
                $"expected_grant_quantity_per_unit={confirmation.ExpectedGrantQuantityPerUnit.ToString(CultureInfo.InvariantCulture)}",
                $"expected_total_quantity={confirmation.ExpectedTotalQuantity.ToString(CultureInfo.InvariantCulture)}",
                $"expected_remaining={confirmation.ExpectedRemaining.ToString(CultureInfo.InvariantCulture)}",
                $"expected_purchase_ready={(confirmation.ExpectedPurchaseReady ? "1" : "0")}",
                $"quote_fingerprint={WaterVendorWire.Encode(confirmation.QuoteFingerprint)}",
                $"issued_at_utc={DateTime.UtcNow:O}",
                "complete=1",
                ""
            });
            File.WriteAllText(temporaryPath, payload, new UTF8Encoding(false));
            File.Move(temporaryPath, path, true);
            return true;
        }
        catch (Exception exception)
        {
            error = $"{exception.GetType().Name}:{exception.Message}";
            try { if (File.Exists(temporaryPath)) File.Delete(temporaryPath); } catch { }
            return false;
        }
    }

    public static long ReadLatestSequence(string path, string expectedSession)
    {
        try
        {
            if (!File.Exists(path) || !ValidText(expectedSession, 128)) return 0;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > 16 * 1024) return 0;
            using var reader = new StreamReader(stream, Encoding.UTF8, true);
            if (!TryParseFields(reader.ReadToEnd(), out var values)) return 0;
            if (Get(values, "format") != Format || Get(values, "complete") != "1" ||
                Get(values, "command") is not ("select_offer" or "purchase") ||
                !WaterVendorWire.TryDecode(Get(values, "session_id"), out var sessionId) ||
                sessionId != expectedSession)
                return 0;
            return long.TryParse(Get(values, "sequence"), NumberStyles.None, CultureInfo.InvariantCulture,
                out var sequence) && sequence is > 0 and <= 2_147_483_647 ? sequence : 0;
        }
        catch
        {
            return 0;
        }
    }

    private static bool TryParseFields(string payload, out Dictionary<string, string> values)
    {
        values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var rawLine in payload.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = rawLine.IndexOf('=');
            if (separator <= 0) return false;
            var key = rawLine[..separator].Trim();
            var value = rawLine[(separator + 1)..].Trim();
            if (!AllowedKeys.Contains(key) || !values.TryAdd(key, value)) return false;
        }
        return values.Count == AllowedKeys.Count && AllowedKeys.All(values.ContainsKey);
    }

    private static bool ValidText(string value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) && value.Length <= maximumLength &&
        !value.Any(character => character < ' ' || character == '\u007F');
    private static string Get(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? value : "";
}

internal static class WaterVendorWire
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static string Encode(string value)
    {
        var output = new StringBuilder();
        foreach (var valueByte in Encoding.UTF8.GetBytes(value))
        {
            if (valueByte is >= (byte)'a' and <= (byte)'z' or >= (byte)'A' and <= (byte)'Z' or
                >= (byte)'0' and <= (byte)'9' || valueByte is (byte)'.' or (byte)'_' or (byte)':' or
                (byte)'/' or (byte)'-')
                output.Append((char)valueByte);
            else
                output.Append('%').Append(valueByte.ToString("X2", CultureInfo.InvariantCulture));
        }
        return output.ToString();
    }

    public static bool TryDecode(string encoded, out string value)
    {
        value = "";
        var bytes = new List<byte>(encoded.Length);
        for (var index = 0; index < encoded.Length; index++)
        {
            var character = encoded[index];
            if (character == '%')
            {
                if (index + 2 >= encoded.Length ||
                    !byte.TryParse(encoded.AsSpan(index + 1, 2), NumberStyles.HexNumber,
                        CultureInfo.InvariantCulture, out var decoded)) return false;
                bytes.Add(decoded);
                index += 2;
            }
            else
            {
                if (character > 0x7F) return false;
                bytes.Add((byte)character);
            }
        }
        try
        {
            value = StrictUtf8.GetString(bytes.ToArray());
            return true;
        }
        catch (DecoderFallbackException)
        {
            return false;
        }
    }
}

internal static class WaterBrokerInputPolicy
{
    // Surface-input ownership is intentionally independent from economy
    // command readiness. A durability or transaction block must not stop an
    // already visible Broker from heartbeating or closing its input lease.
    public static bool CanWrite(bool contractsOnly, bool hubAvailable,
        string sessionId, bool open, out string reason)
    {
        if (contractsOnly)
        {
            reason = "contracts_only_mode";
            return false;
        }
        if (string.IsNullOrWhiteSpace(sessionId))
        {
            reason = "input_session_not_ready";
            return false;
        }
        if (open && !hubAvailable)
        {
            reason = "exact_hub_not_available";
            return false;
        }
        reason = "ready";
        return true;
    }
}

internal static class ContractBoardInputPolicy
{
    // The input lease belongs to the surface, independent of fee/reward readiness.
    public static bool CanWrite(bool vendorOnly, bool hubAvailable, bool raidInProgress,
        string sessionId, bool open) => !vendorOnly && !string.IsNullOrWhiteSpace(sessionId) &&
        (!open || (hubAvailable && !raidInProgress));
}

internal static class HubActionInputPolicy
{
    public static bool CanCloseEscape(HubSurface surface, HubSurface guardSurface,
        bool active, int generation, int postedGeneration) => active && surface != HubSurface.None &&
        surface == guardSurface && generation == postedGeneration;
    public const uint EscapeKey = 0x1B;
    private const uint SpaceKey = 0x20;
    private const uint CKey = 0x43;
    private const uint ControlKey = 0x11;
    private const uint LeftControlKey = 0xA2;
    private const uint RightControlKey = 0xA3;

    public static bool ShouldSuppress(uint virtualKey) => virtualKey is
        EscapeKey or SpaceKey or CKey or ControlKey or LeftControlKey or RightControlKey;

    public static bool IsForegroundInScope(IntPtr foreground, IntPtr gameWindow,
        IntPtr overlayWindow) => foreground != IntPtr.Zero &&
        (foreground == gameWindow || foreground == overlayWindow);
}

internal static class ContractBoardRotationSelfTest
{
    public static void Run()
    {
        var payload = string.Join("\n", new[] {
            "format=fwif.contracts.overlay.v1", "revision=8", "session_id=rotation-test",
            "board_revision=3", "board_locked=0", "board_capacity=6", "board_vacant_count=6",
            "hub_available=1", "raid_in_progress=0", "contract_count=0", "command_enabled=1", "complete=1"
        });
        if (!QuestSnapshot.TryParse(payload, out var empty) || empty.BoardRevision != 3 ||
            empty.Contracts.Count != 0 || empty.CommandEnabled || !empty.HasContractBoard ||
            empty.CanChangeContracts || !empty.BoardNotice.Contains("No contracts"))
            throw new InvalidOperationException("rotation_empty_board_parse_failed");
        if (QuestSnapshot.TryParse(payload.Replace("board_revision=3", "board_revision=-1"), out _) ||
            QuestSnapshot.TryParse(payload.Replace("board_revision=3", "board_revision=1.5"), out _))
            throw new InvalidOperationException("rotation_bad_board_revision_accepted");
        if (QuestSnapshot.TryParse(payload.Replace("session_id=rotation-test", "session_id="), out _) ||
            QuestSnapshot.TryParse(payload.Replace("session_id=rotation-test", "session_id= ")
                .Replace("board_locked=0", "board_locked=1"), out _))
            throw new InvalidOperationException("rotation_board_without_input_session_accepted");
        var lockedPayload = payload.Replace("board_locked=0", "board_locked=1");
        if (!QuestSnapshot.TryParse(lockedPayload, out var emptyLocked) || !emptyLocked.BoardLocked ||
            emptyLocked.CommandEnabled || !emptyLocked.BoardNotice.Contains("unavailable"))
            throw new InvalidOperationException("rotation_locked_board_parse_failed");
        var offeredLocked = QuestSnapshot.Preview() with { BoardRevision = 3, BoardLocked = true };
        var offered = QuestSnapshot.Preview() with { BoardRevision = 4, BoardVacantCount = 3 };
        var size = OverlayLayout.WindowSize(OverlayMode.ContractBoard, 1f);
        var action = ContractBoardLayout.ActionButton(size);
        var close = ContractBoardLayout.CloseButton(size);
        foreach (var candidate in new[] { empty, emptyLocked, offeredLocked })
        {
            if (candidate.CanChangeContracts ||
                OverlayHitTesting.HitTest(OverlayMode.ContractBoard, size,
                    new Point(action.Left + 2, action.Top + 2), candidate, WaterVendorSnapshot.Waiting(), null, false) != OverlayHitTarget.None ||
                OverlayHitTesting.HitTest(OverlayMode.ContractBoard, size,
                    new Point(close.Left + 2, close.Top + 2), candidate, WaterVendorSnapshot.Waiting(), null, false) != OverlayHitTarget.CloseSurface ||
                !ContractBoardInputPolicy.CanWrite(false, candidate.HubAvailable, false, candidate.SessionId, true) ||
                !ContractBoardInputPolicy.CanWrite(false, false, true, candidate.SessionId, false))
                throw new InvalidOperationException("rotation_actions_or_input_lease_failed");
        }
        foreach (var candidate in new[] { empty, emptyLocked, offeredLocked, offered })
        {
            using var bitmap = new Bitmap(size.Width, size.Height);
            using var graphics = Graphics.FromImage(bitmap);
            ContractBoardRenderer.Draw(graphics, size, candidate, false, OverlayHitTarget.None);
        }
        var path = Path.Combine(Path.GetTempPath(), $"FWQuestRotationCommand-{Guid.NewGuid():N}.txt");
        try
        {
            if (!QuestCommandFile.TryWrite(path, "rotation-test", 1, "accept", "contract-a", out _, 3) ||
                !File.ReadAllText(path).Contains("board_revision=3\n", StringComparison.Ordinal) ||
                !QuestCommandFile.TryWrite(path, "legacy-test", 2, "decline", "contract-a", out _) ||
                File.ReadAllText(path).Contains("board_revision=", StringComparison.Ordinal) ||
                QuestCommandFile.TryWrite(path, "rotation-test", 3, "accept", "contract-a", out _, -1))
                throw new InvalidOperationException("rotation_command_wire_failed");
        }
        finally { if (File.Exists(path)) File.Delete(path); }
    }
}

internal static class OverlaySelfTest
{
    public static void Run()
    {
        RunPortableDefaultTests();
        RunRaidTrackerEligibilityTests();
        var root = Path.Combine(Path.GetTempPath(), $"FWQuestOverlaySelfTest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var statePayload = string.Join("\n", new[]
            {
                "format=fwif.contracts.overlay.v1", "revision=4", "session_id=self-test-session",
                "raid_in_progress=0", "hub_available=1", "contract_count=3", "selected_contract_index=1",
                "contract_1_id=europan_infantry_water_reward_stress_test", "contract_1_title=Cull and Carry",
                "contract_1_status=accepted", "contract_1_accepted=1", "contract_1_attempt=0",
                "contract_1_category=COMBAT + RECOVERY", "contract_1_description=Thin patrols and recover Water.",
                "contract_1_failure_condition=Complete every objective and extract alive in the same raid.",
                "contract_1_refund_policy=Contract fees are nonrefundable after acceptance.",
                "contract_1_acceptance_water_cost=1", "contract_1_acceptance_water_paid=1",
                "contract_1_objective_1_id=europan_infantry", "contract_1_objective_1_label=ELIMINATE EUROPAN INFANTRY",
                "contract_1_objective_1_current=0", "contract_1_objective_1_target=5",
                "contract_1_objective_2_id=water_barrel", "contract_1_objective_2_label=RECOVER WATER BARRELS",
                "contract_1_objective_2_current=0", "contract_1_objective_2_target=2",
                "contract_1_rewards_enabled=1", "contract_1_reward_summary=1,111 CR / 500 XP / USP",
                "contract_2_id=euruskan_drones_vodka_single_raid", "contract_2_title=Rotors and Spirits",
                "contract_2_status=accepted", "contract_2_accepted=1", "contract_2_attempt=0",
                "contract_2_category=ANTI-AIR + RECOVERY", "contract_2_description=Destroy drones and recover Vodka.",
                "contract_2_failure_condition=Complete every objective and extract alive in the same raid.",
                "contract_2_refund_policy=Contract fees are nonrefundable after acceptance.",
                "contract_2_acceptance_water_cost=1", "contract_2_acceptance_water_paid=1",
                "contract_2_objective_1_id=euruskan_drones", "contract_2_objective_1_label=DESTROY EURUSKAN DRONES",
                "contract_2_objective_1_current=0", "contract_2_objective_1_target=3",
                "contract_2_objective_2_id=vodka", "contract_2_objective_2_label=RECOVER VODKA",
                "contract_2_objective_2_current=0", "contract_2_objective_2_target=3",
                "contract_2_rewards_enabled=1", "contract_2_reward_summary=10,000 CR / 2,000 XP / 1 EXPLOSIVES",
                "contract_3_id=cultists_lockboxes_single_raid", "contract_3_title=Tithes Below",
                "contract_3_status=accepted", "contract_3_accepted=1", "contract_3_attempt=0",
                "contract_3_category=TUNNEL PURGE + RECOVERY", "contract_3_description=Break a Cultist cell and recover sealed lockboxes.",
                "contract_3_failure_condition=Complete every objective and extract alive in the same raid.",
                "contract_3_refund_policy=Contract fees are nonrefundable after acceptance.",
                "contract_3_acceptance_water_cost=2", "contract_3_acceptance_water_paid=2",
                "contract_3_objective_1_id=cultists", "contract_3_objective_1_label=ELIMINATE CULTISTS",
                "contract_3_objective_1_current=0", "contract_3_objective_1_target=4",
                "contract_3_objective_2_id=large_lockboxes", "contract_3_objective_2_label=RECOVER LARGE LOCKBOXES",
                "contract_3_objective_2_current=0", "contract_3_objective_2_target=3",
                "contract_3_rewards_enabled=1", "contract_3_reward_summary=20,000 CR / 2,500 XP / R8 / .357 MAGNUM",
                "last_reason=quest_accept_requested", "command_enabled=1", "complete=1", ""
            });
            if (!QuestSnapshot.TryParse(statePayload, out var snapshot) || !snapshot.Accepted ||
                snapshot.RaidInProgress || !snapshot.HubAvailable || snapshot.Status != "accepted" ||
                snapshot.SessionId != "self-test-session" ||
                snapshot.QuestId != "europan_infantry_water_reward_stress_test" ||
                snapshot.AcceptanceWaterCost != 1 || snapshot.AcceptanceWaterPaid != 1 ||
                snapshot.Contracts.Count != 3 || !snapshot.RewardsEnabled ||
                snapshot.Contracts[2].AcceptanceWaterCost != 2)
                throw new InvalidOperationException("state_parser_self_test_failed");

            var lockedPayload = statePayload
                .Replace("_status=accepted", "_status=locked", StringComparison.Ordinal)
                .Replace("_accepted=1", "_accepted=0", StringComparison.Ordinal)
                .Replace("raid_in_progress=0", "raid_in_progress=1", StringComparison.Ordinal)
                .Replace("hub_available=1", "hub_available=0", StringComparison.Ordinal)
                .Replace("_acceptance_water_paid=1", "_acceptance_water_paid=0", StringComparison.Ordinal);
            if (!QuestSnapshot.TryParse(lockedPayload, out var lockedSnapshot) ||
                !lockedSnapshot.RaidInProgress || lockedSnapshot.HubAvailable || lockedSnapshot.Accepted ||
                lockedSnapshot.Status != "locked")
                throw new InvalidOperationException("raid_lock_parser_self_test_failed");

            var commandPath = Path.Combine(root, "command.txt");
            if (!QuestCommandFile.TryWrite(commandPath, snapshot.SessionId, 1, "accept", snapshot.QuestId,
                    out var error))
                throw new InvalidOperationException("command_write_self_test_failed:" + error);
            if (QuestCommandFile.ReadLatestSequence(commandPath, snapshot.SessionId) != 1)
                throw new InvalidOperationException("command_sequence_self_test_failed");
            if (!File.ReadAllText(commandPath).Contains($"contract_id={snapshot.QuestId}",
                    StringComparison.Ordinal))
                throw new InvalidOperationException("command_contract_id_self_test_failed");
            if (QuestCommandFile.ReadLatestSequence(commandPath, "different-session") != 0)
                throw new InvalidOperationException("command_session_self_test_failed");

            var boardInputPath = Path.Combine(root, "contract-board-input-v1.txt");
            if (!ContractBoardInputFile.TryWrite(boardInputPath, snapshot.SessionId, 1,
                    true, "self_test_open", out error))
                throw new InvalidOperationException("board_input_open_write_self_test_failed:" + error);
            if (ContractBoardInputFile.ReadLatestSequence(boardInputPath, snapshot.SessionId) != 1 ||
                !File.ReadAllText(boardInputPath).Contains("board_open=1", StringComparison.Ordinal))
                throw new InvalidOperationException("board_input_open_self_test_failed");
            if (!ContractBoardInputFile.TryWrite(boardInputPath, snapshot.SessionId, 2,
                    false, "self_test_close", out error))
                throw new InvalidOperationException("board_input_close_write_self_test_failed:" + error);
            if (ContractBoardInputFile.ReadLatestSequence(boardInputPath, snapshot.SessionId) != 2 ||
                !File.ReadAllText(boardInputPath).Contains("board_open=0", StringComparison.Ordinal) ||
                ContractBoardInputFile.ReadLatestSequence(boardInputPath, "different-session") != 0)
                throw new InvalidOperationException("board_input_close_self_test_failed");

            var brokerInputPath = Path.Combine(root, "water-broker-input-v1.txt");
            if (!WaterBrokerInputFile.TryWrite(brokerInputPath, "water-session", 1,
                    true, "self_test_open", out error))
                throw new InvalidOperationException("broker_input_open_write_self_test_failed:" + error);
            if (WaterBrokerInputFile.ReadLatestSequence(brokerInputPath, "water-session") != 1 ||
                !File.ReadAllText(brokerInputPath).Contains("broker_open=1", StringComparison.Ordinal))
                throw new InvalidOperationException("broker_input_open_self_test_failed");
            if (!WaterBrokerInputFile.TryWrite(brokerInputPath, "water-session", 2,
                    false, "self_test_close", out error))
                throw new InvalidOperationException("broker_input_close_write_self_test_failed:" + error);
            if (WaterBrokerInputFile.ReadLatestSequence(brokerInputPath, "water-session") != 2 ||
                !File.ReadAllText(brokerInputPath).Contains("broker_open=0", StringComparison.Ordinal) ||
                WaterBrokerInputFile.ReadLatestSequence(brokerInputPath, "different-session") != 0)
                throw new InvalidOperationException("broker_input_close_self_test_failed");
            if (!WaterBrokerInputPolicy.CanWrite(false, true, "water-session", true, out _) ||
                !WaterBrokerInputPolicy.CanWrite(false, true, "water-session", false, out _) ||
                !WaterBrokerInputPolicy.CanWrite(false, false, "water-session", false, out _) ||
                WaterBrokerInputPolicy.CanWrite(false, false, "water-session", true, out var hubReason) ||
                hubReason != "exact_hub_not_available" ||
                WaterBrokerInputPolicy.CanWrite(false, true, "", false, out var sessionReason) ||
                sessionReason != "input_session_not_ready")
                throw new InvalidOperationException("broker_input_policy_self_test_failed");
            if (!HubActionInputPolicy.ShouldSuppress(0x20) ||
                !HubActionInputPolicy.ShouldSuppress(0x43) ||
                !HubActionInputPolicy.ShouldSuppress(0x11) ||
                !HubActionInputPolicy.ShouldSuppress(0xA2) ||
                !HubActionInputPolicy.ShouldSuppress(0xA3) ||
                !HubActionInputPolicy.ShouldSuppress(0x1B) ||
                HubActionInputPolicy.ShouldSuppress(0x57) ||
                !HubActionInputPolicy.IsForegroundInScope(
                    new IntPtr(10), new IntPtr(10), new IntPtr(11)) ||
                HubActionInputPolicy.IsForegroundInScope(
                    new IntPtr(12), new IntPtr(10), new IntPtr(11)))
                throw new InvalidOperationException("broker_action_input_policy_self_test_failed");

            var vendorPayload = string.Join("\n", new[]
            {
                "format=fwif.water_vendor.overlay.v1", "revision=5", "session_id=water-session",
                "vendor_id=independent_water_vendor", "vendor_title=The%20Cistern",
                "hub_available=1", "command_enabled=1", "water_known=1", "water_balance=93",
                "rotation_index=12", "stock_band_id=abundant", "weapons_allowed=1",
                "special_items_allowed=1", "weapon_unlock_water=0", "special_item_unlock_water=0",
                "refresh_deadline=0",
                "storefront_status=available", "blocking_reason=none", "transaction_id=",
                "transaction_status=none", "last_result_code=", "last_result_message=", "offer_count=2",
                "selected_offer_index=1", "selected_offer_id=ammo_545",
                "offer_1_id=ammo_545", "offer_1_display_name=5.45x39mm%20Supply",
                "offer_1_category=ammunition", "offer_1_inventory_kind=stackable",
                "offer_1_unit_water_cost=2", "offer_1_grant_quantity_per_unit=120",
                "offer_1_max_purchase_units=5", "offer_1_initial_stock=5", "offer_1_remaining=5",
                "offer_1_purchase_ready=1",
                "offer_1_purchase_block_reason=none", "offer_1_fulfillment_evidence=VERIFIED-CURRENT",
                "offer_1_quote_fingerprint=r12:ammo_545:w2:q120:m5:i5:s5:ready",
                "offer_2_id=med_medium", "offer_2_display_name=Field%20Medical%20Kit",
                "offer_2_category=medical", "offer_2_inventory_kind=stackable",
                "offer_2_unit_water_cost=3", "offer_2_grant_quantity_per_unit=2",
                "offer_2_max_purchase_units=3", "offer_2_initial_stock=3", "offer_2_remaining=2",
                "offer_2_purchase_ready=1",
                "offer_2_purchase_block_reason=none", "offer_2_fulfillment_evidence=UNTESTED-LIVE",
                "offer_2_quote_fingerprint=r12:med_medium:w3:q2:m3:i3:s2:ready",
                "last_reason=self_test", "complete=1", ""
            });
            if (!WaterVendorSnapshot.TryParse(vendorPayload, out var vendor))
                throw new InvalidOperationException("water_vendor_parser_payload_rejected");
            if (vendor.SessionId != "water-session" || !vendor.HubAvailable || !vendor.CommandEnabled ||
                !vendor.WaterKnown || vendor.WaterBalance != 93 || vendor.RotationIndex != 12 ||
                vendor.Offers.Count != 2 || vendor.SelectedIndex != 0 || vendor.OfferId != "ammo_545" ||
                vendor.Selected.DisplayName != "5.45x39mm Supply" ||
                vendor.Selected.GrantQuantityPerUnit != 120 || vendor.Selected.UnitWaterCost != 2 ||
                !vendor.CanPurchaseSelected(out _))
                throw new InvalidOperationException("water_vendor_parser_self_test_failed");
            var soldOutVendorPayload = vendorPayload
                .Replace("revision=5", "revision=6", StringComparison.Ordinal)
                .Replace("water_balance=93", "water_balance=91", StringComparison.Ordinal)
                .Replace("offer_1_remaining=5", "offer_1_remaining=0", StringComparison.Ordinal)
                .Replace("offer_1_purchase_ready=1", "offer_1_purchase_ready=0", StringComparison.Ordinal)
                .Replace("offer_1_purchase_block_reason=none",
                    "offer_1_purchase_block_reason=sold_out", StringComparison.Ordinal)
                .Replace("offer_1_quote_fingerprint=r12:ammo_545:w2:q120:m5:i5:s5:ready",
                    "offer_1_quote_fingerprint=r12:ammo_545:w2:q120:m5:i5:s0:blocked",
                    StringComparison.Ordinal);
            if (!WaterVendorSnapshot.TryParse(soldOutVendorPayload, out var soldOutVendor) ||
                soldOutVendor.Revision != 6 || soldOutVendor.WaterBalance != 91 ||
                soldOutVendor.Selected.Remaining != 0 || soldOutVendor.Selected.PurchaseReady ||
                soldOutVendor.Selected.PurchaseBlockReason != "sold_out" ||
                soldOutVendor.CanPurchaseSelected(out var soldOutReason) || soldOutReason != "sold_out")
                throw new InvalidOperationException("water_vendor_sold_out_snapshot_self_test_failed");
            if (WaterVendorSnapshot.TryParse(soldOutVendorPayload.Replace(
                    "offer_1_purchase_ready=0", "offer_1_purchase_ready=1", StringComparison.Ordinal), out _))
                throw new InvalidOperationException("water_vendor_ready_without_stock_must_reject");
            if (WaterVendorSnapshot.TryParse(vendorPayload.Replace("water_balance=93",
                    "water_balance=93\nwater_balance=94", StringComparison.Ordinal), out _))
                throw new InvalidOperationException("water_vendor_duplicate_key_must_reject");
            if (WaterVendorSnapshot.TryParse(vendorPayload.Replace("offer_2_id=med_medium",
                    "offer_2_id=ammo_545", StringComparison.Ordinal), out _))
                throw new InvalidOperationException("water_vendor_duplicate_offer_id_must_reject");
            if (WaterVendorSnapshot.TryParse(vendorPayload.Replace("complete=1",
                    "unexpected_field=1\ncomplete=1", StringComparison.Ordinal), out _))
                throw new InvalidOperationException("water_vendor_unknown_key_must_reject");
            if (WaterVendorSnapshot.TryParse(vendorPayload.Replace("selected_offer_id=ammo_545",
                    "selected_offer_id=med_medium", StringComparison.Ordinal), out _))
                throw new InvalidOperationException("water_vendor_selected_offer_mismatch_must_reject");
            if (WaterVendorSnapshot.TryParse(vendorPayload.Replace("5.45x39mm%20Supply",
                    "5.45x39mm%2ZSupply", StringComparison.Ordinal), out _))
                throw new InvalidOperationException("water_vendor_invalid_percent_encoding_must_reject");
            if (WaterVendorSnapshot.TryParse(vendorPayload + new string('x', 64 * 1024), out _))
                throw new InvalidOperationException("water_vendor_payload_cap_must_reject");
            if (WaterTraderRotationClock.RemainingSeconds(17_200, 10_000) != 7_200 ||
                WaterTraderRotationClock.Label(17_200, 10_000) != "RESET IN 02:00:00" ||
                WaterTraderRotationClock.Label(10_001, 10_000) != "RESET IN 00:00:01" ||
                WaterTraderRotationClock.Label(10_000, 10_000) != "RESET PENDING" ||
                WaterTraderRotationClock.Label(0, 10_000) != "RESET UNKNOWN")
                throw new InvalidOperationException("water_vendor_rotation_countdown_self_test_failed");
            if (WaterVendorPresentationText.MarketSubtitle(vendor) !=
                    WaterVendorPresentationText.NormalMarketSubtitle ||
                !WaterVendorPresentationText.MarketSubtitle(vendor with
                    {
                        StockBandId = "stable", WeaponsAllowed = false,
                        SpecialItemsAllowed = false, WeaponUnlockWater = 73,
                        SpecialItemUnlockWater = 73
                    }).Contains("73+ REQUIRED", StringComparison.Ordinal) ||
                WaterVendorPresentationText.MarketSubtitle(vendor with
                    {
                        StockBandId = "stable", WeaponsAllowed = false,
                        SpecialItemsAllowed = false, WeaponUnlockWater = 73,
                        SpecialItemUnlockWater = 73
                    }).Contains("66+ REQUIRED", StringComparison.Ordinal) ||
                !WaterVendorPresentationText.MarketSubtitle(vendor with
                    {
                        WeaponsAllowed = true, SpecialItemsAllowed = false,
                        SpecialItemUnlockWater = 91
                    }).Contains("SPECIAL ITEMS 91+ WATER", StringComparison.Ordinal))
                throw new InvalidOperationException("water_trader_band_notice_self_test_failed");
            var firstLivePreview = WaterVendorSnapshot.Preview();
            if (firstLivePreview.WaterBalance != 79 || firstLivePreview.StockBandId != "abundant" ||
                firstLivePreview.Offers.Count != 8 || firstLivePreview.OfferId != "ammo_545_crate" ||
                firstLivePreview.Selected.UnitWaterCost != 1 ||
                firstLivePreview.Selected.GrantQuantityPerUnit != 90 ||
                firstLivePreview.Selected.MaxPurchaseUnits != 99 ||
                firstLivePreview.Selected.InitialStock != 3 || firstLivePreview.Selected.Remaining != 3 ||
                !firstLivePreview.Selected.PurchaseReady || !firstLivePreview.CanPurchaseSelected(out _) ||
                firstLivePreview.StorefrontStatus != "available" ||
                firstLivePreview.MaximumPurchaseUnits() != 3 ||
                firstLivePreview.RefreshDeadline <= DateTimeOffset.UtcNow.ToUnixTimeSeconds() ||
                firstLivePreview.Offers.All(offer => offer.Id != "mead") ||
                firstLivePreview.Offers.Count(offer => offer.Category == "weapon" && offer.PurchaseReady) != 1 ||
                firstLivePreview.Offers.Any(offer => !offer.PurchaseReady))
                throw new InvalidOperationException("water_vendor_first_live_preview_contract_failed");
            if (WaterBrokerOfferIcons.RequiredOfferIds.Count != 55 ||
                WaterBrokerOfferIcons.RequiredOfferIds.Any(offerId =>
                {
                    var icon = WaterBrokerOfferIcons.Resolve(offerId);
                    return icon is null || icon.Width < 1 || icon.Height < 1;
                }) ||
                firstLivePreview.Offers.Any(offer => WaterBrokerOfferIcons.Resolve(offer.IconKey) is null) ||
                WaterBrokerOfferIcons.Resolve("unknown_offer") is not null)
                throw new InvalidOperationException("water_vendor_embedded_portrait_manifest_failed");

            var detectedVendorDirectory = Path.Combine(root, "water-trader");
            Directory.CreateDirectory(detectedVendorDirectory);
            var detectedVendorState = Path.Combine(detectedVendorDirectory, "overlay-v1.txt");
            var detectedVendorCommand = Path.Combine(detectedVendorDirectory, "command-v1.txt");
            var detectedVendorInput = Path.Combine(detectedVendorDirectory, "water-broker-input-v1.txt");
            File.WriteAllText(detectedVendorState, vendorPayload, new UTF8Encoding(false));
            var detectedOptions = OverlayOptions.Parse(new[]
            {
                "--state", detectedVendorState, "--command", detectedVendorCommand
            });
            if (detectedOptions.VendorStatePath != Path.GetFullPath(detectedVendorState) ||
                detectedOptions.VendorCommandPath != Path.GetFullPath(detectedVendorCommand) ||
                detectedOptions.VendorInputPath != Path.GetFullPath(detectedVendorInput) ||
                !detectedOptions.VendorOnly)
                throw new InvalidOperationException("water_vendor_legacy_launch_autodetection_failed");
            var explicitVendorOnly = OverlayOptions.Parse(new[]
            {
                "--vendor-only", "--vendor-state", detectedVendorState,
                "--vendor-command", detectedVendorCommand,
                "--vendor-input", detectedVendorInput
            });
            if (!explicitVendorOnly.VendorOnly ||
                explicitVendorOnly.VendorStatePath != Path.GetFullPath(detectedVendorState) ||
                explicitVendorOnly.VendorCommandPath != Path.GetFullPath(detectedVendorCommand) ||
                explicitVendorOnly.VendorInputPath != Path.GetFullPath(detectedVendorInput))
                throw new InvalidOperationException("water_vendor_explicit_isolation_options_failed");
            var questOptions = OverlayOptions.Parse(new[] { "--state", Path.Combine(root, "quest-overlay-v2.txt") });
            if (questOptions.VendorStatePath != Path.Combine(root, "water-trader", "overlay-v1.txt") ||
                questOptions.VendorCommandPath != Path.Combine(root, "water-trader", "command-v1.txt") ||
                questOptions.VendorInputPath != Path.Combine(root, "water-trader", "water-broker-input-v1.txt"))
                throw new InvalidOperationException("water_vendor_companion_autodetection_failed");
            var contractsOnlyOptions = OverlayOptions.Parse(new[]
            {
                "--contracts-only", "--state", Path.Combine(root, "quest-overlay-v2.txt")
            });
            if (!contractsOnlyOptions.ContractsOnly || contractsOnlyOptions.VendorOnly)
                throw new InvalidOperationException("contract_companion_explicit_isolation_options_failed");
            var conflictingIsolationRejected = false;
            try
            {
                OverlayOptions.Parse(new[]
                {
                    "--contracts-only", "--vendor-only",
                    "--state", Path.Combine(root, "quest-overlay-v2.txt")
                });
            }
            catch (ArgumentException)
            {
                conflictingIsolationRejected = true;
            }
            if (!conflictingIsolationRejected)
                throw new InvalidOperationException("conflicting_isolation_options_must_reject");

            var quote = WaterPurchaseConfirmation.Create(vendor, 1);
            var multiQuote = WaterPurchaseConfirmation.Create(vendor, 3);
            if (!vendor.Matches(multiQuote) || multiQuote.ExpectedTotalWaterCost != 6 ||
                multiQuote.ExpectedTotalQuantity != 360 || multiQuote.PurchaseUnits != 3 ||
                vendor.MaximumPurchaseUnits() != 5)
                throw new InvalidOperationException("water_vendor_multi_quantity_quote_self_test_failed");
            var vendorCommandPath = Path.Combine(root, "water-command.txt");
            if (!WaterVendorCommandFile.TryWrite(vendorCommandPath, vendor.SessionId, 2,
                    "purchase", quote, out error))
                throw new InvalidOperationException("water_vendor_command_write_self_test_failed:" + error);
            if (WaterVendorCommandFile.ReadLatestSequence(vendorCommandPath, vendor.SessionId) != 2 ||
                WaterVendorCommandFile.ReadLatestSequence(vendorCommandPath, "different-session") != 0)
                throw new InvalidOperationException("water_vendor_command_sequence_self_test_failed");
            var vendorCommandPayload = File.ReadAllText(vendorCommandPath);
            var exactCommandKeys = new[]
            {
                "format", "session_id", "sequence", "command", "offer_id", "snapshot_revision",
                "rotation_index", "purchase_units", "expected_unit_water_cost",
                "expected_total_water_cost", "expected_grant_quantity_per_unit",
                "expected_total_quantity", "expected_remaining", "expected_purchase_ready",
                "quote_fingerprint", "issued_at_utc", "complete"
            };
            var writtenCommandKeys = vendorCommandPayload.Split(
                    new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries)
                .Select(line => line[..line.IndexOf('=')]).ToArray();
            if (!writtenCommandKeys.SequenceEqual(exactCommandKeys))
                throw new InvalidOperationException("water_vendor_command_schema_or_order_changed");
            foreach (var expectedLine in new[]
                     {
                         "command=purchase", "offer_id=ammo_545", "snapshot_revision=5",
                         "rotation_index=12", "purchase_units=1", "expected_unit_water_cost=2",
                         "expected_total_water_cost=2", "expected_grant_quantity_per_unit=120",
                         "expected_total_quantity=120", "expected_remaining=5", "expected_purchase_ready=1",
                         "quote_fingerprint=r12:ammo_545:w2:q120:m5:i5:s5:ready"
                     })
                if (!vendorCommandPayload.Contains(expectedLine, StringComparison.Ordinal))
                    throw new InvalidOperationException("water_vendor_command_field_missing:" + expectedLine);
            var malformedVendorCommandPath = Path.Combine(root, "malformed-water-command.txt");
            File.WriteAllText(malformedVendorCommandPath,
                vendorCommandPayload.Replace("sequence=2", "sequence=2\nsequence=3", StringComparison.Ordinal),
                new UTF8Encoding(false));
            if (WaterVendorCommandFile.ReadLatestSequence(malformedVendorCommandPath,
                    vendor.SessionId) != 0)
                throw new InvalidOperationException("water_vendor_duplicate_command_key_must_reject");
            File.WriteAllText(malformedVendorCommandPath,
                vendorCommandPayload + new string('x', 16 * 1024), new UTF8Encoding(false));
            if (WaterVendorCommandFile.ReadLatestSequence(malformedVendorCommandPath,
                    vendor.SessionId) != 0)
                throw new InvalidOperationException("water_vendor_command_payload_cap_must_reject");
            if (!WaterVendorCommandFile.TryWrite(vendorCommandPath, vendor.SessionId, 3,
                    "select_offer", WaterPurchaseConfirmation.Create(vendor.SelectIndex(1), 1), out error) ||
                WaterVendorCommandFile.ReadLatestSequence(vendorCommandPath, vendor.SessionId) != 3)
                throw new InvalidOperationException("water_vendor_select_command_self_test_failed:" + error);
            var presentationOnly = vendor with
            {
                StorefrontStatus = "presentation_only",
                BlockingReason = "native_purchase_disabled",
                Offers = vendor.Offers.Select(offer => offer with
                {
                    PurchaseReady = false,
                    PurchaseBlockReason = "native_purchase_disabled",
                    QuoteFingerprint = offer.QuoteFingerprint.Replace(":ready", ":blocked",
                        StringComparison.Ordinal)
                }).ToArray()
            };
            var presentationOnlyQuote = WaterPurchaseConfirmation.Create(presentationOnly, 1);
            if (!WaterVendorCommandFile.TryWrite(vendorCommandPath, vendor.SessionId, 4,
                    "select_offer", presentationOnlyQuote, out error) ||
                WaterVendorCommandFile.TryWrite(vendorCommandPath, vendor.SessionId, 5,
                    "purchase", presentationOnlyQuote, out _))
                throw new InvalidOperationException("presentation_only_command_gate_self_test_failed:" + error);

            var testedViewports = new[]
            {
                new Rectangle(0, 0, 1280, 720),
                new Rectangle(100, 50, 1920, 1080),
                new Rectangle(0, 0, 2560, 1440),
                new Rectangle(0, 0, 3440, 1440),
                new Rectangle(0, 0, 3840, 2160),
                new Rectangle(0, 0, 5120, 1440),
            };
            foreach (var viewport in testedViewports)
            {
                var placement = QuestPanelLayout.Place(viewport, QuestSnapshot.PreviewRaid());
                if (!viewport.Contains(placement.Bounds) ||
                    placement.Bounds.Right > viewport.Right - placement.ReservedNativeQuestLane - placement.Gap ||
                    placement.Bounds.Left <= viewport.Left || placement.Bounds.Top <= viewport.Top ||
                    placement.Scale <= 0 || placement.Gap <= 0 || placement.ReservedNativeQuestLane <= 0)
                    throw new InvalidOperationException($"adaptive_placement_self_test_failed:{viewport.Width}x{viewport.Height}");
            }
            var ultraWidePlacement = QuestPanelLayout.Place(
                new Rectangle(0, 0, 5120, 1440), QuestSnapshot.PreviewRaid());
            if (ultraWidePlacement.ReservedNativeQuestLane != 749 ||
                ultraWidePlacement.Bounds.X != 3943 ||
                ultraWidePlacement.Bounds.Right + ultraWidePlacement.Gap != 5120 - ultraWidePlacement.ReservedNativeQuestLane ||
                Math.Abs(ultraWidePlacement.Scale - 1f) > 0.001f ||
                ultraWidePlacement.Anchor != "adaptive_native_quest_close_adjacency")
                throw new InvalidOperationException("ultrawide_native_quest_adjacency_self_test_failed");
            var standardPlacement = QuestPanelLayout.Place(
                new Rectangle(0, 0, 1920, 1080), QuestSnapshot.PreviewRaid());
            var fourKPlacement = QuestPanelLayout.Place(
                new Rectangle(0, 0, 3840, 2160), QuestSnapshot.PreviewRaid());
            if (standardPlacement.Scale >= ultraWidePlacement.Scale ||
                fourKPlacement.Scale <= ultraWidePlacement.Scale)
                throw new InvalidOperationException("dynamic_scale_order_self_test_failed");
            if (QuestSnapshot.PreviewRaid().VisibleRaidContracts.Count != 3)
                throw new InvalidOperationException("multi_contract_raid_stack_self_test_failed");
            if (QuestPanelLayout.PanelBackgroundAlpha > 80)
                throw new InvalidOperationException("panel_background_is_not_highly_translucent");
            if (ContractPresentationText.Counter(0, 3, true) != "0/3" ||
                ContractPresentationText.Counter(2, 3, true) != "2/3" ||
                ContractPresentationText.Counter(0, 3, false) != "0/3" ||
                ContractPresentationText.Fee(2) != "CONTRACT FEE  //  2 WATER" ||
                ContractPresentationText.FeePaid(2) != "CONTRACT FEE PAID  //  2 WATER")
                throw new InvalidOperationException("compact_contract_copy_self_test_failed");

            var sameBounds = new Rectangle(10, 20, 402, 310);
            if (!LayeredSurfaceLifecycle.ShouldRender(true, 4, sameBounds, 4, sameBounds))
                throw new InvalidOperationException("reveal_must_force_layered_redraw");
            if (LayeredSurfaceLifecycle.ShouldRender(false, 4, sameBounds, 4, sameBounds))
                throw new InvalidOperationException("unchanged_visible_surface_should_not_redraw");
            if (!LayeredSurfaceLifecycle.ShouldRender(false, 3, sameBounds, 4, sameBounds))
                throw new InvalidOperationException("revision_change_must_redraw");
            if (!LayeredSurfaceLifecycle.ShouldRender(false, 4, Rectangle.Empty, 4, sameBounds))
                throw new InvalidOperationException("placement_change_must_redraw");

            var clickThroughStyle = OverlayWindowStyle.ForMode(OverlayWindowStyle.TopMost, interactive: false);
            if (!OverlayWindowStyle.Has(clickThroughStyle, OverlayWindowStyle.Layered) ||
                !OverlayWindowStyle.Has(clickThroughStyle, OverlayWindowStyle.ToolWindow) ||
                !OverlayWindowStyle.Has(clickThroughStyle, OverlayWindowStyle.NoActivate) ||
                !OverlayWindowStyle.Has(clickThroughStyle, OverlayWindowStyle.Transparent))
                throw new InvalidOperationException("click_through_window_style_policy_failed");
            var interactiveStyle = OverlayWindowStyle.ForMode(clickThroughStyle, interactive: true);
            if (!OverlayWindowStyle.Has(interactiveStyle, OverlayWindowStyle.Layered) ||
                !OverlayWindowStyle.Has(interactiveStyle, OverlayWindowStyle.ToolWindow) ||
                !OverlayWindowStyle.Has(interactiveStyle, OverlayWindowStyle.NoActivate) ||
                OverlayWindowStyle.Has(interactiveStyle, OverlayWindowStyle.Transparent))
                throw new InvalidOperationException("interactive_no_activate_window_style_policy_failed");

            var waitingVendor = WaterVendorSnapshot.Waiting();
            if (OverlayLayout.ResolveMode(QuestSnapshot.Waiting(), waitingVendor, HubSurface.None) != OverlayMode.Hidden)
                throw new InvalidOperationException("title_stage_must_hide_contract_launcher");
            if (OverlayLayout.ResolveMode(QuestSnapshot.Preview(), waitingVendor, HubSurface.None) != OverlayMode.HubLauncher)
                throw new InvalidOperationException("exact_hub_must_offer_contract_launcher");
            if (OverlayLayout.ResolveMode(QuestSnapshot.Preview(), vendor, HubSurface.Contracts) != OverlayMode.ContractBoard)
                throw new InvalidOperationException("exact_hub_board_open_mode_failed");
            if (OverlayLayout.ResolveMode(QuestSnapshot.Waiting(), vendor, HubSurface.WaterTrader) != OverlayMode.WaterTrader)
                throw new InvalidOperationException("water_trader_open_mode_failed");
            if (OverlayLayout.ResolveMode(QuestSnapshot.PreviewRaid(), vendor, HubSurface.WaterTrader) != OverlayMode.RaidTracker)
                throw new InvalidOperationException("raid_must_force_click_through_tracker");
            if (OverlayLayout.ResolveMode(QuestSnapshot.PreviewRaid(), vendor, HubSurface.WaterTrader,
                    vendorOnly: true) != OverlayMode.WaterTrader)
                throw new InvalidOperationException("vendor_only_must_ignore_stale_contract_raid_state");
            if (OverlayLayout.ResolveMode(QuestSnapshot.Preview(), vendor, HubSurface.WaterTrader,
                    contractsOnly: true) != OverlayMode.HubLauncher)
                throw new InvalidOperationException("contracts_only_must_ignore_stale_vendor_surface");
            if (OverlayLayout.ResolveMode(QuestSnapshot.Waiting(), vendor, HubSurface.None,
                    contractsOnly: true) != OverlayMode.Hidden)
                throw new InvalidOperationException("contracts_only_must_ignore_stale_vendor_launcher");
            foreach (var viewport in testedViewports)
            {
                foreach (var mode in new[] { OverlayMode.HubLauncher, OverlayMode.ContractBoard, OverlayMode.WaterTrader })
                {
                    var placement = OverlayLayout.Place(viewport, QuestSnapshot.Preview(), vendor, mode);
                    if (!viewport.Contains(placement.Bounds) || placement.Scale <= 0)
                        throw new InvalidOperationException($"hub_surface_placement_failed:{mode}:{viewport.Width}x{viewport.Height}");
                    if (mode == OverlayMode.ContractBoard)
                    {
                        if (placement.Bounds != viewport ||
                            placement.Anchor != "hub_full_client_centered_safe_area")
                            throw new InvalidOperationException($"contract_board_not_full_client:{viewport.Width}x{viewport.Height}");
                        var safe = ContractBoardLayout.InnerBounds(viewport.Size);
                        var list = ContractBoardLayout.ListBounds(viewport.Size);
                        var details = ContractBoardLayout.DetailsBounds(viewport.Size);
                        var action = ContractBoardLayout.ActionButton(viewport.Size);
                        if (!new Rectangle(Point.Empty, viewport.Size).Contains(safe) ||
                            !safe.Contains(list) || !safe.Contains(details) ||
                            !details.Contains(action))
                            throw new InvalidOperationException($"contract_board_safe_area_failed:{viewport.Width}x{viewport.Height}");
                        for (var cardIndex = 0; cardIndex < 3; cardIndex++)
                            if (!list.Contains(ContractBoardLayout.ContractCard(viewport.Size, cardIndex)))
                                throw new InvalidOperationException($"contract_card_overflow:{viewport.Width}x{viewport.Height}:{cardIndex}");
                    }
                    if (mode == OverlayMode.WaterTrader)
                    {
                        if (placement.Bounds != viewport ||
                            placement.Anchor != "hub_full_client_centered_safe_area_with_shopkeeper")
                            throw new InvalidOperationException($"water_broker_not_full_client:{viewport.Width}x{viewport.Height}");
                        var safe = WaterTraderLayout.InnerBounds(viewport.Size);
                        var content = WaterTraderLayout.ContentBounds(viewport.Size);
                        var shopkeeper = WaterTraderLayout.ShopkeeperBounds(viewport.Size);
                        var offers = WaterTraderLayout.OfferListBounds(viewport.Size);
                        var details = WaterTraderLayout.DetailsBounds(viewport.Size);
                        var purchase = WaterTraderLayout.PurchaseButton(viewport.Size);
                        if (!new Rectangle(Point.Empty, viewport.Size).Contains(safe) ||
                            !safe.Contains(content) || !content.Contains(shopkeeper) ||
                            !content.Contains(offers) || !content.Contains(details) ||
                            !details.Contains(purchase) || shopkeeper.IntersectsWith(offers) ||
                            offers.IntersectsWith(details))
                            throw new InvalidOperationException($"water_broker_safe_area_failed:{viewport.Width}x{viewport.Height}");
                        for (var cardIndex = 0; cardIndex < WaterTraderLayout.MaximumVisibleOffers; cardIndex++)
                            if (!offers.Contains(WaterTraderLayout.OfferCard(viewport.Size, cardIndex)))
                                throw new InvalidOperationException($"water_broker_card_overflow:{viewport.Width}x{viewport.Height}:{cardIndex}");
                        foreach (var control in new[]
                                 {
                                     WaterTraderLayout.QuantityDecreaseButton(viewport.Size),
                                     WaterTraderLayout.QuantityValue(viewport.Size),
                                     WaterTraderLayout.QuantityIncreaseButton(viewport.Size),
                                     WaterTraderLayout.QuantityMaxButton(viewport.Size),
                                     WaterTraderLayout.ConfirmButton(viewport.Size),
                                     WaterTraderLayout.CancelButton(viewport.Size),
                                 })
                            if (!details.Contains(control))
                                throw new InvalidOperationException($"water_broker_control_overflow:{viewport.Width}x{viewport.Height}:{control}");
                    }
                }
            }
            var boardSize = ContractBoardLayout.WindowSize(1f);
            var actionCenter = new Point(
                ContractBoardLayout.ActionButton(boardSize).Left + 10,
                ContractBoardLayout.ActionButton(boardSize).Top + 10);
            if (OverlayHitTesting.HitTest(OverlayMode.ContractBoard, boardSize, actionCenter,
                    QuestSnapshot.Preview(), vendor, null, false) != OverlayHitTarget.Accept)
                throw new InvalidOperationException("available_contract_accept_hit_target_failed");
            var acceptedPreview = QuestSnapshot.PreviewAccepted();
            if (OverlayHitTesting.HitTest(OverlayMode.ContractBoard, boardSize, actionCenter,
                    acceptedPreview, vendor, null, false) != OverlayHitTarget.Discard)
                throw new InvalidOperationException("accepted_contract_discard_hit_target_failed");
            var secondCard = ContractBoardLayout.ContractCard(boardSize, 1);
            if (OverlayHitTesting.HitTest(OverlayMode.ContractBoard, boardSize,
                    new Point(secondCard.Left + 10, secondCard.Top + 10), QuestSnapshot.Preview(),
                    vendor, null, false) != OverlayHitTarget.ContractAt(1))
                throw new InvalidOperationException("second_contract_selection_hit_target_failed");
            var thirdCard = ContractBoardLayout.ContractCard(boardSize, 2);
            if (OverlayHitTesting.HitTest(OverlayMode.ContractBoard, boardSize,
                    new Point(thirdCard.Left + 10, thirdCard.Top + 10), QuestSnapshot.Preview(),
                    vendor, null, false) != OverlayHitTarget.ContractAt(2))
                throw new InvalidOperationException("third_contract_selection_hit_target_failed");
            if (OverlayHitTesting.HitTest(OverlayMode.HubLauncher,
                    HubLauncherLayout.WindowSize(1f), new Point(20, 20), QuestSnapshot.Preview(),
                    vendor, null, false) != OverlayHitTarget.OpenBoard)
                throw new InvalidOperationException("hub_contract_launcher_hit_target_failed");
            if (OverlayHitTesting.HitTest(OverlayMode.HubLauncher,
                    HubLauncherLayout.WindowSize(1f), new Point(20, 75), QuestSnapshot.Preview(),
                    vendor, null, false) != OverlayHitTarget.OpenWaterTrader)
                throw new InvalidOperationException("hub_water_trader_launcher_hit_target_failed");
            var vendorOnlyLauncherSize = HubLauncherLayout.WindowSize(1f, false, true);
            if (vendorOnlyLauncherSize.Height != 58 ||
                OverlayHitTesting.HitTest(OverlayMode.HubLauncher, vendorOnlyLauncherSize,
                    new Point(20, 20), QuestSnapshot.Waiting(), vendor, null, false) !=
                OverlayHitTarget.OpenWaterTrader)
                throw new InvalidOperationException("vendor_only_launcher_surface_failed");
            var contractOnlyPlacement = OverlayLayout.Place(new Rectangle(0, 0, 1920, 1080),
                QuestSnapshot.Preview(), WaterVendorSnapshot.Waiting(), OverlayMode.HubLauncher);
            var composedPlacement = OverlayLayout.Place(new Rectangle(0, 0, 1920, 1080),
                QuestSnapshot.Preview(), vendor, OverlayMode.HubLauncher);
            if (contractOnlyPlacement.Bounds.Height >= composedPlacement.Bounds.Height)
                throw new InvalidOperationException("contract_only_launcher_compatibility_failed");
            var traderSize = WaterTraderLayout.WindowSize(1f);
            if (!WaterBrokerShopkeeperPortrait.Available ||
                WaterBrokerShopkeeperPortrait.PixelSize.Width != 720 ||
                WaterBrokerShopkeeperPortrait.PixelSize.Height != 1280)
                throw new InvalidOperationException("water_broker_shopkeeper_portrait_resource_failed");
            var secondOffer = WaterTraderLayout.OfferCard(traderSize, 1);
            if (OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize,
                    new Point(secondOffer.Left + 8, secondOffer.Top + 8), snapshot, vendor,
                    null, false) != OverlayHitTarget.WaterOfferAt(1))
                throw new InvalidOperationException("water_vendor_indexed_offer_hit_target_failed");
            var purchasePoint = new Point(WaterTraderLayout.PurchaseButton(traderSize).Left + 8,
                WaterTraderLayout.PurchaseButton(traderSize).Top + 8);
            if (OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize, purchasePoint,
                    snapshot, vendor, null, false) != OverlayHitTarget.BeginPurchase ||
                OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize, purchasePoint,
                    snapshot, vendor, null, true) != OverlayHitTarget.None)
                throw new InvalidOperationException("water_vendor_first_click_or_pending_hit_target_failed");
            var confirmPoint = new Point(WaterTraderLayout.ConfirmButton(traderSize).Left + 8,
                WaterTraderLayout.ConfirmButton(traderSize).Top + 8);
            var cancelPoint = new Point(WaterTraderLayout.CancelButton(traderSize).Left + 8,
                WaterTraderLayout.CancelButton(traderSize).Top + 8);
            var minusPoint = new Point(WaterTraderLayout.QuantityDecreaseButton(traderSize).Left + 8,
                WaterTraderLayout.QuantityDecreaseButton(traderSize).Top + 8);
            var plusPoint = new Point(WaterTraderLayout.QuantityIncreaseButton(traderSize).Left + 8,
                WaterTraderLayout.QuantityIncreaseButton(traderSize).Top + 8);
            var maxPoint = new Point(WaterTraderLayout.QuantityMaxButton(traderSize).Left + 8,
                WaterTraderLayout.QuantityMaxButton(traderSize).Top + 8);
            if (WaterTraderLayout.PurchaseButton(traderSize).IntersectsWith(
                    WaterTraderLayout.ConfirmButton(traderSize)) ||
                WaterTraderLayout.PurchaseButton(traderSize).IntersectsWith(
                    WaterTraderLayout.CancelButton(traderSize)))
                throw new InvalidOperationException("water_vendor_confirmation_must_require_pointer_movement");
            if (OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize, confirmPoint,
                    snapshot, vendor, quote, false) != OverlayHitTarget.ConfirmPurchase ||
                OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize, cancelPoint,
                    snapshot, vendor, quote, false) != OverlayHitTarget.CancelPurchase ||
                OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize, minusPoint,
                    snapshot, vendor, quote, false) != OverlayHitTarget.DecreasePurchaseQuantity ||
                OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize, plusPoint,
                    snapshot, vendor, quote, false) != OverlayHitTarget.IncreasePurchaseQuantity ||
                OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize, maxPoint,
                    snapshot, vendor, quote, false) != OverlayHitTarget.MaxPurchaseQuantity ||
                OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize,
                    new Point(secondOffer.Left + 8, secondOffer.Top + 8), snapshot, vendor,
                    quote, false) != OverlayHitTarget.WaterOfferAt(1) ||
                OverlayHitTesting.HitTest(OverlayMode.WaterTrader, traderSize,
                    new Point(secondOffer.Left + 8, secondOffer.Top + 8), snapshot, vendor,
                    quote, true) != OverlayHitTarget.None)
                throw new InvalidOperationException("water_vendor_confirmation_hit_targets_failed");

            foreach (var mode in new[] { OverlayMode.HubLauncher, OverlayMode.ContractBoard, OverlayMode.WaterTrader })
            {
                var renderSize = OverlayLayout.WindowSize(mode, 1f);
                using var render = new Bitmap(renderSize.Width, renderSize.Height);
                using var graphics = Graphics.FromImage(render);
                OverlayRenderer.Draw(graphics, mode, renderSize, QuestSnapshot.Preview(), vendor,
                    false, OverlayHitTarget.None, null, false);
            }
            using (var confirmationRender = new Bitmap(traderSize.Width, traderSize.Height))
            using (var confirmationGraphics = Graphics.FromImage(confirmationRender))
                OverlayRenderer.Draw(confirmationGraphics, OverlayMode.WaterTrader, traderSize,
                    QuestSnapshot.Preview(), vendor, false, OverlayHitTarget.ConfirmPurchase,
                    quote, false);
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { }
        }
    }

    private static void RunPortableDefaultTests()
    {
        var local = OverlayOptions.ResolveLocalApplicationData();
        var expectedRoot = Path.Combine(local, "ForeverWinter", "Saved", "Water4", "v1",
            "FWIndependentFramework");
        var defaults = OverlayOptions.Parse(Array.Empty<string>());
        if (!defaults.StatePath.StartsWith(expectedRoot, StringComparison.OrdinalIgnoreCase) ||
            defaults.StatePath.Contains("ChatGPT", StringComparison.OrdinalIgnoreCase) ||
            defaults.StatePath.Contains("My Documents", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"portable_default_state_path_self_test_failed expected={expectedRoot} actual={defaults.StatePath}");

        var fixtureRoot = Path.Combine(Path.GetTempPath(), $"FWQuestOverlayOptions-{Guid.NewGuid():N}");
        var state = Path.Combine(fixtureRoot, "state.txt");
        var command = Path.Combine(fixtureRoot, "command.txt");
        var vendorState = Path.Combine(fixtureRoot, "vendor-state.txt");
        var vendorCommand = Path.Combine(fixtureRoot, "vendor-command.txt");
        var vendorInput = Path.Combine(fixtureRoot, "vendor-input.txt");
        var explicitOptions = OverlayOptions.Parse(new[]
        {
            "--state", state, "--command", command,
            "--vendor-state", vendorState, "--vendor-command", vendorCommand,
            "--vendor-input", vendorInput
        });
        if (explicitOptions.StatePath != Path.GetFullPath(state) ||
            explicitOptions.CommandPath != Path.GetFullPath(command) ||
            explicitOptions.VendorStatePath != Path.GetFullPath(vendorState) ||
            explicitOptions.VendorCommandPath != Path.GetFullPath(vendorCommand) ||
            explicitOptions.VendorInputPath != Path.GetFullPath(vendorInput))
            throw new InvalidOperationException("explicit_path_precedence_self_test_failed");
    }

    private static void RunRaidTrackerEligibilityTests()
    {
        var preview = QuestSnapshot.Preview();
        var staleHubVendor = WaterVendorSnapshot.Preview();
        var inactive = new[]
        {
            preview.Selected with { Id = "available", Status = "available", Accepted = false },
            preview.Selected with { Id = "accepted", Status = "accepted", Accepted = true },
            preview.Selected with { Id = "failed", Status = "failed", Accepted = false },
            preview.Selected with { Id = "complete", Status = "complete", Accepted = true },
            preview.Selected with { Id = "locked", Status = "locked", Accepted = false },
            preview.Selected with { Id = "unaccepted-active", Status = "active", Accepted = false },
        };
        var raid = preview with { RaidInProgress = true, HubAvailable = false, Contracts = inactive };
        foreach (var cards in new IReadOnlyList<ContractSnapshot>[] { inactive, Array.Empty<ContractSnapshot>() })
        {
            var emptyRaid = raid with { Contracts = cards };
            if (emptyRaid.VisibleRaidContracts.Count != 0)
                throw new InvalidOperationException("inactive_raid_cards_must_not_fall_back_to_selection");
            foreach (var surface in Enum.GetValues<HubSurface>())
            {
                if (OverlayLayout.ResolveMode(emptyRaid, staleHubVendor, surface) != OverlayMode.Hidden ||
                    OverlayLayout.ResolveMode(emptyRaid, staleHubVendor, surface, contractsOnly: true) != OverlayMode.Hidden)
                    throw new InvalidOperationException("empty_raid_must_hide_despite_stale_broker_hub_state");
            }
        }

        var firstActive = preview.Contracts[0] with { Status = "active", Accepted = true };
        var secondActive = preview.Contracts[1] with { Status = "active", Accepted = true };
        var mixed = raid with { Contracts = inactive.Concat(new[] { firstActive, secondActive }).ToArray() };
        for (var selected = 0; selected < mixed.Contracts.Count; selected++)
        {
            var selectedRaid = mixed.SelectIndex(selected);
            if (!selectedRaid.VisibleRaidContracts.Select(contract => contract.Id)
                    .SequenceEqual(new[] { firstActive.Id, secondActive.Id }) ||
                OverlayLayout.ResolveMode(selectedRaid, staleHubVendor, HubSurface.Contracts) != OverlayMode.RaidTracker)
                throw new InvalidOperationException("raid_tracker_must_preserve_all_accepted_active_cards_only");
        }
        var ended = mixed with { Contracts = mixed.Contracts.Select(contract => contract with { Status = "failed" }).ToArray() };
        if (OverlayLayout.ResolveMode(ended, staleHubVendor, HubSurface.None) != OverlayMode.Hidden)
            throw new InvalidOperationException("ending_last_active_contract_must_hide_raid_tracker");

        // F7's hub surface is still the full board, including unaccepted offers.
        foreach (var hub in new[] { preview, QuestSnapshot.PreviewAccepted() })
        {
            if (hub.Contracts.Count != 3 ||
                OverlayLayout.ResolveMode(hub, staleHubVendor, HubSurface.Contracts) != OverlayMode.ContractBoard ||
                OverlayLayout.ResolveMode(hub, staleHubVendor, HubSurface.None) != OverlayMode.HubLauncher)
                throw new InvalidOperationException("raid_eligibility_must_not_filter_hub_board");
        }
    }
}

internal sealed record ContractSnapshot(
    string Id, string Title, string Status, bool Accepted, int Attempt,
    int AcceptanceWaterCost, int AcceptanceWaterPaid,
    string Objective1Id, string Objective1Label, int Objective1Current, int Objective1Target,
    string Objective2Id, string Objective2Label, int Objective2Current, int Objective2Target,
    bool ExtractionSeen, bool RewardsEnabled, string RewardSummary,
    string Category, string Description, string FailureCondition, string RefundPolicy)
{
    public IReadOnlyList<ContractObjective>? ObjectiveList { get; init; }
    public IReadOnlyList<ContractObjective> Objectives => ObjectiveList ?? new[] {
        new ContractObjective(Objective1Id, Objective1Label, Objective1Current, Objective1Target),
        new ContractObjective(Objective2Id, Objective2Label, Objective2Current, Objective2Target)
    };
}
internal sealed record ContractObjective(string Id, string Label, int Current, int Target);

internal sealed record QuestSnapshot(
    long Revision, string SessionId, bool RaidInProgress, bool HubAvailable,
    string LastReason, bool CommandEnabled, IReadOnlyList<ContractSnapshot> Contracts, int SelectedIndex)
{
    public long? BoardRevision { get; init; }
    public bool BoardLocked { get; init; }
    public string BoardReason { get; init; } = "";
    public int BoardCapacity { get; init; } = 6;
    public int BoardVacantCount { get; init; }
    public bool HasContractBoard => Contracts.Count > 0 || BoardRevision.HasValue;
    public bool CanChangeContracts => CommandEnabled && !BoardLocked && Contracts.Count > 0 &&
        HubAvailable && !RaidInProgress;
    public string BoardNotice => BoardLocked
        ? "Contract changes are unavailable. You can close this board normally."
        : Contracts.Count == 0
            ? "No contracts are available. More eligible contracts are needed before this board can refill."
            : BoardVacantCount > 0
                ? $"{BoardVacantCount} open slots. Complete a listed contract to bring in another offer."
                : "";
    private static readonly ContractSnapshot Offline = new(
        "", "WAITING FOR FRAMEWORK", "offline", false, 0, 0, 0,
        "target_kills", "ELIMINATE TARGETS", 0, 1,
        "target_items", "RECOVER ITEMS", 0, 1,
        false, false, "NO REWARD CONFIGURED", "OFFLINE",
        "Waiting for the independent Contract framework.",
        "Complete every objective and extract alive in the same raid.",
        "Contract fees are nonrefundable after acceptance.");

    public ContractSnapshot Selected => Contracts.Count == 0
        ? Offline : Contracts[Math.Clamp(SelectedIndex, 0, Contracts.Count - 1)];
    public string QuestId => Selected.Id;
    public string Title => Selected.Title;
    public string Status => Selected.Status;
    public bool Accepted => Selected.Accepted;
    public int AcceptanceWaterCost => Selected.AcceptanceWaterCost;
    public int AcceptanceWaterPaid => Selected.AcceptanceWaterPaid;
    public int KillCurrent => Selected.Objective1Current;
    public int KillTarget => Selected.Objective1Target;
    public int WaterCurrent => Selected.Objective2Current;
    public int WaterTarget => Selected.Objective2Target;
    public string Objective1Label => Selected.Objective1Label;
    public string Objective2Label => Selected.Objective2Label;
    public bool ExtractionSeen => Selected.ExtractionSeen;
    public bool RewardsEnabled => Selected.RewardsEnabled;
    public string RewardSummary => Selected.RewardSummary;
    public string Category => Selected.Category;
    public string Description => Selected.Description;
    public string FailureCondition => Selected.FailureCondition;
    public string RefundPolicy => Selected.RefundPolicy;
    public int AvailableCount => Contracts.Count(contract =>
        contract.Status is "available" or "failed" or "complete");
    public IReadOnlyList<ContractSnapshot> VisibleRaidContracts =>
        Contracts.Where(contract => contract.Accepted && contract.Status == "active").ToArray();

    public QuestSnapshot SelectIndex(int index) => this with
    {
        SelectedIndex = Contracts.Count == 0 ? 0 : Math.Clamp(index, 0, Contracts.Count - 1)
    };

    public QuestSnapshot SelectById(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return this;
        for (var index = 0; index < Contracts.Count; index++)
            if (string.Equals(Contracts[index].Id, id, StringComparison.Ordinal))
                return this with { SelectedIndex = index };
        return this;
    }

    public static QuestSnapshot Waiting() => new(0, "", false, false,
        "state_file_not_ready", false, Array.Empty<ContractSnapshot>(), 0);

    public static QuestSnapshot Preview()
    {
        var contracts = PreviewContracts("available", false, 0, 0);
        return new QuestSnapshot(7, "preview-session", false, true, "hub_available", true, contracts, 0);
    }

    public static QuestSnapshot PreviewAccepted()
    {
        var contracts = PreviewContracts("accepted", true, 0, 0);
        return new QuestSnapshot(8, "preview-session", false, true, "quest_accept_requested", true, contracts, 0);
    }

    public static QuestSnapshot PreviewRaid()
    {
        var contracts = PreviewContracts("active", true, 2, 1);
        return new QuestSnapshot(9, "preview-session", true, false, "item_collected", true, contracts, 0);
    }

    private static IReadOnlyList<ContractSnapshot> PreviewContracts(string status, bool accepted,
        int firstProgress, int secondProgress) => new[]
    {
        new ContractSnapshot("europan_infantry_water_reward_stress_test", "CULL AND CARRY", status,
            accepted, status == "active" ? 1 : 0, 1, accepted ? 1 : 0,
            "europan_infantry", "ELIMINATE EUROPAN INFANTRY", firstProgress, 5,
            "water_barrel", "RECOVER WATER BARRELS", secondProgress, 2,
            false, true, "1,111 CR  /  500 XP  /  USP\nPOWER CELL  /  1 WATER",
            "COMBAT + RECOVERY", "Thin Europan patrols and recover Water for the Innards in one deployment.",
            "Complete every objective and extract alive in the same raid.",
            "Contract fees are nonrefundable after acceptance."),
        new ContractSnapshot("euruskan_drones_vodka_single_raid", "ROTORS AND SPIRITS", status,
            accepted, status == "active" ? 1 : 0, 1, accepted ? 1 : 0,
            "euruskan_drones", "DESTROY EURUSKAN DRONES", firstProgress, 3,
            "vodka", "RECOVER VODKA", secondProgress, 3,
            false, true, "10,000 CR  /  2,000 XP\n1 EXPLOSIVES",
            "ANTI-AIR + RECOVERY", "Destroy Euruskan aerial patrols and recover Vodka for the Innards in one deployment.",
            "Complete every objective and extract alive in the same raid.",
            "Contract fees are nonrefundable after acceptance."),
        new ContractSnapshot("cultists_lockboxes_single_raid", "TITHES BELOW", status,
            accepted, status == "active" ? 1 : 0, 2, accepted ? 2 : 0,
            "cultists", "ELIMINATE CULTISTS", firstProgress, 4,
            "large_lockboxes", "RECOVER LARGE LOCKBOXES", secondProgress, 3,
            false, true, "20,000 CR  /  2,500 XP\nR8  /  .357 MAGNUM",
            "TUNNEL PURGE + RECOVERY", "Break a Cultist cell and recover its sealed lockboxes from the tunnels in one deployment.",
            "Complete every objective and extract alive in the same raid.",
            "Contract fees are nonrefundable after acceptance."),
    };

    public static bool TryParse(string payload, out QuestSnapshot snapshot)
    {
        snapshot = Waiting();
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in payload.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = rawLine.IndexOf('=');
            if (separator <= 0) continue;
            values[rawLine[..separator].Trim()] = Decode(rawLine[(separator + 1)..].Trim());
        }
        if (Get(values, "format", "") != "fwif.contracts.overlay.v1" ||
            Get(values, "complete", "") != "1" || !TryLong(values, "revision", out var revision) ||
            !TryInt(values, "contract_count", out var count) || count < 0 || count > 8)
            return false;
        long? boardRevision = null;
        var boardLocked = false;
        var boardCapacity = 6;
        var vacantCount = 0;
        if (values.ContainsKey("board_revision"))
        {
            if (!TryLong(values, "board_revision", out var parsedBoardRevision) ||
                parsedBoardRevision < 0 || parsedBoardRevision > 9007199254740991L ||
                !TryInt(values, "board_capacity", out boardCapacity) || boardCapacity < 0 || boardCapacity > 8 ||
                !TryInt(values, "board_vacant_count", out vacantCount) || vacantCount < 0 ||
                vacantCount > boardCapacity || count > boardCapacity ||
                Get(values, "board_locked", "0") is not ("0" or "1")) return false;
            boardRevision = parsedBoardRevision;
            boardLocked = Get(values, "board_locked", "0") == "1";
        }
        var sessionId = Get(values, "session_id", "");
        var commandEnabled = Get(values, "command_enabled", "0") == "1" && !boardLocked && count > 0;
        // A rotating board remains openable when empty or locked; its input
        // lease still requires the session even when no action can be sent.
        if ((commandEnabled || boardRevision.HasValue) && string.IsNullOrWhiteSpace(sessionId)) return false;
        var contracts = new List<ContractSnapshot>(count);
        for (var index = 1; index <= count; index++)
        {
            var prefix = $"contract_{index}_";
            TryInt(values, prefix + "attempt", out var attempt);
            TryInt(values, prefix + "acceptance_water_cost", out var cost);
            TryInt(values, prefix + "acceptance_water_paid", out var paid);
            TryInt(values, prefix + "objective_1_current", out var objective1Current);
            TryInt(values, prefix + "objective_1_target", out var objective1Target);
            TryInt(values, prefix + "objective_2_current", out var objective2Current);
            TryInt(values, prefix + "objective_2_target", out var objective2Target);
            var id = Get(values, prefix + "id", "");
            if (string.IsNullOrWhiteSpace(id)) return false;
            IReadOnlyList<ContractObjective>? objectives = null;
            if (values.ContainsKey(prefix + "objective_count"))
            {
                if (!TryInt(values, prefix + "objective_count", out var objectiveCount) ||
                    objectiveCount < 1 || objectiveCount > 8) return false;
                var parsed = new List<ContractObjective>();
                for (var oi = 1; oi <= objectiveCount; oi++)
                {
                    var op = prefix + $"objective_{oi}_";
                    if (!TryInt(values, op + "current", out var current) || current < 0 ||
                        !TryInt(values, op + "target", out var target) || target < 1 || current > target ||
                        string.IsNullOrWhiteSpace(Get(values, op + "id", "")) ||
                        string.IsNullOrWhiteSpace(Get(values, op + "label", ""))) return false;
                    parsed.Add(new ContractObjective(Get(values, op + "id", ""), Get(values, op + "label", ""), current, target));
                }
                if (parsed.Select(o => o.Id).Distinct().Count() != parsed.Count) return false;
                objectives = parsed;
            }
            contracts.Add(new ContractSnapshot(
                id, Get(values, prefix + "title", "Unknown Contract"),
                Get(values, prefix + "status", "offline"),
                Get(values, prefix + "accepted", "0") == "1", Math.Max(0, attempt),
                Math.Max(0, cost), Math.Max(0, paid),
                Get(values, prefix + "objective_1_id", "target_kills"),
                Get(values, prefix + "objective_1_label", "ELIMINATE TARGETS"),
                Math.Max(0, objective1Current), Math.Max(1, objective1Target),
                Get(values, prefix + "objective_2_id", "target_items"),
                Get(values, prefix + "objective_2_label", "RECOVER ITEMS"),
                Math.Max(0, objective2Current), Math.Max(1, objective2Target),
                Get(values, prefix + "extraction_seen", "0") == "1",
                Get(values, prefix + "rewards_enabled", "0") == "1",
                Get(values, prefix + "reward_summary", "NO REWARD CONFIGURED"),
                Get(values, prefix + "category", "COMBAT + RECOVERY"),
                Get(values, prefix + "description", "Complete the listed objectives in one deployment."),
                Get(values, prefix + "failure_condition", "Complete every objective and extract alive in the same raid."),
                Get(values, prefix + "refund_policy", "Contract fees are nonrefundable after acceptance.")) { ObjectiveList = objectives });
        }
        TryInt(values, "selected_contract_index", out var selectedIndex);
        snapshot = new QuestSnapshot(revision, sessionId,
            Get(values, "raid_in_progress", "0") == "1",
            Get(values, "hub_available", "0") == "1",
            Get(values, "last_reason", "unknown"), commandEnabled, contracts,
            contracts.Count == 0 ? 0 : Math.Clamp(selectedIndex - 1, 0, contracts.Count - 1))
        {
            BoardRevision = boardRevision,
            BoardLocked = boardLocked,
            BoardReason = Get(values, "board_reason", ""),
            BoardCapacity = boardCapacity,
            BoardVacantCount = vacantCount,
        };
        return true;
    }

    private static string Get(Dictionary<string, string> values, string key, string fallback) =>
        values.TryGetValue(key, out var value) ? value : fallback;
    private static bool TryInt(Dictionary<string, string> values, string key, out int value) =>
        int.TryParse(Get(values, key, "0"), out value);
    private static bool TryLong(Dictionary<string, string> values, string key, out long value) =>
        long.TryParse(Get(values, key, "0"), out value);
    private static string Decode(string value) => value.Replace("%0A", "\n").Replace("%0D", "\r").Replace("%3D", "=").Replace("%25", "%");
}

internal sealed record WaterOfferSnapshot(
    string Id, string DisplayName, string Category, string InventoryKind,
    int UnitWaterCost, int GrantQuantityPerUnit, int MaxPurchaseUnits, int InitialStock, int Remaining,
    bool PurchaseReady, string PurchaseBlockReason, string FulfillmentEvidence,
    string QuoteFingerprint, string ItemKey = "", string IconKey = "", string RouteId = "",
    int MaxGrantQuantity = 999, int MaxTotalWaterCost = 1_000_000)
{
    public int TechnicalMaximumUnits => GrantQuantityPerUnit < 1 || UnitWaterCost < 1 ? 0 :
        Math.Max(0, Math.Min(MaxPurchaseUnits,
            Math.Min(Math.Min(MaxGrantQuantity, 999) / GrantQuantityPerUnit,
                Math.Min(MaxTotalWaterCost, 1_000_000) / UnitWaterCost)));
}

internal static class WaterTraderRotationClock
{
    public static long RemainingSeconds(long refreshDeadline, long nowUnixSeconds)
        => refreshDeadline <= 0 ? -1 : Math.Max(0, refreshDeadline - nowUnixSeconds);

    public static string Label(long refreshDeadline, long nowUnixSeconds)
    {
        var remaining = RemainingSeconds(refreshDeadline, nowUnixSeconds);
        if (remaining < 0) return "RESET UNKNOWN";
        if (remaining == 0) return "RESET PENDING";
        var hours = remaining / 3600;
        var minutes = remaining % 3600 / 60;
        var seconds = remaining % 60;
        return $"RESET IN {hours:00}:{minutes:00}:{seconds:00}";
    }
}

internal static class WaterVendorPresentationText
{
    public const string NormalMarketSubtitle = "ROTATING SUPPLIES  /  WATER SETTLEMENT";

    private static string Requirement(string label, int unlockWater) => unlockWater > 0
        ? $"{label} {unlockWater}+ WATER"
        : $"{label} DISABLED BY CONFIG";

    public static string MarketSubtitle(WaterVendorSnapshot snapshot)
    {
        if (snapshot.WeaponsAllowed && snapshot.SpecialItemsAllowed) return NormalMarketSubtitle;
        if (!snapshot.WeaponsAllowed && !snapshot.SpecialItemsAllowed &&
            snapshot.WeaponUnlockWater > 0 &&
            snapshot.WeaponUnlockWater == snapshot.SpecialItemUnlockWater)
            return $"INSUFFICIENT WATER SUPPLY FOR WEAPON / SPECIAL ITEM CATEGORIES  //  " +
                   $"{snapshot.WeaponUnlockWater}+ REQUIRED";

        var requirements = new List<string>(2);
        if (!snapshot.WeaponsAllowed)
            requirements.Add(Requirement("WEAPONS", snapshot.WeaponUnlockWater));
        if (!snapshot.SpecialItemsAllowed)
            requirements.Add(Requirement("SPECIAL ITEMS", snapshot.SpecialItemUnlockWater));
        return "RESTRICTED MARKET  //  " + string.Join("  /  ", requirements);
    }
}

internal sealed record WaterVendorSnapshot(
    long Revision, string SessionId, string VendorId, string VendorTitle,
    bool HubAvailable, bool CommandEnabled, bool WaterKnown,
    int WaterBalance, long RotationIndex, string StockBandId,
    bool WeaponsAllowed, bool SpecialItemsAllowed, int WeaponUnlockWater, int SpecialItemUnlockWater,
    long RefreshDeadline, string StorefrontStatus,
    string BlockingReason, string TransactionId, string TransactionStatus,
    string LastResultCode, string LastResultMessage, IReadOnlyList<WaterOfferSnapshot> Offers,
    int SelectedIndex, string LastReason)
{
    private const int MaximumPayloadCharacters = 64 * 1024;
    private const int MaximumOffers = 8;
    private const int MaximumNumericValue = 1_000_000_000;
    private static readonly string[] GlobalKeys =
    {
        "format", "revision", "session_id", "vendor_id", "vendor_title", "hub_available",
        "command_enabled", "water_known", "water_balance", "rotation_index", "stock_band_id",
        "weapons_allowed", "special_items_allowed", "weapon_unlock_water", "special_item_unlock_water",
        "refresh_deadline", "storefront_status", "blocking_reason", "transaction_id",
        "transaction_status", "last_result_code", "last_result_message", "offer_count",
        "selected_offer_index", "selected_offer_id", "last_reason", "complete"
    };
    private static readonly string[] OfferSuffixes =
    {
        "id", "display_name", "category", "inventory_kind", "unit_water_cost",
        "grant_quantity_per_unit", "max_purchase_units", "initial_stock", "remaining", "purchase_ready",
        "purchase_block_reason", "fulfillment_evidence", "quote_fingerprint"
    };
    private static readonly string[] ContentOfferSuffixes =
        { "item_key", "icon_key", "route_id", "max_grant_quantity", "max_total_water_cost" };
    private static readonly WaterOfferSnapshot OfflineOffer = new(
        "", "NO OFFER SELECTED", "OFFLINE", "unknown", 0, 0, 0, 0, 0,
        false, "No Water Broker offer is available.", "UNTESTED-LIVE", "");

    public WaterOfferSnapshot Selected => Offers.Count == 0
        ? OfflineOffer : Offers[Math.Clamp(SelectedIndex, 0, Offers.Count - 1)];
    public string OfferId => Selected.Id;

    public WaterVendorSnapshot SelectIndex(int index) => this with
    {
        SelectedIndex = Offers.Count == 0 ? 0 : Math.Clamp(index, 0, Offers.Count - 1)
    };

    public WaterVendorSnapshot SelectById(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return this;
        for (var index = 0; index < Offers.Count; index++)
            if (string.Equals(Offers[index].Id, id, StringComparison.Ordinal))
                return this with { SelectedIndex = index };
        return this;
    }

    public bool CanPurchaseSelected(out string reason)
        => CanPurchaseSelected(1, out reason);

    public int MaximumPurchaseUnits()
    {
        if (!WaterKnown || Offers.Count == 0 || Selected.UnitWaterCost < 1 ||
            Selected.GrantQuantityPerUnit < 1) return 0;
        return Math.Max(0, Math.Min(Selected.TechnicalMaximumUnits,
            Math.Min(Selected.Remaining, WaterBalance / Selected.UnitWaterCost)));
    }

    public bool CanPurchaseSelected(int purchaseUnits, out string reason)
    {
        if (!HubAvailable) reason = "exact_hub_not_available";
        else if (!WaterKnown) reason = "water_balance_unknown";
        else if (!StorefrontStatus.Equals("available", StringComparison.OrdinalIgnoreCase))
            reason = string.IsNullOrWhiteSpace(BlockingReason) ? "storefront_unavailable" : BlockingReason;
        else if (!CommandEnabled || string.IsNullOrWhiteSpace(SessionId)) reason = "command_channel_not_ready";
        else if (RotationIndex < 1) reason = "rotation_not_ready";
        else if (Offers.Count == 0) reason = "no_offers";
        else if (!Selected.PurchaseReady) reason = string.IsNullOrWhiteSpace(Selected.PurchaseBlockReason)
            ? "offer_not_ready" : Selected.PurchaseBlockReason;
        else if (Selected.Remaining < 1) reason = "sold_out";
        else if (Selected.MaxPurchaseUnits < 1) reason = "purchase_limit_reached";
        else if (purchaseUnits < 1) reason = "invalid_purchase_units";
        else if (purchaseUnits > Selected.MaxPurchaseUnits) reason = "purchase_limit_reached";
        else if (purchaseUnits > Selected.TechnicalMaximumUnits) reason = "route_purchase_limit_reached";
        else if (purchaseUnits > Selected.Remaining) reason = "insufficient_stock";
        else if (Selected.UnitWaterCost < 1 || WaterBalance < Selected.UnitWaterCost) reason = "insufficient_water";
        else if (purchaseUnits > WaterBalance / Selected.UnitWaterCost) reason = "insufficient_water";
        else if ((long)purchaseUnits * Selected.UnitWaterCost > Selected.MaxTotalWaterCost ||
                 (long)purchaseUnits * Selected.GrantQuantityPerUnit > Selected.MaxGrantQuantity)
            reason = "quote_total_out_of_range";
        else if (Selected.GrantQuantityPerUnit < 1 || string.IsNullOrWhiteSpace(Selected.QuoteFingerprint))
            reason = "invalid_offer";
        else
        {
            reason = "ready";
            return true;
        }
        return false;
    }

    public bool Matches(WaterPurchaseConfirmation confirmation)
    {
        if (!CanPurchaseSelected(confirmation.PurchaseUnits, out _)) return false;
        return confirmation.SnapshotRevision == Revision &&
               confirmation.RotationIndex == RotationIndex &&
               string.Equals(confirmation.OfferId, Selected.Id, StringComparison.Ordinal) &&
               confirmation.ExpectedUnitWaterCost == Selected.UnitWaterCost &&
               confirmation.ExpectedTotalWaterCost == (long)Selected.UnitWaterCost * confirmation.PurchaseUnits &&
               confirmation.ExpectedGrantQuantityPerUnit == Selected.GrantQuantityPerUnit &&
               confirmation.ExpectedTotalQuantity == (long)Selected.GrantQuantityPerUnit * confirmation.PurchaseUnits &&
               confirmation.ExpectedRemaining == Selected.Remaining &&
               confirmation.ExpectedPurchaseReady == Selected.PurchaseReady &&
               string.Equals(confirmation.QuoteFingerprint, Selected.QuoteFingerprint, StringComparison.Ordinal);
    }

    public static WaterVendorSnapshot Waiting() => new(0, "", "independent_water_vendor", "WATER BROKER",
        false, false, false, 0, 0, "", false, false, 0, 0,
        0, "offline", "state_file_not_ready", "", "none",
        "", "", Array.Empty<WaterOfferSnapshot>(), 0,
        "Waiting for the Water Broker presentation state.");

    public static WaterVendorSnapshot Preview()
    {
        var offers = new[]
        {
            new WaterOfferSnapshot("ammo_545_crate", "5.45x39mm (90)", "ammo", "item",
                1, 90, 99, 3, 3, true, "explicit_live_test_route", "HYPOTHESIS",
                "r1:ammo_545_crate:w1:q90:m99:i3:s3:ready"),
            new WaterOfferSnapshot("medium_first_aid", "Standard First Aid Kit", "medical", "item",
                1, 1, 99, 4, 4, true, "explicit_live_test_route", "HYPOTHESIS",
                "r1:medium_first_aid:w1:q1:m99:i4:s4:ready"),
            new WaterOfferSnapshot("ammo_12g_crate", "12-Gauge Buckshot (30)", "ammo", "item",
                1, 30, 99, 2, 2, true, "explicit_live_test_route", "HYPOTHESIS",
                "r1:ammo_12g_crate:w1:q30:m99:i2:s2:ready"),
            new WaterOfferSnapshot("power_cell", "Power Cell", "resource", "item",
                2, 1, 99, 2, 2, true, "verified_exact_route", "VERIFIED-CURRENT",
                "r1:power_cell:w2:q1:m99:i2:s2:ready"),
            new WaterOfferSnapshot("mead", "Mead (2)", "provisions", "item",
                1, 2, 99, 4, 4, true, "verified_exact_route", "VERIFIED-CURRENT",
                "r1:mead:w1:q2:m99:i4:s4:ready"),
            new WaterOfferSnapshot("railgun_component", "Railgun Cooling Component (2)", "contraband", "item",
                4, 2, 99, 1, 1, true, "explicit_live_test_route", "HYPOTHESIS",
                "r1:railgun_component:w4:q2:m99:i1:s1:ready"),
            new WaterOfferSnapshot("recovery_drone", "Recovery Drone", "utility", "item",
                9, 1, 99, 1, 1, true, "explicit_live_test_route", "HYPOTHESIS",
                "r1:recovery_drone:w9:q1:m99:i1:s1:ready"),
            new WaterOfferSnapshot("weapon_ak", "AK", "weapon", "weapon",
                7, 1, 1, 1, 1, true, "verified_exact_route", "VERIFIED-CURRENT",
                "r1:weapon_ak:w7:q1:m1:i1:s1:ready")
        };
        return new WaterVendorSnapshot(18, "preview-water-vendor-session", "independent_water_vendor",
            "WATER BROKER", true, true, true, 79, 1, "abundant", true, true, 0, 0,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 5_400,
            "available", "none", "", "none", "purchase_committed",
            "Advanced First Aid Kit x1 for 3 Water",
            offers.Select(offer => offer with { IconKey = offer.Id }).ToArray(), 0, "purchase_finished");
    }

    public static bool TryParse(string payload, out WaterVendorSnapshot snapshot)
    {
        snapshot = Waiting();
        if (string.IsNullOrEmpty(payload) || payload.Length > MaximumPayloadCharacters) return false;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var rawLine in payload.Split(new[] { "\r\n", "\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = rawLine.IndexOf('=');
            if (separator <= 0) return false;
            var key = rawLine[..separator];
            var rawValue = rawLine[(separator + 1)..];
            if (key.Length == 0 || key.Length > 96 || rawValue.Length > 4096 ||
                !WaterVendorWire.TryDecode(rawValue, out var value) || !values.TryAdd(key, value)) return false;
        }

        var format = Get(values, "format");
        var contentVersion = format == "fwif.water_vendor.overlay.v2";
        if (!HasEvery(values, GlobalKeys) ||
            format is not ("fwif.water_vendor.overlay.v1" or "fwif.water_vendor.overlay.v2") ||
            Get(values, "complete") != "1" || !TryBoundedLong(values, "revision", 1, 2_147_483_647, out var revision) ||
            !TryBoolean(values, "hub_available", out var hubAvailable) ||
            !TryBoolean(values, "command_enabled", out var commandEnabled) ||
            !TryBoolean(values, "water_known", out var waterKnown) ||
            !TryBoundedInt(values, "water_balance", 0, MaximumNumericValue, out var waterBalance) ||
            !TryBoundedLong(values, "rotation_index", 0, 2_147_483_647, out var rotationIndex) ||
            !TryBoolean(values, "weapons_allowed", out var weaponsAllowed) ||
            !TryBoolean(values, "special_items_allowed", out var specialItemsAllowed) ||
            !TryBoundedInt(values, "weapon_unlock_water", 0, MaximumNumericValue, out var weaponUnlockWater) ||
            !TryBoundedInt(values, "special_item_unlock_water", 0, MaximumNumericValue,
                out var specialItemUnlockWater) ||
            !TryBoundedLong(values, "refresh_deadline", 0, 9_999_999_999_999, out var refreshDeadline) ||
            !TryBoundedInt(values, "offer_count", 0, MaximumOffers, out var offerCount) ||
            !TryBoundedInt(values, "selected_offer_index", 0, MaximumOffers, out var selectedOfferIndex))
            return false;

        var allowedKeys = new HashSet<string>(GlobalKeys, StringComparer.Ordinal);
        var offerSuffixes = contentVersion ? OfferSuffixes.Concat(ContentOfferSuffixes).ToArray() : OfferSuffixes;
        for (var index = 1; index <= offerCount; index++)
            foreach (var suffix in offerSuffixes)
                allowedKeys.Add($"offer_{index}_{suffix}");
        if (values.Count != allowedKeys.Count || values.Keys.Any(key => !allowedKeys.Contains(key))) return false;

        var sessionId = Get(values, "session_id");
        var vendorId = Get(values, "vendor_id");
        var vendorTitle = Get(values, "vendor_title");
        var stockBandId = Get(values, "stock_band_id");
        var storefrontStatus = Get(values, "storefront_status");
        var blockingReason = Get(values, "blocking_reason");
        var transactionId = Get(values, "transaction_id");
        var transactionStatus = Get(values, "transaction_status");
        var lastResultCode = Get(values, "last_result_code");
        var lastResultMessage = Get(values, "last_result_message");
        var selectedOfferId = Get(values, "selected_offer_id");
        var lastReason = Get(values, "last_reason");
        if (!ValidText(sessionId, 128) || !ValidText(vendorId, 160) || !ValidText(vendorTitle, 256) ||
            !ValidOptionalText(stockBandId, 128) || !ValidText(storefrontStatus, 64) ||
            !ValidText(blockingReason, 192) || !ValidOptionalText(transactionId, 192) ||
            !ValidText(transactionStatus, 64) || !ValidOptionalText(lastResultCode, 128) ||
            !ValidOptionalText(lastResultMessage, 512) || !ValidOptionalText(selectedOfferId, 160) ||
            !ValidOptionalText(lastReason, 512) || (!waterKnown && waterBalance != 0)) return false;

        var offers = new List<WaterOfferSnapshot>(offerCount);
        var offerIds = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 1; index <= offerCount; index++)
        {
            var prefix = $"offer_{index}_";
            if (!HasEvery(values, offerSuffixes.Select(suffix => prefix + suffix)) ||
                !TryBoundedInt(values, prefix + "unit_water_cost", 1, 1_000_000, out var waterCost) ||
                !TryBoundedInt(values, prefix + "grant_quantity_per_unit", 1, MaximumNumericValue, out var quantity) ||
                !TryBoundedInt(values, prefix + "remaining", 0, MaximumNumericValue, out var remaining) ||
                !TryBoundedInt(values, prefix + "initial_stock", 1, MaximumNumericValue, out var initialStock) ||
                !TryBoundedInt(values, prefix + "max_purchase_units", 1, 999, out var maxUnits) ||
                !TryBoolean(values, prefix + "purchase_ready", out var purchaseReady)) return false;
            var id = Get(values, prefix + "id");
            var displayName = Get(values, prefix + "display_name");
            var category = Get(values, prefix + "category");
            var inventoryKind = Get(values, prefix + "inventory_kind");
            var blockReason = Get(values, prefix + "purchase_block_reason");
            var fulfillmentEvidence = Get(values, prefix + "fulfillment_evidence");
            var fingerprint = Get(values, prefix + "quote_fingerprint");
            var itemKey = contentVersion ? Get(values, prefix + "item_key") : "";
            // Legacy snapshots used their compiled offer ID as the portrait key.
            // Version 2 always resolves the explicit registry key, even if IDs differ.
            var iconKey = contentVersion ? Get(values, prefix + "icon_key") : id;
            var routeId = contentVersion ? Get(values, prefix + "route_id") : "";
            var maxGrantQuantity = 999;
            var maxTotalWaterCost = 1_000_000;
            if (contentVersion &&
                (!ValidItemKey(itemKey) || !ValidText(routeId, 192) ||
                 !routeId.All(c => char.IsAsciiLetterOrDigit(c) || "_./:-".Contains(c)) ||
                 !WaterBrokerOfferIcons.Contains(iconKey) ||
                 !TryBoundedInt(values, prefix + "max_grant_quantity", 1, 999, out maxGrantQuantity) ||
                 !TryBoundedInt(values, prefix + "max_total_water_cost", 1, 1_000_000, out maxTotalWaterCost) ||
                 quantity > maxGrantQuantity || waterCost > maxTotalWaterCost ||
                 maxUnits > maxGrantQuantity / quantity || maxUnits > maxTotalWaterCost / waterCost))
                return false;
            if (!ValidText(id, 160) || !offerIds.Add(id) || !ValidText(displayName, 256) ||
                !ValidText(category, 64) || !ValidText(inventoryKind, 64) ||
                !ValidText(blockReason, 192) || !ValidText(fulfillmentEvidence, 192) ||
                !ValidText(fingerprint, 256) || remaining > initialStock || purchaseReady && remaining < 1)
                return false;
            offers.Add(new WaterOfferSnapshot(id, displayName, category, inventoryKind,
                waterCost, quantity, maxUnits, initialStock, remaining, purchaseReady, blockReason,
                fulfillmentEvidence, fingerprint, itemKey, iconKey, routeId, maxGrantQuantity, maxTotalWaterCost));
        }

        if (offerCount == 0)
        {
            if (selectedOfferIndex != 0 || selectedOfferId.Length != 0) return false;
        }
        else
        {
            if (selectedOfferIndex < 1 || selectedOfferIndex > offerCount ||
                !string.Equals(offers[selectedOfferIndex - 1].Id, selectedOfferId, StringComparison.Ordinal))
                return false;
        }
        snapshot = new WaterVendorSnapshot(revision, sessionId, vendorId, vendorTitle,
            hubAvailable, commandEnabled, waterKnown, waterBalance, rotationIndex, stockBandId,
            weaponsAllowed, specialItemsAllowed, weaponUnlockWater, specialItemUnlockWater,
            refreshDeadline, storefrontStatus, blockingReason, transactionId, transactionStatus,
            lastResultCode, lastResultMessage, offers, Math.Max(0, selectedOfferIndex - 1), lastReason);
        return true;
    }

    private static bool HasEvery(Dictionary<string, string> values, IEnumerable<string> keys) =>
        keys.All(values.ContainsKey);
    private static bool ValidItemKey(string value) => ValidText(value, 512) &&
        System.Text.RegularExpressions.Regex.IsMatch(value,
            @"\A/Game/[A-Za-z0-9_/]+\.[A-Za-z0-9_]+:[A-Za-z0-9_.-]+\z");
    private static string Get(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) ? value : "";
    private static bool TryBoolean(Dictionary<string, string> values, string key, out bool value)
    {
        var raw = Get(values, key);
        value = raw == "1";
        return raw is "0" or "1";
    }
    private static bool TryBoundedLong(Dictionary<string, string> values, string key, long minimum, long maximum,
        out long value) => long.TryParse(Get(values, key), NumberStyles.None, CultureInfo.InvariantCulture,
        out value) && value >= minimum && value <= maximum;
    private static bool TryBoundedInt(Dictionary<string, string> values, string key, int minimum, int maximum,
        out int value) => int.TryParse(Get(values, key), NumberStyles.None, CultureInfo.InvariantCulture,
        out value) && value >= minimum && value <= maximum;
    private static bool ValidText(string value, int maximumLength) =>
        !string.IsNullOrWhiteSpace(value) && value.Length <= maximumLength &&
        !value.Any(character => character < ' ' || character == '\u007F');
    private static bool ValidOptionalText(string value, int maximumLength) =>
        value.Length <= maximumLength && !value.Any(character => character < ' ' || character == '\u007F');
}

internal sealed record WaterPurchaseConfirmation(
    long SnapshotRevision, long RotationIndex, string OfferId, int PurchaseUnits,
    int ExpectedUnitWaterCost, int ExpectedTotalWaterCost, int ExpectedGrantQuantityPerUnit,
    int ExpectedTotalQuantity, int ExpectedRemaining, bool ExpectedPurchaseReady,
    string QuoteFingerprint)
{
    public static WaterPurchaseConfirmation Create(WaterVendorSnapshot snapshot, int purchaseUnits)
    {
        if (purchaseUnits < 1 || purchaseUnits > snapshot.Selected.TechnicalMaximumUnits)
            throw new ArgumentOutOfRangeException(nameof(purchaseUnits));
        return new WaterPurchaseConfirmation(snapshot.Revision, snapshot.RotationIndex,
            snapshot.Selected.Id, purchaseUnits, snapshot.Selected.UnitWaterCost,
            checked(snapshot.Selected.UnitWaterCost * purchaseUnits),
            snapshot.Selected.GrantQuantityPerUnit,
            checked(snapshot.Selected.GrantQuantityPerUnit * purchaseUnits),
            snapshot.Selected.Remaining, snapshot.Selected.PurchaseReady, snapshot.Selected.QuoteFingerprint);
    }
}

internal sealed record QuestPanelPlacement(
    Rectangle Bounds,
    int ReservedNativeQuestLane,
    int Gap,
    float Scale,
    string Anchor);

internal static class LayeredSurfaceLifecycle
{
    public static bool ShouldRender(bool revealed, long lastRevision, Rectangle lastPlacement,
        long currentRevision, Rectangle currentPlacement) =>
        revealed || lastRevision != currentRevision || lastPlacement != currentPlacement;
}

internal static class QuestPanelLayout
{
    public const int PanelBackgroundAlpha = 68;
    private const int BaseNativeQuestGap = 26;
    private const int PanelWidth = 386;
    public const int RaidPanelHeight = 214;
    public const int RaidPanelGap = 8;
    public static int ContractHeight(ContractSnapshot contract) => RaidPanelHeight + (contract.Objectives.Count - 2) * 39;
    private const int HubPanelHeight = 294;
    private const int ShadowMargin = 8;
    private const float MinimumReadableScale = 0.45f;
    private const float PreferredMinimumScale = 0.62f;
    private const float MaximumScale = 1.50f;

    public static bool IsRaidTracker(QuestSnapshot snapshot) =>
        snapshot.RaidInProgress || snapshot.Status.Equals("active", StringComparison.OrdinalIgnoreCase) ||
        snapshot.Status.Equals("locked", StringComparison.OrdinalIgnoreCase);

    public static Size WindowSize(QuestSnapshot snapshot, float scale = 1f)
    {
        var contentHeight = IsRaidTracker(snapshot)
            ? snapshot.VisibleRaidContracts.Sum(ContractHeight) +
              RaidPanelGap * Math.Max(0, snapshot.VisibleRaidContracts.Count - 1)
            : HubPanelHeight;
        return new Size(
            Math.Max(1, (int)Math.Round((PanelWidth + ShadowMargin * 2) * scale)),
            Math.Max(1, (int)Math.Round((contentHeight + ShadowMargin * 2) * scale)));
    }

    public static Rectangle InnerBounds(Size clientSize) => new(
        ShadowMargin, ShadowMargin,
        Math.Max(1, clientSize.Width - ShadowMargin * 2),
        Math.Max(1, clientSize.Height - ShadowMargin * 2));

    public static float ScaleFromWindow(Size clientSize, QuestSnapshot snapshot)
    {
        var baseSize = WindowSize(snapshot);
        return Math.Max(MinimumReadableScale, clientSize.Width / (float)baseSize.Width);
    }

    public static QuestPanelPlacement Place(Rectangle gameBounds, QuestSnapshot snapshot)
    {
        // TFW's native quest list scales primarily with screen height. Reserve
        // a height-derived lane that is deliberately narrower than v0.12.0's
        // conservative 90%-of-height estimate, then clamp it for ordinary and
        // ultrawide clients. This keeps the Contract tracker immediately left
        // of the quest HUD instead of overlapping it or drifting needlessly
        // toward the center of a 32:9 display.
        var laneMinimum = (int)Math.Round(gameBounds.Width * 0.12);
        var laneMaximum = (int)Math.Round(gameBounds.Width * 0.29);
        var reservedNativeQuestLane = Math.Clamp(
            (int)Math.Round(gameBounds.Height * 0.52), laneMinimum, laneMaximum);

        var preferredScale = Math.Clamp(
            Math.Min(gameBounds.Height / 1440f, gameBounds.Width / 2560f),
            PreferredMinimumScale, MaximumScale);
        var safeMargin = Math.Max(8, (int)Math.Round(20 * preferredScale));
        var preferredGap = Math.Max(10, (int)Math.Round(BaseNativeQuestGap * preferredScale));
        var baseWidth = WindowSize(snapshot).Width;
        var availableWidth = gameBounds.Width - reservedNativeQuestLane - preferredGap - safeMargin * 2;
        var fitScale = availableWidth / (float)Math.Max(1, baseWidth);
        var heightFitScale = (gameBounds.Height - safeMargin * 2) /
            (float)Math.Max(1, WindowSize(snapshot).Height);
        var scale = Math.Clamp(Math.Min(preferredScale, Math.Min(fitScale, heightFitScale)), MinimumReadableScale, MaximumScale);

        safeMargin = Math.Max(8, (int)Math.Round(20 * scale));
        var gap = Math.Max(10, (int)Math.Round(BaseNativeQuestGap * scale));
        var size = WindowSize(snapshot, scale);
        var x = gameBounds.Right - reservedNativeQuestLane - gap - size.Width;
        var yOffset = Math.Clamp(
            (int)Math.Round(gameBounds.Height * 0.06),
            safeMargin,
            Math.Max(safeMargin, (int)Math.Round(96 * scale)));
        x = Math.Max(gameBounds.Left + safeMargin, x);
        var y = Math.Max(gameBounds.Top + safeMargin,
            Math.Min(gameBounds.Top + yOffset, gameBounds.Bottom - safeMargin - size.Height));

        return new QuestPanelPlacement(
            new Rectangle(x, y, size.Width, size.Height),
            reservedNativeQuestLane,
            gap,
            scale,
            "adaptive_native_quest_close_adjacency");
    }
}

internal static class ContractPresentationText
{
    public static string Counter(int current, int target, bool showProgress = true)
    {
        var safeTarget = Math.Max(0, target);
        var safeCurrent = showProgress ? Math.Clamp(current, 0, safeTarget) : 0;
        return $"{safeCurrent}/{safeTarget}";
    }

    public static string Fee(int waterCost) => $"CONTRACT FEE  //  {Math.Max(0, waterCost)} WATER";

    public static string FeePaid(int waterPaid) =>
        $"CONTRACT FEE PAID  //  {Math.Max(0, waterPaid)} WATER";
}

internal enum OverlayMode
{
    Hidden,
    HubLauncher,
    ContractBoard,
    WaterTrader,
    RaidTracker,
}

internal enum HubSurface
{
    None,
    Contracts,
    WaterTrader,
}

internal enum OverlayHitKind
{
    None,
    OpenBoard,
    OpenWaterTrader,
    CloseSurface,
    Accept,
    Discard,
    Contract,
    WaterOffer,
    BeginPurchase,
    DecreasePurchaseQuantity,
    IncreasePurchaseQuantity,
    MaxPurchaseQuantity,
    ConfirmPurchase,
    CancelPurchase,
}

internal readonly record struct OverlayHitTarget(OverlayHitKind Kind, int Index)
{
    public static readonly OverlayHitTarget None = new(OverlayHitKind.None, -1);
    public static readonly OverlayHitTarget OpenBoard = new(OverlayHitKind.OpenBoard, -1);
    public static readonly OverlayHitTarget OpenWaterTrader = new(OverlayHitKind.OpenWaterTrader, -1);
    public static readonly OverlayHitTarget CloseSurface = new(OverlayHitKind.CloseSurface, -1);
    public static readonly OverlayHitTarget Accept = new(OverlayHitKind.Accept, -1);
    public static readonly OverlayHitTarget Discard = new(OverlayHitKind.Discard, -1);
    public static readonly OverlayHitTarget BeginPurchase = new(OverlayHitKind.BeginPurchase, -1);
    public static readonly OverlayHitTarget DecreasePurchaseQuantity = new(OverlayHitKind.DecreasePurchaseQuantity, -1);
    public static readonly OverlayHitTarget IncreasePurchaseQuantity = new(OverlayHitKind.IncreasePurchaseQuantity, -1);
    public static readonly OverlayHitTarget MaxPurchaseQuantity = new(OverlayHitKind.MaxPurchaseQuantity, -1);
    public static readonly OverlayHitTarget ConfirmPurchase = new(OverlayHitKind.ConfirmPurchase, -1);
    public static readonly OverlayHitTarget CancelPurchase = new(OverlayHitKind.CancelPurchase, -1);
    public static OverlayHitTarget ContractAt(int index) => new(OverlayHitKind.Contract, index);
    public static OverlayHitTarget WaterOfferAt(int index) => new(OverlayHitKind.WaterOffer, index);
}

internal static class OverlayLayout
{
    public static OverlayMode ResolveMode(QuestSnapshot snapshot, WaterVendorSnapshot vendor,
        HubSurface hubSurface, bool vendorOnly = false, bool contractsOnly = false)
    {
        // A raid with no accepted active contracts has no surface. Resolve it
        // before hub fallbacks, since the Broker snapshot can still say HUB.
        if (!vendorOnly && QuestPanelLayout.IsRaidTracker(snapshot))
            return snapshot.VisibleRaidContracts.Count > 0 ? OverlayMode.RaidTracker : OverlayMode.Hidden;
        if (!vendorOnly && hubSurface == HubSurface.Contracts && snapshot.HubAvailable)
            return OverlayMode.ContractBoard;
        if (!contractsOnly && hubSurface == HubSurface.WaterTrader && vendor.HubAvailable)
            return OverlayMode.WaterTrader;
        return (!vendorOnly && snapshot.HubAvailable) || (!contractsOnly && vendor.HubAvailable)
            ? OverlayMode.HubLauncher : OverlayMode.Hidden;
    }

    public static string Name(OverlayMode mode) => mode switch
    {
        OverlayMode.HubLauncher => "hub_operations_launcher",
        OverlayMode.ContractBoard => "hub_contract_board",
        OverlayMode.WaterTrader => "hub_water_trader",
        OverlayMode.RaidTracker => "raid_tracker",
        _ => "hidden",
    };

    public static Size WindowSize(OverlayMode mode, float scale) => mode switch
    {
        OverlayMode.HubLauncher => HubLauncherLayout.WindowSize(scale),
        OverlayMode.ContractBoard => ContractBoardLayout.WindowSize(scale),
        OverlayMode.WaterTrader => WaterTraderLayout.WindowSize(scale),
        OverlayMode.RaidTracker => QuestPanelLayout.WindowSize(QuestSnapshot.PreviewRaid(), scale),
        _ => Size.Empty,
    };

    public static QuestPanelPlacement Place(Rectangle gameBounds, QuestSnapshot snapshot,
        WaterVendorSnapshot vendor, OverlayMode mode)
    {
        if (mode == OverlayMode.RaidTracker) return QuestPanelLayout.Place(gameBounds, snapshot);
        if (mode == OverlayMode.ContractBoard)
            return new QuestPanelPlacement(gameBounds, 0, 0, 1f,
                "hub_full_client_centered_safe_area");
        if (mode == OverlayMode.WaterTrader)
            return new QuestPanelPlacement(gameBounds, 0, 0, 1f,
                "hub_full_client_centered_safe_area_with_shopkeeper");
        var scale = Math.Clamp(
            Math.Min(gameBounds.Height / 1440f, gameBounds.Width / 2560f),
            0.65f, 1.5f);
        var size = mode == OverlayMode.HubLauncher
            ? HubLauncherLayout.WindowSize(scale, snapshot.HasContractBoard,
                !string.IsNullOrWhiteSpace(vendor.SessionId))
            : WindowSize(mode, scale);
        if (mode == OverlayMode.HubLauncher)
        {
            var x = gameBounds.Left + Math.Max(18, (int)Math.Round(44 * scale));
            var y = gameBounds.Top + Math.Max(44, (int)Math.Round(86 * scale));
            return new QuestPanelPlacement(new Rectangle(x, y, size.Width, size.Height), 0, 0, scale,
                "hub_upper_left_navigation_lane");
        }

        var boardX = gameBounds.Left + (gameBounds.Width - size.Width) / 2;
        var boardY = gameBounds.Top + Math.Max(28, (gameBounds.Height - size.Height) / 2);
        return new QuestPanelPlacement(new Rectangle(boardX, boardY, size.Width, size.Height), 0, 0, scale,
            "hub_client_center");
    }
}

internal static class HubLauncherLayout
{
    public const int Width = 274;
    public const int Height = 116;
    public static Size WindowSize(float scale) => new(
        Math.Max(1, (int)Math.Round(Width * scale)),
        Math.Max(1, (int)Math.Round(Height * scale)));
    public static Size WindowSize(float scale, bool showContracts, bool showWaterTrader) => new(
        Math.Max(1, (int)Math.Round(Width * scale)),
        Math.Max(1, (int)Math.Round((showContracts && showWaterTrader ? Height : 58) * scale)));
    public static Rectangle ContractButton(Size size, bool showContracts) => showContracts
        ? new Rectangle(5, 5, Math.Max(1, size.Width - 10), 48) : Rectangle.Empty;
    public static Rectangle WaterTraderButton(Size size, bool showContracts, bool showWaterTrader) => showWaterTrader
        ? new Rectangle(5, showContracts ? 63 : 5, Math.Max(1, size.Width - 10), 48) : Rectangle.Empty;
}

internal static class ContractBoardLayout
{
    public const int Width = 1920;
    public const int Height = 1080;
    public static Size WindowSize(float scale) => new(
        Math.Max(1, (int)Math.Round(Width * scale)),
        Math.Max(1, (int)Math.Round(Height * scale)));

    public static float UiScale(Size size) => Math.Clamp(size.Height / 1080f, 0.60f, 2.0f);

    public static Rectangle InnerBounds(Size size)
    {
        var scale = UiScale(size);
        var verticalMargin = Math.Max(18, (int)Math.Round(54 * scale));
        var horizontalMargin = Math.Max(18, (int)Math.Round(54 * scale));
        var availableWidth = Math.Max(1, size.Width - horizontalMargin * 2);
        // The native menus fill the client but keep their working content in a
        // centered ultrawide-safe lane. Height, not raw ultrawide width, sets
        // the maximum content span.
        var safeWidth = Math.Min(availableWidth, (int)Math.Round(size.Height * 2.28));
        var x = (size.Width - safeWidth) / 2;
        return new Rectangle(x, verticalMargin, Math.Max(1, safeWidth),
            Math.Max(1, size.Height - verticalMargin * 2));
    }

    public static Rectangle CloseButton(Size size)
    {
        var bounds = InnerBounds(size);
        var scale = UiScale(size);
        var side = Math.Max(30, (int)Math.Round(44 * scale));
        return new Rectangle(bounds.Right - side - (int)Math.Round(22 * scale),
            bounds.Top + (int)Math.Round(19 * scale), side, side);
    }

    public static Rectangle ListBounds(Size size)
    {
        var bounds = InnerBounds(size);
        var scale = UiScale(size);
        var top = bounds.Top + (int)Math.Round(126 * scale);
        var bottom = bounds.Bottom - (int)Math.Round(72 * scale);
        var width = Math.Max((int)Math.Round(320 * scale),
            (int)Math.Round(bounds.Width * 0.315));
        return new Rectangle(bounds.Left + (int)Math.Round(32 * scale), top,
            width, Math.Max(1, bottom - top));
    }

    public static Rectangle DetailsBounds(Size size)
    {
        var bounds = InnerBounds(size);
        var list = ListBounds(size);
        var scale = UiScale(size);
        var gap = Math.Max(18, (int)Math.Round(34 * scale));
        var right = bounds.Right - (int)Math.Round(32 * scale);
        return new Rectangle(list.Right + gap, list.Top,
            Math.Max(1, right - list.Right - gap), list.Height);
    }

    public static Rectangle ContractCard(Size size, int index, int count = 3)
    {
        var list = ListBounds(size);
        var scale = UiScale(size);
        var heading = (int)Math.Round(42 * scale);
        var gap = Math.Max(8, (int)Math.Round(14 * scale));
        var usableHeight = Math.Max(1, list.Height - heading);
        var cardHeight = Math.Min((int)Math.Round(164 * scale),
            (usableHeight - gap * (Math.Max(1, count) - 1)) / Math.Max(1, count));
        return new Rectangle(list.Left, list.Top + heading + index * (cardHeight + gap),
            list.Width, cardHeight);
    }

    public static Rectangle ActionButton(Size size)
    {
        var details = DetailsBounds(size);
        var scale = UiScale(size);
        var width = Math.Max((int)Math.Round(280 * scale),
            (int)Math.Round(details.Width * 0.44));
        var height = Math.Max(38, (int)Math.Round(52 * scale));
        return new Rectangle(details.Right - width, details.Bottom - height, width, height);
    }
}

internal static class WaterTraderLayout
{
    public const int Width = 1920;
    public const int Height = 1080;
    public const int MaximumVisibleOffers = 8;
    public static Size WindowSize(float scale) => new(
        Math.Max(1, (int)Math.Round(Width * scale)),
        Math.Max(1, (int)Math.Round(Height * scale)));

    public static float UiScale(Size size) => Math.Clamp(size.Height / 1080f, 0.60f, 2.0f);

    public static Rectangle InnerBounds(Size size)
    {
        var scale = UiScale(size);
        var verticalMargin = Math.Max(18, (int)Math.Round(54 * scale));
        var horizontalMargin = Math.Max(18, (int)Math.Round(54 * scale));
        var availableWidth = Math.Max(1, size.Width - horizontalMargin * 2);
        // Match the Contract Board's native-menu composition: the translucent
        // modal covers the complete game client, while its working content is
        // constrained by height so ultrawide displays cannot stretch it apart.
        var safeWidth = Math.Min(availableWidth, (int)Math.Round(size.Height * 2.28));
        var x = (size.Width - safeWidth) / 2;
        return new Rectangle(x, verticalMargin, Math.Max(1, safeWidth),
            Math.Max(1, size.Height - verticalMargin * 2));
    }

    public static Rectangle CloseButton(Size size)
    {
        var bounds = InnerBounds(size);
        var scale = UiScale(size);
        var side = Math.Max(30, (int)Math.Round(44 * scale));
        return new Rectangle(bounds.Right - side - (int)Math.Round(22 * scale),
            bounds.Top + (int)Math.Round(19 * scale), side, side);
    }

    public static Rectangle ContentBounds(Size size)
    {
        var bounds = InnerBounds(size);
        var scale = UiScale(size);
        var inset = Math.Max(18, (int)Math.Round(32 * scale));
        var top = bounds.Top + (int)Math.Round(126 * scale);
        var bottom = bounds.Bottom - (int)Math.Round(70 * scale);
        return new Rectangle(bounds.Left + inset, top,
            Math.Max(1, bounds.Width - inset * 2), Math.Max(1, bottom - top));
    }

    public static Rectangle ShopkeeperBounds(Size size)
    {
        var content = ContentBounds(size);
        var scale = UiScale(size);
        var width = Math.Max((int)Math.Round(205 * scale),
            (int)Math.Round(content.Width * 0.205));
        width = Math.Min(width, (int)Math.Round(content.Width * 0.24));
        return new Rectangle(content.Left, content.Top, Math.Max(1, width), content.Height);
    }

    public static Rectangle OfferListBounds(Size size)
    {
        var content = ContentBounds(size);
        var shopkeeper = ShopkeeperBounds(size);
        var scale = UiScale(size);
        var gap = Math.Max(12, (int)Math.Round(24 * scale));
        var width = Math.Max((int)Math.Round(390 * scale),
            (int)Math.Round(content.Width * 0.39));
        var maximum = Math.Max(1, content.Right - (shopkeeper.Right + gap) -
            (int)Math.Round(365 * scale) - gap);
        width = Math.Min(width, maximum);
        return new Rectangle(shopkeeper.Right + gap, content.Top,
            Math.Max(1, width), content.Height);
    }

    public static Rectangle DetailsBounds(Size size)
    {
        var content = ContentBounds(size);
        var offers = OfferListBounds(size);
        var scale = UiScale(size);
        var gap = Math.Max(12, (int)Math.Round(24 * scale));
        return new Rectangle(offers.Right + gap, content.Top,
            Math.Max(1, content.Right - offers.Right - gap), content.Height);
    }

    public static Rectangle OfferCard(Size size, int index)
    {
        var list = OfferListBounds(size);
        var scale = UiScale(size);
        var heading = (int)Math.Round(42 * scale);
        var columnGap = Math.Max(8, (int)Math.Round(14 * scale));
        var rowGap = Math.Max(7, (int)Math.Round(12 * scale));
        var cardWidth = Math.Max(1, (list.Width - columnGap) / 2);
        var usableHeight = Math.Max(1, list.Height - heading - rowGap * 3);
        var cardHeight = Math.Max(1, usableHeight / 4);
        return new Rectangle(
            list.Left + index % 2 * (cardWidth + columnGap),
            list.Top + heading + index / 2 * (cardHeight + rowGap),
            cardWidth, cardHeight);
    }

    public static Rectangle PurchaseButton(Size size)
    {
        var details = DetailsBounds(size);
        var scale = UiScale(size);
        var height = Math.Max(34, (int)Math.Round(52 * scale));
        return new Rectangle(details.Left, details.Bottom - height, details.Width, height);
    }

    private static int ControlRowY(Size size)
    {
        var confirm = ConfirmButton(size);
        var scale = UiScale(size);
        var gap = Math.Max(6, (int)Math.Round(9 * scale));
        var controlHeight = Math.Max(30, (int)Math.Round(44 * scale));
        return confirm.Top - gap - controlHeight;
    }

    public static Rectangle QuantityDecreaseButton(Size size)
    {
        var details = DetailsBounds(size);
        var scale = UiScale(size);
        return new Rectangle(details.Left, ControlRowY(size),
            Math.Max(34, (int)Math.Round(52 * scale)), Math.Max(30, (int)Math.Round(44 * scale)));
    }

    public static Rectangle QuantityValue(Size size)
    {
        var minus = QuantityDecreaseButton(size);
        var scale = UiScale(size);
        var gap = Math.Max(5, (int)Math.Round(8 * scale));
        return new Rectangle(minus.Right + gap, minus.Top,
            Math.Max(46, (int)Math.Round(72 * scale)), minus.Height);
    }

    public static Rectangle QuantityIncreaseButton(Size size)
    {
        var value = QuantityValue(size);
        var scale = UiScale(size);
        var gap = Math.Max(5, (int)Math.Round(8 * scale));
        return new Rectangle(value.Right + gap, value.Top,
            Math.Max(34, (int)Math.Round(52 * scale)), value.Height);
    }

    public static Rectangle QuantityMaxButton(Size size)
    {
        var details = DetailsBounds(size);
        var plus = QuantityIncreaseButton(size);
        var scale = UiScale(size);
        var gap = Math.Max(5, (int)Math.Round(8 * scale));
        return new Rectangle(plus.Right + gap, plus.Top,
            Math.Max(1, details.Right - plus.Right - gap), plus.Height);
    }

    public static Rectangle ConfirmButton(Size size)
    {
        var details = DetailsBounds(size);
        var scale = UiScale(size);
        var height = Math.Max(30, (int)Math.Round(42 * scale));
        var gap = Math.Max(6, (int)Math.Round(10 * scale));
        var width = Math.Max(1, (int)Math.Round((details.Width - gap) * 0.64));
        return new Rectangle(details.Left, details.Bottom - (int)Math.Round(95 * scale), width, height);
    }

    public static Rectangle CancelButton(Size size)
    {
        var details = DetailsBounds(size);
        var confirm = ConfirmButton(size);
        var scale = UiScale(size);
        var gap = Math.Max(6, (int)Math.Round(10 * scale));
        return new Rectangle(confirm.Right + gap, confirm.Top,
            Math.Max(1, details.Right - confirm.Right - gap), confirm.Height);
    }
}

internal static class OverlayHitTesting
{
    public static OverlayHitTarget HitTest(OverlayMode mode, Size actualSize, Point actualPoint,
        QuestSnapshot snapshot, WaterVendorSnapshot vendor, WaterPurchaseConfirmation? confirmation,
        bool commandAwaitingRevision)
    {
        if (actualSize.Width <= 0 || actualSize.Height <= 0) return OverlayHitTarget.None;
        var fullClientSurface = mode is OverlayMode.ContractBoard or OverlayMode.WaterTrader;
        var baseWidth = mode switch
        {
            OverlayMode.HubLauncher => HubLauncherLayout.Width,
            OverlayMode.ContractBoard => ContractBoardLayout.Width,
            OverlayMode.WaterTrader => WaterTraderLayout.Width,
            _ => 0,
        };
        if (baseWidth == 0) return OverlayHitTarget.None;
        var scale = fullClientSurface ? 1f : actualSize.Width / (float)baseWidth;
        var logicalSize = fullClientSurface ? actualSize : new Size(baseWidth,
            Math.Max(1, (int)Math.Round(actualSize.Height / Math.Max(0.01f, scale))));
        var logicalPoint = fullClientSurface ? actualPoint : new Point(
            (int)Math.Round(actualPoint.X / Math.Max(0.01f, scale)),
            (int)Math.Round(actualPoint.Y / Math.Max(0.01f, scale)));

        if (mode == OverlayMode.HubLauncher)
        {
            var showContracts = snapshot.HasContractBoard;
            var showWaterTrader = !string.IsNullOrWhiteSpace(vendor.SessionId);
            if (snapshot.HubAvailable &&
                HubLauncherLayout.ContractButton(logicalSize, showContracts).Contains(logicalPoint))
                return OverlayHitTarget.OpenBoard;
            if (vendor.HubAvailable &&
                HubLauncherLayout.WaterTraderButton(logicalSize, showContracts, showWaterTrader).Contains(logicalPoint))
                return OverlayHitTarget.OpenWaterTrader;
            return OverlayHitTarget.None;
        }

        if (mode == OverlayMode.WaterTrader)
        {
            if (WaterTraderLayout.CloseButton(logicalSize).Contains(logicalPoint))
                return OverlayHitTarget.CloseSurface;
            if (!commandAwaitingRevision)
                for (var index = 0; index < Math.Min(WaterTraderLayout.MaximumVisibleOffers, vendor.Offers.Count); index++)
                    if (WaterTraderLayout.OfferCard(logicalSize, index).Contains(logicalPoint))
                        return OverlayHitTarget.WaterOfferAt(index);
            if (confirmation is not null)
            {
                if (WaterTraderLayout.QuantityDecreaseButton(logicalSize).Contains(logicalPoint))
                    return OverlayHitTarget.DecreasePurchaseQuantity;
                if (WaterTraderLayout.QuantityIncreaseButton(logicalSize).Contains(logicalPoint))
                    return OverlayHitTarget.IncreasePurchaseQuantity;
                if (WaterTraderLayout.QuantityMaxButton(logicalSize).Contains(logicalPoint))
                    return OverlayHitTarget.MaxPurchaseQuantity;
                if (WaterTraderLayout.ConfirmButton(logicalSize).Contains(logicalPoint))
                    return OverlayHitTarget.ConfirmPurchase;
                if (WaterTraderLayout.CancelButton(logicalSize).Contains(logicalPoint))
                    return OverlayHitTarget.CancelPurchase;
            }
            else if (!commandAwaitingRevision && vendor.CanPurchaseSelected(out _) &&
                     WaterTraderLayout.PurchaseButton(logicalSize).Contains(logicalPoint))
                return OverlayHitTarget.BeginPurchase;
            return OverlayHitTarget.None;
        }

        if (mode != OverlayMode.ContractBoard) return OverlayHitTarget.None;
        if (ContractBoardLayout.CloseButton(logicalSize).Contains(logicalPoint))
            return OverlayHitTarget.CloseSurface;
        if (ContractBoardLayout.ActionButton(logicalSize).Contains(logicalPoint))
        {
            if (!snapshot.CanChangeContracts) return OverlayHitTarget.None;
            return snapshot.Status.Equals("accepted", StringComparison.OrdinalIgnoreCase)
                ? OverlayHitTarget.Discard
                : snapshot.Status is "available" or "failed" or "complete"
                    ? OverlayHitTarget.Accept
                    : OverlayHitTarget.None;
        }
        for (var index = 0; index < snapshot.Contracts.Count; index++)
        {
            if (ContractBoardLayout.ContractCard(logicalSize, index, snapshot.Contracts.Count).Contains(logicalPoint))
                return OverlayHitTarget.ContractAt(index);
        }
        return OverlayHitTarget.None;
    }
}

internal static class OverlayRenderer
{
    public static void Draw(Graphics graphics, OverlayMode mode, Size logicalSize,
        QuestSnapshot snapshot, WaterVendorSnapshot vendor, bool shadow, OverlayHitTarget hovered,
        WaterPurchaseConfirmation? confirmation, bool commandAwaitingRevision)
    {
        switch (mode)
        {
            case OverlayMode.HubLauncher:
                HubLauncherRenderer.Draw(graphics, logicalSize, snapshot, vendor, shadow, hovered);
                break;
            case OverlayMode.ContractBoard:
                ContractBoardRenderer.Draw(graphics, logicalSize, snapshot, shadow, hovered);
                break;
            case OverlayMode.WaterTrader:
                WaterTraderRenderer.Draw(graphics, logicalSize, vendor, shadow, hovered,
                    confirmation, commandAwaitingRevision);
                break;
            case OverlayMode.RaidTracker:
                QuestPanelRenderer.Draw(graphics, QuestPanelLayout.InnerBounds(logicalSize), snapshot, shadow);
                break;
        }
    }
}

internal static class HubLauncherRenderer
{
    public static void Draw(Graphics graphics, Size size, QuestSnapshot snapshot,
        WaterVendorSnapshot vendor, bool shadow, OverlayHitTarget hovered)
    {
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var showContracts = snapshot.HasContractBoard;
        var showWaterTrader = !string.IsNullOrWhiteSpace(vendor.SessionId);
        if (showContracts)
            DrawButton(graphics, HubLauncherLayout.ContractButton(size, true), "CONTRACTS",
                $"{snapshot.Contracts.Count} CONTRACTS", "F7  //  OPEN BOARD", snapshot.HubAvailable,
                hovered == OverlayHitTarget.OpenBoard, shadow);
        if (showWaterTrader)
        {
            var waterText = vendor.WaterKnown ? $"{vendor.WaterBalance} WATER" : "WATER UNKNOWN";
            DrawButton(graphics, HubLauncherLayout.WaterTraderButton(size, showContracts, true), "WATER BROKER",
                $"{vendor.Offers.Count} OFFERS  //  {waterText}", "F6  //  OPEN", vendor.HubAvailable,
                hovered == OverlayHitTarget.OpenWaterTrader, shadow);
        }
    }

    private static void DrawButton(Graphics graphics, Rectangle bounds, string heading, string detail,
        string action, bool enabled, bool hovered, bool shadow)
    {
        if (shadow)
        {
            using var shadowBrush = new SolidBrush(Color.FromArgb(65, 0, 0, 0));
            using var shadowPath = BoardDrawing.AngularPath(
                new Rectangle(bounds.X + 3, bounds.Y + 4, bounds.Width, bounds.Height), 8);
            graphics.FillPath(shadowBrush, shadowPath);
        }
        using var path = BoardDrawing.AngularPath(bounds, 8);
        using var background = new LinearGradientBrush(bounds,
            hovered ? Color.FromArgb(222, 48, 48, 43) : Color.FromArgb(205, 28, 31, 30),
            Color.FromArgb(190, 12, 15, 14), 90f);
        using var border = new Pen(hovered
            ? Color.FromArgb(245, 235, 202, 86)
            : enabled ? Color.FromArgb(224, 214, 77, 55) : Color.FromArgb(135, 96, 103, 98), 1.5f);
        graphics.FillPath(background, path);
        graphics.DrawPath(border, path);
        using var accent = new SolidBrush(enabled
            ? Color.FromArgb(240, 218, 77, 54) : Color.FromArgb(150, 95, 103, 98));
        graphics.FillRectangle(accent, bounds.X, bounds.Y + 8, 3, bounds.Height - 16);
        using var title = BoardDrawing.FontOf(13f, FontStyle.Bold);
        using var small = BoardDrawing.FontOf(7.5f, FontStyle.Bold);
        using var pale = new SolidBrush(Color.FromArgb(250, 233, 236, 226));
        using var gold = new SolidBrush(Color.FromArgb(250, 239, 197, 72));
        using var disabled = new SolidBrush(Color.FromArgb(190, 133, 142, 137));
        graphics.DrawString(heading, title, enabled ? pale : disabled, bounds.X + 17, bounds.Y + 7);
        graphics.DrawString(enabled ? detail : "NOT AVAILABLE", small, enabled ? gold : disabled,
            bounds.X + 19, bounds.Y + 30);
        BoardDrawing.DrawRightAligned(graphics, enabled ? action : "HUB ONLY", small,
            enabled ? pale : disabled,
            bounds.Right - 12, bounds.Y + 30);
    }
}

internal static class ContractBoardRenderer
{
    public static void Draw(Graphics graphics, Size size, QuestSnapshot snapshot, bool shadow,
        OverlayHitTarget hovered)
    {
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var scale = ContractBoardLayout.UiScale(size);
        var bounds = ContractBoardLayout.InnerBounds(size);

        // Use the whole game client as the modal surface, like the native Quest
        // screen, while keeping the actual content in a centered ultrawide-safe
        // lane. The wash is deliberately translucent so the Innards remains
        // perceptible behind it.
        using (var clientWash = new SolidBrush(Color.FromArgb(142, 3, 5, 5)))
            graphics.FillRectangle(clientWash, new Rectangle(Point.Empty, size));
        if (shadow)
        {
            using var shadowBrush = new SolidBrush(Color.FromArgb(105, 0, 0, 0));
            using var shadowPath = BoardDrawing.AngularPath(
                new Rectangle(bounds.X + (int)Math.Round(7 * scale),
                    bounds.Y + (int)Math.Round(8 * scale), bounds.Width, bounds.Height),
                Math.Max(8, (int)Math.Round(14 * scale)));
            graphics.FillPath(shadowBrush, shadowPath);
        }

        using var panelPath = BoardDrawing.AngularPath(bounds, Math.Max(8, (int)Math.Round(14 * scale)));
        using var background = new LinearGradientBrush(bounds,
            Color.FromArgb(224, 30, 33, 31), Color.FromArgb(216, 8, 11, 11), 24f);
        using var edge = new Pen(Color.FromArgb(225, 107, 120, 112), Math.Max(1f, 1.2f * scale));
        graphics.FillPath(background, panelPath);
        graphics.DrawPath(edge, panelPath);

        var headerHeight = (int)Math.Round(102 * scale);
        using var headerWash = new SolidBrush(Color.FromArgb(95, 192, 52, 38));
        graphics.FillRectangle(headerWash, bounds.X + 1, bounds.Y + 1, bounds.Width - 2, headerHeight);
        using var topAccent = new Pen(Color.FromArgb(250, 225, 78, 54), Math.Max(2f, 3f * scale));
        graphics.DrawLine(topAccent, bounds.X + (int)Math.Round(15 * scale), bounds.Y + 2,
            bounds.Right - 2, bounds.Y + 2);
        graphics.DrawLine(topAccent, bounds.X + 2, bounds.Y + (int)Math.Round(15 * scale),
            bounds.X + 2, bounds.Bottom - 2);

        using var eyebrow = BoardDrawing.FontOf(9f * scale, FontStyle.Bold);
        using var header = BoardDrawing.FontOf(27f * scale, FontStyle.Bold);
        using var title = BoardDrawing.FontOf(23f * scale, FontStyle.Bold);
        using var section = BoardDrawing.FontOf(10f * scale, FontStyle.Bold);
        using var body = BoardDrawing.FontOf(10f * scale, FontStyle.Regular);
        using var bodyBold = BoardDrawing.FontOf(10f * scale, FontStyle.Bold);
        using var small = BoardDrawing.FontOf(8f * scale, FontStyle.Regular);
        using var smallBold = BoardDrawing.FontOf(8f * scale, FontStyle.Bold);
        using var pale = new SolidBrush(Color.FromArgb(252, 235, 239, 230));
        using var muted = new SolidBrush(Color.FromArgb(220, 147, 158, 151));
        using var red = new SolidBrush(Color.FromArgb(248, 225, 79, 55));
        using var gold = new SolidBrush(Color.FromArgb(250, 239, 197, 72));
        using var dim = new SolidBrush(Color.FromArgb(175, 101, 112, 106));
        using var divider = new Pen(Color.FromArgb(145, 98, 112, 104), 1f);

        var inset = (int)Math.Round(30 * scale);
        graphics.DrawString("WATER 4.0  //  INNARDS OPERATIONS", eyebrow, red,
            bounds.X + inset, bounds.Y + (int)Math.Round(17 * scale));
        BoardDrawing.DrawShadowedText(graphics, "CONTRACT BOARD", header, pale,
            bounds.X + inset, bounds.Y + (int)Math.Round(39 * scale));
        graphics.DrawString("BROWSE  /  REVIEW  /  DEPLOY", smallBold, muted,
            bounds.X + (int)Math.Round(430 * scale), bounds.Y + (int)Math.Round(59 * scale));

        var close = ContractBoardLayout.CloseButton(size);
        using (var closeBrush = new SolidBrush(hovered == OverlayHitTarget.CloseSurface
                   ? Color.FromArgb(235, 225, 79, 55) : Color.FromArgb(150, 70, 77, 72)))
            graphics.FillRectangle(closeBrush, close);
        BoardDrawing.DrawCentered(graphics, "X", bodyBold, Brushes.White, close);

        var headerRuleY = bounds.Y + headerHeight + (int)Math.Round(8 * scale);
        graphics.DrawLine(divider, bounds.X + inset, headerRuleY, bounds.Right - inset, headerRuleY);
        var listBounds = ContractBoardLayout.ListBounds(size);
        var detailsBounds = ContractBoardLayout.DetailsBounds(size);
        graphics.DrawString("AVAILABLE CONTRACTS", section, red, listBounds.X, listBounds.Y);
        BoardDrawing.DrawRightAligned(graphics, $"{snapshot.Contracts.Count} LISTED", smallBold,
            muted, listBounds.Right, listBounds.Y + (int)Math.Round(3 * scale));

        if (snapshot.Contracts.Count == 0)
        {
            BoardDrawing.DrawShadowedText(graphics, snapshot.BoardLocked ? "BOARD UNAVAILABLE" : "NO OFFERS AVAILABLE",
                title, pale, detailsBounds.X, detailsBounds.Y + (int)Math.Round(24 * scale));
            BoardDrawing.DrawWrapped(graphics, snapshot.BoardNotice, body, muted,
                new RectangleF(detailsBounds.X, detailsBounds.Y + (int)Math.Round(83 * scale),
                    detailsBounds.Width, (int)Math.Round(110 * scale)));
            graphics.DrawString("F7 OR ESC CLOSE", small, muted,
                bounds.X + inset, bounds.Bottom - (int)Math.Round(35 * scale));
            return;
        }

        for (var index = 0; index < snapshot.Contracts.Count; index++)
        {
            var listed = snapshot.Contracts[index];
            var cardBounds = ContractBoardLayout.ContractCard(size, index, snapshot.Contracts.Count);
            var selectedCard = index == snapshot.SelectedIndex;
            var hoverTarget = OverlayHitTarget.ContractAt(index);
            var hoveredCard = hovered == hoverTarget;
            using (var cardBackground = new LinearGradientBrush(cardBounds,
                       selectedCard ? Color.FromArgb(218, 63, 64, 57) :
                           hoveredCard ? Color.FromArgb(204, 52, 55, 51) : Color.FromArgb(178, 31, 35, 33),
                       selectedCard ? Color.FromArgb(202, 27, 31, 29) : Color.FromArgb(168, 18, 22, 21), 90f))
                graphics.FillRectangle(cardBackground, cardBounds);
            using (var cardEdge = new Pen(selectedCard
                       ? Color.FromArgb(242, 226, 79, 54)
                       : hoveredCard ? Color.FromArgb(220, 205, 177, 79) : Color.FromArgb(105, 117, 129, 122),
                       selectedCard ? 1.5f : 1f))
                graphics.DrawRectangle(cardEdge, cardBounds);
            if (selectedCard) graphics.FillRectangle(red, cardBounds.X, cardBounds.Y,
                Math.Max(3, (int)Math.Round(4 * scale)), cardBounds.Height);
            var compact = snapshot.Contracts.Count > 3;
            using var compactTitle = BoardDrawing.FontOf(14 * scale, FontStyle.Bold);
            var cardX = cardBounds.X + (int)Math.Round(18 * scale);
            graphics.DrawString(listed.Category.ToUpperInvariant(), smallBold,
                selectedCard ? red : muted, cardX, cardBounds.Y + (int)Math.Round((compact ? 10 : 15) * scale));
            graphics.DrawString(listed.Title.ToUpperInvariant(), compact ? compactTitle : section, pale,
                cardX, cardBounds.Y + (int)Math.Round((compact ? 34 : 45) * scale));
            graphics.DrawString(ContractPresentationText.Fee(listed.AcceptanceWaterCost), smallBold,
                listed.Accepted ? gold : muted, cardX, compact ? cardBounds.Bottom - (int)Math.Round(30 * scale) : cardBounds.Y + (int)Math.Round(76 * scale));
            DrawStatusChip(graphics, listed.Status, compact ? cardBounds.Right - (int)Math.Round(116 * scale) : cardX,
                cardBounds.Bottom - (int)Math.Round(31 * scale), smallBold);
        }

        var detailsX = detailsBounds.X;
        var detailsRight = detailsBounds.Right;
        var detailsWidth = detailsBounds.Width;
        var detailsY = detailsBounds.Y;
        graphics.DrawString(snapshot.Category.ToUpperInvariant(), eyebrow, red, detailsX, detailsY);
        BoardDrawing.DrawShadowedText(graphics, snapshot.Title.ToUpperInvariant(), title, pale,
            detailsX, detailsY + (int)Math.Round(24 * scale));
        BoardDrawing.DrawWrapped(graphics, snapshot.Description, body, muted,
            new RectangleF(detailsX, detailsY + (int)Math.Round(68 * scale), detailsWidth,
                (int)Math.Round(54 * scale)));

        var objectivesRuleY = detailsY + (int)Math.Round(137 * scale);
        graphics.DrawLine(divider, detailsX, objectivesRuleY, detailsRight, objectivesRuleY);
        graphics.DrawString("OBJECTIVES", section, red, detailsX,
            objectivesRuleY + (int)Math.Round(14 * scale));
        var objectives = snapshot.Selected.Objectives;
        for (var oi = 0; oi < objectives.Count; oi++)
        {
            var objective = objectives[oi];
            DrawObjectiveRow(graphics, detailsX, objectivesRuleY + (int)Math.Round((47 + oi * 37) * scale), detailsWidth,
                objective.Label, objective.Current, objective.Target,
                snapshot.Accepted || snapshot.RaidInProgress, body, bodyBold, pale, muted, gold);
        }
        var extraObjectiveHeight = (objectives.Count - 2) * 37;
        var extractionY = objectivesRuleY + (int)Math.Round((124 + extraObjectiveHeight) * scale);
        graphics.DrawString("EXTRACT ALIVE  //  SAME RAID", bodyBold, pale,
            detailsX + (int)Math.Round(15 * scale), extractionY);
        graphics.FillRectangle(red, detailsX, extractionY + (int)Math.Round(5 * scale),
            Math.Max(3, (int)Math.Round(4 * scale)), Math.Max(8, (int)Math.Round(10 * scale)));

        var failureRuleY = objectivesRuleY + (int)Math.Round((166 + extraObjectiveHeight) * scale);
        graphics.DrawLine(divider, detailsX, failureRuleY, detailsRight, failureRuleY);
        graphics.DrawString("FAILURE CONDITION", section, red, detailsX,
            failureRuleY + (int)Math.Round(14 * scale));
        BoardDrawing.DrawWrapped(graphics, snapshot.FailureCondition, body, pale,
            new RectangleF(detailsX, failureRuleY + (int)Math.Round(42 * scale), detailsWidth,
                (int)Math.Round(44 * scale)));

        var rewardsY = failureRuleY + (int)Math.Round(102 * scale);
        graphics.DrawString("REWARDS", section, red, detailsX, rewardsY);
        var rewards = snapshot.RewardSummary;
        BoardDrawing.DrawWrapped(graphics, rewards, bodyBold, snapshot.RewardsEnabled ? pale : muted,
            new RectangleF(detailsX, rewardsY + (int)Math.Round(29 * scale), detailsWidth,
                (int)Math.Round(60 * scale)));

        var feeRuleY = Math.Min(detailsBounds.Bottom - (int)Math.Round(132 * scale),
            rewardsY + (int)Math.Round(108 * scale));
        graphics.DrawLine(divider, detailsX, feeRuleY, detailsRight, feeRuleY);
        var fee = snapshot.Status.Equals("accepted", StringComparison.OrdinalIgnoreCase)
            ? ContractPresentationText.FeePaid(snapshot.AcceptanceWaterPaid)
            : ContractPresentationText.Fee(snapshot.AcceptanceWaterCost);
        graphics.DrawString(fee, smallBold, gold, detailsX,
            feeRuleY + (int)Math.Round(14 * scale));
        graphics.DrawString("CONTRACT FEES ARE NONREFUNDABLE", small, muted, detailsX,
            feeRuleY + (int)Math.Round(39 * scale));

        var action = ContractBoardLayout.ActionButton(size);
        var actionTarget = !snapshot.CanChangeContracts ? OverlayHitTarget.None
            : snapshot.Status.Equals("accepted", StringComparison.OrdinalIgnoreCase)
            ? OverlayHitTarget.Discard
            : snapshot.Status is "available" or "failed" or "complete"
                ? OverlayHitTarget.Accept : OverlayHitTarget.None;
        var actionHovered = hovered == actionTarget && actionTarget != OverlayHitTarget.None;
        using (var actionBrush = new LinearGradientBrush(action,
                   actionHovered ? Color.FromArgb(245, 241, 204, 79) : Color.FromArgb(230, 204, 170, 54),
                   actionHovered ? Color.FromArgb(238, 216, 80, 55) : Color.FromArgb(215, 132, 92, 40), 0f))
            graphics.FillRectangle(actionBrush, action);
        using (var actionEdge = new Pen(Color.FromArgb(245, 242, 216, 127), 1f))
            graphics.DrawRectangle(actionEdge, action);
        var actionText = actionTarget switch
        {
            { Kind: OverlayHitKind.Discard } => "DISCARD CONTRACT",
            { Kind: OverlayHitKind.Accept } => $"ACCEPT  //  PAY {snapshot.AcceptanceWaterCost} WATER",
            _ => snapshot.BoardLocked ? "BOARD LOCKED" : snapshot.RaidInProgress ? "LOCKED DURING RAID" : "UNAVAILABLE",
        };
        BoardDrawing.DrawCentered(graphics, actionText, bodyBold, Brushes.Black, action);

        graphics.DrawString("MOUSE SELECT  //  F7 OR ESC CLOSE", small, muted,
            bounds.X + inset, bounds.Bottom - (int)Math.Round(35 * scale));
        BoardDrawing.DrawRightAligned(graphics, snapshot.BoardLocked ? "BOARD LOCKED  //  CLOSE NORMALLY" :
                snapshot.BoardVacantCount > 0 ? $"{snapshot.BoardVacantCount} OPEN SLOTS  //  COMPLETE TO ROTATE" :
                "MULTIPLE CONTRACTS MAY BE READIED", small, muted,
            action.Left - (int)Math.Round(20 * scale), bounds.Bottom - (int)Math.Round(35 * scale));
    }

    private static void DrawObjectiveRow(Graphics graphics, int x, int y, int width, string label,
        int current, int target, bool showProgress, Font body, Font bold, Brush pale, Brush muted, Brush gold)
    {
        using var mark = new SolidBrush(Color.FromArgb(240, 220, 77, 54));
        graphics.FillRectangle(mark, x, y + 4, 4, 10);
        graphics.DrawString(label, body, pale, x + 13, y);
        var progress = ContractPresentationText.Counter(current, target, showProgress);
        BoardDrawing.DrawRightAligned(graphics, progress, bold, current >= target ? gold : muted, x + width, y);
    }

    private static void DrawStatusChip(Graphics graphics, string status, int x, int y, Font font)
    {
        var text = status.ToUpperInvariant() switch
        {
            "ACCEPTED" => "READY",
            "COMPLETE" => "COMPLETE",
            "FAILED" => "FAILED",
            _ => "AVAILABLE",
        };
        var color = status.ToLowerInvariant() switch
        {
            "accepted" or "complete" => Color.FromArgb(235, 229, 193, 70),
            "failed" => Color.FromArgb(235, 221, 77, 56),
            _ => Color.FromArgb(210, 132, 144, 137),
        };
        var measured = graphics.MeasureString(text, font);
        var rectangle = new RectangleF(x, y, measured.Width + 12, 20);
        using var brush = new SolidBrush(color);
        graphics.FillRectangle(brush, rectangle);
        graphics.DrawString(text, font, Brushes.Black, x + 6, y + 2);
    }
}

internal static class WaterBrokerOfferIcons
{
    private const string ResourcePrefix = "FWQuestOverlay.WaterBrokerIcons.";
    private static readonly Dictionary<string, string> Resources = new(StringComparer.Ordinal)
    {
        ["small_first_aid"] = ResourcePrefix + "small_first_aid.png",
        ["medium_first_aid"] = ResourcePrefix + "medium_first_aid.png",
        ["large_first_aid"] = ResourcePrefix + "large_first_aid.png",
        ["ammo_545_crate"] = ResourcePrefix + "ammo_545_crate.png",
        ["ammo_556_crate"] = ResourcePrefix + "ammo_556_crate.png",
        ["ammo_12g_crate"] = ResourcePrefix + "ammo_12g_crate.png",
        ["ammo_45acp_crate"] = ResourcePrefix + "ammo_45acp_crate.png",
        ["ammo_762_crate"] = ResourcePrefix + "ammo_762_crate.png",
        ["ammo_40mm_pack"] = ResourcePrefix + "ammo_40mm_pack.png",
        ["mead"] = ResourcePrefix + "mead.png",
        ["power_cell"] = ResourcePrefix + "power_cell.png",
        ["assorted_medicine"] = ResourcePrefix + "assorted_medicine.png",
        ["blood_packs"] = ResourcePrefix + "blood_packs.png",
        ["trauma_kit"] = ResourcePrefix + "trauma_kit.png",
        ["ammo_9mm_crate"] = ResourcePrefix + "ammo_9mm_crate.png",
        ["ammo_50bmg_pack"] = ResourcePrefix + "ammo_50bmg_pack.png",
        ["ammo_20mm_pack"] = ResourcePrefix + "ammo_20mm_pack.png",
        ["ammo_545_surplus_crate"] = ResourcePrefix + "ammo_545_surplus_crate.png",
        ["beer"] = ResourcePrefix + "beer.png",
        ["food_tin"] = ResourcePrefix + "food_tin.png",
        ["boinco_candy"] = ResourcePrefix + "boinco_candy.png",
        ["potato_chips"] = ResourcePrefix + "potato_chips.png",
        ["water_canteen"] = ResourcePrefix + "water_canteen.png",
        ["ethyl_alcohol"] = ResourcePrefix + "ethyl_alcohol.png",
        ["hinoko_cigarettes"] = ResourcePrefix + "hinoko_cigarettes.png",
        ["railgun_component"] = ResourcePrefix + "railgun_component.png",
        ["goodies"] = ResourcePrefix + "goodies.png",
        ["scav_go_bag"] = ResourcePrefix + "scav_go_bag.png",
        ["gunpowder"] = ResourcePrefix + "gunpowder.png",
        ["metal_fragments"] = ResourcePrefix + "metal_fragments.png",
        ["military_cables"] = ResourcePrefix + "military_cables.png",
        ["electric_motor"] = ResourcePrefix + "electric_motor.png",
        ["cpu"] = ResourcePrefix + "cpu.png",
        ["processor_board"] = ResourcePrefix + "processor_board.png",
        ["sewing_kit"] = ResourcePrefix + "sewing_kit.png",
        ["recovery_drone"] = ResourcePrefix + "recovery_drone.png",
        ["fast_travel_drone"] = ResourcePrefix + "fast_travel_drone.png",
        ["construction_drone"] = ResourcePrefix + "construction_drone.png",
        ["deployable_drill"] = ResourcePrefix + "deployable_drill.png",
        ["at_mass_component"] = ResourcePrefix + "at_mass_component.png",
        ["weapon_ak"] = ResourcePrefix + "weapon_ak.png",
        ["weapon_rpk"] = ResourcePrefix + "weapon_rpk.png",
        ["weapon_m16"] = ResourcePrefix + "weapon_m16.png",
        ["weapon_usp"] = ResourcePrefix + "weapon_usp.png",
        ["weapon_wlt_mpl"] = ResourcePrefix + "weapon_wlt_mpl.png",
        ["weapon_apc9"] = ResourcePrefix + "weapon_apc9.png",
        ["weapon_pp19"] = ResourcePrefix + "weapon_pp19.png",
        ["weapon_spectre"] = ResourcePrefix + "weapon_spectre.png",
        ["weapon_usas12"] = ResourcePrefix + "weapon_usas12.png",
        ["weapon_aa12"] = ResourcePrefix + "weapon_aa12.png",
        ["weapon_scar"] = ResourcePrefix + "weapon_scar.png",
        ["weapon_m60"] = ResourcePrefix + "weapon_m60.png",
        ["high_frequency_radio"] = ResourcePrefix + "high_frequency_radio.png",
        ["cyborg_immunosuppressant"] = ResourcePrefix + "cyborg_immunosuppressant.png",
        ["weapon_gm6"] = ResourcePrefix + "weapon_gm6.png",
    };
    private static readonly Dictionary<string, Image?> Cache = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, Rectangle> VisibleBounds = new(StringComparer.Ordinal);
    private static readonly object CacheLock = new();

    public static IReadOnlyCollection<string> RequiredOfferIds => Resources.Keys;

    public static bool Contains(string iconKey) => Resources.ContainsKey(iconKey);

    public static Image? Resolve(string offerId)
    {
        lock (CacheLock)
        {
            if (Cache.TryGetValue(offerId, out var cached)) return cached;
            if (!Resources.TryGetValue(offerId, out var resourceName)) return null;
            try
            {
                using var stream = typeof(WaterBrokerOfferIcons).Assembly.GetManifestResourceStream(resourceName);
                if (stream is null)
                {
                    Cache[offerId] = null;
                    return null;
                }
                using var decoded = Image.FromStream(stream, useEmbeddedColorManagement: false,
                    validateImageData: true);
                var copied = new Bitmap(decoded.Width, decoded.Height,
                    System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                using (var graphics = Graphics.FromImage(copied))
                {
                    graphics.CompositingMode = CompositingMode.SourceCopy;
                    graphics.DrawImageUnscaled(decoded, Point.Empty);
                }
                Cache[offerId] = copied;
                VisibleBounds[offerId] = FindVisibleBounds(copied);
                return copied;
            }
            catch
            {
                Cache[offerId] = null;
                return null;
            }
        }
    }

    public static void DrawContained(Graphics graphics, string offerId, Image image, Rectangle bounds)
    {
        if (bounds.Width < 1 || bounds.Height < 1 || image.Width < 1 || image.Height < 1) return;
        var source = VisibleBounds.TryGetValue(offerId, out var visible)
            ? visible : new Rectangle(0, 0, image.Width, image.Height);
        var scale = Math.Min(bounds.Width / (float)source.Width, bounds.Height / (float)source.Height);
        var width = Math.Max(1, (int)Math.Round(source.Width * scale));
        var height = Math.Max(1, (int)Math.Round(source.Height * scale));
        var target = new Rectangle(
            bounds.X + (bounds.Width - width) / 2,
            bounds.Y + (bounds.Height - height) / 2,
            width, height);
        var state = graphics.Save();
        try
        {
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.DrawImage(image, target, source.X, source.Y, source.Width, source.Height,
                GraphicsUnit.Pixel);
        }
        finally
        {
            graphics.Restore(state);
        }
    }

    private static Rectangle FindVisibleBounds(Bitmap bitmap)
    {
        var full = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(full, System.Drawing.Imaging.ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            var stride = Math.Abs(data.Stride);
            var pixels = new byte[stride * bitmap.Height];
            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            var left = bitmap.Width;
            var top = bitmap.Height;
            var right = -1;
            var bottom = -1;
            for (var y = 0; y < bitmap.Height; y++)
            {
                var row = data.Stride >= 0 ? y * stride : (bitmap.Height - 1 - y) * stride;
                for (var x = 0; x < bitmap.Width; x++)
                {
                    if (pixels[row + x * 4 + 3] <= 4) continue;
                    left = Math.Min(left, x);
                    top = Math.Min(top, y);
                    right = Math.Max(right, x);
                    bottom = Math.Max(bottom, y);
                }
            }
            return right >= left && bottom >= top
                ? Rectangle.FromLTRB(left, top, right + 1, bottom + 1)
                : full;
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }
}

internal static class WaterBrokerShopkeeperPortrait
{
    private const string ResourceName = "FWQuestOverlay.WaterBrokerShopkeeper.portrait.jpg";
    private static readonly Lazy<Image?> Portrait = new(Load);

    public static bool Available => Portrait.Value is not null;
    public static Size PixelSize => Portrait.Value?.Size ?? Size.Empty;

    public static void DrawCover(Graphics graphics, Rectangle bounds)
    {
        var image = Portrait.Value;
        if (image is null || bounds.Width < 1 || bounds.Height < 1) return;
        var scale = Math.Max(bounds.Width / (float)image.Width, bounds.Height / (float)image.Height);
        var sourceWidth = Math.Max(1, (int)Math.Round(bounds.Width / scale));
        var sourceHeight = Math.Max(1, (int)Math.Round(bounds.Height / scale));
        sourceWidth = Math.Min(sourceWidth, image.Width);
        sourceHeight = Math.Min(sourceHeight, image.Height);
        var source = new Rectangle(
            Math.Max(0, (image.Width - sourceWidth) / 2),
            Math.Max(0, (image.Height - sourceHeight) / 2),
            sourceWidth, sourceHeight);
        var state = graphics.Save();
        try
        {
            graphics.CompositingQuality = CompositingQuality.HighQuality;
            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            graphics.DrawImage(image, bounds, source.X, source.Y, source.Width, source.Height,
                GraphicsUnit.Pixel);
        }
        finally
        {
            graphics.Restore(state);
        }
    }

    private static Image? Load()
    {
        try
        {
            using var stream = typeof(WaterBrokerShopkeeperPortrait).Assembly
                .GetManifestResourceStream(ResourceName);
            if (stream is null) return null;
            using var decoded = Image.FromStream(stream, useEmbeddedColorManagement: false,
                validateImageData: true);
            var copied = new Bitmap(decoded.Width, decoded.Height,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using var graphics = Graphics.FromImage(copied);
            graphics.DrawImageUnscaled(decoded, Point.Empty);
            return copied;
        }
        catch
        {
            return null;
        }
    }
}

internal static class WaterTraderRenderer
{
    public static void Draw(Graphics graphics, Size size, WaterVendorSnapshot snapshot, bool shadow,
        OverlayHitTarget hovered, WaterPurchaseConfirmation? confirmation, bool commandAwaitingRevision)
    {
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var scale = WaterTraderLayout.UiScale(size);
        var bounds = WaterTraderLayout.InnerBounds(size);
        var content = WaterTraderLayout.ContentBounds(size);
        var shopkeeper = WaterTraderLayout.ShopkeeperBounds(size);
        var offers = WaterTraderLayout.OfferListBounds(size);
        var details = WaterTraderLayout.DetailsBounds(size);
        var cut = Math.Max(8, (int)Math.Round(14 * scale));

        // Match the Contract Board's full-client modal treatment while the
        // height-derived inner lane protects readable proportions on ultrawide.
        using (var clientWash = new SolidBrush(Color.FromArgb(142, 3, 5, 5)))
            graphics.FillRectangle(clientWash, new Rectangle(Point.Empty, size));
        if (shadow)
        {
            using var shadowBrush = new SolidBrush(Color.FromArgb(105, 0, 0, 0));
            using var shadowPath = BoardDrawing.AngularPath(
                new Rectangle(bounds.X + (int)Math.Round(7 * scale),
                    bounds.Y + (int)Math.Round(8 * scale), bounds.Width, bounds.Height), cut);
            graphics.FillPath(shadowBrush, shadowPath);
        }

        using var panelPath = BoardDrawing.AngularPath(bounds, cut);
        using var background = new LinearGradientBrush(bounds,
            Color.FromArgb(224, 24, 39, 39), Color.FromArgb(218, 7, 13, 14), 24f);
        using var edge = new Pen(Color.FromArgb(225, 87, 145, 140), Math.Max(1f, 1.2f * scale));
        graphics.FillPath(background, panelPath);
        graphics.DrawPath(edge, panelPath);

        var headerHeight = (int)Math.Round(102 * scale);
        using var headerWash = new SolidBrush(Color.FromArgb(96, 36, 125, 126));
        graphics.FillRectangle(headerWash, bounds.X + 1, bounds.Y + 1, bounds.Width - 2, headerHeight);
        using var topAccent = new Pen(Color.FromArgb(250, 65, 190, 186), Math.Max(2f, 3f * scale));
        graphics.DrawLine(topAccent, bounds.X + (int)Math.Round(15 * scale), bounds.Y + 2,
            bounds.Right - 2, bounds.Y + 2);
        graphics.DrawLine(topAccent, bounds.X + 2, bounds.Y + (int)Math.Round(15 * scale),
            bounds.X + 2, bounds.Bottom - 2);

        using var eyebrow = BoardDrawing.FontOf(9f * scale, FontStyle.Bold);
        using var header = BoardDrawing.FontOf(27f * scale, FontStyle.Bold);
        using var title = BoardDrawing.FontOf(21f * scale, FontStyle.Bold);
        using var section = BoardDrawing.FontOf(10f * scale, FontStyle.Bold);
        using var body = BoardDrawing.FontOf(9.5f * scale, FontStyle.Regular);
        using var bodyBold = BoardDrawing.FontOf(9.5f * scale, FontStyle.Bold);
        using var small = BoardDrawing.FontOf(7.5f * scale, FontStyle.Regular);
        using var smallBold = BoardDrawing.FontOf(7.5f * scale, FontStyle.Bold);
        using var pale = new SolidBrush(Color.FromArgb(252, 232, 240, 235));
        using var muted = new SolidBrush(Color.FromArgb(220, 139, 161, 155));
        using var aqua = new SolidBrush(Color.FromArgb(250, 76, 205, 197));
        using var gold = new SolidBrush(Color.FromArgb(250, 239, 197, 72));
        using var red = new SolidBrush(Color.FromArgb(248, 225, 79, 55));
        using var divider = new Pen(Color.FromArgb(145, 82, 119, 115), Math.Max(1f, scale));

        var inset = (int)Math.Round(30 * scale);
        graphics.DrawString("WATER 4.0  //  INNARDS EXCHANGE", eyebrow, aqua,
            bounds.X + inset, bounds.Y + (int)Math.Round(17 * scale));
        BoardDrawing.DrawShadowedText(graphics, snapshot.VendorTitle.ToUpperInvariant(), header, pale,
            bounds.X + inset, bounds.Y + (int)Math.Round(39 * scale));
        var marketSubtitle = WaterVendorPresentationText.MarketSubtitle(snapshot);
        var marketRestricted = !snapshot.WeaponsAllowed || !snapshot.SpecialItemsAllowed;
        graphics.DrawString(marketSubtitle, smallBold,
            marketRestricted ? gold : muted,
            bounds.X + (int)Math.Round(430 * scale), bounds.Y + (int)Math.Round(59 * scale));
        var waterLabel = snapshot.WaterKnown ? $"{snapshot.WaterBalance:N0} WATER" : "WATER UNKNOWN";
        var close = WaterTraderLayout.CloseButton(size);
        BoardDrawing.DrawRightAligned(graphics, waterLabel, title, snapshot.WaterKnown ? gold : muted,
            close.Left - (int)Math.Round(24 * scale), bounds.Y + (int)Math.Round(38 * scale));
        using (var closeBrush = new SolidBrush(hovered == OverlayHitTarget.CloseSurface
                   ? Color.FromArgb(235, 225, 79, 55) : Color.FromArgb(150, 70, 88, 83)))
            graphics.FillRectangle(closeBrush, close);
        BoardDrawing.DrawCentered(graphics, "X", bodyBold, Brushes.White, close);

        var headerRuleY = bounds.Y + headerHeight + (int)Math.Round(8 * scale);
        graphics.DrawLine(divider, bounds.X + inset, headerRuleY, bounds.Right - inset, headerRuleY);

        // Dedicated shopkeeper bay. The embedded portrait is presentation-only
        // and may be replaced later without changing card or economy identity.
        using (var portraitBack = new SolidBrush(Color.FromArgb(225, 10, 15, 15)))
            graphics.FillRectangle(portraitBack, shopkeeper);
        if (WaterBrokerShopkeeperPortrait.Available)
            WaterBrokerShopkeeperPortrait.DrawCover(graphics, shopkeeper);
        using (var portraitShade = new LinearGradientBrush(shopkeeper,
                   Color.FromArgb(16, 4, 7, 7), Color.FromArgb(232, 4, 7, 7), 90f))
            graphics.FillRectangle(portraitShade, shopkeeper);
        using (var portraitEdge = new Pen(Color.FromArgb(180, 76, 154, 148), Math.Max(1f, scale)))
            graphics.DrawRectangle(portraitEdge, shopkeeper);
        using (var portraitTag = new SolidBrush(Color.FromArgb(210, 9, 18, 18)))
            graphics.FillRectangle(portraitTag, shopkeeper.X, shopkeeper.Y,
                shopkeeper.Width, Math.Max(28, (int)Math.Round(40 * scale)));
        graphics.DrawString("SHOPKEEPER", smallBold, aqua,
            shopkeeper.X + (int)Math.Round(14 * scale), shopkeeper.Y + (int)Math.Round(12 * scale));
        var portraitTextY = shopkeeper.Bottom - (int)Math.Round(92 * scale);
        BoardDrawing.DrawShadowedText(graphics, "THE WATER BROKER", section, pale,
            shopkeeper.X + (int)Math.Round(15 * scale), portraitTextY);
        graphics.DrawString("SCAVENGER SUPPLY LIAISON", smallBold, gold,
            shopkeeper.X + (int)Math.Round(16 * scale), portraitTextY + (int)Math.Round(28 * scale));
        BoardDrawing.DrawWrapped(graphics, "Goods turn over. Water keeps the route alive.", small, muted,
            new RectangleF(shopkeeper.X + (int)Math.Round(16 * scale),
                portraitTextY + (int)Math.Round(50 * scale),
                shopkeeper.Width - (int)Math.Round(32 * scale), (int)Math.Round(34 * scale)));

        graphics.DrawLine(divider, shopkeeper.Right + (int)Math.Round(12 * scale), content.Top,
            shopkeeper.Right + (int)Math.Round(12 * scale), content.Bottom);
        graphics.DrawString("CURRENT ROTATION", section, aqua, offers.X, offers.Y);
        var bandText = string.IsNullOrWhiteSpace(snapshot.StockBandId)
            ? "BAND UNKNOWN" : snapshot.StockBandId.ToUpperInvariant();
        graphics.DrawString($"{snapshot.Offers.Count} OFFERS  //  ROTATION {snapshot.RotationIndex}  //  {bandText}",
            smallBold, muted, offers.X, offers.Y + (int)Math.Round(22 * scale));
        var countdown = WaterTraderRotationClock.Label(snapshot.RefreshDeadline,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        BoardDrawing.DrawRightAligned(graphics, countdown, smallBold,
            snapshot.RefreshDeadline > 0 ? gold : muted, offers.Right,
            offers.Y + (int)Math.Round(22 * scale));

        for (var index = 0; index < Math.Min(WaterTraderLayout.MaximumVisibleOffers, snapshot.Offers.Count); index++)
        {
            var offer = snapshot.Offers[index];
            var card = WaterTraderLayout.OfferCard(size, index);
            var selected = index == snapshot.SelectedIndex;
            var cardHovered = hovered == OverlayHitTarget.WaterOfferAt(index);
            using (var cardBackground = new LinearGradientBrush(card,
                       selected ? Color.FromArgb(222, 43, 78, 75) :
                           cardHovered ? Color.FromArgb(207, 43, 61, 59) : Color.FromArgb(180, 26, 35, 34),
                       Color.FromArgb(171, 13, 20, 20), 90f))
                graphics.FillRectangle(cardBackground, card);
            using (var cardEdge = new Pen(selected ? Color.FromArgb(245, 72, 207, 198) :
                       cardHovered ? Color.FromArgb(220, 235, 198, 82) : Color.FromArgb(100, 112, 137, 131),
                       selected ? Math.Max(1.5f, 1.5f * scale) : Math.Max(1f, scale)))
                graphics.DrawRectangle(cardEdge, card);
            if (selected) graphics.FillRectangle(aqua, card.X, card.Y,
                Math.Max(3, (int)Math.Round(4 * scale)), card.Height);
            var cardInset = (int)Math.Round(14 * scale);
            graphics.DrawString(offer.Category.ToUpperInvariant(), smallBold, selected ? aqua : muted,
                card.X + cardInset, card.Y + (int)Math.Round(10 * scale));
            BoardDrawing.DrawRightAligned(graphics, offer.Remaining > 0
                    ? $"{offer.Remaining}/{offer.InitialStock} LEFT" : "SOLD OUT",
                smallBold, offer.Remaining > 0 ? pale : red, card.Right - (int)Math.Round(10 * scale),
                card.Y + (int)Math.Round(10 * scale));
            var iconTop = card.Y + (int)Math.Round(30 * scale);
            var iconBottom = card.Bottom - (int)Math.Round(31 * scale);
            var iconBounds = new Rectangle(card.X + (int)Math.Round(12 * scale), iconTop,
                card.Width - (int)Math.Round(24 * scale), Math.Max(1, iconBottom - iconTop));
            var offerIcon = WaterBrokerOfferIcons.Resolve(offer.IconKey);
            if (offerIcon is not null)
                WaterBrokerOfferIcons.DrawContained(graphics, offer.IconKey, offerIcon, iconBounds);
            else
                BoardDrawing.DrawWrapped(graphics, offer.DisplayName.ToUpperInvariant(), bodyBold, pale,
                    iconBounds);
            graphics.DrawString($"x{offer.GrantQuantityPerUnit:N0}  //  {offer.UnitWaterCost} WATER",
                bodyBold, offer.PurchaseReady ? gold : muted, card.X + cardInset,
                card.Bottom - (int)Math.Round(27 * scale));
        }

        graphics.DrawLine(divider, details.Left - (int)Math.Round(12 * scale), content.Top,
            details.Left - (int)Math.Round(12 * scale), content.Bottom);
        var detailsX = details.X;
        var detailsRight = details.Right;
        var detailsWidth = details.Width;
        var detailsY = details.Y;
        var selectedOffer = snapshot.Selected;
        graphics.DrawString("SELECTED OFFER", section, aqua, detailsX, detailsY);
        BoardDrawing.DrawShadowedText(graphics, selectedOffer.DisplayName.ToUpperInvariant(), title, pale,
            detailsX, detailsY + (int)Math.Round(25 * scale));
        graphics.DrawString(selectedOffer.Id, small, muted, detailsX,
            detailsY + (int)Math.Round(62 * scale));

        var quoteRuleY = detailsY + (int)Math.Round(92 * scale);
        graphics.DrawLine(divider, detailsX, quoteRuleY, detailsRight, quoteRuleY);
        graphics.DrawString("EXCHANGE QUOTE", section, aqua, detailsX,
            quoteRuleY + (int)Math.Round(14 * scale));
        var previewUnits = confirmation?.PurchaseUnits ?? 1;
        var previewQuantity = selectedOffer.GrantQuantityPerUnit * previewUnits;
        var previewCost = selectedOffer.UnitWaterCost * previewUnits;
        var quoteStart = quoteRuleY + (int)Math.Round(47 * scale);
        var rowStep = (int)Math.Round(31 * scale);
        DrawQuoteRow(graphics, "PURCHASE UNITS", previewUnits.ToString("N0"), detailsX, quoteStart,
            detailsWidth, body, bodyBold, pale, gold);
        DrawQuoteRow(graphics, "RECEIVE", $"x{previewQuantity:N0}", detailsX, quoteStart + rowStep,
            detailsWidth, body, bodyBold, pale, gold);
        DrawQuoteRow(graphics, "COST", $"{previewCost:N0} WATER", detailsX, quoteStart + rowStep * 2,
            detailsWidth, body, bodyBold, pale, gold);
        var evidenceRuleY = quoteStart + rowStep * 3 + (int)Math.Round(10 * scale);
        graphics.DrawLine(divider, detailsX, evidenceRuleY, detailsRight, evidenceRuleY);
        var availability = snapshot.CanPurchaseSelected(out var unavailableReason)
            ? "QUOTE READY" : unavailableReason.Replace('_', ' ').ToUpperInvariant();
        graphics.DrawString(availability, bodyBold, snapshot.CanPurchaseSelected(out _) ? aqua : red,
            detailsX, evidenceRuleY + (int)Math.Round(14 * scale));

        var statusRuleY = details.Bottom - (int)Math.Round(190 * scale);
        graphics.DrawLine(divider, detailsX, statusRuleY, detailsRight, statusRuleY);
        if (confirmation is not null)
        {
            using var modalFill = new SolidBrush(Color.FromArgb(218, 12, 24, 24));
            using var modalEdge = new Pen(Color.FromArgb(235, 76, 205, 197), Math.Max(1f, 1.5f * scale));
            var modal = new Rectangle(detailsX - (int)Math.Round(10 * scale),
                statusRuleY + (int)Math.Round(6 * scale), detailsWidth + (int)Math.Round(20 * scale),
                details.Bottom - statusRuleY - (int)Math.Round(6 * scale));
            graphics.FillRectangle(modalFill, modal);
            graphics.DrawRectangle(modalEdge, modal);
            graphics.DrawString("CONFIRM EXCHANGE", section, gold, detailsX,
                statusRuleY + (int)Math.Round(15 * scale));
            BoardDrawing.DrawRightAligned(graphics,
                $"x{confirmation.ExpectedTotalQuantity:N0} / {confirmation.ExpectedTotalWaterCost:N0} WATER",
                bodyBold, pale, detailsRight, statusRuleY + (int)Math.Round(15 * scale));
            DrawActionButton(graphics, WaterTraderLayout.QuantityDecreaseButton(size), "−",
                hovered == OverlayHitTarget.DecreasePurchaseQuantity,
                confirmation.PurchaseUnits > 1, bodyBold);
            var quantityBox = WaterTraderLayout.QuantityValue(size);
            using (var quantityFill = new SolidBrush(Color.FromArgb(235, 27, 45, 43)))
                graphics.FillRectangle(quantityFill, quantityBox);
            using (var quantityEdge = new Pen(Color.FromArgb(210, 88, 139, 132), Math.Max(1f, scale)))
                graphics.DrawRectangle(quantityEdge, quantityBox);
            BoardDrawing.DrawCentered(graphics, confirmation.PurchaseUnits.ToString("N0"), bodyBold, pale,
                quantityBox);
            DrawActionButton(graphics, WaterTraderLayout.QuantityIncreaseButton(size), "+",
                hovered == OverlayHitTarget.IncreasePurchaseQuantity,
                confirmation.PurchaseUnits < snapshot.MaximumPurchaseUnits(), bodyBold);
            DrawActionButton(graphics, WaterTraderLayout.QuantityMaxButton(size), "MAX",
                hovered == OverlayHitTarget.MaxPurchaseQuantity,
                confirmation.PurchaseUnits < snapshot.MaximumPurchaseUnits(), bodyBold);
            DrawActionButton(graphics, WaterTraderLayout.ConfirmButton(size), "CONFIRM EXCHANGE",
                hovered == OverlayHitTarget.ConfirmPurchase, true, bodyBold);
            DrawActionButton(graphics, WaterTraderLayout.CancelButton(size), "CANCEL",
                hovered == OverlayHitTarget.CancelPurchase, true, bodyBold);
        }
        else
        {
            graphics.DrawString("LATEST PURCHASE", section, aqua, detailsX,
                statusRuleY + (int)Math.Round(15 * scale));
            var purchaseMessage = snapshot.LastResultCode.Equals("purchase_committed",
                    StringComparison.OrdinalIgnoreCase)
                && !string.IsNullOrWhiteSpace(snapshot.LastResultMessage)
                    ? snapshot.LastResultMessage
                    : "NO PURCHASE THIS SESSION";
            BoardDrawing.DrawWrapped(graphics, purchaseMessage, bodyBold, pale,
                new RectangleF(detailsX, statusRuleY + (int)Math.Round(44 * scale),
                    detailsWidth, (int)Math.Round(58 * scale)));
            var canPurchase = snapshot.CanPurchaseSelected(out var reason);
            var actionText = commandAwaitingRevision
                ? "WAITING FOR FRAMEWORK SNAPSHOT"
                : canPurchase
                    ? $"REVIEW  //  x{selectedOffer.GrantQuantityPerUnit:N0} FOR {selectedOffer.UnitWaterCost:N0} WATER"
                    : reason.Replace('_', ' ').ToUpperInvariant();
            DrawActionButton(graphics, WaterTraderLayout.PurchaseButton(size), actionText,
                hovered == OverlayHitTarget.BeginPurchase, canPurchase && !commandAwaitingRevision, bodyBold);
        }

        graphics.DrawString("CLICK ITEM  //  CHOOSE − / + / MAX  //  CONFIRM  //  F6 / ESC CLOSE",
            small, muted, bounds.X + inset, bounds.Bottom - (int)Math.Round(35 * scale));
        BoardDrawing.DrawRightAligned(graphics, "EXTERNAL UI  //  FRAMEWORK OWNS ECONOMY",
            small, muted, bounds.Right - inset, bounds.Bottom - (int)Math.Round(35 * scale));
    }

    // Retained as a visual reference for the live-proven v0.0.41 fixed panel.
    // The full-client renderer above is the only active Water Broker path.
    private static void DrawFixedReference(Graphics graphics, Size size, WaterVendorSnapshot snapshot, bool shadow,
        OverlayHitTarget hovered, WaterPurchaseConfirmation? confirmation, bool commandAwaitingRevision)
    {
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var bounds = WaterTraderLayout.InnerBounds(size);
        if (shadow)
        {
            using var shadowBrush = new SolidBrush(Color.FromArgb(105, 0, 0, 0));
            using var shadowPath = BoardDrawing.AngularPath(
                new Rectangle(bounds.X + 7, bounds.Y + 8, bounds.Width, bounds.Height), 14);
            graphics.FillPath(shadowBrush, shadowPath);
        }

        using var panelPath = BoardDrawing.AngularPath(bounds, 14);
        using var background = new LinearGradientBrush(bounds,
            Color.FromArgb(241, 30, 39, 40), Color.FromArgb(234, 9, 16, 17), 24f);
        using var edge = new Pen(Color.FromArgb(225, 87, 126, 123), 1.2f);
        graphics.FillPath(background, panelPath);
        graphics.DrawPath(edge, panelPath);
        using var headerWash = new SolidBrush(Color.FromArgb(92, 36, 125, 126));
        graphics.FillRectangle(headerWash, bounds.X + 1, bounds.Y + 1, bounds.Width - 2, 74);
        using var topAccent = new Pen(Color.FromArgb(250, 65, 190, 186), 3f);
        graphics.DrawLine(topAccent, bounds.X + 15, bounds.Y + 2, bounds.Right - 2, bounds.Y + 2);
        graphics.DrawLine(topAccent, bounds.X + 2, bounds.Y + 15, bounds.X + 2, bounds.Bottom - 2);

        using var eyebrow = BoardDrawing.FontOf(9f, FontStyle.Bold);
        using var header = BoardDrawing.FontOf(25f, FontStyle.Bold);
        using var title = BoardDrawing.FontOf(19f, FontStyle.Bold);
        using var section = BoardDrawing.FontOf(10f, FontStyle.Bold);
        using var body = BoardDrawing.FontOf(9.5f, FontStyle.Regular);
        using var bodyBold = BoardDrawing.FontOf(9.5f, FontStyle.Bold);
        using var small = BoardDrawing.FontOf(7.5f, FontStyle.Regular);
        using var smallBold = BoardDrawing.FontOf(7.5f, FontStyle.Bold);
        using var pale = new SolidBrush(Color.FromArgb(252, 232, 240, 235));
        using var muted = new SolidBrush(Color.FromArgb(220, 139, 161, 155));
        using var aqua = new SolidBrush(Color.FromArgb(250, 76, 205, 197));
        using var gold = new SolidBrush(Color.FromArgb(250, 239, 197, 72));
        using var red = new SolidBrush(Color.FromArgb(248, 225, 79, 55));
        using var divider = new Pen(Color.FromArgb(145, 82, 119, 115), 1f);

        graphics.DrawString("WATER 4.0  //  INNARDS EXCHANGE", eyebrow, aqua, bounds.X + 24, bounds.Y + 15);
        BoardDrawing.DrawShadowedText(graphics, snapshot.VendorTitle.ToUpperInvariant(), header, pale,
            bounds.X + 22, bounds.Y + 31);
        var vendorTitleWidth = graphics.MeasureString(snapshot.VendorTitle.ToUpperInvariant(), header).Width;
        var subtitleX = Math.Max(bounds.X + 266, bounds.X + 22 + (int)Math.Ceiling(vendorTitleWidth) + 18);
        var marketSubtitle = WaterVendorPresentationText.MarketSubtitle(snapshot);
        var marketRestricted = !snapshot.WeaponsAllowed || !snapshot.SpecialItemsAllowed;
        graphics.DrawString(marketSubtitle, smallBold,
            marketRestricted ? gold : muted,
            subtitleX, bounds.Y + 50);
        var waterLabel = snapshot.WaterKnown ? $"{snapshot.WaterBalance:N0} WATER" : "WATER UNKNOWN";
        BoardDrawing.DrawRightAligned(graphics, waterLabel, title, snapshot.WaterKnown ? gold : muted,
            bounds.Right - 75, bounds.Y + 29);

        var close = WaterTraderLayout.CloseButton(size);
        using (var closeBrush = new SolidBrush(hovered == OverlayHitTarget.CloseSurface
                   ? Color.FromArgb(235, 225, 79, 55) : Color.FromArgb(150, 70, 88, 83)))
            graphics.FillRectangle(closeBrush, close);
        graphics.DrawString("X", bodyBold, Brushes.White, close.X + 11, close.Y + 5);

        graphics.DrawLine(divider, bounds.X + 22, bounds.Y + 82, bounds.Right - 22, bounds.Y + 82);
        graphics.DrawString("CURRENT ROTATION", section, aqua, bounds.X + 24, bounds.Y + 94);
        var bandText = string.IsNullOrWhiteSpace(snapshot.StockBandId)
            ? "BAND UNKNOWN" : snapshot.StockBandId.ToUpperInvariant();
        graphics.DrawString($"{snapshot.Offers.Count} OFFERS  //  ROTATION {snapshot.RotationIndex}  //  {bandText}",
            smallBold, muted, bounds.X + 190, bounds.Y + 97);
        var countdown = WaterTraderRotationClock.Label(snapshot.RefreshDeadline,
            DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        var rotationListRight = WaterTraderLayout.OfferCard(size, 1).Right;
        BoardDrawing.DrawRightAligned(graphics, countdown, smallBold,
            snapshot.RefreshDeadline > 0 ? gold : muted, rotationListRight, bounds.Y + 97);

        for (var index = 0; index < Math.Min(WaterTraderLayout.MaximumVisibleOffers, snapshot.Offers.Count); index++)
        {
            var offer = snapshot.Offers[index];
            var card = WaterTraderLayout.OfferCard(size, index);
            var selected = index == snapshot.SelectedIndex;
            var cardHovered = hovered == OverlayHitTarget.WaterOfferAt(index);
            using (var cardBackground = new LinearGradientBrush(card,
                       selected ? Color.FromArgb(222, 43, 78, 75) :
                           cardHovered ? Color.FromArgb(207, 43, 61, 59) : Color.FromArgb(180, 26, 35, 34),
                       Color.FromArgb(171, 13, 20, 20), 90f))
                graphics.FillRectangle(cardBackground, card);
            using (var cardEdge = new Pen(selected ? Color.FromArgb(245, 72, 207, 198) :
                       cardHovered ? Color.FromArgb(220, 235, 198, 82) : Color.FromArgb(100, 112, 137, 131),
                       selected ? 1.5f : 1f))
                graphics.DrawRectangle(cardEdge, card);
            if (selected) graphics.FillRectangle(aqua, card.X, card.Y, 4, card.Height);
            graphics.DrawString(offer.Category.ToUpperInvariant(), smallBold, selected ? aqua : muted,
                card.X + 14, card.Y + 10);
            BoardDrawing.DrawRightAligned(graphics, offer.Remaining > 0
                    ? $"{offer.Remaining}/{offer.InitialStock} LEFT" : "SOLD OUT",
                smallBold, offer.Remaining > 0 ? pale : red, card.Right - 10, card.Y + 10);
            var iconBounds = new Rectangle(card.X + 12, card.Y + 26, card.Width - 24, 47);
            var offerIcon = WaterBrokerOfferIcons.Resolve(offer.IconKey);
            if (offerIcon is not null)
                WaterBrokerOfferIcons.DrawContained(graphics, offer.IconKey, offerIcon, iconBounds);
            else
                BoardDrawing.DrawWrapped(graphics, offer.DisplayName.ToUpperInvariant(), bodyBold, pale,
                    new RectangleF(iconBounds.X + 2, iconBounds.Y + 3, iconBounds.Width - 4,
                        iconBounds.Height - 6));
            graphics.DrawString($"x{offer.GrantQuantityPerUnit:N0}  //  {offer.UnitWaterCost} WATER",
                bodyBold, offer.PurchaseReady ? gold : muted, card.X + 14, card.Bottom - 28);
        }

        var listRight = WaterTraderLayout.OfferCard(size, 1).Right;
        var detailsX = listRight + 42;
        var detailsRight = bounds.Right - 28;
        var detailsWidth = detailsRight - detailsX;
        graphics.DrawLine(divider, listRight + 20, bounds.Y + 93, listRight + 20, bounds.Bottom - 31);
        var selectedOffer = snapshot.Selected;
        graphics.DrawString("SELECTED OFFER", section, aqua, detailsX, bounds.Y + 99);
        BoardDrawing.DrawShadowedText(graphics, selectedOffer.DisplayName.ToUpperInvariant(), title, pale,
            detailsX, bounds.Y + 121);
        graphics.DrawString(selectedOffer.Id, small, muted, detailsX, bounds.Y + 153);

        graphics.DrawLine(divider, detailsX, bounds.Y + 181, detailsRight, bounds.Y + 181);
        graphics.DrawString("EXCHANGE QUOTE", section, aqua, detailsX, bounds.Y + 194);
        var previewUnits = confirmation?.PurchaseUnits ?? 1;
        var previewQuantity = selectedOffer.GrantQuantityPerUnit * previewUnits;
        var previewCost = selectedOffer.UnitWaterCost * previewUnits;
        DrawQuoteRow(graphics, "PURCHASE UNITS", previewUnits.ToString("N0"), detailsX, bounds.Y + 222, detailsWidth,
            body, bodyBold, pale, gold);
        DrawQuoteRow(graphics, "RECEIVE", $"x{previewQuantity:N0}", detailsX,
            bounds.Y + 251, detailsWidth, body, bodyBold, pale, gold);
        DrawQuoteRow(graphics, "COST", $"{previewCost:N0} WATER", detailsX,
            bounds.Y + 280, detailsWidth, body, bodyBold, pale, gold);
        graphics.DrawLine(divider, detailsX, bounds.Y + 313, detailsRight, bounds.Y + 313);
        var availability = snapshot.CanPurchaseSelected(out var unavailableReason)
            ? "QUOTE READY" : unavailableReason.Replace('_', ' ').ToUpperInvariant();
        graphics.DrawString(availability, bodyBold, snapshot.CanPurchaseSelected(out _) ? aqua : red,
            detailsX, bounds.Y + 325);

        graphics.DrawLine(divider, detailsX, bounds.Y + 467, detailsRight, bounds.Y + 467);
        if (confirmation is not null)
        {
            using var modalFill = new SolidBrush(Color.FromArgb(218, 12, 24, 24));
            using var modalEdge = new Pen(Color.FromArgb(235, 76, 205, 197), 1.5f);
            var modal = new Rectangle(detailsX - 10, bounds.Y + 473, detailsWidth + 20, 137);
            graphics.FillRectangle(modalFill, modal);
            graphics.DrawRectangle(modalEdge, modal);
            graphics.DrawString("CONFIRM EXCHANGE", section, gold, detailsX, bounds.Y + 479);
            BoardDrawing.DrawRightAligned(graphics,
                $"x{confirmation.ExpectedTotalQuantity:N0} / {confirmation.ExpectedTotalWaterCost:N0} WATER",
                bodyBold, pale, detailsRight, bounds.Y + 479);
            DrawActionButton(graphics, WaterTraderLayout.QuantityDecreaseButton(size), "−",
                hovered == OverlayHitTarget.DecreasePurchaseQuantity,
                confirmation.PurchaseUnits > 1, bodyBold);
            var quantityBox = WaterTraderLayout.QuantityValue(size);
            using (var quantityFill = new SolidBrush(Color.FromArgb(235, 27, 45, 43)))
                graphics.FillRectangle(quantityFill, quantityBox);
            using (var quantityEdge = new Pen(Color.FromArgb(210, 88, 139, 132), 1f))
                graphics.DrawRectangle(quantityEdge, quantityBox);
            BoardDrawing.DrawCentered(graphics, confirmation.PurchaseUnits.ToString("N0"), bodyBold, pale,
                quantityBox);
            DrawActionButton(graphics, WaterTraderLayout.QuantityIncreaseButton(size), "+",
                hovered == OverlayHitTarget.IncreasePurchaseQuantity,
                confirmation.PurchaseUnits < snapshot.MaximumPurchaseUnits(), bodyBold);
            DrawActionButton(graphics, WaterTraderLayout.QuantityMaxButton(size), "MAX",
                hovered == OverlayHitTarget.MaxPurchaseQuantity,
                confirmation.PurchaseUnits < snapshot.MaximumPurchaseUnits(), bodyBold);
            DrawActionButton(graphics, WaterTraderLayout.ConfirmButton(size), "CONFIRM EXCHANGE",
                hovered == OverlayHitTarget.ConfirmPurchase, true, bodyBold);
            DrawActionButton(graphics, WaterTraderLayout.CancelButton(size), "CANCEL",
                hovered == OverlayHitTarget.CancelPurchase, true, bodyBold);
        }
        else
        {
            graphics.DrawString("LATEST PURCHASE", section, aqua, detailsX, bounds.Y + 479);
            var purchaseMessage = snapshot.LastResultCode.Equals("purchase_committed",
                    StringComparison.OrdinalIgnoreCase)
                && !string.IsNullOrWhiteSpace(snapshot.LastResultMessage)
                    ? snapshot.LastResultMessage
                    : "NO PURCHASE THIS SESSION";
            BoardDrawing.DrawWrapped(graphics, purchaseMessage, bodyBold, pale,
                new RectangleF(detailsX, bounds.Y + 503, detailsWidth, 53));
            var canPurchase = snapshot.CanPurchaseSelected(out var reason);
            var actionText = commandAwaitingRevision
                ? "WAITING FOR FRAMEWORK SNAPSHOT"
                : canPurchase
                    ? $"REVIEW  //  x{selectedOffer.GrantQuantityPerUnit:N0} FOR {selectedOffer.UnitWaterCost:N0} WATER"
                    : reason.Replace('_', ' ').ToUpperInvariant();
            DrawActionButton(graphics, WaterTraderLayout.PurchaseButton(size), actionText,
                hovered == OverlayHitTarget.BeginPurchase, canPurchase && !commandAwaitingRevision, bodyBold);
        }

        graphics.DrawString("CLICK ITEM  //  CHOOSE − / + / MAX  //  CONFIRM  //  F6 / ESC CLOSE",
            small, muted, bounds.X + 24, bounds.Bottom - 31);
        BoardDrawing.DrawRightAligned(graphics, "EXTERNAL UI  //  FRAMEWORK OWNS ECONOMY",
            small, muted, detailsRight, bounds.Bottom - 31);
    }

    private static void DrawQuoteRow(Graphics graphics, string label, string value, int x, int y,
        int width, Font body, Font bold, Brush pale, Brush valueBrush)
    {
        using var marker = new SolidBrush(Color.FromArgb(240, 67, 191, 184));
        graphics.FillRectangle(marker, x, y + 4, 4, 10);
        graphics.DrawString(label, body, pale, x + 13, y);
        BoardDrawing.DrawRightAligned(graphics, value, bold, valueBrush, x + width, y);
    }

    private static void DrawActionButton(Graphics graphics, Rectangle rectangle, string text,
        bool hovered, bool enabled, Font font)
    {
        var first = enabled
            ? hovered ? Color.FromArgb(245, 93, 220, 207) : Color.FromArgb(230, 61, 181, 174)
            : Color.FromArgb(190, 82, 94, 90);
        var second = enabled
            ? hovered ? Color.FromArgb(238, 236, 199, 76) : Color.FromArgb(215, 34, 112, 109)
            : Color.FromArgb(175, 45, 52, 50);
        using var brush = new LinearGradientBrush(rectangle, first, second, 0f);
        using var edge = new Pen(enabled
            ? Color.FromArgb(245, 168, 229, 218) : Color.FromArgb(175, 114, 126, 120), 1f);
        graphics.FillRectangle(brush, rectangle);
        graphics.DrawRectangle(edge, rectangle);
        BoardDrawing.DrawCentered(graphics, text, font, enabled ? Brushes.Black : Brushes.LightGray, rectangle);
    }
}

internal static class BoardDrawing
{
    public static GraphicsPath AngularPath(Rectangle bounds, int cut)
    {
        var path = new GraphicsPath();
        path.AddPolygon(new[]
        {
            new Point(bounds.Left + cut, bounds.Top), new Point(bounds.Right, bounds.Top),
            new Point(bounds.Right, bounds.Bottom - cut), new Point(bounds.Right - cut, bounds.Bottom),
            new Point(bounds.Left, bounds.Bottom), new Point(bounds.Left, bounds.Top + cut),
        });
        return path;
    }

    public static Font FontOf(float size, FontStyle style)
    {
        try { return new Font("Bahnschrift", size, style, GraphicsUnit.Point); }
        catch { return new Font("Segoe UI", size, style, GraphicsUnit.Point); }
    }

    public static void DrawRightAligned(Graphics graphics, string text, Font font, Brush brush,
        float right, float y)
    {
        var size = graphics.MeasureString(text, font);
        graphics.DrawString(text, font, brush, right - size.Width, y);
    }

    public static void DrawCentered(Graphics graphics, string text, Font font, Brush brush, Rectangle rectangle)
    {
        using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
        graphics.DrawString(text, font, brush, rectangle, format);
    }

    public static void DrawWrapped(Graphics graphics, string text, Font font, Brush brush, RectangleF rectangle)
    {
        using var format = new StringFormat { Trimming = StringTrimming.EllipsisWord };
        graphics.DrawString(text, font, brush, rectangle, format);
    }

    public static void DrawShadowedText(Graphics graphics, string text, Font font, Brush brush,
        float x, float y)
    {
        using var shadow = new SolidBrush(Color.FromArgb(190, 0, 0, 0));
        graphics.DrawString(text, font, shadow, x + 1.5f, y + 1.5f);
        graphics.DrawString(text, font, brush, x, y);
    }
}

internal static class QuestPanelRenderer
{
    public static void Draw(Graphics graphics, Rectangle bounds, QuestSnapshot snapshot, bool shadow)
    {
        var contracts = snapshot.VisibleRaidContracts;
        var top = bounds.Y;
        for (var index = 0; index < contracts.Count; index++)
        {
            var height = QuestPanelLayout.ContractHeight(contracts[index]);
            var panel = new Rectangle(bounds.X, top, bounds.Width, height);
            DrawSingle(graphics, panel, snapshot.SelectById(contracts[index].Id), shadow);
            top += height + QuestPanelLayout.RaidPanelGap;
        }
    }

    private static void DrawSingle(Graphics graphics, Rectangle bounds, QuestSnapshot snapshot, bool shadow)
    {
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var raidTracker = QuestPanelLayout.IsRaidTracker(snapshot);

        if (shadow)
        {
            var shadowBounds = new Rectangle(bounds.X + 4, bounds.Y + 5, bounds.Width, bounds.Height);
            using var shadowPath = AngularPath(shadowBounds, 9);
            using var shadowBrush = new SolidBrush(Color.FromArgb(42, 0, 0, 0));
            graphics.FillPath(shadowBrush, shadowPath);
        }

        using var panelPath = AngularPath(bounds, 9);
        using var background = new LinearGradientBrush(bounds,
            Color.FromArgb(QuestPanelLayout.PanelBackgroundAlpha, 29, 32, 31),
            Color.FromArgb(48, 10, 13, 13), 92f);
        using var edge = new Pen(Color.FromArgb(138, 105, 118, 110), 1f);
        graphics.FillPath(background, panelPath);
        graphics.DrawPath(edge, panelPath);

        using var scanline = new Pen(Color.FromArgb(30, 158, 166, 156), 1f);
        for (var y = bounds.Y + 8; y < bounds.Bottom - 4; y += 9)
            graphics.DrawLine(scanline, bounds.X + 3, y, bounds.Right - 4, y);

        using var redPen = new Pen(Color.FromArgb(232, 222, 79, 54), 2f);
        graphics.DrawLine(redPen, bounds.X + 10, bounds.Y + 1, bounds.Right - 2, bounds.Y + 1);
        graphics.DrawLine(redPen, bounds.X + 1, bounds.Y + 10, bounds.X + 1, bounds.Bottom - 2);

        var x = bounds.X + 18;
        var width = bounds.Width - 36;
        using var eyebrowFont = FontOf(8.5f, FontStyle.Bold);
        using var bodyFont = FontOf(9.5f, FontStyle.Regular);
        using var bodyBold = FontOf(9.5f, FontStyle.Bold);
        using var smallFont = FontOf(8f, FontStyle.Regular);
        using var smallBold = FontOf(8f, FontStyle.Bold);
        using var gold = new SolidBrush(Color.FromArgb(245, 239, 197, 72));
        using var pale = new SolidBrush(Color.FromArgb(245, 229, 233, 224));
        using var muted = new SolidBrush(Color.FromArgb(210, 147, 157, 151));
        using var red = new SolidBrush(Color.FromArgb(240, 222, 79, 54));

        graphics.DrawString("CONTRACT  //  WATER 4.0", eyebrowFont, red, x, bounds.Y + 12);
        var titleText = snapshot.Title.ToUpperInvariant();
        using var titleFont = TitleFont(graphics, titleText, width);
        DrawShadowedText(graphics, titleText, titleFont, pale, x, bounds.Y + 31, width);

        var statusText = StatusText(snapshot.Status);
        var statusColor = StatusColor(snapshot.Status);
        using var statusBrush = new SolidBrush(statusColor);
        var statusSize = graphics.MeasureString(statusText, eyebrowFont);
        var statusRect = new RectangleF(bounds.Right - statusSize.Width - 20, bounds.Y + 13,
            statusSize.Width + 10, 18);
        graphics.FillRectangle(statusBrush, statusRect);
        graphics.DrawString(statusText, eyebrowFont, Brushes.Black, statusRect.X + 5, statusRect.Y + 1);

        using var divider = new Pen(Color.FromArgb(120, 86, 101, 93), 1f);
        graphics.DrawLine(divider, x, bounds.Y + 66, bounds.Right - 14, bounds.Y + 66);
        var objectives = snapshot.Selected.Objectives;
        for (var oi = 0; oi < objectives.Count; oi++)
        {
            var objective = objectives[oi];
            DrawObjective(graphics, x, bounds.Y + 78 + oi * 39, width, objective.Label,
                objective.Current, objective.Target, bodyFont, bodyBold, pale, muted, gold);
        }
        var extra = (objectives.Count - 2) * 39;
        graphics.DrawLine(divider, x, bounds.Y + 157 + extra, bounds.Right - 14, bounds.Y + 157 + extra);
        var footerBounds = new Rectangle(bounds.X, bounds.Y + extra, bounds.Width, bounds.Height - extra);
        if (raidTracker)
            DrawRaidFooter(graphics, footerBounds, snapshot, x, width, smallFont, smallBold, gold, pale, muted, red);
        else
            DrawHubDetails(graphics, footerBounds, snapshot, x, width, smallFont, smallBold,
                bodyFont, eyebrowFont, gold, pale, muted, red, divider);
    }

    private static void DrawObjective(Graphics graphics, int x, int y, int width, string label, int current, int target,
        Font body, Font bold, Brush pale, Brush muted, Brush fill)
    {
        using var tick = new SolidBrush(Color.FromArgb(235, 211, 76, 52));
        graphics.FillRectangle(tick, x, y + 4, 3, 9);
        graphics.DrawString(label, body, pale, x + 10, y);
        var counter = ContractPresentationText.Counter(current, target);
        var counterSize = graphics.MeasureString(counter, bold);
        graphics.DrawString(counter, bold, current >= target ? fill : muted, x + width - counterSize.Width, y);
        var bar = new Rectangle(x + 10, y + 23, width - 10, 3);
        using var track = new SolidBrush(Color.FromArgb(115, 62, 71, 67));
        graphics.FillRectangle(track, bar);
        var ratio = Math.Clamp((double)current / Math.Max(1, target), 0, 1);
        graphics.FillRectangle(fill, bar.X, bar.Y, (int)Math.Round(bar.Width * ratio), bar.Height);
    }

    private static void DrawRaidFooter(Graphics graphics, Rectangle bounds, QuestSnapshot snapshot,
        int x, int width, Font small, Font bold, Brush gold, Brush pale, Brush muted, Brush red)
    {
        string condition;
        Brush conditionBrush;
        if (snapshot.Status.Equals("locked", StringComparison.OrdinalIgnoreCase))
        {
            condition = "CONTRACT NOT ACTIVE  //  ACCEPT IN THE INNARDS";
            conditionBrush = red;
        }
        else if (snapshot.Selected.Objectives.All(o => o.Current >= o.Target))
        {
            condition = "OBJECTIVES MET  //  EXTRACT ALIVE";
            conditionBrush = gold;
        }
        else
        {
            condition = "EXTRACT ALIVE  //  SAME RAID";
            conditionBrush = pale;
        }
        graphics.DrawString(condition, bold, conditionBrush, x, bounds.Y + 168);
        graphics.DrawString("TRACKING LIVE", small, muted, x, bounds.Y + 190);
        DrawRightAligned(graphics, "F10  //  HIDE", small, muted, x + width, bounds.Y + 190);
    }

    private static void DrawHubDetails(Graphics graphics, Rectangle bounds, QuestSnapshot snapshot,
        int x, int width, Font small, Font smallBold, Font body, Font eyebrow,
        Brush gold, Brush pale, Brush muted, Brush red, Pen divider)
    {
        var entry = snapshot.Status.Equals("accepted", StringComparison.OrdinalIgnoreCase)
            ? ContractPresentationText.FeePaid(snapshot.AcceptanceWaterPaid) + "  //  NONREFUNDABLE"
            : snapshot.LastReason.Equals("insufficient_water", StringComparison.OrdinalIgnoreCase)
                ? $"INSUFFICIENT WATER  //  NEED {snapshot.AcceptanceWaterCost}"
                : ContractPresentationText.Fee(snapshot.AcceptanceWaterCost);
        graphics.DrawString(entry, smallBold,
            snapshot.Status.Equals("accepted", StringComparison.OrdinalIgnoreCase) ? gold : red,
            x, bounds.Y + 168);

        graphics.DrawString("REWARD", eyebrow, red, x, bounds.Y + 191);
        BoardDrawing.DrawWrapped(graphics, snapshot.RewardSummary, body,
            snapshot.RewardsEnabled ? pale : muted, new RectangleF(x + 67, bounds.Y + 188, width - 67, 44));

        graphics.DrawLine(divider, x, bounds.Y + 236, bounds.Right - 14, bounds.Y + 236);
        var message = snapshot.Status.ToLowerInvariant() switch
        {
            "accepted" => "READY FOR DEPLOYMENT",
            "complete" => "CONTRACT COMPLETE",
            "failed" => "CONTRACT FAILED",
            "available" => "AVAILABLE IN THE INNARDS",
            _ => "WAITING FOR FRAMEWORK"
        };
        graphics.DrawString(message, smallBold,
            snapshot.Status is "accepted" or "complete" ? gold : muted, x, bounds.Y + 247);

        var controls = snapshot.Status.Equals("accepted", StringComparison.OrdinalIgnoreCase)
            ? "F8 DISCARD  //  F10 HIDE"
            : snapshot.Status is "available" or "failed" or "complete"
                ? "F9 ACCEPT  //  F10 HIDE"
                : "F10  //  HIDE";
        DrawRightAligned(graphics, controls, small, muted, x + width, bounds.Y + 270);
    }

    private static void DrawRightAligned(Graphics graphics, string text, Font font, Brush brush, float right, float y)
    {
        var size = graphics.MeasureString(text, font);
        graphics.DrawString(text, font, brush, right - size.Width, y);
    }

    internal static Font TitleFont(Graphics graphics, string text, float availableWidth)
    {
        const float preferredSize = 19.5f;
        const float minimumSize = 9.5f;
        using var preferred = FontOf(preferredSize, FontStyle.Bold);
        var measured = graphics.MeasureString(text, preferred).Width;
        if (measured <= availableWidth) return FontOf(preferredSize, FontStyle.Bold);
        var fitted = Math.Max(minimumSize, preferredSize * availableWidth / Math.Max(1f, measured));
        return FontOf(fitted, FontStyle.Bold);
    }

    private static void DrawShadowedText(Graphics graphics, string text, Font font, Brush brush,
        float x, float y, float availableWidth)
    {
        using var shadow = new SolidBrush(Color.FromArgb(180, 0, 0, 0));
        using var format = new StringFormat
        {
            FormatFlags = StringFormatFlags.NoWrap,
            Trimming = StringTrimming.EllipsisCharacter
        };
        var height = font.GetHeight(graphics) + 4;
        graphics.DrawString(text, font, shadow,
            new RectangleF(x + 1, y + 1, Math.Max(1, availableWidth - 1), height), format);
        graphics.DrawString(text, font, brush,
            new RectangleF(x, y, Math.Max(1, availableWidth), height), format);
    }

    private static GraphicsPath AngularPath(Rectangle bounds, int cut)
    {
        var path = new GraphicsPath();
        path.AddPolygon(new[]
        {
            new Point(bounds.Left + cut, bounds.Top),
            new Point(bounds.Right, bounds.Top),
            new Point(bounds.Right, bounds.Bottom - cut),
            new Point(bounds.Right - cut, bounds.Bottom),
            new Point(bounds.Left, bounds.Bottom),
            new Point(bounds.Left, bounds.Top + cut),
        });
        return path;
    }

    private static Font FontOf(float size, FontStyle style)
    {
        try { return new Font("Bahnschrift", size, style, GraphicsUnit.Point); }
        catch { return new Font("Segoe UI", size, style, GraphicsUnit.Point); }
    }

    private static string StatusText(string status) => status.ToLowerInvariant() switch
    {
        "active" => "ACTIVE",
        "accepted" => "READY",
        "complete" => "COMPLETE",
        "failed" => "FAILED",
        "locked" => "IN RAID",
        "available" => "AVAILABLE",
        _ => "WAITING"
    };

    private static Color StatusColor(string status) => status.ToLowerInvariant() switch
    {
        "complete" => Color.FromArgb(220, 190, 70),
        "failed" => Color.FromArgb(218, 76, 59),
        "active" => Color.FromArgb(226, 190, 69),
        "accepted" => Color.FromArgb(226, 190, 69),
        "locked" => Color.FromArgb(218, 76, 59),
        _ => Color.FromArgb(151, 160, 153)
    };
}
