// Qoder Bridge CLI — sends commands to the local bridge server.
//
// Usage:
//   node cli.js status
//   node cli.js raw <command> ['<json parameters>']
//   node cli.js inspect <path> [prop1,prop2,...]
//   node cli.js find name|class <value>
//   node cli.js create <className> <parentPath> <name> ['<json properties>']
//   node cli.js delete <path> --confirm
//   node cli.js rename <path> <newName>
//   node cli.js move <path> <newParentPath>
//   node cli.js select <path> [<path>...]        (no paths = clear)
//   node cli.js script.read <path>
//   node cli.js script.write <path> <localFile>
//   node cli.js script.create <className> <parentPath> <name> <localFile>
//   node cli.js search <text>
//   node cli.js sync.push <manifest.json>   // [{"path":"ServerScriptService.Game","file":"src/game.luau"}]
//   node cli.js sync.pull <path> [<path>...]
//   node cli.js playtest                 is a Play Test running? (needs the queueing plugin build)
//   node cli.js players                  live character positions and health inside Play Test
//   node cli.js output [n]               last n lines of Studio Output, n<=200
//   node cli.js queue [status|clear|log] what the plugin deferred, and what it did when Play ended
//   // build-accuracy verbs (plugin v3; prove them first: node prove-plugin-handlers.js)
//   node cli.js overlap <x> <y> <z> <sx> <sy> <sz> [--exclude a,b] [--limit n]
//   node cli.js check <plan.json> [--exclude a,b] [--gap n] [--no-support]
//   node cli.js audit [rootPath] [--limit n] [--min-dim n] [--floating] [--exclude a,b]
//   node cli.js probe <Class.member>... [--service Foo.bar,...] [--enum Material.Wood,...]
//                 [--material Wood,...] [--class Part,...]
//   node cli.js batch <plan.json> [--continue]        // create everything, or roll the batch back
//   node cli.js verify <manifest.json>                // place vs disk, before pushing anything
//   node cli.js focus <path> [--clear-selection]      // or: focus <x> <y> <z> [sx sy sz]
//   node cli.js screenshot-pose <path>                // not a verb: see capture-studio.ps1
//
// check/batch read a plan: the items array itself, or {"items":[...], "exclude":[...]}. Batch items
// are {parent, className, name, properties}. verify takes sync.push's manifest shape.
// overlap/audit/probe/focus have no file input — the box, root and specs go on the command line.
// audit/check/batch/verify print tallies plus only the rows that complain; --full prints every row.
//
// Commands the plugin does not know answer `UNKNOWN_COMMAND`, which is how you tell an old plugin
// build from a new one: `playtest.*`, `build.queue.*` and `instance.identify` are the additions, and
// `space.overlap`, `geometry.check`, `scene.audit`, `capability.probe`, `instances.create`,
// `sync.verify` and `viewport.focus` came with v3.

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

function request(method, urlPath, bodyObj) {
  return new Promise((resolve, reject) => {
    const body = bodyObj ? JSON.stringify(bodyObj) : null;
    const req = http.request(
      { host: "127.0.0.1", port: PORT, path: urlPath, method, headers: { "x-bridge-token": TOKEN, ...(body ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) } : {}) } },
      (res) => {
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          try {
            resolve(JSON.parse(data || "{}"));
          } catch {
            reject(new Error("non-JSON response: " + data.slice(0, 200)));
          }
        });
      }
    );
    req.on("error", (e) => reject(new Error(e.code === "ECONNREFUSED" ? `bridge server not running on port ${PORT} — start it: node server.js` : e.message)));
    if (body) req.write(body);
    req.end();
  });
}

const V3_COMMANDS = new Set([
  "space.overlap",
  "geometry.check",
  "capability.probe",
  "scene.audit",
  "instances.create",
  "sync.verify",
  "viewport.focus",
]);

