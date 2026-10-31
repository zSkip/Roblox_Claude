# Roblox_Claude — Combat System v1

Planning docs and reference skills for an OOP, schema-driven, reaction-based combat system on Roblox (Luau).
It uses **ProfileStore** for data, **GoodSignal** for events and **Packet** for networking.

- **Plan:** [`docs/combat-system-plan.md`](docs/combat-system-plan.md). It covers the architecture, the review of the current code, the schema, a WeaponClass sketch, combat rules, packets, milestones, open questions and improvement ideas.

## Skills

Project constraints: **R6 only**, no `Tool` class, weapons on a `Motor6D`, client-side hit detection with multi-client validation, PvP + PvE, built around shift-lock.

**No skill hard-requires a third-party module.** Game and engine skills code against `core.contracts.interfaces`, which ships built-in implementations. The `lib.*` / `project.*` skills document optional adapters (Packet, GoodSignal, ProfileStore, HitboxClass, Indexer).

## Code

| Path | What |
|---|---|
| `src/ReplicatedStorage/TestKit.luau` | zero-dependency unit test kit (`Describe` / `It` / `Expect`) |
| `src/ServerScriptService/Tests/RunTests.server.luau` | runs every `*.spec` module when you press Play in Studio |
| `src/ReplicatedStorage/Combat/Directions.luau` (+ spec) | direction mirror/opposite, incoming side, configurable parry / counter-dodge matcher |
| `src/ReplicatedStorage/Combat/Exhaustion.luau` (+ spec) | in-combat exhaustion stacks, scaling debuff intensity, out-of-combat decay |
| `src/ReplicatedStorage/Combat/Resolver.luau` (+ spec) | attack vs defense → Outcome (full plan §7 matrix) and per-outcome consequences |
| `src/ReplicatedStorage/Combat/Attacks.luau` (+ spec) | AttackDef registry: register, priority matching, build from a weapon schema |
| `src/ReplicatedStorage/Combat/Stats.luau` (+ spec) | LoL stat formulas and the StatBlock modifier container |
| `default.project.json` | Rojo mapping (optional; or recreate the scripts by hand in Studio) |

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
