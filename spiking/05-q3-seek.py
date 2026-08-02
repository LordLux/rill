# Spike 05 Q3 — spike 03's check 4, driven through the libmpv *client API*
# against a chosen libmpv-2.dll.
#
# This is NOT the media_kit/Flutter harness the brief asks for — there is no
# Flutter SDK on this machine (see the report). It is the nearest available
# approximation: the same C entry points media_kit's Dart FFI bindings call,
# against the candidate DLL rather than a system mpv. It therefore isolates the
# remaining unknown to media_kit's binding + ANGLE render path.
#
#   python 05-q3-seek.py <libmpv-2.dll> <urls.json> [av1|vp9] [request_size|baseline]

import ctypes, json, os, sys, time

DLL, URLS = sys.argv[1], sys.argv[2]
TRACK = sys.argv[3] if len(sys.argv) > 3 else "av1"
MODE = sys.argv[4] if len(sys.argv) > 4 else "request_size"
RS = 1048576

PLAN = [(8, 300), (16, 60), (24, 500), (32, 120)]  # (wall-clock second, target)
QUIT_AT = 40

u = json.load(open(URLS))
video_url = u[TRACK]["url"].encode()
audio_url = u["audio"]["url"].encode()

os.add_dll_directory(os.path.dirname(os.path.abspath(DLL)))
m = ctypes.CDLL(DLL)

m.mpv_create.restype = ctypes.c_void_p
m.mpv_initialize.argtypes = [ctypes.c_void_p]
m.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
m.mpv_command.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
m.mpv_get_property_string.restype = ctypes.c_char_p
m.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
m.mpv_get_property.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
m.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
m.mpv_wait_event.restype = ctypes.c_void_p
m.mpv_wait_event.argtypes = [ctypes.c_void_p, ctypes.c_double]
m.mpv_request_log_messages.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

MPV_FORMAT_DOUBLE = 5
ctx = m.mpv_create()

opts = [
    (b"config", b"no"),
    (b"hwdec", b"auto"),
    (b"vo", b"gpu"),
    (b"force-window", b"yes"),
    (b"keep-open", b"no"),
    # mpv dropped the singular --audio-file alias; the list form works on both
    # the 2023 and 2026 builds. The app merges two URLs, so the audio stream
    # has to seek too — F10's refinement 403'd on both.
    (b"audio-files", audio_url),
]
if MODE == "request_size":
    opts.append((b"stream-lavf-o", f"request_size={RS},short_seek_size={RS}".encode()))

OPTION_ERRORS = {}
for k, v in opts:
    rc = m.mpv_set_option_string(ctx, k, v)
    if rc != 0:
        OPTION_ERRORS[k.decode()] = rc
        print(f"OPTION-REJECTED {k.decode()} rc={rc}", file=sys.stderr)

m.mpv_request_log_messages(ctx, b"info")
assert m.mpv_initialize(ctx) == 0, "mpv_initialize failed"

argv = (ctypes.c_char_p * 3)(b"loadfile", video_url, None)
m.mpv_command(ctx, argv)


def pos():
    d = ctypes.c_double()
    if m.mpv_get_property(ctx, b"time-pos", MPV_FORMAT_DOUBLE, ctypes.byref(d)) == 0:
        return d.value
    return None


def prop(name):
    v = m.mpv_get_property_string(ctx, name.encode())
    return v.decode() if v else None


results, log_hits = {}, []
started = time.monotonic()
schedule = []
for i, (at, target) in enumerate(PLAN, 1):
    schedule.append((at, "seek", i, target))
    schedule.append((at + 5, "check", i, target))
schedule.append((QUIT_AT, "quit", 0, 0))
schedule.sort()
si = 0
played_before = None

while True:
    m.mpv_wait_event(ctx, 0.05)  # pumps the event loop; we poll properties
    now = time.monotonic() - started

    while si < len(schedule) and schedule[si][0] <= now:
        _, kind, i, target = schedule[si]
        si += 1
        if kind == "seek":
            if i == 1:
                played_before = pos()
                for p in ("video-codec", "hwdec-current", "duration"):
                    log_hits.append(f"{p}={prop(p)}")
            print(f"SPIKE seek {i} -> {target} (from {pos()})", file=sys.stderr)
            a = (ctypes.c_char_p * 5)(b"seek", str(target).encode(), b"absolute", b"exact", None)
            m.mpv_command(ctx, a)
        elif kind == "check":
            p = pos() if pos() is not None else -1
            ok = p > target + 0.5
            results[i] = {"target": target, "pos": p, "ok": ok}
            print(f"SPIKE seek {i} {'OK' if ok else 'STALLED'} target={target} pos={p}", file=sys.stderr)
        elif kind == "quit":
            si = len(schedule)
            now = QUIT_AT + 1
    if now >= QUIT_AT:
        break

cpu = time.process_time()
verdict = {
    "dll": DLL,
    "mpv_version": prop("mpv-version"),
    "ffmpeg_version": prop("ffmpeg-version"),
    "track": TRACK,
    "itag": u[TRACK]["itag"],
    "mode": MODE,
    "played": (played_before or 0) > 0.5,
    "played_before_first_seek": played_before,
    "seeks_ok": sum(1 for r in results.values() if r["ok"]),
    "seeks_total": len(PLAN),
    "seeks": results,
    "hwdec_current": prop("hwdec-current"),
    "video_codec": prop("video-codec"),
    "audio_codec": prop("audio-codec"),
    "track_count": prop("track-list/count"),
    "option_errors": OPTION_ERRORS,
    "frame_drop_count": prop("frame-drop-count"),
    "stream_lavf_o": prop("stream-lavf-o"),
    "cpu_seconds": round(cpu, 2),
    "at_load": log_hits,
}
m.mpv_terminate_destroy(ctx)
print(json.dumps(verdict, indent=2))
