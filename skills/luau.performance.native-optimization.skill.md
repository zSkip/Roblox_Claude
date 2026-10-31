---
name: luau.performance.native-optimization
description: Luau performance - native code generation (--!native, @native), optimization levels, fast-path rules (locals, table preallocation, avoiding closures/varargs in hot loops, method caching), function attributes (@native, @checked, @deprecated), Parallel Luau basics, profiling with MicroProfiler and debug.profilebegin. Use for hot code like per-frame hitboxes and input processing.
---

# Luau — Performance & Native Codegen

## 1. Directives & attributes

```luau
--!native            -- whole script compiled to machine code (server & Studio; client support varies by platform)
--!optimize 2        -- inlining, loop unrolling (default in live games is 2; Studio default 1)

@native
local function HotLoop(parts: {BasePart}) ... end   -- per-function native

@deprecated
local function OldApi() end                            -- linter warning at call sites

@checked                                               -- (builtin-style arg checking; mostly library use)
```
Native helps numeric/buffer/vector-heavy code. Type annotations (`number`, `Vector3`, `buffer`) let native code skip type checks - annotate hot functions.

## 2. Rules of thumb

| Do | Why |
|---|---|
| Cache globals/services in locals (`local Vector3new = Vector3.new`) at top of module | upvalue/local access is cheap; Luau also has fast-path builtins (`math.*`, `Vector3.new` are already fast; caching matters most for `game:GetService` results and deep tables) |
| `table.create(n)` for known-size arrays | avoids rehash |
| Reuse tables (`table.clear`) in per-frame code | less GC |
| Avoid creating closures per frame/per hit | allocations |
| Use numeric `for` / generalized `for` over arrays | fastest iteration |
| Avoid `select("#", ...)`/`{...}` in hot paths | vararg packing allocates |
| Prefer `:` method calls on tables with table `__index` | inline caching |
| Avoid `getfenv`/`setfenv`/`loadstring` | disables optimizations for the script |
| Use `buffer` for bit-packed data | compact, native-friendly |
| Use `os.clock()` deltas, not `tick()` | precision |

## 3. Roblox-specific costs

- Property reads on Instances cross the engine bridge: cache `HumanoidRootPart` refs, don't call `FindFirstChild` every frame.
- `GetDescendants()` allocates a new array each call.
- Spatial queries: `GetPartBoundsInBox` (AABB) is cheaper than `GetPartsInPart` (exact geometry). Filter with `OverlapParams` instead of filtering results in Lua.
- Connections: one `RunService.Heartbeat` loop that iterates active objects beats N separate connections.
- `task.spawn` per item has overhead; batch work.
- Attribute changes and Instance property sets replicate - batch / throttle.

## 4. Parallel Luau (Actors)

```luau
-- Script under an Actor
local RunService = game:GetService("RunService")
RunService.Heartbeat:ConnectParallel(function(dt)
	-- parallel phase: read-only access to most of the DataModel, compute
	local result = ComputeExpensive()
	task.synchronize()                 -- switch to serial phase to write
	ApplyResult(result)
end)
```
- `task.desynchronize()` / `task.synchronize()` switch phases.
- `Actor:SendMessage(topic, ...)` / `actor:BindToMessage(topic, fn)` / `BindToMessageParallel`.
- `SharedTable` for data shared between actors.
- Worth it only for heavy CPU work (pathing, many raycasts); a fighting game with <50 players rarely needs it.

## 5. Profiling

```luau
debug.profilebegin("Combat.ResolveHits")
-- ...
debug.profileend()
```
Open MicroProfiler (Ctrl+F6 / Ctrl+Alt+F6 in client), Developer Console (F9) -> Memory/Scripts/Network tabs, Script Profiler in Studio.

## 6. Hot path checklist for a combat system

1. Input handler: O(1) table lookups (`KeyToDirection[input.KeyCode]`), no allocations.
2. Hitbox: one query per active hit window, `OverlapParams` filter = attacker's character; dedupe hits with a per-swing `{[Model]: true}` table reused per swing.
3. Network: one packet per action (Packet batches per frame), numbers quantised.
4. Animations: load tracks once per character, never per swing.
