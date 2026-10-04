# Qoder Bridge

**Read `GET-STARTED.md` first** — it is the install walkthrough. This file is the reference: protocol,
every command, and the limits. It is written for the repository this copy came from, so a few names in
the setup and history paragraphs (`game-code/BUILD_STATE.json`, `capture-studio.ps1`,
`prove-plugin-handlers.js`, `restore-scripts.js`) belong to that repo and are not in this copy. What is
here is the plugin, `server.js`, `cli.js`, `bridge-client.js`, `preflight.js`, `check-lua.js`,
`start-bridge.bat` and `make-shortcut.ps1` — enough to run everything below.

A local bridge that lets an AI coding agent (Qoder) inspect and modify a live Roblox Studio place.

```
Qoder / CLI  →  local Node server (127.0.0.1)  →  Qoder Bridge plugin  →  Roblox Studio place
```

Plugins cannot listen on sockets in Luau, so the plugin **long-polls** the server for commands and POSTs results back. This is the same polling pattern commercial Studio plugins use, and it routes around nothing — it is ordinary `HttpService:RequestAsync` traffic to localhost, which the Plugin API permits.

## Files

| File | What |
|---|---|
| `plugin/QoderBridge.lua` | The Studio plugin that is **installed** (`%LOCALAPPDATA%\Roblox\Plugins\QoderBridge.lua`, byte-identical). This is the v3 build (`PLUGIN_VERSION = "3.0.1"`) |
| `plugin/QoderBridge.v3.lua` | The same v3 bytes under a versioned name — this is what `prove-plugin-handlers.js` slices and tests |
| `plugin/QoderBridge.legacy.lua` | The 2026-09-29 build, archived as the rollback. Copy it back over both files to undo v3 |
| `plugin/QoderBridge.enhanced.lua` | The user-supplied build v3 grew out of, kept for reference only — **not** an install target |
| `bridge-server/server.js` | Local command server (Node, zero dependencies) |
| `bridge-server/cli.js` | CLI + the API surface an agent calls |
| `bridge-server/bridge.token` | Auto-generated auth token (created on first run) |

Installing a plugin build means replacing the file in `%LOCALAPPDATA%\Roblox\Plugins` — one file
in, one out, never two `.lua` files there at once, because two live plugins would both poll the same
server and split the command queue between them. Studio only reads that folder at start-up, so it is
the user's action, and it has to follow Ctrl+S: this project's places have never been saved.

**v3 was installed by file swap on 2026-10-02 19:16 UTC** (legacy archived to
`%LOCALAPPDATA%\Roblox\plugin-backups\QoderBridge_20261002T191620Z_pre-v3.lua`), Studio was restarted
by the user, and `preflight.js` has since confirmed the **loaded** build is v3 — so the seven v3 verbs
below are callable, and `studio.eval` returns real values.

**The loaded build can be older than the file on disk.** Studio reads `%LOCALAPPDATA%\Roblox\Plugins`
only at start-up, so a later swap changes nothing until the next restart. As of 2026-10-02 19:31 UTC
the disk holds **3.0.1** (69,325 B, md5 `7b77698c2d2080d515cda1e55e1c9b2c` — the geometry.check fix
below) while the session still runs **3.0.0** (68,356 B, md5 `f5448649aa2b9545a90989d65e4236e6`,
backed up to `plugin-backups\QoderBridge_20261002T193149Z_pre-3.0.1.lua`). Read
`node preflight.js --place <placeId>` for what is *loaded*; never assume the file. Restarting Studio is
the user's action and must follow Ctrl+S.

Verify with `node cli.js raw studio.status '{}'`: a `pluginVersion` and a `commands` list mean v3, and
`pluginVersion` is the exact loaded number.

## Setup (one time)

