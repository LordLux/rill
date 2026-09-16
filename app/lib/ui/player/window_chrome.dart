/// Borderless fullscreen for the app's own OS window.
///
/// Win32 through `dart:ffi` rather than a package. `window_manager` is the
/// obvious dependency and it is **not in this machine's pub cache**, so adding
/// it would make an offline checkout un-buildable to buy four calls we can make
/// ourselves — and `ffi` is already a direct dependency (`debug_player.dart`
/// uses it for `GetProcessTimes`).
///
/// Fullscreen is the OS window going borderless over the monitor, with all app
/// chrome hidden. Theatre is a layout change and lives nowhere near here.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// What the view-mode controller needs from the window. An interface because
/// `flutter test` has no window at all — and because "exit restores the previous
/// bounds" is a property of *this* class that a fake can assert was asked for
/// while only the real one can prove it happened.
abstract class WindowChrome {
  /// Go borderless-fullscreen, or come back to the bounds saved on the way in.
  ///
  /// Idempotent in both directions: asking for a state the window is already in
  /// does nothing, which is what keeps a double `Esc` from restoring bounds that
  /// were captured *during* fullscreen.
  Future<void> setFullscreen(bool value);

  bool get isFullscreen;
}

/// Does nothing, and says so. The default outside Windows and in tests.
class NoWindowChrome implements WindowChrome {
  bool _fullscreen = false;

  /// Every request, in order — so a test can assert the window was asked.
  final List<bool> requests = [];

  @override
  bool get isFullscreen => _fullscreen;

  @override
  Future<void> setFullscreen(bool value) async {
    requests.add(value);
    _fullscreen = value;
  }
}

/// Picks the real implementation on Windows and the no-op everywhere else.
WindowChrome createWindowChrome() =>
    Platform.isWindows ? Win32WindowChrome() : NoWindowChrome();

// ---------------------------------------------------------------------------
// Win32
// ---------------------------------------------------------------------------

const int _gwlStyle = -16;
const int _wsOverlappedWindow = 0x00CF0000;
const int _wsPopup = 0x80000000;

const int _swpNoZOrder = 0x0004;
const int _swpNoOwnerZOrder = 0x0200;
const int _swpFrameChanged = 0x0020;
const int _swpNoMove = 0x0002;
const int _swpNoSize = 0x0001;

const int _monitorDefaultToNearest = 0x0002;

/// `WINDOWPLACEMENT`: two `UINT`s, a `UINT showCmd`, two `POINT`s and a `RECT`.
const int _windowPlacementBytes = 44;
const int _monitorInfoBytes = 40;

typedef _EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr lParam);

typedef _EnumWindowsNative = Int32 Function(
    Pointer<NativeFunction<_EnumWindowsProcNative>> proc, IntPtr lParam);
typedef _EnumWindowsDart = int Function(
    Pointer<NativeFunction<_EnumWindowsProcNative>> proc, int lParam);

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
    IntPtr hwnd, Pointer<Uint32> processId);
typedef _GetWindowThreadProcessIdDart = int Function(int hwnd, Pointer<Uint32> processId);

typedef _HwndToBoolNative = Int32 Function(IntPtr hwnd);
typedef _HwndToBoolDart = int Function(int hwnd);

typedef _GetWindowLongPtrNative = IntPtr Function(IntPtr hwnd, Int32 index);
typedef _GetWindowLongPtrDart = int Function(int hwnd, int index);

typedef _SetWindowLongPtrNative = IntPtr Function(IntPtr hwnd, Int32 index, IntPtr value);
typedef _SetWindowLongPtrDart = int Function(int hwnd, int index, int value);

typedef _WindowPlacementNative = Int32 Function(IntPtr hwnd, Pointer<Uint8> placement);
typedef _WindowPlacementDart = int Function(int hwnd, Pointer<Uint8> placement);

typedef _SetWindowPosNative = Int32 Function(
    IntPtr hwnd, IntPtr insertAfter, Int32 x, Int32 y, Int32 cx, Int32 cy, Uint32 flags);
typedef _SetWindowPosDart = int Function(
    int hwnd, int insertAfter, int x, int y, int cx, int cy, int flags);

typedef _MonitorFromWindowNative = IntPtr Function(IntPtr hwnd, Uint32 flags);
typedef _MonitorFromWindowDart = int Function(int hwnd, int flags);

typedef _GetMonitorInfoNative = Int32 Function(IntPtr monitor, Pointer<Uint8> info);
typedef _GetMonitorInfoDart = int Function(int monitor, Pointer<Uint8> info);

typedef _GetCurrentProcessIdNative = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

/// The window this process owns, found once and cached.
///
/// `FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", null)` is the one-liner and it is
/// wrong: it matches the first window of that class **anywhere on the desktop**,
/// so a second Flutter app running alongside is a coin flip. Enumerating and
/// matching the process id is the version that cannot pick someone else's
/// window.
int? _findOwnWindow(_Win32 api) {
  _enumFound = null;
  _enumPid = api.getCurrentProcessId();
  _enumApi = api;
  api.enumWindows(Pointer.fromFunction<_EnumWindowsProcNative>(_enumWindowsProc, 1), 0);
  _enumApi = null;
  return _enumFound;
}

