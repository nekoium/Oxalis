param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Automation;
using System.Windows.Forms;

internal static class Native {
    [DllImport("user32.dll", SetLastError=true)] internal static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] internal static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] internal static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] internal static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] internal static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
    [DllImport("user32.dll")] internal static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] internal static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll")] internal static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr wParam, ref TITLEBARINFOEX info, uint flags, uint timeout, out UIntPtr result);
    [DllImport("dwmapi.dll", EntryPoint="DwmGetWindowAttribute")] internal static extern int GetCloaked(IntPtr hwnd, int attribute, out int value, int size);
    [StructLayout(LayoutKind.Sequential)] internal struct TITLEBARINFOEX {
        public int Size;
        public RECT Title;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=6)] public uint[] States;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=6)] public RECT[] Buttons;
    }
    [DllImport("user32.dll")] internal static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] internal static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] internal static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
    internal delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] internal struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] internal struct POINT { public int X, Y; public POINT(int x, int y) { X=x; Y=y; } }
    internal const uint MouseLeftDown = 0x0002, MouseLeftUp = 0x0004;
    internal const uint WmSysCommand = 0x0112, ScMinimize = 0xF020, ScMaximize = 0xF030, ScRestore = 0xF120, ScClose = 0xF060;
    internal const long WsCaption = 0x00C00000, WsSysMenu = 0x00080000, WsMinimizeBox = 0x00020000, WsMaximizeBox = 0x00010000;
}

internal sealed class Target {
    internal string Key;
    internal AutomationElement Element;
    internal IntPtr Window;
    internal Rectangle Bounds;
    internal Point Anchor;
    internal string Name;
    internal uint Command;
}

internal sealed class WindowInfo {
    internal IntPtr Handle;
    internal Rectangle Bounds;
    internal Rectangle VisibleBounds;
    internal List<Rectangle> Occluders;
    internal List<Rectangle> CaptionButtons = new List<Rectangle>();
    internal bool Scan;
}

public sealed class Overlay : Form {
    private readonly Timer poll = new Timer { Interval = 25 };
    private readonly NotifyIcon tray;
    private Task<List<Target>> scan;
    private List<Target> targets = new List<Target>();
    private long started;
    private string message = "";
    private string prefix = "";
    private bool acceptingScan;
    private readonly Font labelFont = new Font("Segoe UI", 10, FontStyle.Bold);
    private readonly Brush labelBrush = new SolidBrush(Color.FromArgb(238, 20, 99, 88));
    private readonly Brush textBrush = Brushes.White;

    internal Overlay() {
        Text = "Oxalis";
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        BackColor = Color.Fuchsia;
        TransparencyKey = Color.Fuchsia;
        Bounds = SystemInformation.VirtualScreen;
        StartPosition = FormStartPosition.Manual;
        Opacity = 0.98;
        poll.Tick += PollScan;
        KeyDown += HandleKey;
        var menu = new ContextMenuStrip();
        menu.Items.Add("Exit Oxalis", null, (s, e) => Application.Exit());
        tray = new NotifyIcon { Text = "Oxalis - Ctrl+Space", Icon = SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (s, e) => ShowTargets();
        var handle = Handle;
        if (!Native.RegisterHotKey(handle, 1, 0x0002, 0x20)) {
            tray.Dispose();
            throw new InvalidOperationException("Could not register Ctrl+Space. Another app may own this hotkey.");
        }
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312 && m.WParam.ToInt32() == 1) { ShowTargets(); return; }
        base.WndProc(ref m);
    }

    private void ShowTargets() {
        if (Visible) { acceptingScan = false; Hide(); return; }
        if (scan != null && !scan.IsCompleted) return;
        acceptingScan = true;
        prefix = "";
        targets.Clear();
        message = "Scanning visible windows...";
        started = Stopwatch.GetTimestamp();
        Bounds = SystemInformation.VirtualScreen;
        Show();
        Activate();
        Focus();
        Invalidate();
        var overlay = Handle;
        scan = Task.Run(() => Scan(overlay));
        poll.Start();
    }

    private void PollScan(object sender, EventArgs e) {
        if (scan == null || !scan.IsCompleted) return;
        poll.Stop();
        if (!acceptingScan) return;
        try {
            targets = scan.GetAwaiter().GetResult();
            message = targets.Count == 0 ? "No accessible controls" : "";
            var ms = (Stopwatch.GetTimestamp() - started) * 1000.0 / Stopwatch.Frequency;
            Console.WriteLine("scan_ms={0:F1} targets={1}", ms, targets.Count);
        } catch (Exception ex) {
            targets.Clear();
            message = "UI Automation scan failed";
            Console.Error.WriteLine(ex.GetType().Name + ": " + ex.Message);
        }
        Invalidate();
        Activate();
        Focus();
    }

