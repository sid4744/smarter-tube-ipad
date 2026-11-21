import yt_engine, urllib.request, sys
vid = sys.argv[1] if len(sys.argv) > 1 else "nrMwgTc69y4"
r = yt_engine.innertube("player", {"videoId": vid}, client=yt_engine.IOS)
sd = r.get("streamingData", {})
for f in (sd.get("formats", []) + sd.get("adaptiveFormats", [])):
    it = f.get("itag"); mt = f.get("mimeType", "")[:40]; url = f.get("url")
    res = "cipher" if not url else None
    if url:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": yt_engine.IOS["userAgent"], "Range": "bytes=0-65535"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                res = "%d %dB" % (resp.status, len(resp.read()))
        except Exception as e:
            res = str(e)[:40]
    print(it, mt, f.get("qualityLabel", ""), res)
