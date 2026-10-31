---
name: core.contracts.interfaces
description: Dependency-free contracts that every other skill codes against - SignalLike, NetChannel (typed channels with string type tokens), HitboxQuery, SessionStore, Maid - each with a complete zero-dependency Luau implementation using only Roblox engine APIs, plus adapter notes for swapping in GoodSignal, Packet, HitboxClass, ProfileStore or Indexer. Use first whenever code needs events, networking, hit queries or persistence, so nothing hard-requires a third-party module.
---

# Core Contracts (no third-party modules required)

Every skill in this set codes against these **interfaces**. Each one ships with a working built-in implementation. Third-party libraries are optional adapters: GoodSignal, Packet, HitboxClass, ProfileStore, or your own Indexer. Swap them by changing one `require` in a `Deps` module.

```luau
-- ReplicatedStorage/Core/Deps (the ONLY place that decides implementations)
return {
	Signal  = require(script.Parent.Signal),       -- or an adapter around GoodSignal
	Net     = require(script.Parent.Net),          -- or an adapter around Packet / Indexer
	Hitbox  = require(script.Parent.Hitbox),       -- or an adapter around HitboxClass
	Maid    = require(script.Parent.Maid),
}
-- ServerScriptService/Core/SessionStore          -- or an adapter around ProfileStore (server only)
```

## 1. SignalLike

```luau
export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
export type SignalLike<T...> = {
	Connect: (self: SignalLike<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: SignalLike<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: SignalLike<T...>) -> T...,
	Fire: (self: SignalLike<T...>, T...) -> (),
	DisconnectAll: (self: SignalLike<T...>) -> (),
}
```
Semantics required by this project: **immediate** (handlers start inside `Fire`), **FIFO** (connection order), safe to disconnect during `Fire`, handlers may yield.

### Built-in implementation
```luau
--!strict
local Signal = {} ; Signal.__index = Signal
local Connection = {} ; Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then return end
	self.Connected = false
	local list = self._signal._list
	local i = table.find(list, self)
	if i then table.remove(list, i) end
end

function Signal.new()
	return setmetatable({ _list = {} }, Signal)
end

function Signal:Connect(fn)
	local c = setmetatable({ Connected = true, _fn = fn, _signal = self }, Connection)
	table.insert(self._list, c)
	return c
end

function Signal:Once(fn)
	local c ; c = self:Connect(function(...) c:Disconnect() ; fn(...) end)
	return c
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...) task.spawn(thread, ...) end)
	return coroutine.yield()
end

function Signal:Fire(...)
	local snapshot = table.clone(self._list)       -- safe against connect/disconnect during Fire
	for _, c in snapshot do
		if c.Connected then task.spawn(c._fn, ...) end
	end
end

function Signal:DisconnectAll()
	for _, c in self._list do c.Connected = false end
	table.clear(self._list)
end

return Signal
```
Cost: one `table.clone` + one `task.spawn` per handler. GoodSignal is faster (reuses its coroutine) but runs handlers **LIFO**. An adapter must reverse the order if code relies on FIFO, or the code must not rely on order.

## 2. NetChannel

```luau
-- type tokens (strings): "U8" "U16" "U32" "S8" "S16" "S32" "F32" "F64" "Bool" "String"
--                        "Instance" "Vector3" "CFrame" "Any"
export type Channel = {
	Name: string,
	Fire: (self: Channel, ...any) -> (),                       -- client→server, or server→ALL clients
	FireClient: (self: Channel, player: Player, ...any) -> (), -- server only
	FireExcept: (self: Channel, except: Player, ...any) -> (), -- server only
	OnServer: (self: Channel, fn: (player: Player, ...any) -> ()) -> Connection,
	OnClient: (self: Channel, fn: (...any) -> ()) -> Connection,
}
export type Net = {
	Define: (name: string, types: { string }) -> Channel,        -- call identically on both sides (shared module)
	Request: (name: string, types: { string }, returns: { string }, timeout: number?) -> RequestChannel,
}
```
**Validation is part of the contract.** Incoming server arguments are checked against `types`, and a mismatch drops the message. The handler only ever sees well-typed values. Semantic validation (ranges, state) stays in game code.