    private static List<Target> Scan(IntPtr overlay) {
        var windows = EnumerateWindows(overlay);
        var candidates = new List<Target>();
        foreach (var window in windows) {
            if (!window.Scan) continue;
            try {
                AddCaptionTargets(window, candidates);
                AddAutomationTargets(window, candidates);
            } catch (Exception ex) { Console.Error.WriteLine("Window scan failed: " + ex.Message); }
        }
        candidates.Sort((a, b) => {
            var vertical = a.Anchor.Y.CompareTo(b.Anchor.Y);
            return vertical != 0 ? vertical : a.Anchor.X.CompareTo(b.Anchor.X);
        });
        var keys = LabelKeys(candidates.Count);
        for (var i = 0; i < candidates.Count; i++) candidates[i].Key = keys[i];
        return candidates;
    }

    private static List<WindowInfo> EnumerateWindows(IntPtr overlay) {
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        var windows = new List<WindowInfo>();
        var callback = new Native.EnumWindowsProc((hwnd, data) => {
            if (hwnd == overlay || !Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd)) return true;
            int cloaked;
            if (Native.GetCloaked(hwnd, 14, out cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            Native.RECT raw;
            if (!Native.GetWindowRect(hwnd, out raw) || raw.Right <= raw.Left || raw.Bottom <= raw.Top) return true;
            var bounds = Rectangle.FromLTRB(raw.Left, raw.Top, raw.Right, raw.Bottom);
            var visibleBounds = bounds;
            Native.RECT extended;
            if (Native.DwmGetWindowAttribute(hwnd, 9, out extended, Marshal.SizeOf(typeof(Native.RECT))) == 0 && extended.Right > extended.Left && extended.Bottom > extended.Top)
                visibleBounds = Rectangle.FromLTRB(extended.Left, extended.Top, extended.Right, extended.Bottom);
            windows.Add(new WindowInfo { Handle = hwnd, Bounds = bounds, VisibleBounds = visibleBounds, Scan = true });
            return true;
        });
        Native.EnumWindows(callback, IntPtr.Zero);
        for (var i = 0; i < windows.Count; i++) {
            var occluders = new List<Rectangle>();
            for (var j = 0; j < i; j++) occluders.Add(windows[j].VisibleBounds);
            windows[i].Occluders = occluders;
            Point point;
            windows[i].Scan = windows[i].Scan && FindVisiblePoint(windows[i].VisibleBounds, windows[i].VisibleBounds, occluders, out point);
        }
        return windows;
    }

    private static void AddAutomationTargets(WindowInfo window, List<Target> targets) {
        var root = AutomationElement.FromHandle(window.Handle);
        if (root == null) return;
        var request = new CacheRequest { TreeScope = TreeScope.Element, AutomationElementMode = AutomationElementMode.Full };
        foreach (var property in new[] {
            AutomationElement.BoundingRectangleProperty, AutomationElement.NameProperty,
            AutomationElement.IsEnabledProperty, AutomationElement.IsOffscreenProperty,
            AutomationElement.IsControlElementProperty, AutomationElement.ControlTypeProperty
        }) request.Add(property);
        AutomationElementCollection elements;
        using (request.Activate()) elements = root.FindAll(TreeScope.Descendants, Condition.TrueCondition);
        var seen = new HashSet<string>();
        foreach (AutomationElement element in elements) {
            try {
                if (!(bool)element.GetCachedPropertyValue(AutomationElement.IsControlElementProperty) ||
                    !(bool)element.GetCachedPropertyValue(AutomationElement.IsEnabledProperty) ||
                    (bool)element.GetCachedPropertyValue(AutomationElement.IsOffscreenProperty)) continue;
                var type = (ControlType)element.GetCachedPropertyValue(AutomationElement.ControlTypeProperty);
                if (!IsInteractive(type)) continue;
                var rect = (System.Windows.Rect)element.GetCachedPropertyValue(AutomationElement.BoundingRectangleProperty);
                if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0) continue;
                var bounds = Rectangle.FromLTRB((int)rect.Left, (int)rect.Top, (int)rect.Right, (int)rect.Bottom);
                Point anchor;
                if (!FindVisiblePoint(bounds, window.VisibleBounds, window.Occluders, out anchor)) continue;
                if (window.CaptionButtons.Exists(button => button.Contains(anchor))) continue;
                var signature = bounds.Left + ":" + bounds.Top + ":" + bounds.Width + ":" + bounds.Height;
                if (!seen.Add(signature)) continue;
                targets.Add(new Target { Window = window.Handle, Bounds = bounds, Anchor = anchor, Element = element, Name = (string)element.GetCachedPropertyValue(AutomationElement.NameProperty) });
            } catch (ElementNotAvailableException) { }
              catch (InvalidOperationException) { }
        }
    }

