---
name: lib.goodsignal.events
description: stravant's GoodSignal (Batched Yield-Safe Signal) for Luau - full API, internals (runner-thread reuse, linked list), ordering and disconnect semantics, strictness, typed wrapper, and reaction/event-driven patterns (state entered/exited, combat events). Use when creating custom events in modules.
---

# GoodSignal (stravant) — Custom Events

Gist: `https://gist.github.com/stravant/b75a322e0919d60dde8a0316d1f09d2f` (MIT, "Good Roblox Signal Implementation", file `GoodSignal.lua`).
Behaves like `RBXScriptSignal` but is pure Luau, fires **immediately** (synchronously spawns handlers) and reuses one coroutine for handlers that don't yield.

## 1. API

```luau
local Signal = require(game.ReplicatedStorage.Packages.GoodSignal)

local sig = Signal.new()
local cn  = sig:Connect(function(a, b, ...) end)   -- -> Connection
local cn2 = sig:Once(function(...) end)             -- auto-disconnects before running
sig:Fire(a, b, ...)                                 -- runs handlers now
local a, b = sig:Wait()                             -- yields until next Fire
cn:Disconnect()
sig:DisconnectAll()
```

| Member | Kind | Notes |
|---|---|---|
| `Signal.new()` | constructor | `{ _handlerListHead = false }` |
| `Signal:Connect(fn)` | method | Prepends node to linked list; returns Connection |
| `Signal:Once(fn)` | method | Connection that disconnects itself, then calls `fn(...)` |
| `Signal:Wait()` | method (yields) | Temporary self-disconnecting connection + `coroutine.yield()`; resumed with `task.spawn(waitingCoroutine, ...)` |
| `Signal:Fire(...)` | method | Walks list; `task.spawn(freeRunnerThread, fn, ...)` per connected node |
| `Signal:DisconnectAll()` | method | Sets `_handlerListHead = false` only |
| `Connection:Disconnect()` | method | `_connected = false`, unlinks node, keeps node's `_next` |
| `Connection._connected` | field | boolean, read it if you need `Connected` (there is no public `Connected` property) |
| `Connection._signal`, `._fn`, `._next` | fields | internal |

**Strict:** both `Signal` and `Connection` class tables have metatables whose `__index`/`__newindex` error: `Attempt to get Signal::<key> (not a valid member)`. Typos like `sig:connect()` throw immediately. (Writes to *instances* are not blocked; only unknown reads error.)

## 2. Full source (reference)

```luau
local freeRunnerThread = nil

local function acquireRunnerThreadAndCallEventHandler(fn, ...)
	local acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	-- The handler finished running, this runner thread is free again.
	freeRunnerThread = acquiredRunnerThread
end

local function runEventHandlerInFreeThread()
	while true do
		acquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end

local Connection = {}
Connection.__index = Connection

function Connection.new(signal, fn)
	return setmetatable({ _connected = true, _signal = signal, _fn = fn, _next = false }, Connection)
end

function Connection:Disconnect()
	self._connected = false
	if self._signal._handlerListHead == self then
		self._signal._handlerListHead = self._next
	else
		local prev = self._signal._handlerListHead
		while prev and prev._next ~= self do prev = prev._next end
		if prev then prev._next = self._next end
	end
end

setmetatable(Connection, {
	__index = function(tb, key) error(("Attempt to get Connection::%s (not a valid member)"):format(tostring(key)), 2) end,
	__newindex = function(tb, key, value) error(("Attempt to set Connection::%s (not a valid member)"):format(tostring(key)), 2) end,
})

local Signal = {}
Signal.__index = Signal

function Signal.new() return setmetatable({ _handlerListHead = false }, Signal) end

function Signal:Connect(fn)
	local connection = Connection.new(self, fn)
	if self._handlerListHead then
		connection._next = self._handlerListHead
		self._handlerListHead = connection
	else
		self._handlerListHead = connection
	end
	return connection
end

function Signal:DisconnectAll() self._handlerListHead = false end

function Signal:Fire(...)
	local item = self._handlerListHead
	while item do
		if item._connected then
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
				coroutine.resume(freeRunnerThread)
			end
			task.spawn(freeRunnerThread, item._fn, ...)
		end
		item = item._next
	end
end

function Signal:Wait()
	local waitingCoroutine = coroutine.running()
	local cn
	cn = self:Connect(function(...)
		cn:Disconnect()
		task.spawn(waitingCoroutine, ...)
	end)
	return coroutine.yield()
end

function Signal:Once(fn)
	local cn
	cn = self:Connect(function(...)
		if cn._connected then cn:Disconnect() end
		fn(...)
	end)
	return cn
end

setmetatable(Signal, { --[[ same strict __index/__newindex as Connection ]] })
return Signal
```

