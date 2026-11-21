// Prototype of the TV PoToken (BotGuard) flow, ported from SmartTube's TvPoTokenWebView4.
// Headless Chrome stands in for the iPad's WKWebView: the same HTML page runs Google's BotGuard VM.
// Usage: node tv_potoken.mjs   -> prints {"livingRoomId": ..., "visitorData": ..., "poToken": ...}
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const UA_TV = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)";
const UA_BG = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36(KHTML, like Gecko)";
const API_KEY = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw";
const CHROME = "C:/Program Files/Google/Chrome/Application/chrome.exe";
const log = (...a) => process.stderr.write(a.join(" ") + "\n");

async function bgRequest(url, body, extra = {}) {
  const r = await fetch(url, {
    method: body == null ? "GET" : "POST",
    headers: { "User-Agent": UA_BG, "Accept": "application/json", "Content-Type": "application/json+protobuf",
      "x-goog-api-key": API_KEY, "x-user-agent": "grpc-web-javascript/0.1", ...extra },
    body,
  });
  if (!r.ok) throw new Error(`${url} -> HTTP ${r.status}`);
  return r.text();
}

function b64ToBytes(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/").replace(/\./g, "=");
  return Buffer.from(s, "base64");
}

// --- the TV session: living room id + visitor data (same /tv page), BotGuard request key ------
const tvPage = await (await fetch("https://www.youtube.com/tv", { headers: { "User-Agent": UA_TV } })).text();
const livingRoomId = /"LIVING_ROOM_PO_TOKEN_ID":"(.*?)"/.exec(tvPage)[1].replace(/\\u003d/g, "=");
const visitorData = /"visitorData":"(.*?)"/.exec(tvPage)[1];
const tvConfig = await (await fetch("https://www.youtube.com/tv_config?action_get_config=true&client=lb4&theme=cl",
  { headers: { "User-Agent": UA_TV } })).text();
const requestKey = /"challengeRequestKey":"(.*?)"/.exec(tvConfig)[1];
log("living room id ok, request key", requestKey);

// --- the BotGuard challenge (program + interpreter) from /att/get for the TV client ---------------
const att = JSON.parse(await bgRequest("https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false",
  JSON.stringify({ context: { client: { clientName: "TVHTML5", clientVersion: "7.20260901.15.00" } },
    engagementType: "ENGAGEMENT_TYPE_UNBOUND" }), { "Content-Type": "application/json" }));
const bg = att.bgChallenge;
const interpreterUrl = bg.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue;
const interpreterJs = await (await fetch("https:" + interpreterUrl)).text();
const challenge = {
  interpreterJavascript: { privateDoNotAccessOrElseSafeScriptWrappedValue: interpreterJs,
    privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: interpreterUrl },
  interpreterHash: bg.interpreterHash, program: bg.program, globalName: bg.globalName,
  clientExperimentsStateBlob: bg.clientExperimentsStateBlob,
};
log("challenge ok, interpreter", interpreterJs.length, "chars");

// --- headless Chrome, a page "from" youtube.com running the BotGuard page ------------------------
const port = 9300 + Math.floor(Math.random() * 500);
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "bg-"));
const chrome = spawn(CHROME, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", `--user-agent=${UA_BG}`, "about:blank"], { stdio: "ignore" });
let tab;
for (let i = 0; i < 50 && !tab; i++) {
  await new Promise((r) => setTimeout(r, 200));
  try { tab = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === "page"); } catch {}
}
const ws = new WebSocket(tab.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let seq = 0;
const pending = new Map();
ws.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else if (m.method === "Fetch.requestPaused") onPaused(m.params);
});
const cdp = (method, params = {}) => new Promise((res) => { const id = ++seq; pending.set(id, res); ws.send(JSON.stringify({ id, method, params })); });
const html = fs.readFileSync(path.join(HERE, "po_token2.html"));
function onPaused(p) {
  if (p.request.url.startsWith("https://www.youtube.com/__botguard")) {
    cdp("Fetch.fulfillRequest", { requestId: p.requestId, responseCode: 200,
      responseHeaders: [{ name: "Content-Type", value: "text/html; charset=utf-8" }], body: html.toString("base64") });
  } else {
    cdp("Fetch.failRequest", { requestId: p.requestId, errorReason: "BlockedByClient" }); // like blockNetworkLoads
  }
}
async function evaluate(expr) {
  const r = await cdp("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
}
try {
  await cdp("Fetch.enable", { patterns: [{ urlPattern: "*" }] });
  await cdp("Page.enable");
  await cdp("Page.navigate", { url: "https://www.youtube.com/__botguard" });
  await new Promise((r) => setTimeout(r, 1500));

  const botguardResponse = await evaluate(`runBotGuard(${JSON.stringify(challenge)}).then(function (r) {
      window.webPoSignalOutput = r.webPoSignalOutput; return r.botguardResponse; })`);
  log("botguard ran, response", String(botguardResponse).length, "chars");

  const it = JSON.parse(await bgRequest("https://www.youtube.com/api/jnn/v1/GenerateIT",
    JSON.stringify([requestKey, botguardResponse])));
  const itBytes = [...b64ToBytes(it[0])];
  log("integrity token ok, expires in", it[1], "s");

  await evaluate(`getMinter = webPoSignalOutput[0]; mintCallback = getMinter(new Uint8Array([${itBytes}])); true`);
  const idBytes = [...Buffer.from(livingRoomId, "utf8")];
  const potCsv = await evaluate(`Array.from(obtainPoToken(new Uint8Array([${idBytes}]))).join(",")`);
  const poToken = Buffer.from(potCsv.split(",").map(Number)).toString("base64").replace(/\+/g, "-").replace(/\//g, "_");
  process.stdout.write(JSON.stringify({ livingRoomId, visitorData, poToken, expiresIn: it[1] }));
} finally {
  ws.close();
  chrome.kill();
}
