# Roblox_Claude — Combat System v1

Planning docs and reference skills for an OOP, schema-driven, reaction-based combat system on Roblox (Luau).
It uses **ProfileStore** for data, **GoodSignal** for events and **Packet** for networking.

- **Plan:** [`docs/combat-system-plan.md`](docs/combat-system-plan.md). It covers the architecture, the review of the current code, the schema, a WeaponClass sketch, combat rules, packets, milestones, open questions and improvement ideas.

## Skills

Project constraints: **R6 only**, no `Tool` class, weapons on a `Motor6D`, client-side hit detection with multi-client validation, PvP + PvE, built around shift-lock.

**No skill hard-requires a third-party module.** Game and engine skills code against `core.contracts.interfaces`, which ships built-in implementations. The `lib.*` / `project.*` skills document optional adapters (Packet, GoodSignal, ProfileStore, HitboxClass, Indexer).

## Playtest

1. In Studio, open a new **Baseplate** place and set **Game Settings → Avatar → Avatar Type = R6** (the system is built for R6).
2. Get the code into the place:
   - **With Rojo:** `rojo serve`, then connect from the Rojo Studio plugin. `default.project.json` maps `ReplicatedStorage`, `ServerScriptService` and `StarterPlayer/StarterPlayerScripts`.
   - **By hand:** recreate the `src/` tree in Studio. A folder becomes a Folder, `X.luau` becomes a ModuleScript `X`, `X.server.luau` becomes a Script `X`, and `X.client.luau` becomes a LocalScript `X`. `src/StarterPlayerScripts/Combat` goes in `StarterPlayer > StarterPlayerScripts`.
3. Press **Play**. Unit tests print to Output (`[TestKit] N passed, 0 failed`), you spawn holding a sword, and five training dummies appear:

| Dummy | Does | Try |
|---|---|---|
| Bag (grey) | nothing | combo M1 ×4 (knockback), directional hits fill red limb meters until they burst |
| Blocker (blue) | holds an omni block | chip + posture damage until **GUARD BREAK**; hit it from behind |
| Parrier (gold) | reads your swing and parries, right ~70% of the time | **PARRIED** staggers you; a wrong-direction parry gets punished |
| Dodger (cyan) | counter-dodges your swing | **PERFECT DODGE**, then it answers with its CounterSlash follow-up |
| Fighter (red) | walks up and attacks you | watch the white telegraph + label, then F (block), tap direction + F (parry) or Q (dodge) |

Controls: **M1** combo · **tap W/A/S/D then M1** directional attack (S = knockback) · **hold F** block · **tap direction then F** parry · **Q** dodge (tap a direction first, default back). The label over an attacker names the key that parries it under the current `ParryRule`. Built around shift-lock: without it, your character turns to the camera when you act.

The animations are placeholders (`rbxassetid://0`), so the sword swings procedurally and every state shows a coloured highlight. Put real ids into the `LinkedSword` schema later; no logic changes.

## Code