    private static bool FindVisiblePoint(Rectangle bounds, Rectangle owner, List<Rectangle> occluders, out Point point) {
        var clipped = Rectangle.Intersect(bounds, owner);
        var pieces = new List<Rectangle>();
        foreach (var screen in Screen.AllScreens) {
            var part = Rectangle.Intersect(clipped, screen.Bounds);
            if (part.Width > 0 && part.Height > 0) pieces.Add(part);
        }
        foreach (var cover in occluders) {
            var next = new List<Rectangle>();
            foreach (var part in pieces) {
                var overlap = Rectangle.Intersect(part, cover);
                if (overlap.Width <= 0 || overlap.Height <= 0) { next.Add(part); continue; }
                next.Add(Rectangle.FromLTRB(part.Left, part.Top, part.Right, overlap.Top));
                next.Add(Rectangle.FromLTRB(part.Left, overlap.Bottom, part.Right, part.Bottom));
                next.Add(Rectangle.FromLTRB(part.Left, overlap.Top, overlap.Left, overlap.Bottom));
                next.Add(Rectangle.FromLTRB(overlap.Right, overlap.Top, part.Right, overlap.Bottom));
            }
            pieces = next.FindAll(r => r.Width >= 6 && r.Height >= 6);
            if (pieces.Count == 0) break;
        }
        pieces.Sort((a,b) => ((long)b.Width*b.Height).CompareTo((long)a.Width*a.Height));
        foreach (var part in pieces) if (part.Width >= 6 && part.Height >= 6) {
            point = new Point(part.Left + part.Width/2, part.Top + part.Height/2);
            return true;
        }
        point = Point.Empty;
        return false;
    }

    private static void AddCaptionTargets(WindowInfo window, List<Target> targets) {
        var style = Native.GetWindowLongPtr(window.Handle, -16).ToInt64();
        if ((style & Native.WsCaption) != Native.WsCaption || (style & Native.WsSysMenu) == 0) return;
        var info = new Native.TITLEBARINFOEX { Size = Marshal.SizeOf(typeof(Native.TITLEBARINFOEX)), States = new uint[6], Buttons = new Native.RECT[6] };
        UIntPtr response;
        if (Native.SendMessageTimeout(window.Handle, 0x033F, IntPtr.Zero, ref info, 0x0002, 100, out response) == IntPtr.Zero) return;
        foreach (var index in new[] { 2, 3, 5 }) {
            if ((info.States[index] & (0x1u | 0x8000u | 0x10000u)) != 0) continue;
            if (index == 2 && (style & Native.WsMinimizeBox) == 0) continue;
            if (index == 3 && (style & Native.WsMaximizeBox) == 0) continue;
            var raw = info.Buttons[index];
            var rect = Rectangle.FromLTRB(raw.Left, raw.Top, raw.Right, raw.Bottom);
            Point anchor;
            if (!FindVisiblePoint(rect, window.VisibleBounds, window.Occluders, out anchor)) continue;
            var command = index == 2 ? Native.ScMinimize : index == 5 ? Native.ScClose : Native.IsZoomed(window.Handle) ? Native.ScRestore : Native.ScMaximize;
            window.CaptionButtons.Add(rect);
            targets.Add(new Target { Window = window.Handle, Bounds = rect, Anchor = anchor, Command = command, Name = index == 2 ? "Minimize" : index == 5 ? "Close" : command == Native.ScRestore ? "Restore" : "Maximize" });
        }
    }

    private static bool IsInteractive(ControlType type) {
        return type == ControlType.Button || type == ControlType.CheckBox || type == ControlType.ComboBox ||
            type == ControlType.Hyperlink || type == ControlType.ListItem || type == ControlType.MenuItem ||
            type == ControlType.RadioButton || type == ControlType.TabItem || type == ControlType.TreeItem;
    }