### Built-in implementation (one RemoteEvent, per-frame batching, type checks)
```luau
--!strict
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Signal = require(script.Parent.Signal)

local IS_SERVER = RunService:IsServer()     -- branching lives inside the infrastructure module only
local Remote: RemoteEvent
if IS_SERVER then
	Remote = Instance.new("RemoteEvent") ; Remote.Name = "NetRemote" ; Remote.Parent = script
else
	Remote = script:WaitForChild("NetRemote") :: RemoteEvent
end

local Checks: { [string]: (any) -> boolean } = {
	U8 = function(v) return type(v) == "number" and v % 1 == 0 and v >= 0 and v <= 255 end,
	U16 = function(v) return type(v) == "number" and v % 1 == 0 and v >= 0 and v <= 65535 end,
	U32 = function(v) return type(v) == "number" and v % 1 == 0 and v >= 0 and v <= 4294967295 end,
	S8 = function(v) return type(v) == "number" and v % 1 == 0 and v >= -128 and v <= 127 end,
	S16 = function(v) return type(v) == "number" and v % 1 == 0 and v >= -32768 and v <= 32767 end,
	S32 = function(v) return type(v) == "number" and v % 1 == 0 and v >= -2147483648 and v <= 2147483647 end,
	F32 = function(v) return type(v) == "number" and v == v and math.abs(v) < 3.4e38 end,
	F64 = function(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end,
	Bool = function(v) return type(v) == "boolean" end,
	String = function(v) return type(v) == "string" and #v <= 1024 end,
	Instance = function(v) return v == nil or typeof(v) == "Instance" end,  -- nil = not replicated / streamed out
	Vector3 = function(v) return typeof(v) == "Vector3" and v == v end,
	CFrame = function(v) return typeof(v) == "CFrame" end,
	Any = function(_) return true end,
}

local Net = {}
local Channels: { [string]: any } = {}
local Order: { string } = {}                 -- name ↔ index (same definition order on both sides)

local Outgoing: { any } = {}                  -- client queue or server broadcast queue
local PerPlayer: { [Player]: { any } } = {}

local Channel = {} ; Channel.__index = Channel

function Net.Define(name: string, types: { string })
	assert(Channels[name] == nil, `channel {name} defined twice`)
	for _, t in types do assert(Checks[t], `unknown type token {t}`) end
	local ch = setmetatable({ Name = name, Types = types, _signal = Signal.new() }, Channel)
	Channels[name] = ch
	table.insert(Order, name)
	return ch
end

-- Remotes truncate arrays at the first nil and drop half of mixed tables, so arguments travel as a
-- string-keyed map { n = count, ["1"] = v1, ... }; a nil / non-replicated Instance is simply a missing key.
local function Pack(ch, ...)
	local n = select("#", ...)
	local args = { n = n }
	for i = 1, n do args[tostring(i)] = (select(i, ...)) end
	return { c = ch.Name, a = args }
end

function Channel:Fire(...)
	table.insert(Outgoing, Pack(self, ...))
end
function Channel:FireClient(player: Player, ...)
	local q = PerPlayer[player] ; if not q then q = {} ; PerPlayer[player] = q end
	table.insert(q, Pack(self, ...))
end
function Channel:FireExcept(except: Player, ...)
	for _, p in Players:GetPlayers() do if p ~= except then self:FireClient(p, ...) end end
end
function Channel:OnServer(fn) return self._signal:Connect(fn) end
function Channel:OnClient(fn) return self._signal:Connect(fn) end

local function Unpack(ch, args): (boolean, { any }?)
	if type(args) ~= "table" or type(args.n) ~= "number" or args.n > #ch.Types then return false, nil end
	local out = table.create(#ch.Types)
	for i, t in ch.Types do
		local v = args[tostring(i)]
		if not Checks[t](v) then return false, nil end
		out[i] = v
	end
	return true, out
end

local function Deliver(batch: any, player: Player?)
	if type(batch) ~= "table" or #batch > 64 then return end          -- crude flood guard
	for _, msg in batch do
		local ch = type(msg) == "table" and type(msg.c) == "string" and Channels[msg.c]
		if ch then
			local ok, a = Unpack(ch, msg.a)
			if ok and a then
				local n = #ch.Types
				if player then ch._signal:Fire(player, table.unpack(a, 1, n)) else ch._signal:Fire(table.unpack(a, 1, n)) end
			end
		end
	end
end

if IS_SERVER then
	Remote.OnServerEvent:Connect(function(player, batch) Deliver(batch, player) end)
	Players.PlayerRemoving:Connect(function(p) PerPlayer[p] = nil end)
	RunService.Heartbeat:Connect(function()
		if #Outgoing > 0 then Remote:FireAllClients(Outgoing) ; Outgoing = {} end
		for p, q in PerPlayer do Remote:FireClient(p, q) end
		table.clear(PerPlayer)
	end)
else
	Remote.OnClientEvent:Connect(function(batch) Deliver(batch, nil) end)
	RunService.Heartbeat:Connect(function()
		if #Outgoing > 0 then Remote:FireServer(Outgoing) ; Outgoing = {} end
	end)
end

return Net
```
Notes:
- It sends channel **names**, not ids, which is simple but bigger. To compress, map names to `Order` indices and pack numbers into a `buffer` (see roblox.network.remotes-replication-security §2).
- Per-player server rate limiting belongs in `Deliver` or in game code (token bucket).