1. **Install the plugin:** copy `plugin/QoderBridge.lua` to `%LOCALAPPDATA%\Roblox\Plugins` and restart Studio.
2. **Start the server:** `cd bridge-server && node server.js` (listens on 127.0.0.1:8346; prints the token and saves it to `bridge.token`).
3. **Connect Studio:** open the plugin panel (Plugins tab → Qoder Bridge → Bridge), paste the token, click **Start Bridge**. "Test Connection" verifies the round trip.

### Restarting it on a normal day

Double-click **Qoder Bridge** on the Desktop (or run `start-bridge.bat` in this folder — the Desktop
item is a shortcut to it, and `make-shortcut.ps1` recreates that shortcut on any Desktop). It starts
`bridge-server/server.js` in its own window and says so if a bridge is already listening instead of
failing with a stack trace. **Close that window and the bridge stops**, so keep it open while an
agent is working; the Studio side then reconnects to it by itself within a few seconds, and only
needs **Start Bridge** pressed again if Studio itself was restarted.

## Using it (agent or human)

```
node cli.js status
node cli.js inspect Workspace
node cli.js inspect Workspace Position,Size
node cli.js find class Part
node cli.js create Part Workspace TestPart '{"Anchored":true,"Size":{"__v3":[10,1,10]},"Position":{"__v3":[0,5,0]}}'
node cli.js script.create Script ServerScriptService GameManager src/game.luau
node cli.js script.read ServerScriptService.GameManager
node cli.js search "spawnLoop"
node cli.js delete Workspace.TestPart --confirm
node cli.js raw selection.set '{"paths":["Workspace.Baseplate"]}'
```

Build-accuracy verbs (plugin v3 — the loaded plugin must be v3; prove the handlers without
installing it via `node prove-plugin-handlers.js`):

```
node cli.js overlap 0 -4 0 60 60 60 --exclude Workspace.__Scaffold --limit 40
node cli.js check plan.json --gap 1.5            # plan.json = {"items":[{name,position,size,material}], "exclude":[]}
node cli.js audit Workspace.Map --min-dim 0.3 --floating
node cli.js probe Part.GetCamera --service Lighting.BatchRaycast --enum Material.Wood,Material.Bark
node cli.js batch plan.json                       # creates everything, or rolls the batch back
node cli.js verify push-manifest.json             # place vs disk, before pushing anything
node cli.js focus Workspace.Map --clear-selection # then: capture-studio.ps1
```

`check`/`audit`/`batch`/`verify` print tallies plus only the rows that complain; add `--full` for
every row.

`raw <command> '<json>'` reaches every command; everything else is sugar.

## Protocol

Request (CLI → server): `{ "command": "...", "parameters": { ... }, "timeout"? }`
Dispatched to plugin as: `{ "id": "<uuid>", "command": "...", "parameters": { ... } }`
Response: `{ "id": "...", "success": true, "result": {...} }` or `{ "id": "...", "success": false, "error": { "code": "...", "message": "..." } }`

### Value encoding

Roblox types are JSON-tagged: Vector3 `{"__v3":[x,y,z]}`, Vector2 `{"__v2":[x,y]}`, Color3 `{"__c3":[r,g,b]}` (0–1), CFrame `{"__cf":{"pos":[x,y,z],"rot":[yxz-euler]}}`, UDim2 `{"__udim2":[sx,ox,sy,oy]}`, UDim `{"__udim":[s,o]}`, Enum `{"__enum":"Enum.PartType.Block"}`, Instance refs return as `{"__instance":"Workspace.Foo"}`. Plain numbers/strings/bools pass through.

### Commands

