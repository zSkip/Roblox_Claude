---
name: luau.metatables.oop-classes
description: Metatables and object-oriented Luau - every metamethod, __index/__newindex as table vs function, rawget/rawset, class/constructor pattern, inheritance, composition, proxy objects with change hooks (property setters like IsActive), state-machine classes, Maid/Trove cleanup, blueprint vs instance split, and pitfalls. Use when designing class-based systems (weapons, states, binds).
---

# Luau — Metatables & OOP Classes

## 1. Metamethods

| Key | Trigger |
|---|---|
| `__index` | read of missing key: `t[k]` -> table (lookup chain) or `function(t, k)` |
| `__newindex` | write of **missing** key (`rawget(t,k) == nil`): table (redirect) or `function(t, k, v)` |
| `__call` | `t(...)` -> `function(t, ...)` |
| `__tostring` | `tostring(t)` / print |
| `__len` | `#t` |
| `__eq` | `a == b` (both tables, same `__eq`) |
| `__lt`, `__le` | `<`, `<=` (`>`/`>=` swap operands) |
| `__add __sub __mul __div __idiv __mod __pow __unm __concat` | arithmetic |
| `__iter` | generalized `for k, v in t` -> returns iterator triple |
| `__mode` | `"k"`, `"v"`, `"kv"` weak table |
| `__metatable` | value returned by `getmetatable`; blocks `setmetatable` |
| `__namecall` | (internal, not available to user code) |

Not supported: `__gc`, `__close`.

Key fact: `__newindex` only fires when the key is **absent from the raw table**. To intercept every write, keep data in a separate table (proxy pattern).

## 2. Basic class

```luau
local Weapon = {}
Weapon.__index = Weapon

function Weapon.new(id: string, damage: number)
	local self = setmetatable({}, Weapon)
	self.Id = id
	self.Damage = damage
	return self
end

function Weapon:Describe(): string
	return `{self.Id} ({self.Damage})`
end

Weapon.__tostring = Weapon.Describe

return Weapon
```
- Methods live on the class table (shared), data lives on the instance.
- `self` is the instance; call with `:`.
- Static/class functions use `.` (`Weapon.new`).

## 3. Inheritance

```luau
local Base = {} ; Base.__index = Base
function Base.new(name) return setmetatable({ Name = name }, Base) end
function Base:Hello() return "base " .. self.Name end

local Sword = setmetatable({}, { __index = Base }) ; Sword.__index = Sword
function Sword.new(name, length)
	local self = Base.new(name)
	setmetatable(self, Sword)
	self.Length = length
	return self
end
function Sword:Hello() return "sword / " .. Base.Hello(self) end   -- super call
```
Prefer **composition** for gameplay: a Weapon *has* States, Binds, Hitbox components; avoid deep hierarchies.

## 4. Proxy with property hooks (user's `IsActive` pattern, fixed)

Goal: setting `state.IsActive = true` runs enter logic; reads fall through to data then methods.

```luau
local StateMethods = {}

local StateMeta = {}
StateMeta.__index = function(self, key)
	local data = rawget(self, "_data")
	local v = data[key]
	if v ~= nil then return v end
	return StateMethods[key]
end
StateMeta.__newindex = function(self, key, value)
	local data = rawget(self, "_data")
	if key == "IsActive" then
		if data.IsActive == value then return end
		data.IsActive = value                      -- STORE IT (common bug: forgetting this)
		if value then
			for _, fn in data.OnEnter do task.spawn(fn, self) end   -- run ALL, not [1]
		else
			for _, fn in data.OnExit do task.spawn(fn, self) end
		end
		return
	end
	data[key] = value                              -- don't silently drop other writes
end

local function NewState(name: string)
	return setmetatable({ _data = { Name = name, IsActive = false, OnEnter = {}, OnExit = {} } }, StateMeta)
end
```
Simpler alternative (recommended): explicit method `state:SetActive(bool)` + signals (`Entered`, `Exited`). Explicit setters are greppable, typeable and cheaper than `__index` functions.

## 5. Read-only / validated objects

```luau
local function ReadOnly<T>(t: T): T
	return setmetatable({}, {
		__index = t,
		__newindex = function(_, k) error(`attempt to write read-only key {tostring(k)}`, 2) end,
		__iter = function() return next, t end,
		__len = function() return #(t :: any) end,
	}) :: any
end
-- or just table.freeze(t) (shallow, faster, errors on write)
```

