// Shared Qoder Bridge client for the build scripts.
//   const { send, sleep, create, setProp, v3, c3, cf, en } = require("./bridge-client");
const http = require("http");
const fs = require("fs");
const path = require("path");

const PORT = Number(process.env.BRIDGE_PORT || 8346);
// A copy of this repo that has never run the server has no bridge.token, and a bare ENOENT from
// readFileSync does not tell you the one command that fixes it.
const TOKEN_FILE = process.env.BRIDGE_TOKEN_FILE || path.join(__dirname, "bridge.token");
if (!fs.existsSync(TOKEN_FILE)) {
  throw new Error(
    `no token file at ${TOKEN_FILE} — start the bridge once: cd "${__dirname}" && node server.js. ` +
      "It creates bridge.token and prints the token to paste into the plugin panel."
  );
}
const TOKEN = fs.readFileSync(TOKEN_FILE, "utf8").trim();
const STEP_MS = Number(process.env.BRIDGE_STEP_MS || 110);

function raw(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = http.request(
      {
        host: "127.0.0.1",
        port: PORT,
        path: urlPath,
        method,
        headers: { "x-bridge-token": TOKEN, ...(payload ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) } : {}) },
      },
      (res) => {
        let d = "";
        res.on("data", (c) => (d += c));
        res.on("end", () => {
          let parsed = null;
          try { parsed = JSON.parse(d || "{}"); } catch { parsed = null; }
          resolve({ status: res.statusCode, body: parsed, text: d });
        });
      }
    );
    req.on("error", (e) => reject(new Error(e.code === "ECONNREFUSED" ? `bridge server not running on port ${PORT} — start it: node server.js` : e.message)));
    if (payload) req.write(payload);
    req.end();
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Studio's plugin answers for whichever tab has the focus, so a long run of commands quietly follows
// the user to another place. That matters here: two Qoder sessions share this bridge, and a facility
// build is about seven hundred commands over twelve minutes — long enough for the other session's tab
// to come forward mid-run. A script that is about to write for a while calls expectPlace(id) once, and
// every command after that re-checks the place first, so the worst case is the handful of writes
// between two checks rather than a whole building landing in someone else's place.
let expectedPlaceId = null;
let guardEvery = 10;
let sinceGuard = 0;

function expectPlace(placeId, every = 10) {
  expectedPlaceId = placeId;
  guardEvery = every;
  // arm it so the very next command re-checks rather than waiting out a whole interval: the caller
  // has usually just checked by hand, so this costs one command and closes the gap right after it.
  sinceGuard = every;
}

async function placeNow() {
  const res = await raw("POST", "/api/command", { command: "studio.status", parameters: {} });
  return res.body && res.body.result ? res.body.result.placeId : null;
}

async function send(command, parameters) {
  if (expectedPlaceId !== null && command !== "studio.status") {
    if (sinceGuard >= guardEvery) {
      sinceGuard = 0;
      const live = await placeNow();
      if (live !== expectedPlaceId) {
        throw new Error(
          `Studio is showing placeId ${live}, not ${expectedPlaceId} — stopping rather than writing into the wrong place`
        );
      }
    }
    sinceGuard++;
  }
  for (let attempt = 0; attempt < 8; attempt++) {
    const res = await raw("POST", "/api/command", { command, parameters });
    if (res.status === 429) { await sleep(300 * (attempt + 1)); continue; }
    if (!res.body) throw new Error(`non-JSON reply for ${command}: ${res.text.slice(0, 160)}`);
    await sleep(STEP_MS);
    return res.body;
  }
  throw new Error(`stuck at the rate limiter for ${command}`);
}

// Numbers go through a guard because the failure is otherwise silent and confusing: NaN
// survives JSON.stringify as `null`, the plugin's deserialize leaves a nil in the CFrame and
// the write fails with "could not set CFrame: Argument 2 missing or nil", naming the instance
// and not the arithmetic that produced it. (Stain props, 2026-09-29: `(stringSeed % 7) * 0.4`.)
function num(value, what) {
	const n = Number(value);
	if (!Number.isFinite(n)) throw new TypeError(`${what} must be a finite number, got ${JSON.stringify(value)}`);
	return n;
}

const v3 = (x, y, z) => ({ __v3: [num(x, "Vector3.x"), num(y, "Vector3.y"), num(z, "Vector3.z")] });
const c3 = (r, g, b) => ({ __c3: [num(r, "Color3.r") / 255, num(g, "Color3.g") / 255, num(b, "Color3.b") / 255] });
const cf = (x, y, z, rx = 0, ry = 0, rz = 0) => ({
	__cf: { pos: [num(x, "CFrame.x"), num(y, "CFrame.y"), num(z, "CFrame.z")], rot: [num(rx, "CFrame.rx"), num(ry, "CFrame.ry"), num(rz, "CFrame.rz")] },
});
const en = (name) => ({ __enum: "Enum." + name });

// Shared failure collection: every builder reports the same way.
function makeReporter(label) {
  const state = { made: 0, failures: [] };
  async function create(parent, className, name, properties) {
    const out = await send("instance.create", { parent, className, name, properties });
    if (!out.success) {
      state.failures.push(`${name}: ${(out.error && out.error.message) || "unknown"}`);
    } else {
      state.made++;
      if (state.made % 40 === 0) console.log(`  ... ${state.made} instances`);
    }
    return out;
  }
  async function setProp(target, property, value) {
    const out = await send("property.set", { path: target, property, value });
    if (!out.success) state.failures.push(`${target}.${property}: ${(out.error && out.error.message) || "unknown"}`);
    return out;
  }
  function report() {
    console.log(`\n${label}: ${state.made} instances`);
    if (state.failures.length) {
      console.log(`${state.failures.length} failures:`);
      for (const f of state.failures.slice(0, 20)) console.log("  - " + f);
    } else {
      console.log("no failures");
    }
    return state;
  }
  return { state, create, setProp, report, send };
}

module.exports = { raw, send, sleep, v3, c3, cf, en, makeReporter, expectPlace, STEP_MS, PORT };
