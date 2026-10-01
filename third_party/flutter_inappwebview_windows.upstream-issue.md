<!--
Draft of an issue for https://github.com/pichillilorenzo/flutter_inappwebview (rill architecture.md F27).
Title: [Windows] Process fails fast (0xC0000602) at exit: static Compositor released at DLL unload
Post everything below this comment as the body. Checked 2026-10-01 against 0.6.0 and
0.7.0-beta.3 source; not yet reproduced against beta.3 itself.
-->

### Summary

`InAppWebViewManager` keeps the WinRT `Compositor` in `inline static winrt::com_ptr<ICompositor> compositor_`. It is created when the plugin registers, which is on every launch whether or not a WebView is ever used. Nothing releases it before the static destructor runs at DLL unload, by which point CoreMessaging can no longer serve the release, and the process fails fast with `0xC0000602` (`STATUS_FAIL_FAST_EXCEPTION`). The app has already shut down, so no data is lost, but every close produces a crash event, and with WER `LocalDumps` configured, a dump.

### Environment

- flutter_inappwebview 6.1.5, flutter_inappwebview_windows 0.6.0
- Flutter 3.44.9 (release build), Windows 10 22H2 (19045)
- The app registers the plugin and opens a WebView only for a sign-in page.

### Measurement

20 launch-and-close cycles of a release build (window closed with `WM_CLOSE`, ~10 s after the window appeared): **20 of 20** exited with `0xC0000602`.

### Fix

Release the compositor in `~InAppWebViewManager()`, which runs at plugin teardown while the engine is alive:

```cpp
  InAppWebViewManager::~InAppWebViewManager()
  {
    debugLog("dealloc InAppWebViewManager");
    webViews.clear();
    keepAliveWebViews.clear();
    windowWebViews.clear();
    compositor_ = nullptr;   // added
    UnregisterClass(windowClass_.lpszClassName, nullptr);
    plugin = nullptr;
  }
```

With that single line, the same 20-cycle run gave **20 of 20** exits with code 0.

0.7.0-beta.3 handles the same crash with `compositor_->AddRef()` after creation ("fix for KernelBase.dll RaiseFailFastException when app is closing"). That avoids the failing release by leaking one reference, rather than releasing it while it can still be served.
