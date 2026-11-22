import yt_engine, urllib.request, sys
r = yt_engine.tv_streams(sys.argv[1] if len(sys.argv) > 1 else "nrMwgTc69y4")
print({k: v for k, v in r.items() if k != "formats"}, len(r["formats"]), "direct formats")
for itag in [137, 136, 22, 18, 140, 251]:
    f = r["formats"].get(itag)
    if not f:
        continue
    try:
        req = urllib.request.Request(f["url"], headers={"User-Agent": yt_engine.UA_TV, "Range": "bytes=0-262143"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            print(itag, f["mime"][:28], f["quality"], resp.status, len(resp.read()), "bytes")
    except Exception as e:
        print(itag, f["mime"][:28], "FAIL", str(e)[:70])
