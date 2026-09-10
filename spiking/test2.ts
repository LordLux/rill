const url = "https://manifest.googlevideo.com/api/manifest/hls_variant/expire/1789029986/ei/AhqiatOvIbK-hcIPu9jAyQk/ip/151.48.80.83/id/jXAEIWcGXwE.4/source/yt_live_broadcast/requiressl/yes/xpc/EgVo2aDSNQ%3D%3D/hfr/1/playlist_duration/3600/manifest_duration/3600/demuxed/1/maudio/1/bui/AR3QkAmkYv1wd-o3bPM4n6ukeGgo93Da9XsnrVf_QIlTCY3fBpWZD5fDRgYQaWtTgrMEHdWehr3I-kSA/spc/I-rgIQEGOFvpwH_eCI19IBGhx1ZATnXclIeQZ73lpD4OPmwwccV2uxBV9Q/vprv/1/go/1/rqh/5/reg/0/pacing/0/nvgoi/1/short_key/1/ncsapi/1/keepalive/yes/fexp/51565115%2C52135441%2C52178455%2C52189887/dover/13/itag/0/playlist_type/DVR/sparams/expire%2Cei%2Cip%2Cid%2Csource%2Crequiressl%2Cxpc%2Chfr%2Cplaylist_duration%2Cmanifest_duration%2Cdemuxed%2Cmaudio%2Cbui%2Cspc%2Cvprv%2Cgo%2Crqh%2Creg%2Citag%2Cplaylist_type/sig/AE0s2JYwRgIhAOslZ2l3kZWGTQpUDWqiKXhvkqgzZMnq7e6l39dVM0RWAiEAqU61aISmaZ756ptj-IgUXWxWg67Vg9xuiek908sIXsg%3D/file/index.m3u8";
const updated = url.replace(/(playlist_duration\/)\d+/, "$1" + "43200").replace(/(manifest_duration\/)\d+/, "$1" + "43200");
console.log(updated);
const res = await fetch(updated);
const text = await res.text();
console.log(text.slice(0, 500));