| Path | What |
|---|---|
| `src/ReplicatedStorage/Core/` | contracts with built-in implementations: `Signal`, `Net` (one batched RemoteEvent + type checks), `Hitbox`, `Maid`, `Deps` (the one place to swap in adapters) |
| `src/ReplicatedStorage/Combat/WeaponClass.luau` (+ spec) | the dual-context weapon constructor: `Define` (validate + freeze + attack registry), builder sugar, per-owner `Runtime` state machine, combo, cooldowns |
| `src/ReplicatedStorage/Combat/Weapons/LinkedSword.luau` | first weapon schema (combo, directionals, CounterSlash follow-up, defense, limbs) |
| `src/ReplicatedStorage/Combat/Combatant.luau` (+ spec) | per-character combat state shared by players and NPCs: posture, exhaustion debuff, limb meters, resolver snapshot, walk speed |
| `src/ReplicatedStorage/Combat/WeaponModel.luau` / `Movement.luau` / `Limbs.luau` | Motor6D weapon attach (procedural sword), dash/knockback bursts, limb group registry |
| `src/ReplicatedStorage/Combat/CombatConfig.luau` / `CombatEnums.luau` / `Net.luau` | global tuning, network ids, combat channels |
| `src/ServerScriptService/Combat/` | `CombatServer` (entry), `CombatService` (intents, claims, resolution, effects), `Dummies` (training NPCs) |
| `src/StarterPlayerScripts/Combat/` | `CombatClient` (input → intents, local hitbox → claims), `Fx` (telegraphs, swings, popups, limb highlights), `Hud` |
| `src/ReplicatedStorage/TestKit.luau` | zero-dependency unit test kit (`Describe` / `It` / `Expect`) |
| `src/ServerScriptService/Tests/RunTests.server.luau` | runs every `*.spec` module when you press Play in Studio |
| `src/ReplicatedStorage/Combat/Directions.luau` (+ spec) | direction mirror/opposite, incoming side, configurable parry / counter-dodge matcher |
| `src/ReplicatedStorage/Combat/Exhaustion.luau` (+ spec) | in-combat exhaustion stacks, scaling debuff intensity, out-of-combat decay |
| `src/ReplicatedStorage/Combat/Resolver.luau` (+ spec) | attack vs defense → Outcome (full plan §7 matrix) and per-outcome consequences |
| `src/ReplicatedStorage/Combat/Attacks.luau` (+ spec) | AttackDef registry: register, priority matching, build from a weapon schema |
| `src/ReplicatedStorage/Combat/Stats.luau` (+ spec) | LoL stat formulas and the StatBlock modifier container |
| `default.project.json` | Rojo mapping (optional, see Playtest) |

Every file follows the `domain.subject.focus.skill.md` naming scheme and stays under 60 KB.
Each file starts with YAML front-matter (`name`, `description`) so an agent can pick the right one.

