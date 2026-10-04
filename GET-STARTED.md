# Qoder Bridge — setting it up on your machine

What it is:

```
your AI agent / CLI  →  local Node server (127.0.0.1:8346)  →  Studio plugin  →  the place open in Studio
```

The server holds a queue of commands; the plugin long-polls it and POSTs results back. Everything stays
on your own machine — nothing is hosted, no account, no internet traffic.

Five files, no install step:

| File | What |
|---|---|
| `plugin/QoderBridge.lua` | the Studio plugin (one self-contained file) |
| `bridge-server/server.js` | the local command server |
| `bridge-server/cli.js` | the commands, one per line, for a human or an agent |
| `bridge-server/preflight.js` | answers "can I write to Studio right now, and if not, why?" |
| `bridge-server/check-lua.js` | compiles a `.lua` file with the real Luau compiler inside Studio |

## Setup (once)

1. **Install Node.js** (nodejs.org, LTS or newer). Check: open a new terminal and run `node -v`.
   There is nothing to `npm install` — the server uses only Node's built-in modules.

2. **Install the plugin.** Copy `plugin\QoderBridge.lua` to:
   - Windows: `%LOCALAPPDATA%\Roblox\Plugins` (create the `Plugins` folder if it is not there)
   - macOS: `~/Library/Application Support/Roblox/Plugins`

   **That folder must hold exactly one copy of this plugin.** Two `.lua` files there means two live
   plugins polling the same server, and they split the command queue between them — half your writes
   land and half vanish, with no error. If you installed it before, replace the file, don't add one.

3. **Fully quit Roblox Studio and open it again.** Studio reads the Plugins folder only at start-up, so
   a file you just copied is invisible until the next launch. Save your place first (`Ctrl+S`) — see the
   warning at the bottom, it is the one thing that can cost you work.

4. **Start the server.** Open a terminal in this folder and run:

   ```
   cd bridge-server
   node server.js
   ```

   (`start-bridge.bat` does the same thing by double-clicking, but a downloaded `.bat` is what SmartScreen
   warns about — see the section below.) The first run prints a line like:

   ```
   Token: <32 hex characters>  (also in bridge.token)
   ```

   and creates `bridge.token` next to it. **That token is generated on your machine — never copy
   anyone else's `bridge.token`, and don't send yours to anyone.** Keep this window open; closing it
   stops the bridge.

5. **Connect Studio.** In Studio: **Plugins tab → Qoder Bridge**. In the panel set Port `8346`, paste
   the token into the **Token** box, then click **Start Bridge**. `Test Connection` checks the round trip.
   No Game Settings switch is needed — the "Allow HTTP Requests" option applies to place scripts, not to
   plugins, and a plugin may always talk to localhost.

6. **Verify it from the terminal:**

   ```
   cd bridge-server
   node preflight.js
   ```

   `WRITABLE — Studio is answering for the game place (<placeId>)` means you are done. Exit code 1 means
   blocked, and the output names the state and the fix. Read it rather than guessing: the blocked cases
   look similar and have different cures.

## If Windows says SmartScreen prevented it (Akıllı Ekran / "Windows protected your PC")

SmartScreen isn't calling this malware — it's a reputation check, and an unsigned `.bat` that arrived in a
downloaded zip has no reputation. Cheapest fix first, and none of them touch a security setting:

1. **Type the command instead of double-clicking it.** This is the real cure:

   ```
   cd <where you unzipped this>\bridge-server
   node server.js
   ```

   SmartScreen only gates what you launch by double-clicking. A `node` command you run yourself is just
   Node, which is signed, so nothing is blocked and the bridge starts identically.
2. **"More info" → "Run anyway"** on the SmartScreen page — a one-time, per-file choice, after which
   `start-bridge.bat` launches normally.
3. **Unblock the folder** if you'd rather not click through anything:

   ```
   powershell -ExecutionPolicy Bypass -File motw-check.ps1 -Path . -Unblock
   ```

   Windows stamps every file inside a downloaded zip as "from the internet"; that stamp is what triggers
   the warning, and this clears it. Run it without `-Unblock` to just list what's flagged. It exits 2 if
   the path doesn't exist or contains no files, because a scan of a folder it never read must not print
   "all clean" — which is how the first version of this script lied to me.

Don't disable SmartScreen or Defender for this, and don't add exclusions. If **Node itself** is blocked (the
installer won't run, or `node -v` refuses), that's a different problem from a blocked `.bat` — on a managed
or work machine an app-control policy is deliberate, so raise it with whoever owns that machine rather than
working around it.

Two things that look like SmartScreen but aren't:

- **The server window appears and disappears instantly** — `server.js` exited, it wasn't blocked. Run it from
  an already-open terminal (option 1) so you can read the error line.
- **`'node' is not recognized`** — Node isn't installed, or the terminal predates installing it. Open a new
  terminal; `node -v` must print a version. There is nothing to `npm install` — the server uses only Node's
  built-in modules and there is no `package.json` in this copy.

## A normal day

1. Start the server: `cd bridge-server` then `node server.js` (or double-click `start-bridge.bat`, which
   also tells you a bridge is already listening instead of crashing).
2. In Studio, click **Start Bridge** if the panel is idle.
3. `node preflight.js` → WRITABLE, then use `cli.js`.

The server window is the bridge: close it and Studio's panel goes quiet. Restarting Studio also needs
another **Start Bridge** click — nothing auto-starts, and a plugin that is *loaded* but not *polling*
looks exactly like a broken bridge from the outside.

## Using it

```
node cli.js status                         # is the plugin polling?
node cli.js inspect Workspace              # what is in the place
node cli.js find class Model
node cli.js create Part Workspace TestPart '{"Anchored":true,"Size":{"__v3":[10,1,10]},"Position":{"__v3":[0,5,0]}}'
node cli.js script.read ServerScriptService.GameManager
node cli.js script.create Script ServerScriptService GameManager src/game.luau
node cli.js delete Workspace.TestPart --confirm
node cli.js raw studio.eval '{"code":"return 1+1"}'
node check-lua.js --all ../some-lua-folder
```

`README.md` has the full verb list, including the v3 build-accuracy verbs (`overlap`, `check`, `audit`,
`probe`, `batch`, `verify`, `focus`).

## Three things that will otherwise confuse you

- **The bridge writes to whichever Studio tab has focus**, and the tab's *label* is not an identity — if
  you have several places open, confirm the placeId `preflight.js` prints before a big run.
- **The bridge cannot save.** It edits the place in Studio's memory; nothing reaches Roblox's cloud until
  you press `Ctrl+S` (or publish) yourself. Which leads to:
- **Never restart or close Studio to "fix" the bridge** while you have unsaved work — 99% of bridge
  problems are a stopped server window or an un-clicked **Start Bridge**, both of which are free to undo.
  A place that was never saved is not.