### Request / response (server asks one client, with timeout)
```luau
-- add to the Net module above
export type RequestChannel = {
	Invoke: (self: RequestChannel, player: Player, ...any) -> ...any,   -- server: yields ≤ timeout, nil on timeout
	OnInvoke: (self: RequestChannel, fn: (...any) -> ...any) -> (),      -- client: answer
}

function Net.Request(name: string, types: { string }, returns: { string }, timeout: number?)
	local ask = Net.Define(name .. ":Ask", { "U16", table.unpack(types) })
	local reply = Net.Define(name .. ":Reply", { "U16", table.unpack(returns) })
	local waiting: { [number]: { Thread: thread, Player: Player } } = {}
	local nextId = 0
	local limit = timeout or 1
	local req = {}

	function req:Invoke(player: Player, ...)
		nextId = nextId % 65535 + 1
		local id = nextId
		waiting[id] = { Thread = coroutine.running(), Player = player }
		task.delay(limit, function()
			local w = waiting[id]
			if w then waiting[id] = nil ; task.spawn(w.Thread, nil) end     -- timeout → nil
		end)
		ask:FireClient(player, id, ...)
		return coroutine.yield()
	end

	reply:OnServer(function(player, id, ...)
		local w = waiting[id]
		if w and w.Player == player then waiting[id] = nil ; task.spawn(w.Thread, ...) end
	end)

	function req:OnInvoke(fn)
		ask:OnClient(function(id, ...) reply:Fire(id, fn(...)) end)
	end

	return req
end
```
Answers from the wrong player, late answers and wrongly-typed answers are dropped. The caller treats `nil` as "no opinion".

### Adapter: Packet
```luau
local Packet = require(path.Packet)
local Map = { U8 = Packet.NumberU8, U16 = Packet.NumberU16, U32 = Packet.NumberU32, S8 = Packet.NumberS8, S16 = Packet.NumberS16,
	S32 = Packet.NumberS32, F32 = Packet.NumberF32, F64 = Packet.NumberF64, Bool = Packet.Boolean8, String = Packet.String,
	Instance = Packet.Instance, Vector3 = Packet.Vector3F32, CFrame = Packet.CFrameF32U16, Any = Packet.Any }
function Net.Define(name, types)
	local tokens = table.create(#types) ; for i, t in types do tokens[i] = Map[t] end
	local p = Packet(name, table.unpack(tokens))
	return {
		Name = name,
		Fire = function(_, ...) p:Fire(...) end,
		FireClient = function(_, plr, ...) p:FireClient(plr, ...) end,
		FireExcept = function(_, ex, ...) for _, plr in Players:GetPlayers() do if plr ~= ex then p:FireClient(plr, ...) end end end,
		OnServer = function(_, fn) return p.OnServerEvent:Connect(fn) end,
		OnClient = function(_, fn) return p.OnClientEvent:Connect(fn) end,
	}
end
```
Packet decodes types (ranges via its own encodings), and handlers run deferred. Keep semantic validation in game code either way.

