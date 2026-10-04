// check-lua.js — compile a .lua file with the real Luau compiler inside Studio.
//
//   node check-lua.js <file.lua> [<file.lua> ...]
//   node check-lua.js --all [<dir>]        walks ../game-code unless <dir> is given
//
// There is no lua/luau interpreter on this machine, and node lua-balance.js only counts
// keywords — it passes a file with balanced ends and a call to a function that does not exist.
// The bridge plugin runs inside Studio, where `loadstring` is available, so it can hand back
// a genuine compile error with a real line number. Nothing is executed: only compiled.
//
// Costs one bridge round trip per file (~2 s at the plugin's 1 Hz poll), so this is cheap
// enough to run after every edit and far cheaper than finding the error in Play.

const fs = require("fs");
const path = require("path");
const { send, sleep } = require("./bridge-client");

const CODE = path.join(__dirname, "..", "game-code");
const SINK = "game.ServerStorage.__probe";

function collect(args) {
  if (args.includes("--all")) {
    const next = args[args.indexOf("--all") + 1];
    const dir = next && !next.startsWith("--") ? path.resolve(next) : CODE;
    if (!fs.existsSync(dir)) throw new Error(`no such folder to walk: ${dir}  (pass one: node check-lua.js --all ../my-lua)`);
    const out = [];
    const walk = (d) => {
      for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
        const full = path.join(d, entry.name);
        if (entry.isDirectory()) walk(full);
        else if (entry.name.endsWith(".lua")) out.push(full);
      }
    };
    walk(dir);
    return out;
  }
  return args.filter((a) => !a.startsWith("--"));
}

// Luau's long-bracket string needs a level that does not appear inside the payload.
function longBracket(src) {
  for (let level = 0; level < 12; level++) {
    const eq = "=".repeat(level);
    if (!src.includes("]" + eq + "]")) return { open: "[" + eq + "[", close: "]" + eq + "]" };
  }
  throw new Error("could not find a free long-bracket level");
}

(async () => {
  const files = collect(process.argv.slice(2));
  if (!files.length) {
    console.error("usage: node check-lua.js <file.lua> [...]   |   node check-lua.js --all");
    process.exitCode = 2;
    return;
  }

  let bad = 0;
  for (const file of files) {
    const src = fs.readFileSync(file, "utf8");
    const { open, close } = longBracket(src);
    const label = path.relative(CODE, file).replace(/\\/g, "/");

    const code = `
local src = ${open}
${src}
${close}
local sink = game.ServerStorage:FindFirstChild("__probe")
if not sink then
	sink = Instance.new("StringValue")
	sink.Name = "__probe"
	sink.Parent = game.ServerStorage
end
local fn, err = (loadstring or load)(src, ${JSON.stringify(label)})
if fn then sink.Value = "OK" else sink.Value = "COMPILE: " .. tostring(err) end
`;
    const ran = await send("studio.eval", { code });
    if (!ran.success) {
      console.log(`REFUSED  ${label}  ${JSON.stringify(ran.error)}`);
      bad++;
      continue;
    }
    await sleep(150);
    const out = await send("property.get", { path: SINK, property: "Value" });
    const value = (out.success && out.result && out.result.value) || "";
    if (value === "OK") {
      console.log(`ok       ${label}  ${src.length} bytes`);
    } else {
      bad++;
      console.log(`FAIL     ${label}`);
      console.log(`         ${value.replace(/\n/g, "\n         ")}`);
    }
  }
  console.log(bad ? `\n${bad} of ${files.length} did not compile.` : `\nall ${files.length} compile.`);
  if (bad) process.exitCode = 1;
})();