// `Pointer.fromFunction` needs a top-level function, so the callback's inputs
// and output travel in these rather than in a closure. `EnumWindows` is
// synchronous and single-threaded, so the window between setting and clearing
// them contains no other Dart code.
int? _enumFound;
int _enumPid = 0;
_Win32? _enumApi;

int _enumWindowsProc(int hwnd, int lParam) {
  final api = _enumApi;
  if (api == null) return 0;
  if (api.isWindowVisible(hwnd) == 0) return 1;

  final out = calloc<Uint32>();
  try {
    api.getWindowThreadProcessId(hwnd, out);
    if (out.value != _enumPid) return 1;
  } finally {
    calloc.free(out);
  }

  _enumFound = hwnd;
  return 0; // Stop enumerating.
}

class _Win32 {
  _Win32()
      : _user32 = DynamicLibrary.open('user32.dll'),
        _kernel32 = DynamicLibrary.open('kernel32.dll') {
    enumWindows = _user32.lookupFunction<_EnumWindowsNative, _EnumWindowsDart>('EnumWindows');
    isWindowVisible =
        _user32.lookupFunction<_HwndToBoolNative, _HwndToBoolDart>('IsWindowVisible');
    getWindowThreadProcessId =
        _user32.lookupFunction<_GetWindowThreadProcessIdNative, _GetWindowThreadProcessIdDart>(
            'GetWindowThreadProcessId');
    getWindowLongPtr = _user32
        .lookupFunction<_GetWindowLongPtrNative, _GetWindowLongPtrDart>('GetWindowLongPtrW');
    setWindowLongPtr = _user32
        .lookupFunction<_SetWindowLongPtrNative, _SetWindowLongPtrDart>('SetWindowLongPtrW');
    getWindowPlacement = _user32
        .lookupFunction<_WindowPlacementNative, _WindowPlacementDart>('GetWindowPlacement');
    setWindowPlacement = _user32
        .lookupFunction<_WindowPlacementNative, _WindowPlacementDart>('SetWindowPlacement');
    setWindowPos =
        _user32.lookupFunction<_SetWindowPosNative, _SetWindowPosDart>('SetWindowPos');
    monitorFromWindow = _user32
        .lookupFunction<_MonitorFromWindowNative, _MonitorFromWindowDart>('MonitorFromWindow');
    getMonitorInfo =
        _user32.lookupFunction<_GetMonitorInfoNative, _GetMonitorInfoDart>('GetMonitorInfoW');
    getCurrentProcessId =
        _kernel32.lookupFunction<_GetCurrentProcessIdNative, _GetCurrentProcessIdDart>(
            'GetCurrentProcessId');
  }

  final DynamicLibrary _user32;
  final DynamicLibrary _kernel32;

  late final _EnumWindowsDart enumWindows;
  late final _HwndToBoolDart isWindowVisible;
  late final _GetWindowThreadProcessIdDart getWindowThreadProcessId;
  late final _GetWindowLongPtrDart getWindowLongPtr;
  late final _SetWindowLongPtrDart setWindowLongPtr;
  late final _WindowPlacementDart getWindowPlacement;
  late final _WindowPlacementDart setWindowPlacement;
  late final _SetWindowPosDart setWindowPos;
  late final _MonitorFromWindowDart monitorFromWindow;
  late final _GetMonitorInfoDart getMonitorInfo;
  late final _GetCurrentProcessIdDart getCurrentProcessId;
}

/// The real thing.
///
/// **Threading.** These are called straight from the Dart isolate. Current
/// Flutter Windows runs the Dart UI task runner merged onto the platform thread,
/// so this is a plain call on the window's owning thread. Even unmerged,
/// `SetWindowPos` and friends are documented as callable cross-thread — they
/// marshal to the owner and block — and nothing in this flow has the owner
/// waiting on us, so the deadlock that pattern can produce has nothing to form
/// around. Stated because it is the sort of assumption that is invisible until
/// an embedder changes.
class Win32WindowChrome implements WindowChrome {
  _Win32? _api;
  int? _hwnd;

  /// The style and placement to put back. Captured **on the way in only** — see
  /// [setFullscreen]'s idempotence, which is what protects them.
  int? _savedStyle;
  Pointer<Uint8>? _savedPlacement;

  bool _fullscreen = false;

  @override
  bool get isFullscreen => _fullscreen;

  @override
  Future<void> setFullscreen(bool value) async {
    if (value == _fullscreen) return;
    try {
      if (value) {
        _enter();
      } else {
        _exit();
      }
      _fullscreen = value;
    } on Object catch (error) {
      // A window that will not go fullscreen is a degraded control, not a
      // reason to take the app down mid-video. The view mode stays where it was
      // because `_fullscreen` is only assigned on success.
      stderr.writeln('window: could not set fullscreen=$value ($error)');
    }
  }