### Adapter: Indexer (your module)
One `Indexer.New({Remote, Identifier = name})` per channel. `Fire` → `:Recursive({PassedData = table.pack(...)})`. Unpack in `:Connect`, and run the same `Valid` check on the server.

## 3. HitboxQuery

```luau
export type HitboxSpec = { Size: Vector3, Offset: CFrame, Shape: ("Box" | "Sphere")?, MinDot: number? }
export type HitboxQuery = {
	Hit: SignalLike<Model>,                      -- once per model per swing
	Start: (self: HitboxQuery, follow: BasePart, spec: HitboxSpec, ignore: { Instance }) -> (),
	Stop: (self: HitboxQuery) -> (),
	Destroy: (self: HitboxQuery) -> (),
}
```
### Built-in implementation (works on client or server; no folder requirement)
```luau
--!strict
local RunService = game:GetService("RunService")
local Signal = require(script.Parent.Signal)

local Hitbox = {} ; Hitbox.__index = Hitbox

function Hitbox.new()
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	return setmetatable({ Hit = Signal.new(), _params = params, _tagged = {}, _conn = nil :: RBXScriptConnection? }, Hitbox)
end

local function ModelOf(part: BasePart): (Model?, Humanoid?)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		local hum = model:FindFirstChildOfClass("Humanoid")
		if hum then return model, hum end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

function Hitbox:Start(follow: BasePart, spec, ignore: { Instance })
	self:Stop()
	table.clear(self._tagged)
	self._params.FilterDescendantsInstances = ignore
	self._conn = RunService.PostSimulation:Connect(function()
		local cf = follow.CFrame * spec.Offset
		local parts = if spec.Shape == "Sphere"
			then workspace:GetPartBoundsInRadius(cf.Position, spec.Size.X / 2, self._params)
			else workspace:GetPartBoundsInBox(cf, spec.Size, self._params)
		for _, part in parts do
			local model, hum = ModelOf(part)
			if model and hum and hum.Health > 0 and not self._tagged[model] then
				local ok = true
				if spec.MinDot and model.PrimaryPart then
					local to = (model.PrimaryPart.Position - follow.Position) * Vector3.new(1, 0, 1)
					ok = to.Magnitude < 1e-3 or follow.CFrame.LookVector:Dot(to.Unit) >= spec.MinDot
				end
				if ok then self._tagged[model] = true ; self.Hit:Fire(model) end
			end
		end
	end)
end

function Hitbox:Stop() if self._conn then self._conn:Disconnect() ; self._conn = nil end end
function Hitbox:Destroy() self:Stop() ; self.Hit:DisconnectAll() end

return Hitbox
```
Adapter for HitboxClass: `HitboxClass.new({SizeOrPart = spec.Size, SpatialOption = "InBox", Blacklist = ignore, DebounceTime = 0})`. Then `:WeldTo(follow, spec.Offset)`, call `:ClearTaggedChars(); :Start()` in `Start`, and forward each model from `HitSomeone` to `Hit:Fire(model)`. Characters must be in its Alive folder.

## 4. SessionStore (server persistence)