| Command | Parameters | Notes |
|---|---|---|
| `studio.status` | — | place/game ids, editing state |
| `instance.query` | `path, properties?` | children (capped 200), attributes, tags |
| `instance.find` | `by("name"\|"class"), value, root?, limit?` | |
| `instance.create` | `className, parent, name?, properties?` | |
| `instance.clone` | `path, parent?` | |
| `instance.move` / `instance.rename` | `path, newParent` / `path, name` | |
| `instance.delete` | `path, confirm` | `confirm:true`; `confirm:"force"` needed for 100+ descendants |
| `property.get` / `property.set` | `path, property, value` | Parent/Source rejected — use dedicated commands |
| `attribute.set` | `path, name, value` | |
| `tag.add` / `tag.remove` | `path, tag` | |
| `selection.get` / `selection.set` | `paths` (empty = clear) | |
| `script.read` / `script.write` | `path[, source]` | via `ScriptEditorService:GetEditorSource` / `UpdateSourceAsync`, `.Source` fallback |
| `script.create` | `className, parent, name, source?` | via `ScriptEditorService:CreateScript`, fallback `Instance.new` |
| `script.search` | `text, root?` | scans up to 800 scripts |
| `sync.push` | `files:[{path,source,mode?}]` | mode `safe`(default)/`force`; never silent overwrite — returns `updated/unchanged/conflict/not_found` per file |
| `sync.pull` | `paths:[...]` | returns `{path, source}` for local files |
| `instance.identify` | `path, qoderId?` | **queueing build only** — stamps/reads a stable `QoderId` attribute, so a renamed or moved instance is still addressable |
| `playtest.status` | — | **queueing build only** — `running`, players, session start/end, queue length, `buildVersion` |
| `playtest.players` | — | **queueing build only** — live character position + health for every player in the session |
| `playtest.output` | `limit?` (≤200) | **queueing build only** — the tail of Studio's Output, captured via `LogService.MessageOut` |
| `build.queue.status` / `.clear` | — | **queueing build only** — what is deferred, or drop it |
| `build.version` | `increment?` | **queueing build only** — counter that moves once per applied batch |
| `space.overlap` | `position\|cframe, size, exclude?, limit?` | **v3** — what already stands in this box (`GetPartBoundsInBox` + `OverlapParams`); reports `excluded` and `unresolvedExclude` so a typo'd exclude path cannot read as "clear" |
| `geometry.check` | `items:[{name,position,size,rotation?,cframe?,material?}], exclude?, supportGap?, support?` | **v3** — dry-runs a whole build plan: overlaps, floating parts, unknown materials, non-finite numbers. Mutates nothing. From **3.0.1** every row gets *all* its verdicts — on 3.0.0 any earlier complaint (bad material or class) short-circuits the spatial queries, so a mis-materialled part inside a wall reports one problem and no collision. `malformed` counts footprints that cannot be judged (3.0.0 counts any row with two problems instead) |
| `capability.probe` | `members:[{class\|service\|enum, name}], classes?, materials?` | **v3** — asks *this* Studio build what it has, in one round trip, before generated code reaches for it |
| `scene.audit` | `root?, limit?, minDim?, floating?, exclude?` | **v3** — census of a subtree (class counts, flags, defect rows) instead of hundreds of `property.get` calls |
| `instances.create` | `items:[{parent,className,name?,properties?,qoderId?}], stopOnError?` | **v3** — many instances in one command; a failure rolls the batch back and rewrites its own rows, so nothing claims to exist |
| `sync.verify` | `files:[{path,source}]` | **v3** — place vs disk without writing, with `firstDiffByte`/`firstDiffLine` per mismatch |
| `viewport.focus` | `path \| position, size?, clearSelection?` | **v3** — frames the thing about to be screenshot, using a real world-space AABB walk (a Part has no `GetBoundingBox`) |

`studio.status` on v3 additionally returns `pluginVersion`, `commands` and `commandCount`, so a run can
check for a verb instead of discovering its absence through `UNKNOWN_COMMAND`.

### The Play Test queue (plugin ≥ "enhanced" build) and why a `queued` answer is not a result