## 3. Semantics you must know

- **Order is LIFO**: `Connect` prepends, so the *last connected handler runs first*. If order matters (e.g. "apply damage" before "play VFX"), don't rely on connection order - use separate signals or a priority list.
- **Immediate**: handlers start inside `Fire`. Non-yielding handlers finish before `Fire` returns -> state they set is visible right after `Fire`. Contrast with Packet's internal signal / Roblox deferred events which run later.
- **Yielding handlers**: if a handler yields (`task.wait`, `WaitForChild`), the runner thread is "taken" by the scheduler and `Fire` creates a new runner for the next handler. Fire does not wait for yielded handlers.
- **Errors**: an erroring handler kills only its runner thread (error printed via `task.spawn`), other handlers still run.
- **Disconnect during Fire**: disconnected nodes are skipped; an in-flight Fire can still walk past an unlinked node. Connections added during Fire are prepended *behind* the iterator -> not called in that Fire.
- **DisconnectAll during Fire** does not set `_connected=false` on existing nodes: an in-progress Fire keeps calling the remaining handlers.
- **Re-entrancy**: firing the same signal from inside its handler works (new runner created).
- No `Destroy` method; `DisconnectAll` is the cleanup.

## 4. Typed wrapper (strict mode friendly)

GoodSignal is untyped. Wrap it to get autocomplete:

```luau
--!strict
local GoodSignal = require(script.Parent.GoodSignal)

export type Connection = { Disconnect: (self: Connection) -> (), _connected: boolean }
export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

local function new<T...>(): Signal<T...>
	return GoodSignal.new() :: any
end

return { new = new }
```

Usage: `local StateEntered: Signal.Signal<string, number> = Signal.new()`.

## 5. Reaction-based patterns

### State entered / exited (replaces BoundFunctions / BoundMaids lists)
```luau
local State = {}
State.__index = State

function State.new(name: string)
	return setmetatable({
		Name = name ;
		IsActive = false ;
		Entered = Signal.new() ;  -- (context)
		Exited  = Signal.new() ;  -- (context, reason)
	}, State)
end

function State:SetActive(active: boolean, context: any, reason: string?)
	if self.IsActive == active then return end
	self.IsActive = active
	if active then self.Entered:Fire(context) else self.Exited:Fire(context, reason) end
end
```
Server script: `IdleState.Entered:Connect(StartServerLogic)`. Client script: `IdleState.Entered:Connect(PlayAnim)`. Shared module never checks context.

### Cancellable / validating hooks
GoodSignal can't return values. For "can this happen?" checks use a hook list instead:
```luau
local Validators: {(ctx) -> boolean} = {}
local function CanEnter(ctx) for _, v in Validators do if not v(ctx) then return false end end return true end
```

### Cleanup
Store connections and disconnect on owner destroy:
```luau
local Connections = {}
table.insert(Connections, Weapon.Equipped:Connect(OnEquip))
-- later
for _, c in Connections do c:Disconnect() end
table.clear(Connections)
```

### Signal per instance vs global bus
- Per-object signals (`weapon.Hit`) = local reactions.
- One module-level bus (`CombatEvents.HitLanded:Fire(attacker, defender, info)`) = cross-system reactions (UI, sound, analytics) without coupling.

## 6. When to use which signal

| Need | Use |
|---|---|
| In-module custom events, synchronous, fast | GoodSignal |
| Engine events | `RBXScriptSignal` (`Instance.Changed`, `Humanoid.Died`) |
| Cross script, same side, through instances | `BindableEvent` (copies tables! loses metatables) - prefer a shared ModuleScript + GoodSignal |
| Network | Packet (`OnServerEvent`/`OnClientEvent`) |
