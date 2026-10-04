-- Qoder Bridge — Roblox Studio plugin.
-- Long-polls a local Node server for JSON commands, executes them against the
-- open place with PluginSecurity privileges, and posts structured results back.
--
-- Install: copy this file to %LOCALAPPDATA%\Roblox\Plugins, restart Studio.
-- Start the server first: node bridge-server/server.js, then Start Bridge here.
--
-- Sections: [1] services/state  [2] value codec  [3] path resolver
--           [4] handlers        [4b] build-accuracy handlers
--           [5] router       [6] network poll loop
--           [7] widget UI      [8] toolbar wiring

-- ============ [1] services & state ============
local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local LogService = game:GetService("LogService")

-- The build's own version: a run that needs a verb can check this instead of
-- discovering its absence through an UNKNOWN_COMMAND timeout.
local PLUGIN_VERSION = "3.0.1"

local SCRIPT_EDITOR = game:GetService("ScriptEditorService")

local state = {
	active = false,
	requestCount = 0,
	lastCommand = "none",
	log = {},
	pollThread = nil,
	lastPollError = nil,
	playtest = {
		running = false,
		startedAt = nil,
		lastEndedAt = nil,
	},
	mutationQueue = {},
	queueEnabled = plugin:GetSetting("queueDuringPlay", true) ~= false,
	queueApplying = false,
	buildVersion = tonumber(plugin:GetSetting("buildVersion", 0)) or 0,
	recentOutput = {},
}

local settings = {
	port = plugin:GetSetting("port", 8346),
	token = plugin:GetSetting("token", ""),
}
-- a previously stored nil beats GetSetting's default, so normalise here
if type(settings.port) ~= "number" then settings.port = 8346 end
if type(settings.token) ~= "string" then settings.token = "" end

local function addLog(msg)
	local line = os.date("%H:%M:%S") .. "  " .. msg
	table.insert(state.log, line)
	while #state.log > 15 do
		table.remove(state.log, 1)
	end
	-- also print, so the message lands in Studio's Output/log file and can be
	-- diagnosed from outside the panel
	print("[QoderBridge] " .. line)
end

-- Capture recent Studio output so Qoder can inspect Play Test failures without
-- needing to scrape the Output window. Keep this bounded to avoid memory growth.
pcall(function()
	LogService.MessageOut:Connect(function(message, messageType)
		table.insert(state.recentOutput, {
		time = os.time(),
		message = tostring(message),
		type = tostring(messageType),
		})
		while #state.recentOutput > 200 do
			table.remove(state.recentOutput, 1)
		end
	end)
end)

local function isPlaytestRunning()
	local ok, running = pcall(function()
		return RunService:IsRunning()
	end)
	return ok and running == true
end

local function refreshPlaytestState()
	local running = isPlaytestRunning()
	if running ~= state.playtest.running then
		state.playtest.running = running
		if running then
			state.playtest.startedAt = os.time()
			addLog("Play Test detected — mutation queue is " .. (state.queueEnabled and "enabled" or "disabled"))
		else
			state.playtest.lastEndedAt = os.time()
			addLog("Play Test ended")
		end
	end
	return running
end

local function currentPlayerCount()
	local ok, players = pcall(function()
		return #game:GetService("Players"):GetPlayers()
	end)
	return ok and players or 0
end

-- ============ [2] value codec (JSON <-> Roblox types) ============
local function pathOf(inst)
	local names = {}
	local node = inst
	while node and node ~= game do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	if node == game then
		table.insert(names, 1, "game")
	end
	return table.concat(names, ".")
end

local function serialize(value)
	local t = typeof(value)
	if t == "Vector3" then
		return { __v3 = { value.X, value.Y, value.Z } }
	elseif t == "Vector2" then
		return { __v2 = { value.X, value.Y } }
	elseif t == "Color3" then
		return { __c3 = { value.R, value.G, value.B } }
	elseif t == "CFrame" then
		-- `__cf12` is the frame itself: `GetComponents` yields the 12 matrix numbers and
		-- `CFrame.new(...)` accepts exactly those, so that round trip is bit-exact. `__cf` is kept
		-- beside it for callers that already speak position + euler; the euler form is the one that
		-- has to survive a rotation composed *before* a translation, and it does not always.
		local comps
		local okC = pcall(function()
			local c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12 = value:GetComponents()
			comps = { c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12 }
		end)
		-- some Studio builds have CFrame.Position but not :GetPosition(); try both
		local pos
		local okP, p = pcall(function()
			local q = value.Position
			return { q.X, q.Y, q.Z }
		end)
		if okP then
			pos = p
		else
			local okG, g = pcall(function()
				local x, y, z = value:GetPosition()
				return { x, y, z }
			end)
			if okG then pos = g end
		end
		local rot
		local okR, r = pcall(function()
			local x, y, z = value:ToEulerAnglesYXZ()
			return { x, y, z }
		end)
		if okR then rot = r end
		if okC then
			return { __cf = { pos = pos or { 0, 0, 0 }, rot = rot or { 0, 0, 0 } }, __cf12 = comps }
		end
		return { __cf = { pos = pos or { 0, 0, 0 }, rot = rot or { 0, 0, 0 } } }
	elseif t == "UDim2" then
		return { __udim2 = { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset } }
	elseif t == "UDim" then
		return { __udim = { value.Scale, value.Offset } }
	elseif t == "EnumItem" then
		return { __enum = tostring(value) }
	elseif t == "Instance" then
		return { __instance = pathOf(value) }
	elseif t == "function" or t == "userdata" then
		return { __unsupported = t }
	elseif t == "ColorSequence" or t == "NumberRange" or t == "Rect" or t == "NumberSequence" or t == "DateTime" or t == "BinaryString" then
		-- Anything this table misses comes back as JSON `null`, which is indistinguishable from a
		-- value that was never set. Naming the type is the difference between "no attribute" and
		-- "an attribute this transport cannot carry", and the second one is actionable.
		return { __unsupported = t }
	end
	return value
end

local function deserialize(value)
	if typeof(value) ~= "table" then
		return value
	end
	if value.__v3 then
		return Vector3.new(value.__v3[1], value.__v3[2], value.__v3[3])
	elseif value.__v2 then
		return Vector2.new(value.__v2[1], value.__v2[2])
	elseif value.__c3 then
		return Color3.new(value.__c3[1], value.__c3[2], value.__c3[3])
	elseif value.__cf12 then
		-- Checked before __cf on purpose: a v3 plugin sends both, and the matrix is the exact one.
		local m = value.__cf12
		return CFrame.new(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12])
	elseif value.__cf then
		local p = value.__cf.pos
		local r = value.__cf.rot or { 0, 0, 0 }
		return CFrame.new(p[1], p[2], p[3]) * CFrame.Angles(r[1], r[2], r[3])
	elseif value.__udim2 then
		local u = value.__udim2
		return UDim2.new(u[1], u[2], u[3], u[4])
	elseif value.__udim then
		return UDim.new(value.__udim[1], value.__udim[2])
	elseif value.__enum then
		local a, b, c = value.__enum:match("^(%w+)%.([%w_]+)%.([%w_]+)$")
		if a == "Enum" and b and c then
			local e = Enum[b]
			if e then
				return e[c]
			end
		end
		return nil
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deserialize(v)
	end
	return out
end

-- `GetAttributes()` returns a plain map of engine values, and `JSONEncode` renders every value it
-- does not understand as `null` — measured on this build: a Vector3, a CFrame and a Color3 attribute
-- all came back `{"Offset":null,"Where":null,"Tint":null}` while the string and bool survived. That
-- is why markers have been carried as invisible Parts with a string `Kind` and a separately read
-- position: the attribute was there and unreadable, not missing. Serialising the map is the fix, and
-- every handler that returns attributes goes through here so none of them re-introduce the null.
local function serializeMap(map)
	local out = {}
	for k, v in pairs(map or {}) do
		out[tostring(k)] = serialize(v)
	end
	return out
end

-- ============ [3] path resolver ============
local BridgeError = {}
BridgeError.__index = BridgeError
local function bridgeError(code, message)
	return setmetatable({ code = code, message = message }, BridgeError)
end

local function resolvePath(p)
	if type(p) ~= "string" or p == "" then
		return nil, bridgeError("INVALID_PATH", "path must be a non-empty string like 'Workspace.Map.Part'")
	end
	local root = game
	local first = p:match("^([^%.]+)")
	if first == "game" then
		p = p:sub(6)
		if p:match("^%.") then
			p = p:sub(2)
		end
		if p == "" then
			return game
		end
	end
	local node = root
	for seg in p:gmatch("[^%.]+") do
		node = node:FindFirstChild(seg)
		if not node then
			return nil, bridgeError("INSTANCE_NOT_FOUND", "no instance at path: " .. p .. " (failed at '" .. seg .. "')")
		end
	end
	return node
