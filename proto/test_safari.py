import yt_engine, urllib.request, sys, json
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)"
SAFARI = {"clientName": "WEB", "clientVersion": "2.20260907.06.00", "userAgent": UA}
yt_engine.CLIENT_IDS["WEB"] = "1"
vid = sys.argv[1] if len(sys.argv) > 1 else "nrMwgTc69y4"
info = yt_engine.app_info()
r = yt_engine.innertube("player", {"videoId": vid}, client=SAFARI, visitor=info["visitor"])
st = r.get("playabilityStatus", {}); sd = r.get("streamingData", {})
print(st.get("status"), st.get("reason"), "hls:", bool(sd.get("hlsManifestUrl")), "sabr:", bool(sd.get("serverAbrStreamingUrl")),
      "formats:", len(sd.get("adaptiveFormats", [])))
if sd.get("hlsManifestUrl"):
    m = yt_engine.http(sd["hlsManifestUrl"], headers={"User-Agent": UA})
    inf = [l for l in m.splitlines() if l.startswith("#EXT-X-STREAM-INF")]
    print(len(inf), "variants;", inf[-1][:160] if inf else "")
    v = [l for l in m.splitlines() if l.startswith("http")]
    media = yt_engine.http(v[-1], headers={"User-Agent": UA})
    seg = [l for l in media.splitlines() if l.startswith("http")][0]
    try:
        d = yt_engine.http(seg, headers={"User-Agent": UA}, raw=True); print("segment", len(d), "bytes")
    except Exception as e:
        print("segment FAIL", e)