```luau
export type Session<T> = {
	Data: T,
	IsActive: (self: Session<T>) -> boolean,
	Save: (self: Session<T>) -> (),
	End: (self: Session<T>) -> (),
	Ended: SignalLike<string>,                    -- reason: "Manual" | "Shutdown" | "Stolen"
}
export type SessionStore<T> = { Start: (self: SessionStore<T>, key: string, isStillWanted: () -> boolean) -> Session<T>? }
```
### Built-in implementation (session lock via UpdateAsync)
```luau
--!strict
local DataStoreService = game:GetService("DataStoreService")
local Signal = require(game.ReplicatedStorage.Core.Signal)
local LOCK_EXPIRE, AUTOSAVE = 360, 120

local Store = {} ; Store.__index = Store
local Session = {} ; Session.__index = Session
local Live: { any } = {}

local function Reconcile(target, template)
	for k, v in template do
		if target[k] == nil then target[k] = if type(v) == "table" then table.clone(v) else v
		elseif type(v) == "table" and type(target[k]) == "table" then Reconcile(target[k], v) end
	end
end

function Store.new(name: string, template)
	return setmetatable({ _ds = DataStoreService:GetDataStore(name), _template = template }, Store)
end

local function Write(s, release: boolean)
	local ok = pcall(function()
		s._store._ds:UpdateAsync(s._key, function(old)
			if old and old.Lock and old.Lock ~= game.JobId and os.time() - (old.LockTime or 0) < LOCK_EXPIRE then
				return nil                                 -- someone else owns it now: don't overwrite
			end
			return { Data = s.Data, Lock = if release then nil else game.JobId, LockTime = os.time() }
		end)
	end)
	return ok
end

function Store:Start(key: string, isStillWanted: () -> boolean)
	for _ = 1, 10 do
		if not isStillWanted() then return nil end
		local data
		local ok = pcall(function()
			self._ds:UpdateAsync(key, function(old)
				old = old or {}
				if old.Lock and old.Lock ~= game.JobId and os.time() - (old.LockTime or 0) < LOCK_EXPIRE then
					data = nil ; return nil                -- locked elsewhere: retry later
				end
				old.Lock, old.LockTime = game.JobId, os.time()
				old.Data = old.Data or table.clone(self._template)
				data = old.Data
				return old
			end)
		end)
		if ok and data then
			Reconcile(data, self._template)
			local s = setmetatable({ Data = data, Ended = Signal.new(), _store = self, _key = key, _active = true }, Session)
			table.insert(Live, s)
			task.spawn(function() while s._active do task.wait(AUTOSAVE) ; if s._active then Write(s, false) end end end)
			return s
		end
		task.wait(5)
	end
	return nil
end

function Session:IsActive() return self._active end
function Session:Save() if self._active then Write(self, false) end end
function Session:End(reason: string?)
	if not self._active then return end
	self._active = false
	Write(self, true)
	local i = table.find(Live, self) ; if i then table.remove(Live, i) end
	self.Ended:Fire(reason or "Manual")
end

game:BindToClose(function() for _, s in table.clone(Live) do task.spawn(s.End, s, "Shutdown") end ; task.wait(3) end)

return Store
```
This is deliberately simple: locks expire after 6 minutes, and there's no cross-server "please release" message, no message queue and no versions. That's fine to start. Use the ProfileStore adapter for production (faster hand-off via MessagingService, critical-state handling, mock store): `Start` → `StartSessionAsync(key, {Cancel = function() return not isStillWanted() end})`, `End` → `EndSession`, `Ended` ← `OnSessionEnd`.

## 5. Maid (cleanup)

```luau
local Maid = {} ; Maid.__index = Maid
function Maid.new() return setmetatable({ _t = {} }, Maid) end
function Maid:Give<T>(x: T): T table.insert(self._t, x) return x end
function Maid:Clean()
	local t = self._t ; self._t = {}
	for i = #t, 1, -1 do
		local x = t[i] ; local k = typeof(x)
		if k == "function" then x()
		elseif k == "RBXScriptConnection" then x:Disconnect()
		elseif k == "Instance" then x:Destroy()
		elseif k == "thread" then pcall(task.cancel, x)
		elseif type(x) == "table" then
			if type(x.Destroy) == "function" then x:Destroy() elseif type(x.Disconnect) == "function" then x:Disconnect() end
		end
	end
end
Maid.Destroy = Maid.Clean
return Maid
```

## 6. Rules for all other skills

- Game code says `Deps.Signal.new()`, `Deps.Net.Define(...)`, `Deps.Hitbox.new()`. It never names a library.
- Library-specific facts (Packet byte sizes, ProfileStore request costs, HitboxClass folder setup) live only in the `lib.*` / `project.*` skills, which describe **adapters**.
- If a library's semantics differ from the contract (GoodSignal LIFO, Packet deferred handlers), the adapter documents the difference.
