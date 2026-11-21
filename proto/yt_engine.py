"""Prototype of the YouTube engine the iPad app will use (ported from SmartTube's MediaServiceCore)."""
import json, re, urllib.request, urllib.parse, uuid, os, time

UA_TV = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
STATE = os.path.join(os.path.dirname(__file__), "state.json")


def http(url, data=None, headers=None, raw=False):
    h = {"User-Agent": UA_TV}
    h.update(headers or {})
    body = None
    if data is not None:
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
        h.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body, headers=h)
    with urllib.request.urlopen(req, timeout=30) as r:
        b = r.read()
    return b if raw else b.decode("utf-8", "replace")


def app_info():
    page = http("https://www.youtube.com/tv")
    base = None
    for rx in [r'id="base-js" src="(.*?)"', r"\.src = '(.*?m=base)'", r"\.src = '(.*?)'; .\.id = 'base-js'"]:
        m = re.search(rx, page)
        if m:
            base = m.group(1)
            break
    player = re.search(r'"player_url":"(.*?)"', page)
    visitor = re.search(r'"visitorData":"(.*?)"', page)
    return {"base_js": base, "player_url": player.group(1).replace(r"\/", "/") if player else None,
            "visitor": visitor.group(1) if visitor else None}


def client_data(base_js):
    url = base_js if base_js.startswith("http") else "https://www.youtube.com" + base_js
    js = http(url)
    m = re.search(r'clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"(\w+)"', js)
    return {"client_id": m.group(1), "client_secret": m.group(2)} if m else None


if __name__ == "__main__":
    info = app_info()
    print("app info:", {k: (v[:80] if v else v) for k, v in info.items()})
    cd = client_data(info["base_js"])
    print("client id found:", bool(cd), (cd["client_id"][:12] + "...") if cd else "")


# --- sign-in: the TV device-code flow (code confirmed at yt.be/activate) -----------------------
SCOPE = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
TOKEN_FILE = os.environ.get("YT_TOKEN_FILE", "token.json")  # never commit this


def device_code(cd):
    return json.loads(http("https://www.youtube.com/o/oauth2/device/code", {
        "client_id": cd["client_id"], "device_id": str(uuid.uuid4()), "model_name": "ytlr::", "scope": SCOPE}))


def poll_token(cd, code, interval, timeout=600):
    end = time.time() + timeout
    while time.time() < end:
        r = json.loads(http("https://www.youtube.com/o/oauth2/token", {
            "code": code, "client_id": cd["client_id"], "client_secret": cd["client_secret"],
            "grant_type": "http://oauth.net/grant_type/device/1.0"}))
        if "refresh_token" in r:
            return r
        if r.get("error") not in ("authorization_pending", "slow_down"):
            raise RuntimeError(r)
        time.sleep(interval)
    raise TimeoutError()


def access_token():
    t = json.load(open(TOKEN_FILE))
    if t.get("expires_at", 0) > time.time() + 60:
        return t["access_token"]
    cd = t["client"]
    r = json.loads(http("https://www.youtube.com/o/oauth2/token", {
        "refresh_token": t["refresh_token"], "client_id": cd["client_id"], "client_secret": cd["client_secret"],
        "grant_type": "refresh_token"}))
    t["access_token"] = r["access_token"]
    t["expires_at"] = time.time() + r.get("expires_in", 3600)
    json.dump(t, open(TOKEN_FILE, "w"))
    return t["access_token"]


def sign_in():
    info = app_info()
    cd = client_data(info["base_js"])
    dc = device_code(cd)
    print("CODE", dc["user_code"], dc.get("verification_url"), flush=True)
    tok = poll_token(cd, dc["device_code"], dc.get("interval", 5))
    tok["client"] = cd
    tok["expires_at"] = time.time() + tok.get("expires_in", 3600)
    json.dump(tok, open(TOKEN_FILE, "w"))
    print("SIGNED IN", flush=True)


# --- InnerTube (YouTube's internal API) ---------------------------------------------------------
TV = {"clientName": "TVHTML5", "clientVersion": "7.20260901.15.00", "userAgent": UA_TV}
IOS = {"clientName": "IOS", "clientVersion": "21.26.4", "deviceMake": "Apple", "deviceModel": "iPhone16,2",
       "osName": "iPhone", "osVersion": "18.3.2.22D82",
       "userAgent": "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"}
CLIENT_IDS = {"TVHTML5": "7", "IOS": "5"}