## 6. Blueprint (definition) vs Instance (runtime)

Critical for multiplayer: a weapon **definition** (schema: damage, animations, binds) is shared by every player; the **runtime instance** (current state, combo index, cooldowns, loaded AnimationTracks) is per owner.

```luau
local Definition = {} ; Definition.__index = Definition
local Runtime = {} ; Runtime.__index = Runtime

function Definition.new(schema) return setmetatable({ Schema = table.freeze(schema), States = {} }, Definition) end
function Definition:Instantiate(owner: Model)
	return setmetatable({
		Definition = self,
		Owner = owner,
		ActiveState = nil,
		ComboIndex = 0,
		Cooldowns = {},
		Tracks = {},
	}, Runtime)
end
function Runtime:GetStat(name) return self.Definition.Schema.Stats[name] end
```
Putting `IsActive` on the definition means one player idling toggles it for everyone.

## 7. State machine class

```luau
local StateMachine = {} ; StateMachine.__index = StateMachine

function StateMachine.new(states: {[string]: {Enter: (any)->()?, Exit: (any)->()?, CanEnter: (any)->boolean?}}, initial: string)
	local self = setmetatable({ States = states, Current = nil :: string? }, StateMachine)
	self:Set(initial)
	return self
end

function StateMachine:Set(name: string, ctx: any?): boolean
	if self.Current == name then return false end
	local nextState = self.States[name]
	assert(nextState, `unknown state {name}`)
	if nextState.CanEnter and not nextState.CanEnter(ctx) then return false end
	local prev = self.Current and self.States[self.Current]
	if prev and prev.Exit then prev.Exit(ctx) end
	self.Current = name
	if nextState.Enter then nextState.Enter(ctx) end
	return true
end
```
Add a transition table (`Allowed = { Idle = {Attack=true, Block=true, Dodge=true}, Stunned = {} }`) to centralise rules.

This is the minimal flat version. For events, guards, nested states, `after` timers, run-to-completion and the RobloxStateMachine / Arch libraries, see `roblox.architecture.state-machines`.

## 8. Maid / Trove cleanup

```luau
local Maid = {} ; Maid.__index = Maid
function Maid.new() return setmetatable({ _tasks = {} }, Maid) end
function Maid:Give(task_: any) table.insert(self._tasks, task_) return task_ end
function Maid:Clean()
	local tasks = self._tasks
	self._tasks = {}
	for i = #tasks, 1, -1 do
		local t = tasks[i]
		local kind = typeof(t)
		if kind == "function" then t()
		elseif kind == "RBXScriptConnection" then t:Disconnect()
		elseif kind == "Instance" then t:Destroy()
		elseif kind == "thread" then pcall(task.cancel, t)
		elseif type(t) == "table" then
			if t.Destroy then t:Destroy() elseif t.Disconnect then t:Disconnect() end
		end
	end
end
Maid.Destroy = Maid.Clean
```
Pattern: each state owns a Maid; `Enter` gives tasks (connections, playing tracks, tweens), `Exit` calls `Clean()`. This replaces hand-written "BoundMaids".

## 9. Weak tables (caches keyed by instances)

```luau
local TracksByAnimator = setmetatable({}, { __mode = "k" })
```
Instances as weak keys are only collected after they're destroyed *and* unreferenced; still clean up explicitly on `Destroying`/`CharacterRemoving`.

## 10. Pitfalls

- `__index` **function** runs on every missing-key read - put methods on a table `__index` for speed; avoid function `__index` in hot paths.
- `rawget(self, "x")` inside `__index` to avoid infinite recursion.
- Calling `obj.Method()` instead of `obj:Method()` -> `self` is nil.
- Mutating a shared default table: `function C.new() return setmetatable({ List = DEFAULT_LIST }, C) end` shares one list - clone it.
- Metatables are lost when tables pass through RemoteEvents/BindableEvents/DataStores - send plain data and rebuild objects.
- `setmetatable` returns the table; `getmetatable` respects `__metatable`.
- Type checker: annotate `self` (see luau.types.typechecking) or use `typeof(setmetatable(...))`.
