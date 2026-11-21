import yt_engine, urllib.request, sys
vid = sys.argv[1] if len(sys.argv) > 1 else "nrMwgTc69y4"
status, reason, title, urls = yt_engine.stream_urls(vid)
print(status, reason, title, len(urls), "formats")
for itag in [18, 137, 136, 22, 140, 251]:
    if itag in urls:
        try:
            req = urllib.request.Request(urls[itag]["url"], headers={"User-Agent": yt_engine.UA_TV, "Range": "bytes=0-131071"})
            with urllib.request.urlopen(req, timeout=20) as r:
                print(itag, urls[itag]["mime"][:30], urls[itag]["quality"], r.status, len(r.read()), "bytes")
        except Exception as e:
            print(itag, urls[itag]["mime"][:30], "FAIL", str(e)[:60])