end

local CHILD_LIMIT = 200

-- ============ [4] handlers ============
local handlers = {}

-- Derived from the handler table itself, so the advertised surface can never
-- drift from the real one the way a hand-maintained list would.
local function commandNames()
	local names = {}
	for name in pairs(handlers) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

handlers["studio.status"] = function()
	local editing = nil
	pcall(function()
		editing = RunService:IsEditing()
	end)
	local running = refreshPlaytestState()
	return {
		placeName = game.Name,
		gameId = game.GameId,
		placeId = game.PlaceId,
		isEditing = editing,
		isPlaytest = running,
		playersInPlace = currentPlayerCount(),
		bridgeRequestsHandled = state.requestCount,
		queuedMutations = #state.mutationQueue,
		queueDuringPlay = state.queueEnabled,
		buildVersion = state.buildVersion,
		pluginVersion = PLUGIN_VERSION,
		commands = commandNames(),
		commandCount = #commandNames(),
	}
end

handlers["playtest.status"] = function()
	local running = refreshPlaytestState()
	return {
		running = running,
		players = currentPlayerCount(),
		startedAt = state.playtest.startedAt,
		lastEndedAt = state.playtest.lastEndedAt,
		queuedMutations = #state.mutationQueue,
		queueDuringPlay = state.queueEnabled,
		buildVersion = state.buildVersion,
	}
end

