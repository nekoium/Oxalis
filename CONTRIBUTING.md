# Prototype checks

Run from this directory using PowerShell 7 on Windows:

```powershell
pwsh -NoProfile -STA -ExecutionPolicy Bypass -File .\Oxalis.ps1 -SelfTest
```

This compiles the embedded C# core, checks visible/covered/partially exposed rectangles and prefix-free labels, creates a disposable native test window, discovers its UIA button and caption rectangles, enumerates it, and exercises minimize, restore, maximize, and close on that test window only.

For manual checks, run `Oxalis.ps1` without `-SelfTest`. Try two side-by-side windows, overlapping windows, a maximized window, and desktop/taskbar controls. Verify that labels correspond to the visible control, multi-character input narrows targets, and Escape during a scan prevents late results from taking focus. Repeat on different DPI settings and monitors.

Successful scans print `scan_ms` and target count to the launching console. This measures hotkey handling through scan-result polling, not time to display presentation. A single sample is not a p95 benchmark. UIA providers are scanned sequentially; one hung provider currently blocks scan completion.

Visibility uses native window rectangles in z-order, excluding minimized and DWM-cloaked windows and the Oxalis overlay. It is not pixel-accurate for translucent or shaped windows. UIA provider geometry remains a trust limitation. Caption rectangles come from `WM_GETTITLEBARINFOEX` with a bounded native message wait; this does not bound UIA calls.
