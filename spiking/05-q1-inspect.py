# Spike 05 Q1/Q2 — interrogate libmpv binaries directly.
# Two passes: (1) inert string scan, (2) load via ctypes and ask mpv itself.
import ctypes, json, os, re, sys

TARGETS = json.load(open(sys.argv[1]))
SYSTEM_MPV = r"C:\Program Files\MPV Player\mpv.exe"  # spike 03's control

NEEDLES = [b"request_size", b"initial_request_size", b"short_seek_size", b"seekable"]


def strings_scan(path):
    blob = open(path, "rb").read()
    out = {}
    for n in NEEDLES:
        # count standalone occurrences; request_size is a substring of
        # initial_request_size, so subtract to get the bare-option count
        out[n.decode()] = blob.count(n)
    out["request_size_standalone"] = out["request_size"] - out["initial_request_size"]
    lavf = sorted(set(m.decode() for m in re.findall(rb"Lavf\d+\.\d+\.\d+", blob)))
    lavc = sorted(set(m.decode() for m in re.findall(rb"Lavc\d+\.\d+\.\d+", blob)))
    ver = sorted(set(m.decode() for m in re.findall(rb"mpv v?\d+\.\d+\.\d+[-\w.]*", blob)))
    out["Lavf"] = lavf
    out["Lavc"] = lavc
    out["mpv_version_strings"] = ver[:5]
    out["bytes"] = len(blob)
    return out


def probe(path):
    """Load the DLL and ask mpv for its own versions + option reachability."""
    res = {"loaded": False}
    try:
        lib = ctypes.CDLL(path)
    except OSError as e:
        res["load_error"] = str(e)
        return res
    res["loaded"] = True

    lib.mpv_client_api_version.restype = ctypes.c_ulong
    api = lib.mpv_client_api_version()
    res["MPV_CLIENT_API_VERSION"] = f"{api >> 16}.{api & 0xFFFF}"
    res["MPV_CLIENT_API_VERSION_raw"] = api

    lib.mpv_create.restype = ctypes.c_void_p
    lib.mpv_get_property_string.restype = ctypes.c_char_p
    lib.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.mpv_initialize.argtypes = [ctypes.c_void_p]
    lib.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]

    ctx = lib.mpv_create()
    if not ctx:
        res["mpv_create"] = "NULL"
        return res

    # headless: no window, no audio device
    for k, v in [(b"vo", b"null"), (b"ao", b"null"), (b"terminal", b"no")]:
        lib.mpv_set_option_string(ctx, k, v)

    # option reachability, before and after init
    res["set_stream_lavf_o_request_size"] = lib.mpv_set_option_string(
        ctx, b"stream-lavf-o", b"request_size=1048576,short_seek_size=1048576"
    )

    res["mpv_initialize"] = lib.mpv_initialize(ctx)

    for prop in ("mpv-version", "ffmpeg-version", "libass-version", "stream-lavf-o"):
        v = lib.mpv_get_property_string(ctx, prop.encode())
        res[prop] = v.decode() if v else None

    lib.mpv_terminate_destroy(ctx)
    return res


report = []
for t in TARGETS:
    d = os.path.splitext(t["file"])[0]
    dll = os.path.join(d, "libmpv-2.dll")
    entry = {"id": t["id"], "note": t["note"], "dll": dll,
             "archive_md5": t["md5"], "md5_matches_cmakelists": t["md5Match"]}
    entry["strings"] = strings_scan(dll)
    entry["probe"] = probe(dll)
    report.append(entry)

if os.path.exists(SYSTEM_MPV):
    report.append({"id": "system-mpv-control", "note": "spike 03's measurement binary",
                   "dll": SYSTEM_MPV, "strings": strings_scan(SYSTEM_MPV), "probe": None})

print(json.dumps(report, indent=2))