| Group | File | Covers |
|---|---|---|
| **core** (start here) | [`core.contracts.interfaces`](skills/core.contracts.interfaces.skill.md) | dependency-free contracts (Signal, Net channels + requests, Hitbox query, SessionStore, Maid) with complete built-in implementations and adapter notes |
| **lib** (optional adapters) | [`lib.packet.networking`](skills/lib.packet.networking.skill.md) | Packet constructor, every data type with byte cost, structs/arrays, Fire/FireClient/Response, batching, rate limits, config modules |
| | [`lib.goodsignal.events`](skills/lib.goodsignal.events.skill.md) | GoodSignal API, full source, LIFO ordering, disconnect semantics, typed wrapper, state signals |
| | [`lib.hitboxclass.hitbox`](skills/lib.hitboxclass.hitbox.skill.md) | HitboxClass v1.2.0 setup (Alive folder), params, spatial options, methods, signals, UseClient internals and security gaps |
| | [`lib.profilestore.datastore`](skills/lib.profilestore.datastore.skill.md) | ProfileStore module/store/profile API, exported types, signals, constants, costs, loader template, data rules |
| **luau** (language) | [`luau.syntax.core`](skills/luau.syntax.core.skill.md) | operators, if-expressions, interpolation, iteration, functions, errors, directives |
| | [`luau.types.typechecking`](skills/luau.types.typechecking.skill.md) | annotations, unions/singletons, generics, typeof/export, type functions, typing classes |
| | [`luau.stdlib.table-string-math`](skills/luau.stdlib.table-string-math.skill.md) | globals, table, string, math, bit32, utf8, os, buffer, vector, coroutine, debug |
| | [`luau.metatables.oop-classes`](skills/luau.metatables.oop-classes.skill.md) | metamethods, classes, inheritance, proxies, blueprint/runtime, state machine, Maid |
| | [`luau.performance.native-optimization`](skills/luau.performance.native-optimization.skill.md) | `--!native`, attributes, hot-path rules, Parallel Luau, profiling |
| | [`luau.testing.unit-tests`](skills/luau.testing.unit-tests.skill.md) | what unit tests are, zero-dependency runner, TestEZ, Jest Lua, Lune, resolver matrix tests |
| **roblox** (engine) | [`roblox.instance.hierarchy-services`](skills/roblox.instance.hierarchy-services.skill.md) | Instance API, attributes, tags, script containers/RunContext, require, services, Tool, project layout |
| | [`roblox.scheduler.task-runservice-signals`](skills/roblox.scheduler.task-runservice-signals.skill.md) | task library, RunService frame order, RBXScriptSignal, deferred events, clocks, timing patterns |
| | [`roblox.input.userinput-contextaction`](skills/roblox.input.userinput-contextaction.skill.md) | UserInputService, InputObject, input enums, ContextActionService, Input Action System, tap/hold, direction buffer |
| | [`roblox.animation.animator-tracks`](skills/roblox.animation.animator-tracks.skill.md) | Animator, AnimationTrack, priorities, preloading, Length gotcha, replication, combat patterns |
| | [`roblox.character.humanoid-players`](skills/roblox.character.humanoid-players.skill.md) | Players/Player, character lifecycle, Humanoid API, HumanoidStateType, damage, movement modifiers, rigs |
| | [`roblox.spatial.raycast-overlap-hitbox`](skills/roblox.spatial.raycast-overlap-hitbox.skill.md) | Raycast/shapecasts, overlap queries, params, collision groups, hitbox recipes, server validation |
| | [`roblox.physics.movers-knockback`](skills/roblox.physics.movers-knockback.skill.md) | impulses, network ownership, LinearVelocity/Align*, knockback, dash, ragdoll |
| | [`roblox.network.remotes-replication-security`](skills/roblox.network.remotes-replication-security.skill.md) | replication rules, remotes and limits, StreamingEnabled, validation checklist, rate limiting, latency |
| | [`roblox.datatypes.cframe-vector-math`](skills/roblox.datatypes.cframe-vector-math.skill.md) | Vector3/Vector2/CFrame, other datatypes, Enum API, direction math |
| | [`roblox.feedback.tween-vfx-sound-camera`](skills/roblox.feedback.tween-vfx-sound-camera.skill.md) | TweenService, Debris, particles/trails/Highlight, Sound, camera shake, combat UI, per-outcome feel |
| | [`roblox.data.datastore-messaging-memory`](skills/roblox.data.datastore-messaging-memory.skill.md) | DataStoreService, OrderedDataStore, BindToClose, MessagingService, MemoryStoreService |
| **project** (yours, optional adapter) | [`project.indexer.networking`](skills/project.indexer.networking.skill.md) | your Indexer module: API, types, bugs to fix, running it on Packet |
| **game** (domain) | [`game.combat.architecture-patterns`](skills/game.combat.architecture-patterns.skill.md) | dual-context modules, schema, state machine, input layer, M1 chain, configurable parry rule, resolution matrix, posture/exhaustion, feints, combo breaker, server/client flow |
| | [`game.combat.hit-validation-multiclient`](skills/game.combat.hit-validation-multiclient.skill.md) | client hit claims, server hard checks, position/state history rewind, victim corroboration, witness trust score |
| | [`game.combat.limb-damage-highlight`](skills/game.combat.limb-damage-highlight.skill.md) | R6 direction→limb mapping, limb meters, red highlight → burst, white attack telegraph, Highlight budget |
| | [`game.combat.animation-movement-lock`](skills/game.combat.animation-movement-lock.skill.md) | timeline lock windows, Controls:Disable, rotation lock, jump lock, anti-slide validation |
| | [`game.status-effects.lol-stats-cc`](skills/game.status-effects.lol-stats-cc.skill.md) | LoL stats and formulas, modifier stacking, CC taxonomy, stack modes, StatBlock/StatusController, replication |

### Sources
- ProfileStore: https://github.com/MadStudioRoblox/ProfileStore (read from the repository source and docs)
- GoodSignal: https://gist.github.com/stravant/b75a322e0919d60dde8a0316d1f09d2f (full source)
- Packet: https://devforum.roblox.com/t/packet-networking-library/3573907. The DevForum couldn't be reached from the build environment, so this reference was written from the v1.7.x **library source**, taken from a public mirror of the module. Check it against your copy.
- HitboxClass: https://github.com/RedTrioVirus/HitboxClass/releases (v1.2.0 source and README)
- Indexer: the module source you provided
- League of Legends stats: built from LoL's public mechanics. The Trello card couldn't be reached from the build environment.
- Luau: https://luau.org
- Roblox Engine API: https://create.roblox.com/docs/reference/engine. Newer APIs are marked *verify* in the skills.
