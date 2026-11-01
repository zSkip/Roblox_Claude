---
name: roblox.architecture.single-script-ssa
description: Single-script architecture (SSA) as this project uses it from V2 - one Script and one LocalScript as the only entry points, every system a ModuleScript run by Core/Loader with an Init (sync, no yielding, Get dependencies) then Start (own thread) lifecycle, Services (server) vs Controllers (client) vs plain shared modules, priorities and load order, how modules talk (Get, signals, Net channels), the project folder layout, adding a new service/controller, testing lifecycle modules, pitfalls (cyclic requires, yielding in Init, top-level side effects, command-bar require cache) and when SSA is overkill. Use when adding, moving or wiring any module, or when deciding where new code lives.
---

# Single-Script Architecture (SSA)

Companion skills: roblox.instance.hierarchy-services (where code runs), core.contracts.interfaces (Signal, Net, Hitbox, Maid), game.combat.architecture-patterns (dual-context shared modules), luau.testing.unit-tests.

## 1. What SSA means

**One server `Script` and one client `LocalScript` are the only entry points. Everything else is a ModuleScript.** The entry scripts decide the load order. Without SSA, Roblox starts scripts in an effectively random order, which causes race conditions between systems.

What the DevForum threads this project was built from agree on, and where they disagree:
- **Single entry, not a monolith.** "Put everything in one script" is monolithic: it's unreadable and makes the editor lag. SSA is one entry point with the work in modules. (colbert2677, *Single script architecture and modular programming*)
- **Code at the top level of a module runs once, when it's first required.** Every later require gets the same table back. (*SSA: how does it work*, ChickHenEn)
- **Entry scripts can call explicit init functions** instead of blindly requiring everything (Emorser). This project keeps both ideas: a folder sweep plus an explicit `Init`/`Start` lifecycle.
- **Each system owns its own state; no globals.** "Nothing should have access to everything." Modules expose a small API and are reached by name. (*How do you architect an SSA*, #17)
- **The criticisms:** SSA is overkill for tiny projects, and it can feel "janky." The Knit framework is a similar design. The lifecycle below is a small, dependency-free version of Knit's.
- The 200-local limit applies per function scope, not per script, so it's not an argument against modules.

Sources:
- https://devforum.roblox.com/t/single-script-architecture-how-does-it-work-how-can-i-learn-it/2060738
- https://devforum.roblox.com/t/how-do-you-architect-a-single-script-architecture/1550226/17
- https://devforum.roblox.com/t/single-script-architecture-and-modular-programming/2432662

## 2. Project layout (V2)

```
ReplicatedStorage
├─ Core/                     infrastructure, no game rules
│  ├─ Loader                 SSA lifecycle runner (this skill)
│  ├─ Deps                   the one place that picks implementations (Signal, Net, Hitbox, Maid)
│  ├─ Signal, Net, Hitbox, Maid, TestKit
├─ Shared/
│  └─ Combat/                pure / dual-context game modules, plain requires (no lifecycle)
│     ├─ WeaponClass, Attacks, Combatant, Resolver, Stats, Exhaustion, Limbs, Directions, Movement, WeaponModel
│     ├─ Timeline, LockProfile, AnimationPlayer, AnimationManifest (generated)
│     ├─ CombatConfig, CombatEnums, CombatNet (channel definitions)
│     └─ Weapons/LinkedSword
└─ Assets/
   └─ Animations/            Animation instances (Rojo: *.model.json)
ServerScriptService
├─ Main                      ← the only server Script: Loader.Run({ Services })
├─ Services/                 lifecycle modules, server only
│  ├─ CombatService  (20)    combatants, state machine, intents → states, regen tick
│  ├─ AnimationService (25)  NPC animations
│  ├─ HitService     (30)    server hitboxes, claim validation, resolution
│  ├─ IntentService  (40)    rate-limited client intents / claims → services
│  ├─ PlayerService  (50)    characters → combatants
│  ├─ DummyService   (60)    training NPCs
│  └─ TestService  (1000)    Studio only: runs Tests/*.spec
├─ Tests/                    *.spec modules (not lifecycle modules)
└─ Tools/                    Studio command-bar tools (AnimationBake), never required by the game
StarterPlayer/StarterPlayerScripts
├─ Main                      ← the only LocalScript: waits for game.Loaded, Loader.Run({ Controllers })
└─ Controllers/              lifecycle modules, client only
   ├─ FxController (10), HudController (10)
   ├─ CombatController (20)  own character, intents, local hitbox → claims, broadcast fan-out
   ├─ AnimationController (30), MovementController (30)
   └─ InputController (40)
```
The numbers are `Priority` values: lower runs `Init` first, and equal priorities run in name order. Order only matters for `Init` side effects. Dependencies are resolved by name (`Get`), so you can read the list as "who sets up first."

Naming: server lifecycle modules end in **`Service`** and client ones in **`Controller`**. Shared modules have plain names and are never in a lifecycle folder.

## 3. The lifecycle contract (Core/Loader)

```luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CombatNet = require(ReplicatedStorage.Shared.Combat.CombatNet)   -- shared modules: plain requires

local ExampleService = { Priority = 45 }        -- optional, default 100

local CombatService : any = nil                 -- other lifecycle modules: filled in Init

function ExampleService.Init(_self : any, Get : (string) -> any)
	CombatService = Get("CombatService")         -- look up, don't use yet
	-- create signals / tables here; no yielding, no event connections that can fire
end

function ExampleService.Start(_self : any)
	-- every Init has returned: connect events, start loops; yielding is fine
	CombatService.StateChanged:Connect(function(C, State) end)
end

-- public API: plain functions (this codebase uses Module.Fn(C, ...) style, not methods)
function ExampleService.DoThing(C : any) end

return ExampleService
```

Rules the Loader enforces:
| Rule | What happens otherwise |
|---|---|
| A module must return a table | `[Loader] X must return a table` |
| Names are unique across the folders passed to `Run` | `two modules named X` |
| `Get("Name")` must exist | `no module named Name` (error points at the caller) |
| `Init` must not yield (`task.wait`, `WaitForChild` on something missing, `:Wait()`, InvokeServer...) | `X.Init yielded; move waits and connections into Start` |
| `Init` errors stop the boot | the error plus the Init thread's traceback |

`Start` runs in `task.spawn`. An error there is printed with a traceback and doesn't stop other modules' `Start`.

`Loader.Run(Folders)` requires every ModuleScript **directly** inside the folders. Subfolders aren't swept, so helper modules can live in a subfolder next to the service that uses them. `Loader.RunModules({ {Name, Module} })` does the same thing for tables you've already built, which is what the specs use.

## 4. How modules talk

| Need | Use |
|---|---|
| call another service / controller | `Get("Name")` in `Init`, store it in a local, call it from `Start` or later |
| react to something another module does | that module exposes a `Deps.Signal` field (`CombatService.StateChanged`, `HitService.Resolved`, `CombatController.StateChanged`) |
| server ↔ client | channels in `Shared/Combat/CombatNet` (Core/Net: one batched RemoteEvent, typed, numeric channel ids) |
| shared logic / data | a plain module in `Shared/`, required directly; pure if possible (unit-testable) |
| one-off tuning | `CombatConfig` (frozen) |

Two lifecycle modules may `Get` each other: CombatService ↔ HitService do this. That's fine because both tables exist before any `Init` runs. What isn't fine is two modules **requiring** each other at the top level (a cyclic require). Use `Get` for lifecycle modules, and keep shared modules in a one-way dependency order: Core ← Shared ← Services/Controllers.

Shared modules never `Get` anything and never branch on `RunService:IsServer()`. Each side wires them up (game.combat.architecture-patterns §1). Infrastructure in `Core/` (Net) may branch internally.

## 5. Adding things

- **New server system:** add `ServerScriptService/Services/FooService.luau` with `Priority`, `Init` and `Start` as needed. No entry script changes.
- **New client system:** add `StarterPlayerScripts/Controllers/FooController.luau`.
- **New shared logic:** add `ReplicatedStorage/Shared/Combat/Foo.luau` (or a new `Shared/<Domain>/` folder) plus `ServerScriptService/Tests/Foo.spec.luau`.
- **New network message:** add one `Net.Define("S_Foo", {types})` line to `CombatNet`. Ids are hashed from the name, so order doesn't matter, and a collision errors at boot.
- **New weapon:** add a module in `Shared/Combat/Weapons/`. `WeaponClass.LoadAll()` (called in CombatService.Init and CombatController.Init) picks it up.
- **New animation:** upload it, drop the Animation into `Assets/Animations`, then run `require(game.ServerScriptService.Tools.AnimationBake).Run()` from the command bar.

## 6. Pitfalls

- **Top-level side effects.** Code at the top level of a lifecycle module runs during the folder sweep, before any `Init`. Keep it to requires and table construction. Instance creation that never yields is acceptable (HudController builds its ScreenGui at the top level and parents it in `Start`).
- **Yielding in Init.** `Model:WaitForChild(...)`, `Player.CharacterAdded:Wait()` and the like go in `Start`, or in a `task.spawn` from `Start`.
- **Client replication.** The client `Main` waits for `game.Loaded` first, so controllers can index `ReplicatedStorage.Shared.Combat.X` directly without a `WaitForChild` chain.
- **Late subscribers.** If a controller's `Start` needs state another controller sets asynchronously (for example the character), do both: connect the signal **and** check the current value (`CombatController.CharacterChanged` plus `CombatController.Character`).
- **Command bar and MCP `execute_luau` run in a separate VM.** `require(ServerScriptService.Services.CombatService)` there returns a **fresh** copy with no combatants, not the running game's module. To poke the live game, go through the network (fire a `CombatNet` channel from the client context) or read instances and attributes.
- **Debugging.** Errors name the module (`[Loader] HitService.Init failed: ...`). Because every system is a module with a name, there are no anonymous cloned scripts to hunt for.
- **When it's overkill.** A one-off prop script (a door, a kill brick) can still be a lifecycle module in `Services`. Don't build a mini-framework inside a module; split it into another module instead.

## 7. Testing lifecycle modules

The pure logic sits in `Shared/` and is tested directly. To test lifecycle wiring, pass tables to `Loader.RunModules`:
```luau
Loader.RunModules({
	{ Name = "Other", Module = { Value = 7 } },
	{ Name = "User", Module = { Init = function(_self, Get) Seen = Get("Other").Value end } },
})
```
`TestService` (priority 1000, Studio only) runs every `ServerScriptService/Tests/*.spec` after boot and prints `[TestKit] N passed, M failed`.