  /// The window's current outer rectangle, `[left, top, right, bottom]`.
  ///
  /// **Diagnostics only, and it is why it exists at all.** "Exit restores the
  /// previous bounds" is a property of this class that no widget test can see —
  /// `flutter test` has no window, so the fake can only record that the window
  /// was *asked*. Reading the rect before entering and after leaving is the only
  /// way that claim gets checked against Windows rather than against a list of
  /// booleans. Used by `controls_probe.dart`; nothing that renders calls it.
  List<int>? debugBounds() {
    try {
      final api = _resolve();
      final placement = calloc<Uint8>(_windowPlacementBytes);
      try {
        placement.cast<Uint32>().value = _windowPlacementBytes;
        if (api.getWindowPlacement(_hwnd!, placement) == 0) return null;
        // WINDOWPLACEMENT: two UINTs, showCmd, two POINTs, then rcNormalPosition
        // — 4 + 4 + 4 + 8 + 8 = 28 bytes in, so the RECT starts at Int32 index 7.
        final fields = placement.cast<Int32>();
        return [fields[7], fields[8], fields[9], fields[10]];
      } finally {
        calloc.free(placement);
      }
    } on Object {
      return null;
    }
  }

  /// The window's `GWL_STYLE`. Diagnostics only, like [debugBounds].
  ///
  /// `bitsdojo_window` owns the frame too (`BDW_CUSTOM_FRAME`), so leaving
  /// fullscreen has to hand back exactly the style it found — a restored
  /// rectangle with a changed style is a native title bar reappearing, which
  /// [debugBounds] alone cannot see.
  int? debugStyle() {
    try {
      final api = _resolve();
      return api.getWindowLongPtr(_hwnd!, _gwlStyle);
    } on Object {
      return null;
    }
  }

  _Win32 _resolve() {
    final api = _api ??= _Win32();
    _hwnd ??= _findOwnWindow(api);
    if (_hwnd == null) throw StateError('no top-level window for this process');
    return api;
  }

  void _enter() {
    final api = _resolve();
    final hwnd = _hwnd!;

    // A placement left over from an entry that failed after saving one.
    //
    // `setFullscreen` swallows the throw and leaves `_fullscreen` false, so the
    // next attempt calls this again — and overwriting the field would strand the
    // first allocation in unmanaged memory with nothing left pointing at it.
    // Concurrency is *not* the hazard: everything from the idempotence guard to
    // `_fullscreen = value` runs in one synchronous stretch, so two calls cannot
    // interleave here. A failed attempt can, and does.
    final stale = _savedPlacement;
    if (stale != null) {
      calloc.free(stale);
      _savedPlacement = null;
    }

    final placement = calloc<Uint8>(_windowPlacementBytes);
    placement.cast<Uint32>().value = _windowPlacementBytes;
    if (api.getWindowPlacement(hwnd, placement) == 0) {
      calloc.free(placement);
      throw StateError('GetWindowPlacement failed');
    }

    final monitor = api.monitorFromWindow(hwnd, _monitorDefaultToNearest);
    final info = calloc<Uint8>(_monitorInfoBytes);
    try {
      info.cast<Uint32>().value = _monitorInfoBytes;
      if (api.getMonitorInfo(monitor, info) == 0) {
        calloc.free(placement);
        throw StateError('GetMonitorInfoW failed');
      }
      // MONITORINFO: DWORD cbSize, then rcMonitor as four LONGs at offset 4.
      final rect = info.cast<Int32>();
      final left = rect[1];
      final top = rect[2];
      final right = rect[3];
      final bottom = rect[4];

      _savedStyle = api.getWindowLongPtr(hwnd, _gwlStyle);
      _savedPlacement = placement;

      // `~WS_OVERLAPPEDWINDOW` drops the caption, the resize frame and the
      // system menu in one mask; `WS_POPUP` is what makes the remainder
      // genuinely borderless rather than merely thin.
      api.setWindowLongPtr(hwnd, _gwlStyle, (_savedStyle! & ~_wsOverlappedWindow) | _wsPopup);
      api.setWindowPos(hwnd, 0, left, top, right - left, bottom - top,
          _swpNoZOrder | _swpNoOwnerZOrder | _swpFrameChanged);
    } finally {
      calloc.free(info);
    }
  }

  void _exit() {
    final api = _resolve();
    final hwnd = _hwnd!;
    final style = _savedStyle;
    final placement = _savedPlacement;
    if (style == null || placement == null) return;

    api.setWindowLongPtr(hwnd, _gwlStyle, style);
    // `SetWindowPlacement` rather than a saved `RECT`: it restores a *maximized*
    // window as maximized. A rect alone comes back as a floating window the size
    // of the screen, which looks almost right and is not what was there.
    api.setWindowPlacement(hwnd, placement);
    api.setWindowPos(hwnd, 0, 0, 0, 0, 0,
        _swpNoMove | _swpNoSize | _swpNoZOrder | _swpNoOwnerZOrder | _swpFrameChanged);

    calloc.free(placement);
    _savedPlacement = null;
    _savedStyle = null;
  }
}
