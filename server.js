// Qoder Bridge — local server between the CLI/AI agent and the Roblox Studio plugin.
//
// Architecture: plugins cannot listen on sockets in Luau, so the plugin LONG-POLLS
// this server for commands and POSTs results back. All traffic is 127.0.0.1 only.
//
//   Qoder/CLI --POST /api/command--> [ this server ] <--GET /poll-- Studio plugin
//                                     |               --POST /result->
//
// Run: node server.js [--port 8346]

const http = require("http");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const PORT = Number(process.argv.find((a, i) => process.argv[i - 1] === "--port") || 8346);
const HOST = "127.0.0.1"; // localhost only, never bind elsewhere
const TOKEN_FILE = path.join(__dirname, "bridge.token");
const PLUGIN_STALE_MS = 30_000;
const COMMAND_TIMEOUT_MS = 120_000;
const RATE_LIMIT_PER_SEC = 25;

if (!fs.existsSync(TOKEN_FILE)) {
  fs.writeFileSync(TOKEN_FILE, crypto.randomBytes(16).toString("hex"));
}
const TOKEN = fs.readFileSync(TOKEN_FILE).toString().trim();

let pluginLastSeen = 0;
let reqCount = 0;
let lastCommand = null;
const serverStarted = Date.now();
const queue = []; // commands waiting for the plugin to pick up
const waiting = new Map(); // id -> {res, timer}

// The plugin queues mutating commands while a Play Test is running and posts the real outcome
// minutes later, under the SAME id, with `phase`. The HTTP caller has long since been answered with
// the "queued" acknowledgement, so that second post would fall on the floor — and a build run that
// reports success while its writes are still sitting in a plugin array is the exact failure this
// project has been burned by before ("loaded != polling", "a placeId match proves where you are").
// So every phase gets recorded, and `GET /api/queue` is how anyone finds out what actually happened.
const queueOutcomes = []; // {id, command, phase, success, error, at} newest last
const QUEUE_OUTCOME_LIMIT = 100;
const commandById = new Map(); // id -> command name, so an outcome POST can name what it applied

// naive token bucket
let bucket = RATE_LIMIT_PER_SEC;
setInterval(() => (bucket = RATE_LIMIT_PER_SEC), 1000);

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => {
      data += c;
      if (data.length > 2_000_000) reject(new Error("body too large"));
    });
    req.on("end", () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch (e) {
        reject(new Error("invalid JSON: " + e.message));
      }
    });
  });
}

function authorized(req) {
  return (req.headers["x-bridge-token"] || "") === TOKEN;
}

const VERBOSE = process.argv.includes("--verbose");
function log(...parts) {
  if (VERBOSE) console.log(new Date().toISOString().slice(11, 23), ...parts);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${HOST}`);
  log(req.method, url.pathname + url.search);

  if (!authorized(req)) {
    log("  401 bad token");
    return json(res, 401, { error: "authentication failed: bad or missing x-bridge-token header" });
  }
  if (!bucket--) {
    log("  429 rate limited");
    return json(res, 429, { error: "rate limited" });
  }

  // ---- plugin: long-poll for a command ----
  if (req.method === "GET" && url.pathname === "/poll") {
    pluginLastSeen = Date.now();
    const cmd = queue.shift();
    if (cmd) {
      log("  -> hand-off", cmd.command, cmd.id);
      return json(res, 200, cmd);
    }
    const timeout = Number(url.searchParams.get("timeout") || 25) * 1000;
    const start = Date.now();
    const timer = setInterval(() => {
      const c = queue.shift();
      if (c) {
        clearInterval(timer);
        log("  -> hand-off (held poll)", c.command, c.id);
        json(res, 200, c);
      } else if (Date.now() - start > timeout) {
        clearInterval(timer);
        log("  204 no command after", Math.round((Date.now() - start) / 1000) + "s");
        res.writeHead(204).end();
      }
    }, 250);
    req.on("close", () => {
      clearInterval(timer);
      log("  poll closed early after", Math.round((Date.now() - start) / 1000) + "s");
    });
    return;
  }

  // ---- plugin: deliver a result ----
  if (req.method === "POST" && url.pathname === "/result") {
    pluginLastSeen = Date.now();
    let body;
    try {
      body = await readBody(req);
    } catch (e) {
      return json(res, 400, { error: e.message });
    }
    log("  <- result POST", body.phase || "(final)", body.id);
    // Two posts can carry one id: "queued" now, "queue_applied" when Play Test ends. Both are
    // recorded; only the first one to find a waiting caller gets delivered to it.
    if (body.phase) {
      queueOutcomes.push({
        id: body.id,
        command: commandById.get(body.id) || body.result?.command || "?",
        phase: body.phase,
        success: body.success,
        error: body.error || null,
        at: new Date().toISOString(),
      });
      while (queueOutcomes.length > QUEUE_OUTCOME_LIMIT) queueOutcomes.shift();
      if (body.phase === "queue_applied") commandById.delete(body.id);
    }
    const w = waiting.get(body.id);
    if (w) {
      waiting.delete(body.id);
      clearTimeout(w.timer);
      json(w.res, 200, body);
    }
    return json(res, 200, { ok: true });
  }

  // ---- CLI/agent: status ----
  if (req.method === "GET" && url.pathname === "/api/status") {
    return json(res, 200, {
      server: "Qoder Bridge",
      port: PORT,
      pluginConnected: Date.now() - pluginLastSeen < PLUGIN_STALE_MS,
      pluginLastSeenMs: Date.now() - pluginLastSeen,
      queued: queue.length,
      inFlight: waiting.size,
      reqCount,
      lastCommand,
      queuedOutcomes: queueOutcomes.length,
      lastQueueOutcome: queueOutcomes[queueOutcomes.length - 1] || null,
    });
  }

  // ---- CLI/agent: what happened to commands the plugin deferred during Play ----
  if (req.method === "GET" && url.pathname === "/api/queue") {
    return json(res, 200, { outcomes: queueOutcomes, serverUptimeMs: Date.now() - serverStarted });
  }

  // ---- CLI/agent: send a command and wait for the plugin result ----
  if (req.method === "POST" && url.pathname === "/api/command") {
    let body;
    try {
      body = await readBody(req);
    } catch (e) {
      return json(res, 400, { error: e.message });
    }
    if (!body.command || typeof body.command !== "string") return json(res, 400, { error: "missing command" });
    const id = crypto.randomUUID();
    reqCount++;
    lastCommand = { id, command: body.command, at: new Date().toISOString() };
    const cmd = { id, command: body.command, parameters: body.parameters || {} };
    queue.push(cmd);
    commandById.set(id, body.command);

    const timer = setTimeout(() => {
      const idx = queue.findIndex((c) => c.id === id);
      if (idx >= 0) queue.splice(idx, 1);
      commandById.delete(id);
      if (waiting.has(id)) {
        waiting.delete(id);
        json(res, 504, { id, success: false, error: { code: "TIMEOUT", message: "plugin did not respond in time (is the bridge started in Studio?)" } });
      }
    }, Number(body.timeout || COMMAND_TIMEOUT_MS));

    waiting.set(id, { res, timer });
    return;
  }

  return json(res, 404, { error: "unknown endpoint" });
});

server.listen(PORT, HOST, () => {
  console.log(`Qoder Bridge server on http://${HOST}:${PORT}`);
  console.log(`Token: ${TOKEN}  (also in bridge.token)`);
});
