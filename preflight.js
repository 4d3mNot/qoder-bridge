// preflight.js — can this run write to Studio right now, and if not, WHY?
//
//   node preflight.js        exit 0 = writable, exit 1 = blocked (with the cause and the fix)
//   node preflight.js --place 134588888780601   check a specific place instead of BUILD_STATE's
//
// Read-only, and it deliberately sends no command at all unless the plugin is already polling:
// queueing writes against a dead poll thread is the thing OVERNIGHT_PLAN forbids.
//
// It exists because `node cli.js status` answers only true/false, and four runs straight concluded
// "the other session's tab has focus, one click fixes it" — when on 2026-09-30 the real state was
// that the plugin had been UNLOADED at 02:02:51 UTC and no click whatsoever would bring it back.
// The evidence for the difference is in Studio's log, not in the bridge: the plugin prints
// "poll failed:" the instant its poll breaks, so total silence after an "Unloading plugin
// 'user_QoderBridge.lua'" line means it is not running at all.
//
// The second misdiagnosis, found at 05:19 UTC the same morning, was the opposite one and it cost the
// user a recommendation to quit Studio. `pluginConnected === false` covers TWO plugin states, and the
// log tells them apart:
//   "loadPlugin user_QoderBridge.lua … [dm=Edit]"      — the chunk is in memory, idle
//   "[QoderBridge] … bridge started on port 8346"      — its POLL LOOP is running
// Nothing auto-starts: startBridge() has exactly one caller, the Start button in the plugin's own dock
// widget (plugin/QoderBridge.lua:997), and that widget opens closed (DockWidgetPluginGuiInfo's
// preferredOpen is false). All four times the bridge came up tonight, a load line is followed 4-9 s
// later by a "bridge started" line — i.e. by a click. The 05:01:19 load has no click after it, so the
// fix then was one click in a panel, NOT a Studio restart. Prefer the cheap reversible fix and say so:
// restarting or quitting Studio is the one option that can throw away a place this project has never
// saved with Ctrl+S.
//
// Trap that hid this: Studio's own lines about the plugin ("Running plugin user_QoderBridge.lua",
// "Unloading plugin …") contain the word QoderBridge, so treating any such line as "the last line the
// plugin printed" made a plugin silent for 3 h look like one that had just spoken. Only a line the
// plugin wrote itself ([QoderBridge]) counts as its own output.
const fs = require("fs");
const path = require("path");
const { raw, send } = require("./bridge-client");

const ROOT = path.join(__dirname, "..");
const STATE = path.join(ROOT, "game-code", "BUILD_STATE.json");
const LOG_DIR = process.env.LOCALAPPDATA
  ? path.join(process.env.LOCALAPPDATA, "Roblox", "logs")
  : path.join(process.env.HOME || "", "AppData/Local/Roblox/logs");

const stamp = (line) => (line.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/) || [])[1] || "?";

function newestStudioLog() {
  if (!fs.existsSync(LOG_DIR)) return null;
  const files = fs
    .readdirSync(LOG_DIR)
    .filter((f) => f.endsWith("_Studio_*.log") || /_Studio_[0-9A-F]+_last\.log$/.test(f))
    .map((f) => ({ f, m: fs.statSync(path.join(LOG_DIR, f)).mtimeMs }))
    .sort((a, b) => b.m - a.m);
  return files.length ? { file: path.join(LOG_DIR, files[0].f), name: files[0].f, mtime: files[0].m } : null;
}