// `condense` turns a row-heavy answer into tallies plus the rows that matter; pass it only when the
// caller did not ask for --full.
async function command(cmd, params, condense) {
  const out = await request("POST", "/api/command", { command: cmd, parameters: params || {} });
  console.log(JSON.stringify(condense && out.success !== false ? condense(out) : out, null, 2));
  // A deferred write is NOT a completed write. The plugin answers `queued: true` and applies the
  // command when Play Test ends, so anything that byte-verifies right now would be reading a
  // response, not the place. Shout, because this is the state that turns a build run into a fiction.
  if (out.result && out.result.queued) {
    console.error(`QUEUED, NOT APPLIED: "${out.result.command}" is sitting in the plugin's queue until Play Test ends.`);
    console.error(`node cli.js queue status  |  node cli.js playtest  |  outcomes land under GET /api/queue`);
  }
  // The plugin's own message for an unknown verb is "command not allowed", which reads like a
  // permission problem and sends a build agent off to check Studio API access. It is usually just a
  // legacy plugin build, so say which verbs need v3 and where the proof runs without installing.
  if (out.error && out.error.code === "UNKNOWN_COMMAND" && V3_COMMANDS.has(cmd)) {
    console.error(`"${cmd}" is a plugin v3 verb; the plugin loaded in Studio is older than that.`);
    console.error(`Prove the handlers without installing: node prove-plugin-handlers.js`);
    console.error(`Installing v3 (plugin/QoderBridge.v3.lua) is the user's action — it needs the place saved first.`);
  }
  if (out.success === false) process.exitCode = 1;
}

// The v3 verbs share one option shape (`--exclude a,b`, `--limit 40`, `--no-support`), parsed here
// rather than per branch: seven verbs each indexing `args[i]` by hand is where an off-by-one becomes a
// silently short exclude list, and a short exclude list is a false-clean overlap verdict. An
// unrecognised `--flag` is an error for the same reason — a typo used to become a positional.
function parseOpts(argv) {
  const positionals = [];
  const flags = {};
  let i = 0;
  const next = (name) => {
    i += 1;
    if (i >= argv.length) throw new Error(`${name} needs a value`);
    return argv[i];
  };
  const csv = (name) => next(name).split(",").filter(Boolean);
  const num = (name) => {
    const value = Number(next(name));
    if (!Number.isFinite(value)) throw new Error(`${name} needs a number`);
    return value;
  };
  while (i < argv.length) {
    const a = argv[i];
    if (a === "--exclude") flags.exclude = csv(a);
    else if (a === "--limit") flags.limit = num(a);
    else if (a === "--gap") flags.gap = num(a);
    else if (a === "--min-dim") flags.minDim = num(a);
    else if (a === "--no-support") flags.noSupport = true;
    else if (a === "--floating") flags.floating = true;
    else if (a === "--continue") flags.continueOnError = true;
    else if (a === "--clear-selection") flags.clearSelection = true;
    else if (a === "--full") flags.full = true;
    else if (a === "--enum") flags.enums = csv(a);
    else if (a === "--service") flags.services = csv(a);
    else if (a === "--material") flags.materials = csv(a);
    else if (a === "--class") flags.classes = csv(a);
    else if (a.startsWith("--")) throw new Error(`unknown option ${a}`);
    else positionals.push(a);
    i += 1;
  }
  return { positionals, flags };
}

// check and batch both read a plan file: the items array itself, or {"items":[...], "exclude":[...]}.
function readPlan(file) {
  if (!file) throw new Error("a plan file is required");
  const doc = JSON.parse(fs.readFileSync(file, "utf8"));
  const items = Array.isArray(doc) ? doc : doc.items;
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error(`${file}: expected a non-empty items array (the array itself, or {"items":[...]})`);
  }
  return { items, exclude: Array.isArray(doc.exclude) ? doc.exclude : undefined };
}

// verify reads sync.push's manifest: [{"path":"ServerScriptService.Game","file":"src/game.luau"}].
function readManifest(file) {
  if (!file) throw new Error("a manifest file is required (same shape as sync.push)");
  const doc = JSON.parse(fs.readFileSync(file, "utf8"));
  const entries = Array.isArray(doc) ? doc : doc.files;
  if (!Array.isArray(entries) || entries.length === 0) throw new Error(`${file}: expected a non-empty manifest array`);
  return entries.map((m) => ({ path: m.path, source: typeof m.source === "string" ? m.source : fs.readFileSync(m.file, "utf8") }));
}