`plugin/QoderBridge.enhanced.lua` detects a running Play Test and, for the 13 commands in its
`MUTATING` table (`studio.eval`, every `instance.*` write, `property.set`, `attribute.set`, tags,
`script.write/create`, `sync.push`), posts back `{queued:true}` immediately and applies the command
when the session ends. Read-only commands — including all three `playtest.*` ones — still answer at
once, which is what makes diagnosing a live session possible without pressing Stop.

The old plugin has no queue: a write during Play Solo lands in the edit DataModel while the running
game holds its own copy, so it reports `ok` and the game never sees it. `node preflight.js` now
reports which build is loaded and refuses writes in either case.

Two consequences a build run has to respect:

- **`{queued:true}` has `success:true`.** Anything that byte-verifies right after a push would be
  reading an acknowledgement, not the place. `cli.js` shouts `QUEUED, NOT APPLIED` when it sees one.
- **The real outcome arrives as a second POST under the same id**, with `phase:"queue_applied"`. The
  server keeps the last 100 of those (`GET /api/queue`, `node cli.js queue log`) since the original
  caller is long gone; the plugin's own `build.queue.status` remains the live truth.

Error codes: `INSTANCE_NOT_FOUND, INVALID_PATH, INVALID_CLASS, INVALID_PROPERTY, INVALID_ARGUMENT, CONFIRM_REQUIRED, PERMISSION_DENIED, UNSUPPORTED_OPERATION, UNKNOWN_COMMAND, EXECUTION_ERROR, TIMEOUT, authentication failed`.

## Security

- **127.0.0.1 only** — the server binds to localhost and nothing else.
- **Token auth** — random 32-hex token, required on every request (`x-bridge-token`), persisted in `bridge.token`; plugin stores its copy in plugin settings.
- **Command allowlist** — the plugin only executes the table above; unknown commands are refused before touching the DataModel.
- **Rate limiting** — 25 requests/sec on the server.
- **Body caps** — 2 MB requests, 200 children / 50 search results / 800 scripts scanned.
- **Malformed input can't crash the plugin** — every handler runs inside `pcall` and returns a structured error.

## Undo & safety

- Every mutating command is wrapped in `ChangeHistoryService:SetWaypoint(...)` before and after — **Ctrl+Z in Studio reverts any single bridge operation**.
- Deletes require explicit `confirm`, and refuse 100+ descendant subtrees without `confirm:"force"`.
- The plugin cannot create/modify other plugins, and never touches Studio settings beyond its own widget.

## Roblox API limitations (documented, not bypassed)

- **No play-mode control:** plugins can't press Play or script a test session. Closest workflow: edit-mode commands + the human presses F5; if a place's own scripts report errors to the bridge (e.g. via HttpService in-game with HTTP enabled), those can be collected too.
- **No Output-panel reading:** plugin APIs don't expose the Output log. Errors surface through command results instead.
- **No publishing / website actions:** Dev Products, game passes, thumbnails, publishing stay manual in Studio/browser (or Roblox CLI tooling outside this bridge).
- **`Script.Source` writes:** direct writes are restricted on current Studio builds; the plugin uses `ScriptEditorService` (`CreateScript`/`GetEditorSource`/`UpdateSourceAsync`) with an `Instance.new`/`.Source` fallback for older builds.
- **DataModel access is edit-mode only** — while a playtest runs, the plugin sees the edit world, not the play world.

## File sync pattern (Rojo-lite)

Keep scripts locally (`src/ServerScriptService/GameManager.luau`), push/pull through the bridge:

```
node cli.js sync.pull ServerScriptService.MainServer   # save current to disk
# edit locally
node cli.js raw sync.push '[{"path":"ServerScriptService.MainServer","file":"..."}]'  # see manifest form below
```

`sync.push` via `raw`:
```
node cli.js raw sync.push '{"files":[{"path":"ServerScriptService.MainServer","source":"...file contents...","mode":"force"}]}'
```
Conflicts come back as `status:"conflict"` with byte counts on both sides — resolve deliberately, nothing is overwritten silently.