def innertube(endpoint, payload, client=TV, auth=False, visitor=None):
    ctx = {"client": dict(client, hl="en", gl="NL", utcOffsetMinutes=60)}
    if visitor:
        ctx["client"]["visitorData"] = visitor
    body = dict(payload, context=ctx, racyCheckOk=True, contentCheckOk=True)
    headers = {"User-Agent": client["userAgent"], "X-YouTube-Client-Name": CLIENT_IDS[client["clientName"]],
               "X-YouTube-Client-Version": client["clientVersion"]}
    if auth:
        headers["Authorization"] = "Bearer " + access_token()
    return json.loads(http("https://www.youtube.com/youtubei/v1/%s?prettyPrint=false" % endpoint, body, headers))


def player_ios(video_id):
    r = innertube("player", {"videoId": video_id}, client=IOS)
    sd = r.get("streamingData", {})
    return {"status": r.get("playabilityStatus", {}).get("status"),
            "reason": r.get("playabilityStatus", {}).get("reason"),
            "hls": sd.get("hlsManifestUrl"),
            "formats": len(sd.get("formats", [])) + len(sd.get("adaptiveFormats", [])),
            "title": r.get("videoDetails", {}).get("title"),
            "length": r.get("videoDetails", {}).get("lengthSeconds")}


# --- unscrambling stream addresses: yt-dlp's EJS solver run on YouTube's own player script -----
# (Node stands in for the iPad's JavaScriptCore here; the solver is plain JavaScript)
import subprocess, tempfile
SOLVER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "solver")
_player_cache = {}


def player_js(player_url):
    if player_url not in _player_cache:
        _player_cache[player_url] = http("https://www.youtube.com" + player_url)
    return _player_cache[player_url]


def signature_timestamp(js):
    m = re.search(r"signatureTimestamp:(\d+)", js)
    return int(m.group(1)) if m else None


def solve(js, n_list, sig_list):
    lib = "".join(open(os.path.join(SOLVER_DIR, f), encoding="utf-8").read() + "\n"
                  for f in ["polyfill.js", "meriyah-6.1.4.min.js", "astring-1.9.0.min.js", "yt.solver.core.js"])
    reqs = []
    if n_list:
        reqs.append({"type": "n", "challenges": n_list})
    if sig_list:
        reqs.append({"type": "sig", "challenges": sig_list})
    data = {"type": "player", "player": js, "requests": reqs, "output_preprocessed": False}
    script = lib + "\nconst __in = " + json.dumps(data) + ";\nprocess.stdout.write(JSON.stringify(jsc(__in)));\n"
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
        f.write(script)
        path = f.name
    out = subprocess.run(["node", path], capture_output=True, text=True, encoding="utf-8").stdout
    os.unlink(path)
    res = json.loads(out)
    if res.get("type") == "error":
        raise RuntimeError(res.get("error"))
    result = {}
    for req, resp in zip(reqs, res["responses"]):
        if resp.get("type") == "error":
            raise RuntimeError(resp.get("error"))
        result[req["type"]] = resp["data"]
    return result


def stream_urls(video_id, auth=False):
    """Playable URLs per itag, via the TV client (SmartTube's way)."""
    info = app_info()
    js = player_js(info["player_url"])
    r = innertube("player", {"videoId": video_id, "playbackContext": {"contentPlaybackContext": {
        "signatureTimestamp": signature_timestamp(js)}}}, client=TV, auth=auth, visitor=info["visitor"])
    st = r.get("playabilityStatus", {})
    fmts = r.get("streamingData", {}).get("adaptiveFormats", []) + r.get("streamingData", {}).get("formats", [])
    entries = []
    for f in fmts:
        if "url" in f:
            url, s, sp = f["url"], None, None
        else:
            q = urllib.parse.parse_qs(f.get("signatureCipher", ""))
            url, s, sp = q.get("url", [None])[0], q.get("s", [None])[0], q.get("sp", ["sig"])[0]
        if not url:
            continue
        n = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("n", [None])[0]
        entries.append((f, url, s, sp, n))
    ns = sorted({e[4] for e in entries if e[4]})
    ss = sorted({e[2] for e in entries if e[2]})
    solved = solve(js, ns, ss) if (ns or ss) else {}
    out = {}
    for f, url, s, sp, n in entries:
        u = urllib.parse.urlparse(url)
        q = urllib.parse.parse_qs(u.query)
        if n and "n" in solved:
            q["n"] = [solved["n"][n]]
        if s and "sig" in solved:
            q[sp] = [solved["sig"][s]]
        out[f["itag"]] = {"url": u._replace(query=urllib.parse.urlencode(q, doseq=True)).geturl(),
                          "mime": f.get("mimeType"), "quality": f.get("qualityLabel"), "bitrate": f.get("bitrate"),
                          "init": f.get("initRange"), "index": f.get("indexRange"), "len": f.get("contentLength")}
    return st.get("status"), st.get("reason"), r.get("videoDetails", {}).get("title"), out