const badProblems = (row) => Array.isArray(row.problems) && row.problems.length > 0;
const badBatchRow = (row) => row.ok !== true;
const badVerifyRow = (row) => row.status !== "match";

// A 900-instance batch or a whole-scene audit returns a row each: thousands of JSON lines, and the
// tallies that decide the next move scroll past. Print the counts and only the rows that complain.
function brief(rowKey, isBad) {
  return (out) => {
    const r = out.result || {};
    const rows = Array.isArray(r[rowKey]) ? r[rowKey] : [];
    const bad = rows.filter(isBad);
    const head = Object.assign({}, r);
    delete head[rowKey];
    head.rowsTotal = rows.length;
    head.rowsWithProblems = bad.length;
    head[rowKey] = bad.slice(0, 25);
    if (bad.length > 25) head.rowsTruncated = true;
    return head;
  };
}

const [cmd, ...args] = process.argv.slice(2);

(async () => {
  try {
    if (cmd === "status") {
      console.log(JSON.stringify(await request("GET", "/api/status"), null, 2));
    } else if (cmd === "playtest") {
      // Read-only, so unlike every other command it answers while Play is running. This is how a
      // build agent learns that Studio is mid-session instead of guessing from a stalled write.
      await command("playtest.status", {});
    } else if (cmd === "players") {
      await command("playtest.players", {});
    } else if (cmd === "output") {
      await command("playtest.output", { limit: Number(args[0]) || 50 });
    } else if (cmd === "queue") {
      if (args[0] === "log") {
        console.log(JSON.stringify(await request("GET", "/api/queue"), null, 2));
      } else if (args[0] === "clear") {
        await command("build.queue.clear", {});
      } else {
        await command("build.queue.status", {});
      }
    } else if (cmd === "raw") {
      await command(args[0], args[1] ? JSON.parse(args[1]) : {});
    } else if (cmd === "inspect") {
      await command("instance.query", { path: args[0], properties: args[1] ? args[1].split(",") : undefined });
    } else if (cmd === "eval") {
      // node cli.js eval '<luau>'   or   node cli.js eval --file probe.lua
      const code = args[0] === "--file" ? fs.readFileSync(args[1], "utf8") : args[0];
      await command("studio.eval", { code });
    } else if (cmd === "find") {
      await command("instance.find", { by: args[0], value: args[1] });
    } else if (cmd === "create") {
      await command("instance.create", { className: args[0], parent: args[1], name: args[2], properties: args[3] ? JSON.parse(args[3]) : {} });
    } else if (cmd === "delete") {
      await command("instance.delete", { path: args[0], confirm: args.includes("--confirm") });
    } else if (cmd === "rename") {
      await command("instance.rename", { path: args[0], name: args[1] });
    } else if (cmd === "move") {
      await command("instance.move", { path: args[0], newParent: args[1] });
    } else if (cmd === "select") {
      await command("selection.set", { paths: args });
    } else if (cmd === "script.read") {
      await command("script.read", { path: args[0] });
    } else if (cmd === "script.write") {
      await command("script.write", { path: args[0], source: fs.readFileSync(args[1], "utf8") });
    } else if (cmd === "script.create") {
      await command("script.create", { className: args[0], parent: args[1], name: args[2], source: fs.readFileSync(args[3], "utf8") });
    } else if (cmd === "search") {
      await command("script.search", { text: args.join(" ") });
    } else if (cmd === "sync.push") {
      const manifest = JSON.parse(fs.readFileSync(args[0], "utf8"));
      await command("sync.push", {
        files: manifest.map((m) => ({ path: m.path, source: fs.readFileSync(m.file, "utf8") })),
      });
    } else if (cmd === "sync.pull") {
      await command("sync.pull", { paths: args });
    } else if (cmd === "overlap") {
      // What already stands where this box would go: the query that stops a prop being built inside
      // a wall, which is the defect a geometry build is most often finished with and never shipped.
      const { positionals, flags } = parseOpts(args);
      const n = positionals.map(Number);
      if (n.length !== 6 || n.some((v) => !Number.isFinite(v))) {
        throw new Error("usage: node cli.js overlap <x> <y> <z> <sx> <sy> <sz> [--exclude a,b] [--limit n]");
      }
      await command("space.overlap", { position: n.slice(0, 3), size: n.slice(3, 6), exclude: flags.exclude, limit: flags.limit });
    } else if (cmd === "check") {
      // Dry-run the whole plan: overlaps, floating parts, bad materials, non-finite sizes, before any
      // of it exists in the place.
      const { positionals, flags } = parseOpts(args);
      const plan = readPlan(positionals[0]);
      await command(
        "geometry.check",
        { items: plan.items, exclude: flags.exclude || plan.exclude, supportGap: flags.gap, support: !flags.noSupport },
        flags.full ? undefined : brief("items", badProblems)
      );
    } else if (cmd === "audit") {
      const { positionals, flags } = parseOpts(args);
      await command(
        "scene.audit",
        { root: positionals[0] || "Workspace", limit: flags.limit, minDim: flags.minDim, floating: flags.floating, exclude: flags.exclude },
        flags.full ? undefined : brief("rows", badProblems)
      );
    } else if (cmd === "probe") {
      // Ask this Studio build what it has, before generating code that reaches for it.
      const { positionals, flags } = parseOpts(args);
      const dotted = (spec, kind) => {
        const at = spec.indexOf(".");
        if (at < 1 || at === spec.length - 1) throw new Error(`${kind} probes need the form Name.member, got "${spec}"`);
        return { [kind]: spec.slice(0, at), name: spec.slice(at + 1) };
      };
      await command("capability.probe", {
        members: [
          ...positionals.map((s) => dotted(s, "class")),
          ...(flags.services || []).map((s) => dotted(s, "service")),
          ...(flags.enums || []).map((s) => dotted(s, "enum")),
        ],
        classes: flags.classes,
        materials: flags.materials,
      });
    } else if (cmd === "batch") {
      // Many instances, one command, and a failed build rolls itself back instead of leaving a ruin
      // that reads as two-thirds of a building.
      const { positionals, flags } = parseOpts(args);
      const plan = readPlan(positionals[0]);
      await command("instances.create", { items: plan.items, stopOnError: !flags.continueOnError }, flags.full ? undefined : brief("results", badBatchRow));
    } else if (cmd === "verify") {
      // Place vs disk without writing anything — the check an installer should run before it pushes.
      const { positionals, flags } = parseOpts(args);
      await command("sync.verify", { files: readManifest(positionals[0]) }, flags.full ? undefined : brief("results", badVerifyRow));
    } else if (cmd === "focus") {
      // Frame the thing about to be screenshot, so capture-studio.ps1 is looking at the work rather
      // than wherever the viewport happened to be.
      const { positionals, flags } = parseOpts(args);
      const n = positionals.map(Number);
      const byCoords = positionals.length === 3 || positionals.length === 6;
      if (byCoords && n.some((v) => !Number.isFinite(v))) throw new Error("focus coordinates must be numbers");
      if (!byCoords && !positionals[0]) throw new Error("usage: node cli.js focus <path> | focus <x> <y> <z> [sx sy sz] [--clear-selection]");
      const params = { clearSelection: flags.clearSelection };
      if (byCoords) {
        params.position = n.slice(0, 3);
        if (positionals.length === 6) params.size = n.slice(3, 6);
      } else {
        params.path = positionals[0];
      }
      await command("viewport.focus", params);
    } else {
      console.log("unknown command — see header comment in cli.js for usage");
      process.exitCode = 2;
    }
  } catch (e) {
    console.error("error:", e.message);
    process.exitCode = 1;
  }
})();
