---
name: roblox.scheduler.task-runservice-signals
description: Roblox task scheduler and timing - task library (spawn/defer/delay/wait/cancel), RunService frame events in order (PreRender, PreAnimation, PreSimulation, PostSimulation, Heartbeat) and legacy aliases, BindToRenderStep with Enum.RenderPriority, RBXScriptSignal/RBXScriptConnection API, deferred vs immediate SignalBehavior, clocks (os.clock, time, GetServerTimeNow), cooldown/timing-window patterns. Use for anything frame-based, timed or event-driven.
---

# Roblox — Task Scheduler, RunService, Signals, Time

## 1. task library

| Function | Behaviour |
|---|---|
| `task.spawn(fnOrThread, ...)` -> thread | run **now** (immediately, until it yields) |
| `task.defer(fnOrThread, ...)` -> thread | run at end of current resumption cycle (same frame, later) |
| `task.delay(seconds, fnOrThread, ...)` -> thread | run after delay (on Heartbeat granularity) |
| `task.wait(seconds?)` -> elapsed | yield (min one frame); returns actual time |
| `task.cancel(thread)` | stop a scheduled/suspended thread (errors if thread is running/normal - wrap in pcall when unsure) |
| `task.synchronize()` / `task.desynchronize()` | Parallel Luau phase switch |

Never use legacy `wait()`, `spawn()`, `delay()` (throttled, 1/30s granularity).

```luau
local thread = task.delay(0.4, function() EndParryWindow(player) end)
-- if state changes early:
task.cancel(thread)
```

## 2. RunService frame pipeline (per frame order)

| Event | Side | Arg | Use |
|---|---|---|---|
| `PreRender` (was `RenderStepped`) | client | `deltaTimeRender` | camera, input sampling, UI, local VFX before frame renders |
| `PreAnimation` | both | `deltaTimeSim` | before animations step - modify Motor6D/animation weights |
| `PreSimulation` (was `Stepped`) | both | `deltaTimeSim` | before physics - set velocities/forces |
| `PostSimulation` (was `Heartbeat`) | both | `deltaTimeSim` | after physics - read final positions, hitboxes |
| `Heartbeat` | both | `deltaTime` | legacy alias of PostSimulation (still widely used) |
| `RenderStepped` | client | `deltaTime` | legacy alias of PreRender |
| `Stepped` | both | `(time, deltaTime)` | legacy alias of PreSimulation (two args!) |

Server has no render events. Physics runs at 240Hz internally but these events fire once per frame (~60Hz).

```luau
RunService:BindToRenderStep("CombatCamera", Enum.RenderPriority.Camera.Value + 1, function(dt) end)
RunService:UnbindFromRenderStep("CombatCamera")
```
`Enum.RenderPriority`: `First (0)`, `Input (100)`, `Camera (200)`, `Character (300)`, `Last (2000)`.

Other RunService: `IsServer()`, `IsClient()`, `IsStudio()`, `IsRunning()`, `IsRunMode()`, `IsEdit()`.

## 3. RBXScriptSignal / RBXScriptConnection

```luau
local conn: RBXScriptConnection = humanoid.Died:Connect(function() end)
humanoid.Died:Once(function() end)                 -- auto-disconnects
local arg = signal:Wait()                          -- yields
signal:ConnectParallel(fn)                         -- Actors only
conn.Connected                                     -- boolean
conn:Disconnect()
```
- Instances destroyed via `:Destroy()` disconnect their own signals' connections.
- Connections to other objects' signals (e.g. `RunService.Heartbeat`) **leak** unless disconnected.

### SignalBehavior (Workspace.SignalBehavior)
- `Deferred` (default for new places): engine event handlers run at the next resumption point, not inline when the property changes. Multiple changes in one frame -> handlers see final state. Code that fires an event and expects listeners to have run immediately will break.
- `Immediate`: legacy inline behaviour.
- GoodSignal (custom) is always immediate regardless.

## 4. Clocks

| Source | Use |
|---|---|
| `os.clock()` | high-precision local timer: input windows, cooldowns, frame timing (per machine, not synced) |
| `workspace:GetServerTimeNow()` | **synced** across server & clients (~ms accuracy): timestamps sent over network, lag compensation, synced animations |
| `time()` | seconds since game start (this machine) |
| `DateTime.now().UnixTimestampMillis` | wall clock |
| `os.time()` | unix seconds, integer - too coarse for combat |
| `tick()` | legacy local time; avoid |

Ping: `player:GetNetworkPing()` (seconds, one-way-ish estimate; server-side per player, client-side for self).

## 5. Timing patterns

### Cooldown
```luau
local Cooldowns: {[string]: number} = {}
local function Ready(key: string, duration: number): boolean
	local now = os.clock()
	if (Cooldowns[key] or 0) > now then return false end
	Cooldowns[key] = now + duration
	return true
end
```

### Time window buffer (directional input)
```luau
local LastDirection, LastDirectionTime = nil, -math.huge
local WINDOW = 0.25
local function PushDirection(dir) LastDirection, LastDirectionTime = dir, os.clock() end
local function ConsumeDirection()
	if os.clock() - LastDirectionTime <= WINDOW then
		local d = LastDirection
		LastDirection, LastDirectionTime = nil, -math.huge
		return d
	end
	return nil
end
```
Prefer timestamp comparison over per-frame cleanup loops; nothing to tick.

### Fixed-step accumulator
```luau
local STEP, acc = 1/30, 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	while acc >= STEP do acc -= STEP ; Tick(STEP) end
end)
```

### Per-frame update of many objects (one connection)
```luau
local Active: {[any]: true} = {}
RunService.Heartbeat:Connect(function(dt)
	for obj in Active do obj:Update(dt) end
end)
```

### Timeline from a start timestamp (scheduled hit frames)
```luau
local start = os.clock()
for _, ev in Schema.Timeline do       -- { {At = 0.2, Do = "HitboxOn"}, {At = 0.35, Do = "HitboxOff"} }
	task.delay(ev.At - (os.clock() - start), Dispatch, ev.Do)
end
```
Keep returned threads and `task.cancel` them if the action is interrupted (stun, parry).

## 6. Thread safety notes

- Lua is single-threaded per VM (outside Actors) - no locks, but **yields interleave**: after any `task.wait`/`WaitForChild`/`Async` call, re-check state (`if not self.Alive then return end`).
- Version counters guard stale delayed callbacks:
```luau
self.ActionId += 1
local id = self.ActionId
task.delay(0.3, function() if self.ActionId ~= id then return end ; self:Recover() end)
```
