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
    return {"base_js": base, "player_url": player.group(1).replace("\/", "/") if player else None,
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
