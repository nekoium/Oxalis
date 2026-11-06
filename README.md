# Oxalis

Oxalis is a Windows keyboard overlay prototype for controls exposed by Microsoft UI Automation (UIA).

Press `Ctrl+Space` to label controls across visible windows, including the desktop and taskbar where UI Automation exposes them. Type a label to activate its control. When there are more than 35 targets, labels use multiple characters; typing narrows the labels, and `Backspace` removes a character. Press `Esc` or `Ctrl+Space` again to dismiss the overlay. Right-click the tray icon to exit.

Standard Windows title bars also get minimize, maximize/restore, and close labels when Windows reports visible, enabled caption buttons. These actions use window commands, not mouse clicks. Close behaves like clicking the window’s close button: the app decides whether to prompt for unsaved work.

Oxalis filters controls using their reported bounds and window stacking order, then sorts labels by screen position. UIA activation patterns are preferred; the fallback clicks a point within UIA-reported bounds after checking that the same window is still under that point. No screenshot recognition is used.

Run from Windows PowerShell 7:

```powershell
pwsh -NoProfile -STA -ExecutionPolicy Bypass -File .\Oxalis.ps1
```

Elevated windows are unsupported. Apps with incomplete or incorrect UIA data can still have missing or misplaced targets. Custom-drawn title bars may not expose usable caption rectangles; Oxalis does not guess their positions. Visibility filtering treats windows as opaque rectangles, so transparent or irregular windows can hide valid targets. Tiny exposed areas below six pixels are ignored. Mixed-DPI multi-monitor layouts need further validation.

Scanning runs in the background, but a slow or stuck UIA provider can delay all labels. There is no hard scan timeout yet. Dismissing the overlay discards the pending result. This prototype does not yet guarantee imperceptible loading or continuously track controls moving after a scan.

## License

Oxalis is available under the [MIT License](LICENSE).