// The plugin events that tell the blocked states apart, plus the timeline they form. `events` exists
// because four separate "newest of each" scalars cannot be checked by eye — the order is the diagnosis.
function scanPluginLines(logPath) {
  const out = {
    loaded: null,
    started: null,
    unloaded: null,
    pollFailed: null,
    lastSelfLine: null,
    lastAboutLine: null,
    events: [],
    lines: 0,
  };
  const text = fs.readFileSync(logPath, "utf8");
  for (const line of text.split("\n")) {
    if (line.indexOf("QoderBridge") < 0) continue;
    out.lines++;
    // dm-tagged on purpose: Play clones the plugin into the Play DataModel, and a Play-mode load line
    // is not evidence that the EDIT place — the only one any push can write to — has it loaded.
    let kind = null;
    if (/loadPlugin user_QoderBridge\.lua.*\[dm=Edit/.test(line)) kind = "loaded";
    else if (/Unloading plugin 'user_QoderBridge\.lua'/.test(line)) kind = "unloaded";
    else if (/\[QoderBridge\].*bridge started on port/.test(line)) kind = "started";
    else if (/\[QoderBridge\].*poll failed/.test(line)) kind = "pollFailed";
    if (kind) {
      out[kind] = stamp(line);
      out.events.push({ at: stamp(line), kind });
    }
    const own = line.indexOf("[QoderBridge]");
    if (own >= 0) {
      out.lastSelfLine = { at: stamp(line), text: line.slice(own + 13).replace(/^\s+/, "").slice(0, 100) };
    }
    out.lastAboutLine = { at: stamp(line), text: line.slice(-110) };
  }
  out.events.sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
  return out;
}

(async () => {
  // BUILD_STATE.place is the place the LAST run wrote to, and this repo now holds two games plus a
  // scratch tab. `--place 134588888780601` therefore has to be allowed, or an Eclipse run reports a
  // false BLOCKED every time and people stop reading the exit code.
  const at = process.argv.indexOf("--place");
  const override = at >= 0 ? Number(process.argv[at + 1]) : null;
  // A copy of this repo without a game (a fresh install on another machine) has no BUILD_STATE.json,
  // and a checker that throws on the missing file is worse than one that reports the place it found.
  let wanted = Number.isFinite(override) ? override : null;
  let pinned = "--place";
  if (wanted === null && fs.existsSync(STATE)) {
    wanted = Number(JSON.parse(fs.readFileSync(STATE, "utf8")).place.placeId);
    pinned = "game-code/BUILD_STATE.json";
  }
  console.log(`game place this run writes to: ${Number.isFinite(wanted) ? wanted : "none pinned — reporting whatever place answers"} (${pinned})`);

  let status = null;
  try {
    status = (await raw("GET", "/api/status")).body;
  } catch (e) {
    console.log(`\nBLOCKED — the bridge server itself is not answering: ${e.message}`);
    console.log(`fix: cd ${__dirname} && node server.js`);
    process.exit(1);
  }
  const pluginUp = status && status.pluginConnected === true;
  console.log(`pluginConnected: ${pluginUp}  (last poll ${Math.round((status.pluginLastSeenMs || 0) / 1000)}s ago, reqCount ${status.reqCount})`);
  // Printed because a run otherwise cannot tell its own writes from another session's: reqCount counts
  // /api/command POSTs, and on 2026-09-30 05:03:54 it moved without this session sending anything.
  // queued/inFlight > 0 means a command is waiting on (or stuck to) a plugin that may never answer.
  console.log(`queued ${status.queued}  inFlight ${status.inFlight}  last command ${status.lastCommand ? `${status.lastCommand.command} at ${status.lastCommand.at}` : "none"}`);

  if (pluginUp) {
    // Only now is a command worth sending — the plugin is polling, so it will actually be answered.
    const s = await send("studio.status", {});
    const place = s.success && s.result ? Number(s.result.placeId) : null;
    if (place === wanted || (wanted === null && place !== 0)) {
      // `buildVersion` only exists on the plugin build that defers writes during Play Test, so its
      // presence is the cheapest possible version probe — and the answer below changes what a run
      // should DO about Play, not just whether it is allowed to.
      const queueing = s.result.buildVersion !== undefined;
      // v3 names itself (`pluginVersion`) and lists its verbs (`commands`), which is the difference
      // between "some queueing build" and "the build with geometry.check / instances.create". Without
      // it a v3 install and the enhanced build print the identical line, and a run can only discover
      // the gap by meeting an UNKNOWN_COMMAND mid-build.
      const named = s.result.pluginVersion ? `v${s.result.pluginVersion}` : queueing ? "enhanced" : "legacy";
      console.log(`plugin build: ${named}${queueing ? ` (buildVersion ${s.result.buildVersion})` : ""}  queueDuringPlay: ${s.result.queueDuringPlay === undefined ? "unknown" : s.result.queueDuringPlay}`);
      if (s.result.pluginVersion && s.result.commandCount) console.log(`  ${s.result.commandCount} verbs advertised by the plugin itself`);
      if (s.result.isPlaytest === true) {
        // Why this blocks even though the new plugin "handles" Play: a queued write is answered with
        // `{queued:true}` and applied only when the session ends, so every byte-verification this run
        // would do reads an acknowledgement instead of the place. Reporting "21 written, 0 differ"
        // from that response is how a build silently never lands.
        console.log(`\nBLOCKED for WRITES — a Play Test is RUNNING in this place (players ${s.result.playersInPlace}).`);
        if (queueing) {
          console.log("This plugin build queues every mutating command until Play ends, so an install run now would be");
          console.log("answered `{queued:true}` and could verify nothing — the byte check would read the acknowledgement,");
          console.log("not the place. Reads are still safe: node cli.js playtest | players | output | queue.");
          console.log("To build mid-session on purpose: push, then STOP Play, then re-run the verifier. Never trust the");
          console.log("queued answer itself.");
        } else {
          console.log("This plugin build has no Play Test queue, so a write now goes into the edit DataModel while Play");
          console.log("Solo is running on its own copy — it appears to succeed and the running game never sees it.");
          console.log("fix: stop the Play Test (Shift+F5), then run this again. Nothing is lost by stopping Play.");
        }
        process.exit(1);
      }
      console.log(`\nWRITABLE — Studio is answering for the game place (${place}).`);
      console.log(`next: read the place before you write it — node cli.js find class Model, node cli.js inspect Workspace.`);
      process.exit(0);
    }
    if (place === 0) {
      console.log(`\nBLOCKED — the plugin is polling for placeId 0 ("${s.result && s.result.placeName}"), which is a NEW, NEVER-SAVED PLACE, not a different game tab.`);
      console.log("This is what Studio focuses after an auto-update restart, so the game place may not be open at");
      console.log("all. Check RobloxStudio\\AutoSaves for a Template_*_AutoRecovery_*.rbxl: ~60 KB means an empty");
      console.log("place. Do not push scripts or geometry here, and do not rebuild yet — " +
        (Number.isFinite(wanted)
          ? `open the game place (placeId ${wanted}) from Roblox, or ask the user which tab holds it, then run this again.`
          : "open a real place with File → Open from Roblox, then run this again."));
      process.exit(1);
    }
    console.log(`\nBLOCKED — the plugin is polling, but for placeId ${place} ("${s.result && s.result.placeName}"), not the game.`);
    console.log("fix: click the game's tab so it has focus. Tab names lie; only the placeId above matters.");
    process.exit(1);
  }

  // Not polling. Decide between "unloaded" and "loaded but cannot reach the server".
  const log = newestStudioLog();
  if (!log) {
    console.log("\nBLOCKED — plugin is not polling and no Studio log was found to explain it.");
    console.log(`looked in ${LOG_DIR}`);
    process.exit(1);
  }
  const session = (log.name.match(/_(\d{8}T\d{6})Z_Studio_/) || [])[1] || "?";
  const p = scanPluginLines(log.file);
  const ageMin = Math.round((Date.now() - log.mtime) / 60000);
  const show = (v) => v || "never";
  console.log(`\nnewest log: ${log.name}`);
  console.log(`  Studio session started ~${session} UTC, log still written ${ageMin} min ago (Studio is ${ageMin < 5 ? "OPEN" : "quiet — possibly closed"})`);
  console.log(`  place loaded the plugin : ${show(p.loaded)}`);
  console.log(`  Start clicked (polling) : ${show(p.started)}`);
  console.log(`  plugin last unloaded    : ${show(p.unloaded)}`);
  console.log(`  last poll failure       : ${show(p.pollFailed)}`);
  console.log(`  plugin's own last line  : ${p.lastSelfLine ? `${p.lastSelfLine.at}  ${p.lastSelfLine.text}` : "the plugin never printed a line in this session"}`);
  console.log(`  line about it, newest   : ${p.lastAboutLine ? `${p.lastAboutLine.at}  ${p.lastAboutLine.text}` : "none"}`);
  console.log(`  timeline                : ${p.events.length ? p.events.slice(-6).map((e) => `${e.at} ${e.kind}`).join(" | ") : "no load/unload/start events in this log at all"}`);

  // Which blocked state? The order is the logic: is it in memory at all (last of load/unload is a
  // load), and only if so, did anything start polling after that load. Stamps are ISO to the second,
  // so plain string comparison is chronological.
  const loadedLast = !!p.loaded && (!p.unloaded || p.unloaded < p.loaded);
  const startedAfterLoad = !!(p.started && p.loaded && p.started >= p.loaded);

  if (!loadedLast) {
    console.log("\nBLOCKED — the QoderBridge plugin is NOT LOADED. Studio unloaded it and never loaded it");
    console.log("again, so there is nothing in memory to click; no panel toggle and no tab click can bring it");
    console.log("back. Only a fresh place DataModel loads a plugin. Cheapest-and-safest first, and nothing");
    console.log("here needs quitting Studio — this place has NEVER been saved with Ctrl+S tonight:");
    console.log("  1. Ctrl+S in Studio first, so every later step is safe;");
    console.log("  2. switch to the game's tab, or File → Open the GAME place (not the other tab); watch");
    console.log("     Studio's log print 'loadPlugin user_QoderBridge.lua … [dm=Edit]' — that alone is NOT");
    console.log("     connected: go on to 3;");
    console.log("  3. Plugins tab → Qoder Bridge → click \"Start Bridge\" (the token box keeps its saved value).");
    console.log("Then: node preflight.js again must print WRITABLE before any push.");
  } else if (!startedAfterLoad) {
    console.log("\nBLOCKED — the plugin IS LOADED (into the Edit DataModel at " + p.loaded + ") and simply");
    console.log("was never started. This is NOT a restart problem and Studio must stay open. The plugin has no");
    console.log("auto-start: its poll loop only begins when Start is clicked in the plugin's own panel, and");
    console.log("that panel opens closed. One click fixes this, in the game's tab:");
    console.log("  1. Studio's Plugins tab → the Qoder Bridge button — this opens the dock panel;");
    console.log("  2. check the port box reads 8346 and the token box is not empty (it remembers the token);");
    console.log("  3. click \"Start Bridge\". Status should read \"Connected (polling)\" and this script should then");
    console.log("     print WRITABLE — run it again to be sure, because the panel's own status is not proof");
    console.log("     of which PLACE it is polling for.");
    console.log("If that button instead prints \"ERROR: paste the token from bridge.token first\", that is the");
    console.log("only extra step:");
    console.log("copy bridge.token into the box and click Start Bridge again. Never paste the token into");
    console.log("a chat window or a script, and never print it here.");
  } else if (p.pollFailed && p.pollFailed >= p.started) {
    console.log("\nBLOCKED — the plugin is loaded and was started (" + p.started + "), but its poll is failing");
    console.log("(it prints \"poll failed:\"). The server answers locally, so this is Studio's side: the place");
    console.log("must allow HTTP requests (Game Settings → Security → Allow HTTP Requests), and the plugin in");
    console.log("%LOCALAPPDATA%\\Roblox\\Plugins must be the repo copy. Click \"Stop Bridge\" then \"Start Bridge\" to");
    console.log("retry once before changing anything.");
  } else {
    console.log("\nBLOCKED — the plugin loaded (" + p.loaded + ") and started (" + p.started + ") but stopped");
    console.log("polling WITHOUT ever printing \"poll failed:\", so its poll thread ended quietly. Click");
    console.log("\"Stop Bridge\" then \"Start Bridge\" in the Qoder Bridge panel. If it goes quiet again the Edit DataModel has to be");
    console.log("reloaded (save with Ctrl+S, then switch tabs or reopen the place) — and note the watchdog at");
    console.log("plugin/QoderBridge.lua:834 is supposed to restart a dead poll thread, so a silent stop here");
    console.log("is a plugin bug worth reading that function for, not a Studio-state problem.");
  }
  process.exit(1);
})();