handlers["playtest.output"] = function(params)
	local limit = math.clamp(tonumber(params.limit) or 50, 1, 200)
	local start = math.max(1, #state.recentOutput - limit + 1)
	local out = {}
	for i = start, #state.recentOutput do
		table.insert(out, state.recentOutput[i])
	end
	return { running = refreshPlaytestState(), entries = out, count = #out }
end

handlers["playtest.players"] = function()
	local Players = game:GetService("Players")
	local players = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local entry = { name = player.Name, displayName = player.DisplayName, userId = player.UserId }
		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if root then
				entry.position = { root.Position.X, root.Position.Y, root.Position.Z }
			end
			if humanoid then
				entry.health = humanoid.Health
				entry.maxHealth = humanoid.MaxHealth
			end
		end
		table.insert(players, entry)
	end
	return { running = refreshPlaytestState(), players = players, count = #players }
end

handlers["build.queue.status"] = function()
	local items = {}
	for i, item in ipairs(state.mutationQueue) do
		items[i] = {
			index = i,
			id = item.id,
			command = item.command,
			queuedAt = item.queuedAt,
		}
	end
	return {
		count = #items,
		items = items,
		queueDuringPlay = state.queueEnabled,
		buildVersion = state.buildVersion,
	}
end

handlers["build.queue.clear"] = function()
	local count = #state.mutationQueue
	state.mutationQueue = {}
	addLog("cleared " .. count .. " queued mutation(s)")
	return { cleared = count }
end

handlers["build.version"] = function(params)
	if params.increment == true then
		state.buildVersion += 1
		plugin:SetSetting("buildVersion", state.buildVersion)
	end
	return { buildVersion = state.buildVersion }
end

-- Runs a short Luau snippet in the plugin's own (edit-mode) context and returns
-- its values. This is the only way to learn which members THIS Studio build has
-- without pressing Play. Keep snippets short and loop-free: they run on Studio's
-- main thread, so a while-loop here freezes the editor.
handlers["studio.eval"] = function(params)
	local code = params.code
	if type(code) ~= "string" or code == "" then
		return nil, bridgeError("INVALID_ARGUMENT", "code must be a non-empty string")
	end
	local loader = loadstring or load
	if typeof(loader) ~= "function" then
		return nil, bridgeError("UNSUPPORTED", "loadstring/load is not available on this build")
	end
	local chunk, compileErr = loader(code)
	if not chunk then
		return nil, bridgeError("COMPILE_ERROR", tostring(compileErr))
	end
	local values = {}
	-- `table.pack`, not `{ chunk() }`: the brace form relies on `n` being set by the constructor, and
	-- when it is not, `for i = 1, packed.n` throws `invalid 'for' limit` AFTER the chunk has already
	-- run. That is the worst possible shape for this verb — the side effects land and the answer is
	-- lost, so every probe ever written against it had to hide its result in a StringValue and be
	-- read back with a second command. `table.pack` always sets `n`.
	local ok, err = pcall(function()
		local packed = table.pack(chunk())
		for i = 1, packed.n do
			values[i] = serialize(packed[i])
		end
	end)
	return {
		values = values,
		valueCount = #values,
		errored = ok == false,
		error = ok and nil or tostring(err),
	}
end

handlers["instance.query"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	local children = {}
	local childCount = #inst:GetChildren()
	local truncated = false
	for i, child in ipairs(inst:GetChildren()) do
		if i > CHILD_LIMIT then
			-- A `{truncated=true}` row used to be the only signal, and it arrived as one more nameless
			-- child in the list — so a caller counting children read 201 and could not tell a cap from a
			-- part. A sibling boolean cannot be mistaken for an instance.
			truncated = true
			break
		end
		table.insert(children, { name = child.Name, className = child.ClassName })
	end
	local result = {
		name = inst.Name,
		path = pathOf(inst),
		className = inst.ClassName,
		qoderId = inst:GetAttribute("QoderId"),
		children = children,
		childCount = childCount,
		truncated = truncated,
		attributes = serializeMap(inst:GetAttributes()),
		tags = { CollectionService:GetTags(inst) },
	}
	local okPivot, pivot = pcall(function()
		return inst:GetPivot()
	end)
	if okPivot then
		result.pivot = serialize(pivot)
	end
	if params.countDescendants then
		-- Bounded on purpose: `#GetDescendants()` on Workspace materialises the whole array, and a
		-- census is not worth freezing the editor for. `capped:true` says the number is a floor.
		local cap = math.clamp(tonumber(params.countDescendants) or 2000, 1, 20000)
		local n = 0
		local capped = false
		local function walk(node)
			for _, c in ipairs(node:GetChildren()) do
				if n >= cap then
					capped = true
					return
				end
				n += 1
				walk(c)
			end
		end
		walk(inst)
		result.descendantCount = n
		result.descendantsCapped = capped
	end
	if params.properties then
		result.properties = {}
		for _, propName in ipairs(params.properties) do
			local ok, value = pcall(function()
				return inst[propName]
			end)
			result.properties[propName] = ok and serialize(value) or { __error = "unreadable" }
		end
	end
	return result
end

handlers["instance.find"] = function(params)
	local by = params.by or "name"
	local value = params.value
	local root = params.root and resolvePath(params.root) or workspace
	local limit = params.limit or 50
	local found = {}
	local ok, err = pcall(function()
		for _, inst in ipairs(root:GetDescendants()) do
			if #found >= limit then
				break
			end
			if by == "class" and inst.ClassName == value then
				table.insert(found, { path = pathOf(inst), className = inst.ClassName })
			elseif by == "name" and inst.Name == value then
				table.insert(found, { path = pathOf(inst), className = inst.ClassName })
			end
		end
	end)
	if not ok then
		return nil, bridgeError("INVALID_PATH", tostring(err))
	end
	return { matches = found, count = #found }
end

local function makeQoderId(prefix)
	local guid = HttpService:GenerateGUID(false):gsub("-", ""):sub(1, 12)
	return (prefix or "inst") .. "_" .. guid
end

local function ensureQoderId(inst, requested)
	local existing = inst:GetAttribute("QoderId")
	if type(existing) == "string" and existing ~= "" then
		return existing
	end
	local id = requested or makeQoderId(string.lower(inst.ClassName))
	inst:SetAttribute("QoderId", id)
	return id
end

handlers["instance.identify"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then return nil, err end
	return { path = pathOf(inst), qoderId = ensureQoderId(inst, params.qoderId) }
end

handlers["instance.create"] = function(params)
	local parent, err = resolvePath(params.parent)
	if not parent then
		return nil, err
	end
	local ok, inst = pcall(Instance.new, params.className)
	if not ok then
		return nil, bridgeError("INVALID_CLASS", "cannot create class: " .. tostring(params.className))
	end
	inst.Name = params.name or inst.Name
	if params.properties then
		for propName, value in pairs(params.properties) do
			if propName == "Parent" or propName == "Source" then
				inst:Destroy()
				return nil, bridgeError("INVALID_PROPERTY", "use instance.move / script.write for Parent and Source")
			end
			local setOk, setErr = pcall(function()
				inst[propName] = deserialize(value)
			end)
			if not setOk then
				inst:Destroy()
				return nil, bridgeError("INVALID_PROPERTY", "could not set " .. propName .. ": " .. tostring(setErr))
			end
		end
	end
	inst.Parent = parent
	local qoderId = ensureQoderId(inst, params.qoderId)
	return { path = pathOf(inst), className = inst.ClassName, qoderId = qoderId }
end

handlers["instance.delete"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst or inst == game then
		return nil, err or bridgeError("INVALID_PATH", "cannot delete the DataModel root")
	end
	if params.confirm ~= true and params.confirm ~= "force" then
		return nil, bridgeError("CONFIRM_REQUIRED", "delete requires parameters.confirm = true (or 'force' for big subtrees)")
	end
	local count = 0
	for _ in ipairs(inst:GetDescendants()) do
		count += 1
		if count > 100 and params.confirm ~= "force" then
			return nil, bridgeError("CONFIRM_REQUIRED", "instance has 100+ descendants; pass confirm='force' to delete anyway")
		end
	end
	local deletedPath = pathOf(inst)
	inst:Destroy()
	return { deleted = deletedPath, descendantsRemoved = count }
end

handlers["instance.clone"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	local parent = params.parent and resolvePath(params.parent) or inst.Parent
	local copy = inst:Clone()
	copy.Parent = parent
	local qoderId = ensureQoderId(copy, params.qoderId)
	return { path = pathOf(copy), qoderId = qoderId }
end

handlers["instance.move"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	local parent, err2 = resolvePath(params.newParent)
	if not parent then
		return nil, err2
	end
	inst.Parent = parent
	return { path = pathOf(inst) }
end

handlers["instance.rename"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	if type(params.name) ~= "string" or params.name == "" then
		return nil, bridgeError("INVALID_ARGUMENT", "name must be a non-empty string")
	end
	inst.Name = params.name
	return { path = pathOf(inst) }
end

handlers["property.get"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	local ok, value = pcall(function()
		return inst[params.property]
	end)
	if not ok then
		return nil, bridgeError("INVALID_PROPERTY", "cannot read " .. tostring(params.property))
	end
	return { value = serialize(value) }
end

handlers["property.set"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	if params.property == "Parent" or params.property == "Source" then
		return nil, bridgeError("INVALID_PROPERTY", "use dedicated commands for Parent/Source")
	end
	local ok, setErr = pcall(function()
		inst[params.property] = deserialize(params.value)
	end)
	if not ok then
		return nil, bridgeError("INVALID_PROPERTY", "cannot set " .. tostring(params.property) .. ": " .. tostring(setErr))
	end
	return { path = pathOf(inst), property = params.property }
end

handlers["attribute.set"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	inst:SetAttribute(params.name, deserialize(params.value))
	return { path = pathOf(inst), name = params.name }
end

handlers["tag.add"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	CollectionService:AddTag(inst, params.tag)
	return { path = pathOf(inst), tag = params.tag }
end

handlers["tag.remove"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	CollectionService:RemoveTag(inst, params.tag)
	return { path = pathOf(inst), tag = params.tag }
end

handlers["selection.get"] = function()
	local result = {}
	for _, inst in ipairs(Selection:Get()) do
		table.insert(result, { path = pathOf(inst), className = inst.ClassName })
	end
	return { selected = result }
end

handlers["selection.set"] = function(params)
	local insts = {}
	for _, p in ipairs(params.paths or {}) do
		local inst, err = resolvePath(p)
		if not inst then
			return nil, err
		end
		table.insert(insts, inst)
	end
	Selection:Set(insts)
	return { count = #insts }
end

-- ---- script operations ----
-- Studio keeps renaming this API, so probe for whatever this build exposes.
local READ_APIS = { "GetEditorSource", "GetSource" }

local function available(names)
	local found = {}
	for _, name in ipairs(names) do
		-- indexing a Service with an unknown member THROWS, so probe through pcall
		local ok, fn = pcall(function()
			return SCRIPT_EDITOR[name]
		end)
		if ok and typeof(fn) == "function" then
			table.insert(found, name)
		end
	end
	return found
end

local function getScriptSource(scriptInst)
	for _, name in ipairs(available(READ_APIS)) do
		local ok, src = pcall(function()
			return SCRIPT_EDITOR[name](SCRIPT_EDITOR, scriptInst)
		end)
		if ok and typeof(src) == "string" then
			return src
		end
	end
	local ok, src = pcall(function()
		return scriptInst.Source
	end)
	if ok then
		return src
	end
	return nil
end

local function setScriptSource(scriptInst, source)
	local tried = {}

	local okEdit, edited = pcall(function()
		return SCRIPT_EDITOR:EditAsync(scriptInst, source)
	end)
	if okEdit and edited ~= false and getScriptSource(scriptInst) == source then
		return true, "EditAsync"
	end
	table.insert(tried, "EditAsync: " .. tostring(okEdit and "reported success but source unchanged" or edited))

	local okUpdate = pcall(function()
		SCRIPT_EDITOR:UpdateSourceAsync(scriptInst, function()
			return source
		end)
	end)
	if okUpdate and getScriptSource(scriptInst) == source then
		return true, "UpdateSourceAsync"
	end
	table.insert(tried, "UpdateSourceAsync: " .. tostring(okUpdate and "source unchanged" or "not available"))

	local okDirect = pcall(function()
		scriptInst.Source = source
	end)
	if okDirect and getScriptSource(scriptInst) == source then
		return true, "Source"
	end
	table.insert(tried, "Source: " .. tostring(okDirect and "source unchanged" or "not available"))

	return false, table.concat(tried, " | ")
end

-- Last resort when Studio refuses plugin script writes: drop the source on disk so
-- it can be pasted in by hand. Flattened name, no folder, because writefile cannot mkdir.
local function dumpToDisk(name, source)
	local leaf = tostring(name or "script"):gsub("[^%w_%-%.]", "_")
	local file = "qoder-bridge-" .. leaf .. ".lua"
	local ok, err = pcall(function()
		writefile(file, source)
	end)
	if not ok then
		return nil, tostring(err)
	end
	local abs
	pcall(function()
		if typeof(workspace.TranslateRelativePath) == "function" then
			abs = workspace:TranslateRelativePath(file)
		end
	end)
	return abs or file
end

handlers["script.read"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	if not inst:IsA("LuaSourceContainer") then
		return nil, bridgeError("UNSUPPORTED_OPERATION", "not a script: " .. inst.ClassName)
	end
	return { path = pathOf(inst), className = inst.ClassName, source = getScriptSource(inst) }
end

handlers["script.write"] = function(params)
	local inst, err = resolvePath(params.path)
	if not inst then
		return nil, err
	end
	if not inst:IsA("LuaSourceContainer") then
		return nil, bridgeError("UNSUPPORTED_OPERATION", "not a script: " .. inst.ClassName)
	end
	if type(params.source) ~= "string" then
		return nil, bridgeError("INVALID_ARGUMENT", "source must be a string")
	end
	local wrote, how = setScriptSource(inst, params.source)
	if not wrote then
		local file, dumpErr = dumpToDisk(inst.Name, params.source)
		return nil, bridgeError(
			"PERMISSION_DENIED",
			"Studio refused every script-write API. " .. how
				.. (file and (" | saved to " .. file .. " for manual paste") or (" | disk dump failed: " .. tostring(dumpErr)))
		)
	end
	-- `setScriptSource` already compares once, but it compares inside the same call that may have been
	-- served from a stale editor buffer, and an installer that trusts `usedApi` alone has to make its
	-- own second round trip to be sure. Reading back here costs one call the plugin was going to make
	-- anyway and moves the answer into the same response, so `match:false` is impossible to miss.
	local readBack = getScriptSource(inst)
	return {
		path = pathOf(inst),
		bytesWritten = #params.source,
		readBackBytes = readBack and #readBack or 0,
		match = readBack == params.source,
		usedApi = how,
	}
end

handlers["script.create"] = function(params)
	local parent, err = resolvePath(params.parent)
	if not parent then
		return nil, err
	end
	local className = params.className or "Script"
	local created
	local ok = pcall(function()
		created = SCRIPT_EDITOR:CreateScript(className, params.name or "Script", parent)
	end)
	if not ok or not created then
		local ok2, inst = pcall(Instance.new, className)
		if not ok2 then
			return nil, bridgeError("INVALID_CLASS", "cannot create script class: " .. className)
		end
		inst.Name = params.name or "Script"
		created = inst
	end
	created.Parent = parent
	local usedApi
	if params.source and params.source ~= "" then
		local wrote, how = setScriptSource(created, params.source)
		if not wrote then
			local file, dumpErr = dumpToDisk(created.Name, params.source)
			return {
				path = pathOf(created),
				className = created.ClassName,
				warning = "script exists but Studio refused the write" .. (file and (" | source saved to " .. file) or (" | " .. tostring(dumpErr))),
			}
		end
		usedApi = how
		local back = getScriptSource(created) or ""
		return {
			path = pathOf(created),
			className = created.ClassName,
			usedApi = usedApi,
			readBackBytes = #back,
			match = back == params.source,
		}
	end
	return { path = pathOf(created), className = created.ClassName, usedApi = usedApi }
end

handlers["script.search"] = function(params)
	local root = params.root and resolvePath(params.root) or game
	local needle = string.lower(params.text or "")
	if needle == "" then
		return nil, bridgeError("INVALID_ARGUMENT", "text is required")
	end
	local matches = {}
	local scanned = 0
	for _, inst in ipairs(root:GetDescendants()) do
		if inst:IsA("LuaSourceContainer") then
			scanned += 1
			if scanned > 800 then
				break
			end
			local src = getScriptSource(inst) or ""
			local lower = string.lower(src)
			local pos = string.find(lower, needle, 1, true)
			if pos then
				local lineNo = select(2, src:sub(1, pos):gsub("\n", "")) + 1
				table.insert(matches, { path = pathOf(inst), line = lineNo })
				if #matches >= 50 then
					break
				end
			end
		end
	end
	return { matches = matches, scriptsScanned = scanned }
end

-- ---- sync ----
-- files: [{path, source, mode}] mode: "force" | "safe" (default).
-- safe = conflict if existing source differs and non-empty; never silent overwrite.
handlers["sync.push"] = function(params)
	local results = {}
	local mismatches = 0
	for _, f in ipairs(params.files or {}) do
		local entry = { path = f.path }
		local inst = resolvePath(f.path)
		if typeof(inst) ~= "Instance" then
			entry.status = "not_found"
		elseif not inst:IsA("LuaSourceContainer") then
			entry.status = "not_a_script"
		elseif type(f.source) ~= "string" then
			entry.status = "invalid_source"
		else
			local current = getScriptSource(inst) or ""
			if current == f.source then
				entry.status = "unchanged"
			elseif current ~= "" and (f.mode or "safe") == "safe" then
				entry.status = "conflict"
				entry.currentBytes = #current
				entry.incomingBytes = #f.source
			else
				local wrote, how = setScriptSource(inst, f.source)
				entry.status = wrote and "updated" or "write_failed"
				entry.usedApi = wrote and how or nil
				if not wrote then
					entry.reason = how
					local file = dumpToDisk(inst.Name, f.source)
					entry.exportedTo = file
				else
					-- Studio accepts a script write and can still hold different bytes (an
					-- autocorrect pass, a write that landed on another instance). Reporting
					-- `updated` from the acknowledgement alone is how 21 "written" units turn
					-- out to be 21 unchanged ones, so the read-back is part of the answer.
					local back = getScriptSource(inst) or ""
					entry.readBackBytes = #back
					if back ~= f.source then
						entry.status = "wrote_but_differs"
						entry.incomingBytes = #f.source
						mismatches += 1
					end
				end
			end
		end
		table.insert(results, entry)
	end
	return {
		results = results,
		total = #results,
		mismatches = mismatches,
		allApplied = mismatches == 0,
	}
end

handlers["sync.pull"] = function(params)
	local files = {}
	for _, p in ipairs(params.paths or {}) do
		local inst, err = resolvePath(p)
		if inst and inst:IsA("LuaSourceContainer") then
			table.insert(files, { path = p, source = getScriptSource(inst) })
		else
			table.insert(files, { path = p, error = err and err.message or "not a script" })
		end
	end
	return { files = files }
end

-- ============ [4b] build-accuracy handlers (v3) ============
-- Everything above answers "what is in the place" one instance at a time. That is why a geometry
-- build costs hundreds of round trips, and why the mistakes it makes — a prop standing inside a wall,
-- a slab with no ground under it, a material name this build has never heard of — only surface
-- afterwards, in a screenshot or as a hole nobody notices. `Material.Bark` once made `instance.create`
-- fail for *only those parts* and the build came back looking complete.
--
-- The handlers here answer those questions BEFORE the write, in one call, against the real place.
-- They are read-only except `instances.create`, and none of them needs a Play session.

local function finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local MATERIAL_SET
local function materialOk(name)
	if type(name) ~= "string" or name == "" then
		return true
	end
	if not MATERIAL_SET then
		MATERIAL_SET = {}
		local ok, items = pcall(function()
			return Enum.Material:GetEnumItems()
		end)
		if ok then
			for _, item in ipairs(items) do
				MATERIAL_SET[item.Name] = true
			end
		end
	end
	return MATERIAL_SET[name] == true
end

-- A footprint as its caller described it: either a whole encoded CFrame, or a position with an
-- optional euler rotation. Both forms are accepted everywhere a box is, because a builder that has a
-- CFrame should not have to decompose it just to be told to send it back together again.
local function frameOf(item)
	if item.cframe then
		local ok, frame = pcall(deserialize, item.cframe)
		if ok and typeof(frame) == "CFrame" then
			return frame
		end
		return nil
	end
	local p = item.position
	if type(p) ~= "table" then
		return nil
	end
	local pos = Vector3.new(p[1] or p.x or 0, p[2] or p.y or 0, p[3] or p.z or 0)
	local r = item.rotation
	if type(r) == "table" then
		return CFrame.new(pos) * CFrame.Angles(r[1] or 0, r[2] or 0, r[3] or 0)
	end
	return CFrame.new(pos)
end

local function sizeOf(item)
	local s = item.size
	if type(s) ~= "table" then
		return nil
	end
	return Vector3.new(s[1] or s.x or 0, s[2] or s.y or 0, s[3] or s.z or 0)
end

-- The one filter shape every spatial query here wants: "the world, minus my own scaffolding".
--
-- Measured, because the name gives no hint: GetPartBoundsInBox rejects a RaycastParams outright
-- ("Unable to cast RaycastParams to OverlapParams") even though RaycastParams filters with the same
-- Enum.RaycastFilterType. These spatial calls take OverlapParams, so that is what is built here.
--
-- It also returns how many paths landed and which did not. A typo in `exclude` otherwise costs the
-- caller a false overlap verdict from a scaffold that was supposed to be filtered out.
local function buildFilter(excludePaths)
	local matched = 0
	local unresolved = {}
	local ok, filter = pcall(function()
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local list = {}
		for _, p in ipairs(excludePaths or {}) do
			local inst = resolvePath(p)
			if inst then
				list[#list + 1] = inst
				matched += 1
			else
				unresolved[#unresolved + 1] = tostring(p)
			end
		end
		params.FilterDescendantsInstances = list
		return params
	end)
	if not ok then
		return nil, 0, { "OverlapParams unavailable" }
	end
	return filter, matched, unresolved
end

local function rowFor(part)
	local ok, row = pcall(function()
		return {
			path = pathOf(part),
			className = part.ClassName,
			position = serialize(part.Position),
			size = serialize(part.Size),
			anchored = part.Anchored,
			material = part.Material.Name,
		}
	end)
	if ok then
		return row
	end
	return { path = pathOf(part) }
end

---What is already standing where this box would go.
handlers["space.overlap"] = function(params)
	local frame = frameOf(params)
	local size = sizeOf(params)
	if not frame then
		return nil, bridgeError("INVALID_ARGUMENT", "cframe or position [x,y,z] is required")
	end
	if not size then
		return nil, bridgeError("INVALID_ARGUMENT", "size [x,y,z] is required")
	end
	local filter, excluded, unresolved = buildFilter(params.exclude)
	local limit = math.clamp(tonumber(params.limit) or 40, 1, 200)
	local hits
	local ok, err = pcall(function()
		if filter then
			hits = workspace:GetPartBoundsInBox(frame, size, filter)
		else
			hits = workspace:GetPartBoundsInBox(frame, size)
		end
	end)
	if not ok then
		return nil, bridgeError("UNSUPPORTED_OPERATION", "GetPartBoundsInBox: " .. tostring(err))
	end
	local rows = {}
	for i, part in ipairs(hits) do
		if i > limit then
			break
		end
		rows[#rows + 1] = rowFor(part)
	end
	return {
		count = #hits,
		shown = #rows,
		truncated = #hits > limit,
		filtered = filter ~= nil,
		excluded = excluded,
		unresolvedExclude = unresolved,
		parts = rows,
	}
end

---Validate a whole build plan without writing a single instance.
---
-- This is the handler that exists because of the silent-hole failure: a bad material, a NaN size, a
-- prop inside its own wall or a slab with nothing under it are all cheap to detect before the build
-- and expensive to notice after it. Every item gets a verdict list; nothing here mutates.
handlers["geometry.check"] = function(params)
	local items = params.items
	if type(items) ~= "table" or #items == 0 then
		return nil, bridgeError("INVALID_ARGUMENT", "items must be a non-empty array of footprints")
	end
	local filter, excluded, unresolved = buildFilter(params.exclude)
	local supportGap = tonumber(params.supportGap) or 1.5
	local checkSupport = params.support ~= false
	local tally = { ok = 0, bad = 0, overlapping = 0, floating = 0, badMaterial = 0, malformed = 0, spatialFailed = 0 }
	local rows = {}
	for index, item in ipairs(items) do
		local problems = {}
		-- "malformed" means the FOOTPRINT cannot be judged at all, which is a different thing from a
		-- footprint that has two verdicts. It used to be inferred from `#problems > 1`, and once the
		-- spatial checks became additive that proxy started calling a mis-materialled part sitting in a
		-- wall a malformed row — so the counter stopped meaning anything a builder could act on.
		local geomBroken = false
		local frame = frameOf(item)
		local size = sizeOf(item)
		if not frame then
			problems[#problems + 1] = "no position/cframe"
			geomBroken = true
		end
		if not size then
			problems[#problems + 1] = "no size"
			geomBroken = true
		end
		if size then
			if not (finite(size.X) and finite(size.Y) and finite(size.Z)) then
				problems[#problems + 1] = "non-finite size"
				geomBroken = true
			elseif size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
				problems[#problems + 1] = "non-positive size"
				geomBroken = true
			end
		end
		if frame and not finite(frame.X) then
			problems[#problems + 1] = "non-finite position"
			geomBroken = true
		end
		if item.className and not pcall(Instance.new, item.className) then
			problems[#problems + 1] = "cannot create class " .. tostring(item.className)
		end
		if item.material and not materialOk(item.material) then
			problems[#problems + 1] = "no such material: " .. tostring(item.material)
			tally.badMaterial = tally.badMaterial + 1
		end
		-- Overlap and support are the two spatial verdicts, and both are one query each. The box is
		-- shrunk a hair so a part that merely TOUCHES its neighbour's face — the normal case for a
		-- wall meeting a floor — does not read as an intrusion.
		--
		-- This guard is about the GEOMETRY being evaluable, not about whether the row already has a
		-- complaint. It used to read `#problems == 0`, so a part with a material typo skipped these
		-- queries entirely and came back with one problem and no overlap verdict — the collision stayed
		-- hidden until the material was fixed and the plan re-run. Live-measured, not theoretical.
		local geomUsable = frame ~= nil and size ~= nil
			and finite(frame.X)
			and finite(size.X) and finite(size.Y) and finite(size.Z)
			and size.X > 0 and size.Y > 0 and size.Z > 0
		if geomUsable then
			local inner = size * 0.98
			local okHits, hitsOrErr = pcall(function()
				if filter then
					return workspace:GetPartBoundsInBox(frame, inner, filter)
				end
				return workspace:GetPartBoundsInBox(frame, inner)
			end)
			if not okHits then
				-- A swallowed spatial failure used to read as "nothing here", which is the one
				-- verdict a build plan must never be given by mistake. Name it instead.
				problems[#problems + 1] = "overlap query failed: " .. tostring(hitsOrErr):sub(1, 120)
				tally.spatialFailed = tally.spatialFailed + 1
			else
				local hits = hitsOrErr
				if #hits > 0 then
					problems[#problems + 1] = ("overlaps %d part(s), e.g. %s"):format(#hits, hits[1].Name)
					tally.overlapping = tally.overlapping + 1
				end
				if checkSupport and size.Y > 0 then
					local probeSize = Vector3.new(math.max(size.X * 0.6, 0.2), supportGap, math.max(size.Z * 0.6, 0.2))
					local probeFrame = frame * CFrame.new(0, -(size.Y / 2 + supportGap / 2), 0)
					local okBelow, belowOrErr = pcall(function()
						if filter then
							return workspace:GetPartBoundsInBox(probeFrame, probeSize, filter)
						end
						return workspace:GetPartBoundsInBox(probeFrame, probeSize)
					end)
					if not okBelow then
						problems[#problems + 1] = "support query failed: " .. tostring(belowOrErr):sub(1, 120)
						tally.spatialFailed = tally.spatialFailed + 1
					elseif #belowOrErr == 0 then
						problems[#problems + 1] = "nothing within " .. supportGap .. " studs below"
						tally.floating = tally.floating + 1
					end
				end
			end
		end
		if #problems == 0 then
			tally.ok = tally.ok + 1
		else
			tally.bad = tally.bad + 1
			if geomBroken then
				tally.malformed = tally.malformed + 1
			end
		end
		rows[#rows + 1] = {
			index = index,
			name = item.name or item.path or ("item " .. index),
			problems = problems,
		}
	end
	return {
		checked = #items,
		ok = tally.ok,
		bad = tally.bad,
		overlapping = tally.overlapping,
		floating = tally.floating,
		badMaterial = tally.badMaterial,
		malformed = tally.malformed,
		spatialFailed = tally.spatialFailed,
		filtered = filter ~= nil,
		excluded = excluded,
		unresolvedExclude = unresolved,
		items = rows,
	}
end

---Ask this Studio build what it has, in one round trip.
--
-- `members` entries are {class=|service=|enum=, name=}. Indexing an Instance or a service for a
-- member it lacks THROWS, so every probe here runs under pcall and reports a verdict instead of
-- ending the command. This is what stops a builder from discovering `RenderFidelity` at runtime,
-- three hundred parts into a run.
handlers["capability.probe"] = function(params)
	local report = {}
	for _, spec in ipairs(params.members or {}) do
		local label = tostring(spec.name or "?")
		local verdict = { name = label }
		if spec.enum then
			verdict.scope = "Enum." .. tostring(spec.enum)
			verdict.ok = pcall(function()
				local e = Enum[spec.enum]
				if not e then
					error("no such enum", 0)
				end
				local item = e[spec.name]
				if item == nil then
					error("no such item", 0)
				end
			end)
		elseif spec.service then
			verdict.scope = "service " .. tostring(spec.service)
			verdict.ok = pcall(function()
				local s = game:GetService(spec.service)
				if s[spec.name] == nil then
					error("absent", 0)
				end
			end)
		elseif spec.class then
			verdict.scope = "class " .. tostring(spec.class)
			verdict.ok = pcall(function()
				local inst = Instance.new(spec.class)
				local present = inst[spec.name] ~= nil
				inst:Destroy()
				if not present then
					error("absent", 0)
				end
			end)
		else
			verdict.scope = "unspecified"
			verdict.ok = false
		end
		report[#report + 1] = verdict
	end
	local classes = {}
	for _, name in ipairs(params.classes or {}) do
		local ok = pcall(Instance.new, name)
		classes[#classes + 1] = { name = name, creatable = ok }
	end
	local materials = {}
	for _, name in ipairs(params.materials or {}) do
		materials[#materials + 1] = { name = name, ok = materialOk(name) }
	end
	local enumCount
	pcall(function()
		enumCount = {
			Material = #Enum.Material:GetEnumItems(),
			Font = #Enum.Font:GetEnumItems(),
		}
	end)
	return { members = report, classes = classes, materials = materials, enums = enumCount }
end

---A census of a subtree in one command, with the defects named rather than eyeballed.
--
-- `get-scene.js` used to assemble this from hundreds of `property.get` calls at ~110 ms each, which
-- is why scene reviews were slow enough to skip. Rows are capped and the cap is reported as a field,
-- so a caller can never read "1500 rows" as "1500 parts".
handlers["scene.audit"] = function(params)
	local root, err = resolvePath(params.root or "Workspace")
	if not root then
		return nil, err
	end
	local limit = math.clamp(tonumber(params.limit) or 1500, 1, 8000)
	local minDim = tonumber(params.minDim) or 0.2
	local wantFloating = params.floating == true
	local byClass = {}
	local rows = {}
	local parts, models, scripts, other = 0, 0, 0, 0
	local flags = { unanchored = 0, nan = 0, thin = 0, floating = 0, invisible = 0 }
	local filter = buildFilter(params.exclude)
	local truncated = false
	-- The root counts as much as its descendants do: `scene.audit {root = "Workspace..Lamp"}` is a
	-- caller asking about one prop, and GetDescendants() alone answers zero parts about it.
	local nodes = { root }
	for _, d in ipairs(root:GetDescendants()) do
		nodes[#nodes + 1] = d
	end
	for _, inst in ipairs(nodes) do
		byClass[inst.ClassName] = (byClass[inst.ClassName] or 0) + 1
		if inst:IsA("BasePart") then
			parts = parts + 1
			local p, s = inst.Position, inst.Size
			local problems = {}
			-- Studio clamps a NaN written through a property, so this fires for values that arrived
			-- by another route (a script during Play, a damaged place file) — not for a bad plan,
			-- which is what geometry.check is for.
			if not (finite(p.X) and finite(p.Y) and finite(p.Z) and finite(s.X) and finite(s.Y) and finite(s.Z)) then
				problems[#problems + 1] = "nan"
				flags.nan = flags.nan + 1
			end
			if not inst.Anchored then
				problems[#problems + 1] = "unanchored"
				flags.unanchored = flags.unanchored + 1
			end
			if math.min(s.X, s.Y, s.Z) < minDim then
				problems[#problems + 1] = "thin"
				flags.thin = flags.thin + 1
			end
			local transparent = inst.Transparency >= 1
			if transparent then
				flags.invisible = flags.invisible + 1
			end
			if #rows < limit and not transparent then
				-- Only the flagged rows are worth the bytes: an audit that dumps 40 000 clean parts
				-- hides the four that are broken, which is the whole point of running it.
				if #problems > 0 or (wantFloating and #problems == 0) then
					if wantFloating then
						local okBelow, below = pcall(function()
							local probe = inst.CFrame * CFrame.new(0, -(s.Y / 2 + 1), 0)
							if filter then
								return workspace:GetPartBoundsInBox(probe, Vector3.new(math.max(s.X, 1), 2, math.max(s.Z, 1)), filter)
							end
							return workspace:GetPartBoundsInBox(probe, Vector3.new(math.max(s.X, 1), 2, math.max(s.Z, 1)))
						end)
						if okBelow and #below == 0 then
							problems[#problems + 1] = "floating"
							flags.floating = flags.floating + 1
						elseif not okBelow then
							problems[#problems + 1] = "support-unsupported"
						end
					end
					rows[#rows + 1] = {
						path = pathOf(inst),
						position = serialize(p),
						size = serialize(s),
						problems = problems,
					}
				end
			elseif #problems > 0 and #rows >= limit then
				truncated = true
			end
		elseif inst:IsA("Model") then
			models = models + 1
		elseif inst:IsA("LuaSourceContainer") then
			scripts = scripts + 1
		else
			other = other + 1
		end
	end
	return {
		root = pathOf(root),
		parts = parts,
		models = models,
		scripts = scripts,
		other = other,
		flags = flags,
		byClass = byClass,
		rows = rows,
		rowsCapped = truncated,
		limit = limit,
	}
end

---Create many instances in one command, and say which ones failed.
--
-- `instance.create` one at a time is 110 ms a part and, worse, half a build: the failure mode this
-- replaces is a builder that dies on part 400 of 900 and leaves a ruin that reads as complete.
-- `stopOnError` (default true) rolls the batch back in reverse order, so a failed build leaves the
-- place exactly as it found it rather than two-thirds of the way to something.
handlers["instances.create"] = function(params)
	local items = params.items
	if type(items) ~= "table" or #items == 0 then
		return nil, bridgeError("INVALID_ARGUMENT", "items must be a non-empty array")
	end
	if #items > 2000 then
		return nil, bridgeError("INVALID_ARGUMENT", "batch capped at 2000 instances; send the rest separately")
	end
	local stopOnError = params.stopOnError ~= false
	local created = {}
	local results = {}
	local failed = 0
	for index, item in ipairs(items) do
		local parent, err = resolvePath(item.parent or "Workspace")
		if not parent then
			failed += 1
			results[index] = { ok = false, name = item.name, error = err.message }
			if stopOnError then
				break
			end
		else
			local ok, inst = pcall(Instance.new, item.className or "Part")
			if not ok or not inst then
				failed += 1
				results[index] = { ok = false, name = item.name, error = "cannot create " .. tostring(item.className) }
				if stopOnError then
					break
				end
			else
				inst.Name = item.name or inst.Name
				local badProp
				for propName, value in pairs(item.properties or {}) do
					if propName == "Parent" or propName == "Source" then
						badProp = propName .. " is set by the batch, not by properties"
						break
					end
					local okSet, setErr = pcall(function()
						inst[propName] = deserialize(value)
					end)
					if not okSet then
						badProp = "could not set " .. propName .. ": " .. tostring(setErr)
						break
					end
				end
				if badProp then
					inst:Destroy()
					failed += 1
					results[index] = { ok = false, name = item.name, error = badProp }
					if stopOnError then
						break
					end
				else
					inst.Parent = parent
					created[#created + 1] = inst
					results[index] = { ok = true, path = pathOf(inst), qoderId = ensureQoderId(inst, item.qoderId) }
				end
			end
		end
	end
	local rolledBack = 0
	if failed > 0 and stopOnError then
		for i = #created, 1, -1 do
			created[i]:Destroy()
			rolledBack += 1
		end
		-- Without this the answer says "part 3 created" about a part that no longer exists, which is
		-- the exact misreading that makes a rolled-back build look half-installed.
		for _, row in ipairs(results) do
			if row.ok then
				row.ok = false
				row.error = "rolled back with the batch"
			end
		end
	end
	return {
		requested = #items,
		created = failed == 0 and #created or (#created - rolledBack),
		failed = failed,
		rolledBack = rolledBack,
		results = results,
	}
end

---Compare what the place holds against what this run is about to push, in one command.
--
-- Installers used to push and then read back per file — two round trips and one cache hazard each,
-- because `script.write` does not invalidate Studio's `require` cache. This answers the same question
-- without writing anything, and reports the first differing byte so a conflict is diagnosable.
handlers["sync.verify"] = function(params)
	local results = {}
	local match, differ, missing = 0, 0, 0
	for _, f in ipairs(params.files or {}) do
		local entry = { path = f.path }
		local inst = resolvePath(f.path)
		if typeof(inst) ~= "Instance" then
			entry.status = "not_found"
			missing += 1
		elseif not inst:IsA("LuaSourceContainer") then
			entry.status = "not_a_script"
			missing += 1
		else
			local current = getScriptSource(inst) or ""
			local incoming = type(f.source) == "string" and f.source or ""
			entry.installedBytes = #current
			entry.incomingBytes = #incoming
			if current == incoming then
				entry.status = "match"
				match += 1
			else
				entry.status = "differ"
				differ += 1
				local n = math.min(#current, #incoming)
				local at = n + 1
				for i = 1, n do
					if current:byte(i) ~= incoming:byte(i) then
						at = i
						break
					end
				end
				entry.firstDiffByte = at
				local line = 1
				for i = 1, math.min(at, #current) do
					if current:byte(i) == 10 then
						line += 1
					end
				end
				entry.firstDiffLine = line
			end
		end
		results[#results + 1] = entry
	end
	return { checked = #results, match = match, differ = differ, missing = missing, results = results }
end

---World-space AABB of an instance and everything under it.
--
-- Measured on this build: a BasePart has NO `GetBoundingBox` (it throws), `CFrame` has no `.Size`
-- member, and `Model:GetBoundingBox()` carries the size as a SECOND return value. Three classes,
-- three shapes — so one uniform walk that costs 8 corners per part and is right for rotated parts
-- too, which is what a focus verb needs before it can be trusted to frame a screenshot.
local function worldAabb(root)
	local minV, maxV
	local function eat(v)
		if not minV then
			minV = v
			maxV = v
		else
			minV = Vector3.new(math.min(minV.X, v.X), math.min(minV.Y, v.Y), math.min(minV.Z, v.Z))
			maxV = Vector3.new(math.max(maxV.X, v.X), math.max(maxV.Y, v.Y), math.max(maxV.Z, v.Z))
		end
	end
	local parts = {}
	if root:IsA("BasePart") then
		parts[1] = root
	else
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") then
				parts[#parts + 1] = d
			end
		end
	end
	for _, p in ipairs(parts) do
		local s, cf = p.Size, p.CFrame
		local hx, hy, hz = s.X * 0.5, s.Y * 0.5, s.Z * 0.5
		for dx = -1, 1, 2 do
			for dy = -1, 1, 2 do
				for dz = -1, 1, 2 do
					eat(cf:PointToWorldSpace(Vector3.new(hx * dx, hy * dy, hz * dz)))
				end
			end
		end
	end
	if not minV then
		return nil
	end
	return (minV + maxV) * 0.5, maxV - minV
end

---Put the viewport somewhere useful.
--
-- There was no focus verb, so aiming a screenshot meant an eval that set `Camera.CFrame` — and that
-- only works after `CameraType = Scriptable`, because otherwise the position reads back correct while
-- the viewport keeps flying its own camera. Both halves live here so the ordering mistake cannot be
-- repeated by the next caller.
handlers["viewport.focus"] = function(params)
	local cam = workspace.CurrentCamera
	if not cam then
		return nil, bridgeError("UNSUPPORTED_OPERATION", "no Camera in this DataModel")
	end
	local target, size
	if params.path then
		local inst, err = resolvePath(params.path)
		if not inst then
			return nil, err
		end
		local centre, ext = worldAabb(inst)
		if not centre then
			return nil, bridgeError("INVALID_ARGUMENT", "no BasePart under " .. tostring(params.path))
		end
		target, size = centre, ext
	else
		local frame = frameOf(params)
		if not frame then
			return nil, bridgeError("INVALID_ARGUMENT", "path, or position [x,y,z], is required")
		end
		target = frame.Position
		size = sizeOf(params) or Vector3.new(10, 10, 10)
	end
	local reach = math.max(size.X, size.Y, size.Z, 4) * 2.2
	local eye = target + Vector3.new(reach * 0.6, reach * 0.55, reach * 0.6)
	local ok, setErr = pcall(function()
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = CFrame.lookAt(eye, target)
	end)
	if not ok then
		return nil, bridgeError("EXECUTION_ERROR", tostring(setErr))
	end
	if params.clearSelection then
		pcall(function()
			Selection:Set({})
		end)
	end
	return {
		target = serialize(target),
		eye = serialize(eye),
		reach = reach,
		cameraType = cam.CameraType.Name,
	}
end

-- ============ [5] router ============
-- Every verb that touches the DataModel must be listed here or a Play Test can
-- have it applied mid-session and verify against a place that is not yet the
-- one the command described.
local MUTATING = {
	["studio.eval"] = true,
	["instance.create"] = true,
	["instance.delete"] = true,
	["instance.clone"] = true,
	["instance.move"] = true,
	["instance.rename"] = true,
	["instances.create"] = true,
	["viewport.focus"] = true,
	["property.set"] = true,
	["attribute.set"] = true,
	["tag.add"] = true,
	["tag.remove"] = true,
	["script.write"] = true,
	["script.create"] = true,
	["sync.push"] = true,
}

local execute
local postResult

local function queueMutation(cmd)
	table.insert(state.mutationQueue, {
		id = cmd.id,
		command = cmd.command,
		parameters = cmd.parameters or {},
		queuedAt = os.time(),
	})
	addLog("queued during Play: " .. tostring(cmd.command) .. " (#" .. #state.mutationQueue .. ")")
	return {
		success = true,
		result = {
			queued = true,
			queueIndex = #state.mutationQueue,
			command = cmd.command,
			message = "Mutation queued until Play Test ends.",
		},
	}
end

execute = function(cmd)
	local handler = handlers[cmd.command]
	if not handler then
		return { success = false, error = { code = "UNKNOWN_COMMAND", message = "command not allowed: " .. tostring(cmd.command) } }
	end
	local result, err
	local ok, r1, r2 = pcall(handler, cmd.parameters or {})
	if ok then
		result, err = r1, r2
	else
		err = bridgeError("EXECUTION_ERROR", tostring(r1))
	end

	if err then
		return {
			success = false,
			error = {
				code = (typeof(err) == "table" and err.code) or "ERROR",
				message = (typeof(err) == "table" and err.message) or tostring(err),
			},
		}
	end
	return { success = true, result = result }
end

-- ============ [6] network ============
local function headers()
	return { ["x-bridge-token"] = settings.token, ["Content-Type"] = "application/json" }
end

local function baseUrl()
	local port = tonumber(settings.port) or 8346
	return "http://127.0.0.1:" .. port
end

-- Studio builds differ: modern RequestAsync returns (success, response), some
-- builds return the response table alone (or an error string). Normalise both.
local function httpRequest(options)
	local okCall, a, b = pcall(function()
		return HttpService:RequestAsync(options)
	end)
	if not okCall then
		return false, tostring(a)
	end
	if type(a) == "boolean" then
		return a, b
	end
	if typeof(a) == "table" then
		return true, a
	end
	return false, tostring(a)
end

postResult = function(payload)
	local ok, resp = httpRequest({
		Url = baseUrl() .. "/result",
		Method = "POST",
		Headers = headers(),
		Body = HttpService:JSONEncode(payload),
		Timeout = 30,
	})
	if not ok or not resp or not resp.Success then
		addLog("result delivery failed: " .. tostring(ok and (resp and resp.StatusCode) or resp))
	end
end

local function applyQueuedMutations()
	if state.queueApplying or #state.mutationQueue == 0 or isPlaytestRunning() then
		return
	end
	state.queueApplying = true
	ChangeHistoryService:SetWaypoint("QoderBridge: Apply queued build")
	local queued = state.mutationQueue
	state.mutationQueue = {}
	addLog("applying " .. #queued .. " queued mutation(s)")

	for _, cmd in ipairs(queued) do
		local okRun, out = pcall(execute, cmd)
		if not okRun then
			out = { success = false, error = { code = "PLUGIN_CRASH", message = tostring(out) } }
		end
		if out.success then
			addLog("queued " .. tostring(cmd.command) .. " applied")
		else
			addLog("queued " .. tostring(cmd.command) .. " FAILED: " .. tostring(out.error and out.error.message))
		end
		-- Send a second, explicit completion event. The original request already received
		-- a queued acknowledgement, so consumers that support phases can correlate by id.
		pcall(postResult, {
			id = cmd.id,
			phase = "queue_applied",
			success = out.success,
			result = out.result,
			error = out.error,
		})
	end

	state.buildVersion += 1
	plugin:SetSetting("buildVersion", state.buildVersion)
	ChangeHistoryService:SetWaypoint("QoderBridge: Apply queued build done")
	state.queueApplying = false
end

local function handleCommand(decoded)
	state.requestCount += 1
	state.lastCommand = decoded.command
	local running = refreshPlaytestState()

	if MUTATING[decoded.command] and running and state.queueEnabled then
		local queued = queueMutation(decoded)
		local okPost, postErr = pcall(postResult, {
			id = decoded.id,
			phase = "queued",
			success = queued.success,
			result = queued.result,
			error = queued.error,
		})
		if not okPost then addLog("queued result could not be sent: " .. tostring(postErr)) end
		return
	end

	if MUTATING[decoded.command] then
		ChangeHistoryService:SetWaypoint("QoderBridge: " .. decoded.command)
	end
	local okRun, out = pcall(execute, decoded)
	if not okRun then
		out = { success = false, error = { code = "PLUGIN_CRASH", message = tostring(out) } }
	end
	if MUTATING[decoded.command] then
		ChangeHistoryService:SetWaypoint("QoderBridge: " .. decoded.command .. " done")
	end
	addLog(string.format("%s -> %s", decoded.command, out.success and "ok" or ("ERR " .. tostring(out.error.code))))
	local okPost, postErr = pcall(postResult, {
		id = decoded.id,
		success = out.success,
		result = out.result,
		error = out.error,
	})
	if not okPost then
		addLog("result could not be sent: " .. tostring(postErr))
	end
end

local function pollLoop()
	state.pollThread = task.spawn(function()
		while state.active do
			local ok, resp = httpRequest({
				Url = baseUrl() .. "/poll?timeout=20",
				Method = "GET",
				Headers = headers(),
				Timeout = 35,
			})
			if not ok then
				local reason = tostring(resp)
				if reason ~= state.lastPollError then
					state.lastPollError = reason
					addLog("poll failed: " .. reason)
				end
			elseif resp.StatusCode == 200 then
				if state.lastPollError then
					state.lastPollError = nil
					addLog("poll OK: connected to the bridge server")
				end
				local decoded = nil
				local decodeErr = nil
				pcall(function()
					decoded = HttpService:JSONDecode(resp.Body)
				end)
				if decoded and decoded.id then
					local okLoop, loopErr = pcall(handleCommand, decoded)
					if not okLoop then
						addLog("command handling threw: " .. tostring(loopErr))
					end
				else
					addLog("ignored an empty/unparsable poll response (type=" .. typeof(decoded) .. ")")
				end
			end
			if state.active then
				task.wait(1)
			end
		end
		state.pollThread = nil
	end)
end

-- keeps the bridge alive if the poll thread ever exits unexpectedly
local function watchDog()
	task.spawn(function()
		while state.active do
			task.wait(5)
			if state.active and state.pollThread == nil then
				addLog("poll thread stopped — restarting")
				pollLoop()
			end
		end
	end)
end

local function queueWatchdog()
	task.spawn(function()
		while state.active do
			local wasRunning = state.playtest.running
			local running = refreshPlaytestState()
			if wasRunning and not running then
				applyQueuedMutations()
			elseif not running and #state.mutationQueue > 0 then
				applyQueuedMutations()
			end
			task.wait(0.5)
		end
	end)
end

local function startBridge()
	if state.active then
		return
	end
	if settings.token == "" then
		addLog("ERROR: paste the token from bridge.token first")
		return
	end
	state.active = true
	addLog("bridge started on port " .. settings.port)
	addLog("Play Test queue: " .. (state.queueEnabled and "ON" or "OFF"))
	pollLoop()
	watchDog()
	queueWatchdog()
end

local function stopBridge()
	state.active = false
	addLog("bridge stopped")
end

-- ============ [7] widget UI ============
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	true,
	false,
	320,
	420,
	260,
	300
)
local widget = plugin:CreateDockWidgetPluginGui("QoderBridgeWidget", widgetInfo)
widget.Title = "Qoder Bridge"

local function buildUi()
	widget:ClearAllChildren()

	local root = Instance.new("Frame")
	root.BackgroundColor3 = Color3.fromRGB(24, 24, 34)
	root.Size = UDim2.fromScale(1, 1)
	root.BorderSizePixel = 0
	root.Parent = widget

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.Parent = root
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.PaddingTop = UDim.new(0, 10)
	pad.Parent = root

	local function label(text, name, color)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, 0, 0, 20)
		l.Text = text
		l.TextColor3 = color or Color3.fromRGB(220, 222, 240)
		l.Font = Enum.Font.GothamBold
		l.TextSize = 14
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Name = name
		l.Parent = root
		return l
	end

	local function input(placeholder, name, value)
		local t = Instance.new("TextBox")
		t.Size = UDim2.new(1, 0, 0, 26)
		t.BackgroundColor3 = Color3.fromRGB(38, 38, 54)
		t.TextColor3 = Color3.fromRGB(235, 235, 245)
		t.PlaceholderText = placeholder
		t.Text = value or ""
		t.Font = Enum.Font.Code
		t.TextSize = 13
		t.ClearTextOnFocus = false
		t.Name = name
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = t
		t.Parent = root
		return t
	end

	local function button(text, name, color)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 30)
		b.BackgroundColor3 = color or Color3.fromRGB(52, 90, 150)
		b.TextColor3 = Color3.fromRGB(240, 240, 250)
		b.Text = text
		b.Font = Enum.Font.GothamBold
		b.TextSize = 14
		b.Name = name
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = b
		b.Parent = root
		return b
	end

	label("QODER BRIDGE", "Title", Color3.fromRGB(255, 205, 70))
	local status = label("Status:  Disconnected", "Status")
	label("Port:", "PortLabel")
	local portBox = input("8346", "Port", tostring(settings.port))
	label("Auth token (from bridge.token):", "TokenLabel")
	local tokenBox = input("paste token", "Token", settings.token)
	local startBtn = button("Start Bridge", "Start", Color3.fromRGB(60, 130, 80))
	local stopBtn = button("Stop Bridge", "Stop", Color3.fromRGB(140, 55, 65))
	local testBtn = button("Test Connection", "Test", Color3.fromRGB(70, 75, 100))
	local queueBtn = button("Queue Mutations During Play: " .. (state.queueEnabled and "ON" or "OFF"), "QueueToggle", Color3.fromRGB(90, 80, 130))
	local statsLabel = label("Requests: 0   Last: none", "Stats")
	local playLabel = label("Play Test: OFF   Queue: 0", "PlayStatus", Color3.fromRGB(180, 220, 255))
	label("Command log:", "LogLabel")

	local logBox = Instance.new("ScrollingFrame")
	logBox.Size = UDim2.new(1, 0, 0, 140)
	logBox.BackgroundColor3 = Color3.fromRGB(16, 16, 24)
	logBox.ScrollBarThickness = 5
	logBox.CanvasSize = UDim2.new(0, 0, 0, 0)
	logBox.AutomaticCanvasSize = Enum.AutomaticSize.Y
	logBox.Name = "Log"
	local logLayout = Instance.new("UIListLayout")
	logLayout.Parent = logBox
	local logPad = Instance.new("UIPadding")
	logPad.PaddingLeft = UDim.new(0, 4)
	logPad.Parent = logBox
	logBox.Parent = root

	local function refresh()
		refreshPlaytestState()
		status.Text = state.active and "Status:  Connected (polling)" or "Status:  Disconnected"
		status.TextColor3 = state.active and Color3.fromRGB(90, 220, 120) or Color3.fromRGB(230, 90, 90)
		statsLabel.Text = "Requests: " .. tostring(state.requestCount) .. "   Last: " .. tostring(state.lastCommand)
		playLabel.Text = "Play Test: " .. (state.playtest.running and "ON" or "OFF") .. "   Queue: " .. tostring(#state.mutationQueue) .. "   Build: " .. tostring(state.buildVersion)
		queueBtn.Text = "Queue Mutations During Play: " .. (state.queueEnabled and "ON" or "OFF")
		for _, child in ipairs(logBox:GetChildren()) do
			if child:IsA("TextLabel") then
				child:Destroy()
			end
		end
		for _, line in ipairs(state.log) do
			local l = Instance.new("TextLabel")
			l.BackgroundTransparency = 1
			l.Size = UDim2.new(1, 0, 0, 16)
			l.Text = line
			l.TextColor3 = Color3.fromRGB(190, 195, 215)
			l.Font = Enum.Font.Code
			l.TextSize = 11
			l.TextXAlignment = Enum.TextXAlignment.Left
			l.Parent = logBox
		end
	end

	-- assignment truncates gsub's second return value; passing it straight to tonumber would look like a bad base
	local function typedPort()
		local raw = portBox.Text:gsub("%s+", "")
		return tonumber(raw) or settings.port
	end

	startBtn.MouseButton1Click:Connect(function()
		settings.port = typedPort()
		settings.token = tokenBox.Text
		plugin:SetSetting("port", settings.port)
		plugin:SetSetting("token", settings.token)
		startBridge()
		refresh()
	end)
	stopBtn.MouseButton1Click:Connect(function()
		stopBridge()
		refresh()
	end)
	queueBtn.MouseButton1Click:Connect(function()
		state.queueEnabled = not state.queueEnabled
		plugin:SetSetting("queueDuringPlay", state.queueEnabled)
		addLog("Play Test mutation queue " .. (state.queueEnabled and "enabled" or "disabled"))
		refresh()
	end)

	testBtn.MouseButton1Click:Connect(function()
		settings.port = typedPort()
		settings.token = tokenBox.Text
		plugin:SetSetting("port", settings.port)
		plugin:SetSetting("token", settings.token)
		task.spawn(function()
			local ok, resp = httpRequest({
				Url = baseUrl() .. "/api/status",
				Method = "GET",
				Headers = headers(),
				Timeout = 5,
			})
			if ok and resp and resp.Success then
				addLog("test OK: server reachable, plugin seen=" .. tostring(resp.Body:find('"pluginConnected":true') and "yes" or "no"))
			else
				addLog("test FAILED: " .. tostring(ok and (resp and resp.StatusCode) or resp))
			end
			refresh()
		end)
	end)

	refresh()
	task.spawn(function()
		while widget do
			task.wait(1)
			refresh()
		end
	end)
end

buildUi()

-- ============ [8] toolbar ============
local toolbar = plugin:CreateToolbar("Qoder Bridge")

-- Studio builds differ: newer ones have InsertButton, older ones CreateButton.
local toggle
pcall(function() toggle = toolbar:InsertButton("QoderBridgeToggle") end)
if not toggle then
	pcall(function() toggle = toolbar:CreateButton("QoderBridgeToggle", "Open the Qoder Bridge panel", "", "Bridge") end)
end
if not toggle then
	addLog("toolbar button unavailable on this Studio build — use the Qoder Bridge panel directly")
end
if toggle then
	pcall(function() toggle:SetButtonText("Bridge") end)
	pcall(function() toggle:SetTooltip("Open the Qoder Bridge panel") end)
end

local function readProp(inst, name)
	local ok, value = pcall(function() return inst[name] end)
	if ok then return value end
	return nil
end

local function isOpen()
	local value = readProp(widget, "Enabled")
	if value == nil then value = readProp(widget, "Visible") end
	return value == true
end

local function setOpen(open)
	pcall(function() widget.Enabled = open end)
	pcall(function() widget.Visible = open end)
	if toggle then pcall(function() toggle.Active = open end) end
end

if toggle then
	local clicked
	pcall(function() clicked = toggle.Clicked end)
	if clicked == nil then pcall(function() clicked = toggle.Click end) end
	if typeof(clicked) == "RBXScriptSignal" then
		clicked:Connect(function()
			setOpen(not isOpen())
		end)
	end
end

plugin.Unloading:Connect(function()
	state.active = false
end)