    private void HandleKey(object sender, KeyEventArgs e) {
        if (e.KeyCode == Keys.Escape) { acceptingScan = false; Hide(); e.Handled = true; return; }
        if (e.KeyCode == Keys.Back) { if (prefix.Length > 0) prefix = prefix.Substring(0, prefix.Length-1); Invalidate(); e.Handled = true; return; }
        var key = e.KeyCode.ToString();
        if (e.KeyCode >= Keys.D1 && e.KeyCode <= Keys.D9) key = ((int)e.KeyCode - (int)Keys.D0).ToString();
        else if (e.KeyCode >= Keys.A && e.KeyCode <= Keys.Z) key = key.ToLowerInvariant();
        if (key.Length != 1) return;
        var next = prefix + key;
        if (!targets.Exists(t => t.Key.StartsWith(next, StringComparison.Ordinal))) return;
        prefix = next;
        var target = targets.Find(t => t.Key == prefix);
        if (target == null) { Invalidate(); e.Handled = true; return; }
        acceptingScan = false;
        Hide();
        if (target.Command != 0) {
            if (Native.IsWindow(target.Window)) Native.PostMessage(target.Window, Native.WmSysCommand, new IntPtr(target.Command), IntPtr.Zero);
            e.Handled = true;
            return;
        }
        try {
            if (!target.Element.Current.IsEnabled || target.Element.Current.IsOffscreen) return;
            object pattern;
            if (target.Element.TryGetCurrentPattern(InvokePattern.Pattern, out pattern)) ((InvokePattern)pattern).Invoke();
            else if (target.Element.TryGetCurrentPattern(TogglePattern.Pattern, out pattern)) ((TogglePattern)pattern).Toggle();
            else if (target.Element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out pattern)) ((SelectionItemPattern)pattern).Select();
            else if (target.Element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out pattern)) ((ExpandCollapsePattern)pattern).Expand();
            else {
                var point = target.Anchor;
                var hit = Native.WindowFromPoint(new Native.POINT(point.X, point.Y));
                if (Native.GetAncestor(hit, 2) != target.Window) return;
                Native.SetCursorPos(point.X, point.Y);
                Native.mouse_event(Native.MouseLeftDown, 0, 0, 0, UIntPtr.Zero);
                Native.mouse_event(Native.MouseLeftUp, 0, 0, 0, UIntPtr.Zero);
            }
        } catch (Exception ex) { Console.Error.WriteLine("Activation failed: " + ex.Message); }
        e.Handled = true;
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        if (!String.IsNullOrEmpty(message)) {
            using (var font = new Font("Segoe UI", 11, FontStyle.Bold)) {
                var box = new Rectangle(12, 12, (int)e.Graphics.MeasureString(message, font).Width + 20, 34);
                e.Graphics.FillRectangle(labelBrush, box);
                e.Graphics.DrawString(message, font, textBrush, box.Left + 10, box.Top + 7);
            }
            return;
        }
        foreach (var target in targets) {
            if (!target.Key.StartsWith(prefix, StringComparison.Ordinal)) continue;
            var x = target.Anchor.X - Left;
            var y = target.Anchor.Y - Top;
            var size = e.Graphics.MeasureString(target.Key, labelFont);
            var box = new Rectangle(x, y, Math.Max(24, (int)size.Width + 10), Math.Max(24, (int)size.Height + 4));
            e.Graphics.FillRectangle(labelBrush, box);
            e.Graphics.DrawString(target.Key, labelFont, textBrush, x + 5, y + 2);
        }
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            Native.UnregisterHotKey(Handle, 1);
            poll.Dispose(); tray.Dispose(); labelFont.Dispose(); labelBrush.Dispose();
        }
        base.Dispose(disposing);
    }

    private static List<string> LabelKeys(int count) {
        const string alphabet = "123456789abcdefghijklmnopqrstuvwxyz";
        var width = 1;
        long capacity = alphabet.Length;
        while (capacity < count) { capacity *= alphabet.Length; width++; }
        var result = new List<string>();
        for (int i = 0; i < count; i++) {
            var value = i;
            var chars = new char[width];
            for (int j = width-1; j >= 0; j--) { chars[j] = alphabet[value % alphabet.Length]; value /= alphabet.Length; }
            result.Add(new string(chars));
        }
        return result;
    }

    public static void SelfTest() {
        Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Point point;
        var area = new Rectangle(Screen.PrimaryScreen.Bounds.Left+20, Screen.PrimaryScreen.Bounds.Top+20, 100, 100);
        if (!FindVisiblePoint(area, area, new List<Rectangle>(), out point) || !area.Contains(point)) throw new Exception("Visible target rejected");
        if (FindVisiblePoint(area, area, new List<Rectangle>{area}, out point)) throw new Exception("Covered target accepted");
        var cover = new Rectangle(area.Left+10, area.Top, 90, 100);
        if (!FindVisiblePoint(area, area, new List<Rectangle>{cover}, out point) || cover.Contains(point)) throw new Exception("Exposed strip missed");
        foreach (var count in new[] {0, 1, 35, 36, 500, 1226}) {
            var labels = LabelKeys(count);
            if (labels.Count != count || new HashSet<string>(labels).Count != count) throw new Exception("Invalid labels");
            foreach (var label in labels) if (label.Length != labels[0].Length) throw new Exception("Ambiguous prefix");
        }
        using (var form = new Form { Text = "Oxalis test window", Width=400, Height=240, TopMost=true }) {
            form.Controls.Add(new Button { Name="OxalisTestButton", Text="Oxalis test button", Left=40, Top=60 });
            form.Show();
            Application.DoEvents();
            Native.RECT raw;
            Native.GetWindowRect(form.Handle, out raw);
            var window = new WindowInfo { Handle=form.Handle, Bounds=Rectangle.FromLTRB(raw.Left,raw.Top,raw.Right,raw.Bottom), VisibleBounds=Rectangle.FromLTRB(raw.Left,raw.Top,raw.Right,raw.Bottom), Occluders=new List<Rectangle>() };
            var found = new List<Target>();
            AddCaptionTargets(window, found);
            foreach (var command in new[] {Native.ScClose,Native.ScMinimize,Native.ScMaximize})
                if (!found.Exists(t => t.Command == command)) throw new Exception("Caption target missing: " + command);
            AddAutomationTargets(window, found);
            if (!found.Exists(t => t.Name == "Oxalis test button")) throw new Exception("UIA button missing");
            var enumerated = EnumerateWindows(IntPtr.Zero);
            var own = enumerated.Find(w => w.Handle == form.Handle);
            if (own == null) throw new Exception("Test window not enumerated");
            Native.PostMessage(form.Handle, Native.WmSysCommand, new IntPtr(Native.ScMinimize), IntPtr.Zero);
            Application.DoEvents();
            if (!Native.IsIconic(form.Handle)) throw new Exception("Minimize command failed");
            Native.PostMessage(form.Handle, Native.WmSysCommand, new IntPtr(Native.ScRestore), IntPtr.Zero);
            Application.DoEvents();
            Native.PostMessage(form.Handle, Native.WmSysCommand, new IntPtr(Native.ScMaximize), IntPtr.Zero);
            Application.DoEvents();
            if (!Native.IsZoomed(form.Handle)) throw new Exception("Maximize command failed");
            Native.PostMessage(form.Handle, Native.WmSysCommand, new IntPtr(Native.ScClose), IntPtr.Zero);
            Application.DoEvents();
            if (!form.IsDisposed) throw new Exception("Close command failed");
        }
        Console.WriteLine("PASS: visibility, occlusion, exposed strip, labels, caption rectangles, UIA discovery, window enumeration, minimize/maximize/close");
    }

    [STAThread]
    public static void Run() {
        Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
        Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try {
            var overlay = new Overlay();
            overlay.Hide();
            Application.Run(new ApplicationContext());
            overlay.Dispose();
        } catch (Exception ex) { MessageBox.Show(ex.Message, "Oxalis", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
'@

$refs = @(
    (Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll' | Select-Object -ExpandProperty FullName)
    [System.Windows.Forms.Form].Assembly.Location
    [System.Windows.Forms.Message].Assembly.Location
    (Join-Path $PSHOME 'System.Private.Windows.Core.dll')
    [System.Drawing.Font].Assembly.Location
    [System.Drawing.Rectangle].Assembly.Location
    [System.Windows.Rect].Assembly.Location
    [System.Windows.Automation.AutomationElement].Assembly.Location
    [System.Windows.Automation.ControlType].Assembly.Location
) | Select-Object -Unique
Add-Type -TypeDefinition $source -ReferencedAssemblies $refs
if ($SelfTest) { [Overlay]::SelfTest() } else { [Overlay]::Run() }
