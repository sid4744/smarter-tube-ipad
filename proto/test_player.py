import yt_engine, urllib.request, sys
vid = sys.argv[1] if len(sys.argv) > 1 else "jNQXAC9IVRw"
p = yt_engine.player_ios(vid)
print({k: (v[:90] if isinstance(v, str) else v) for k, v in p.items()})
if p["hls"]:
    master = yt_engine.http(p["hls"], headers={"User-Agent": yt_engine.IOS["userAgent"]})
    lines = [l for l in master.splitlines() if l.startswith("#EXT-X-STREAM-INF")]
    print("variants:", len(lines)); print("\n".join(l[:140] for l in lines[:4]))
    var = [l for l in master.splitlines() if l.startswith("http")][0]
    media = yt_engine.http(var, headers={"User-Agent": yt_engine.IOS["userAgent"]})
    seg = [l for l in media.splitlines() if l.startswith("http")][0]
    data = yt_engine.http(seg, headers={"User-Agent": yt_engine.IOS["userAgent"]}, raw=True)
    print("first segment bytes:", len(data))
