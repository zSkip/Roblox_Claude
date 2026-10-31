# Roblox_Claude — Combat System v1

Planning docs and reference skills for an OOP, schema-driven, reaction-based combat system on Roblox (Luau).
It uses **ProfileStore** for data, **GoodSignal** for events and **Packet** for networking.

- **Plan:** [`docs/combat-system-plan.md`](docs/combat-system-plan.md). It covers the architecture, the review of the current code, the schema, a WeaponClass sketch, combat rules, packets, milestones, open questions and improvement ideas.

## Skills

Every file follows the `domain.subject.focus.skill.md` naming scheme and stays under 60 KB.
Each file starts with YAML front-matter (`name`, `description`) so an agent can pick the right one.

| Group | File | Covers |
|---|---|---|
| **lib** (third-party) | [`lib.packet.networking`](skills/lib.packet.networking.skill.md) | Packet constructor, every data type with byte cost, structs/arrays, Fire/FireClient/Response, batching, rate limits, config modules |
| | [`lib.goodsignal.events`](skills/lib.goodsignal.events.skill.md) | GoodSignal API, full source, LIFO ordering, disconnect semantics, typed wrapper, state signals |
| | [`lib.profilestore.datastore`](skills/lib.profilestore.datastore.skill.md) | ProfileStore module/store/profile API, exported types, signals, constants, costs, loader template, data rules |
| **luau** (language) | [`luau.syntax.core`](skills/luau.syntax.core.skill.md) | operators, if-expressions, interpolation, iteration, functions, errors, directives |
| | [`luau.types.typechecking`](skills/luau.types.typechecking.skill.md) | annotations, unions/singletons, generics, typeof/export, type functions, typing classes |
| | [`luau.stdlib.table-string-math`](skills/luau.stdlib.table-string-math.skill.md) | globals, table, string, math, bit32, utf8, os, buffer, vector, coroutine, debug |
| | [`luau.metatables.oop-classes`](skills/luau.metatables.oop-classes.skill.md) | metamethods, classes, inheritance, proxies, blueprint/runtime, state machine, Maid |
| | [`luau.performance.native-optimization`](skills/luau.performance.native-optimization.skill.md) | `--!native`, attributes, hot-path rules, Parallel Luau, profiling |
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
| **game** (domain) | [`game.combat.architecture-patterns`](skills/game.combat.architecture-patterns.skill.md) | dual-context modules, schema, state machine, input layer, M1 chain, resolution matrix, exhaustion, frame data, server/client flow |

### Sources
- ProfileStore: https://github.com/MadStudioRoblox/ProfileStore (read from the repository source and docs)
- GoodSignal: https://gist.github.com/stravant/b75a322e0919d60dde8a0316d1f09d2f (full source)
- Packet: https://devforum.roblox.com/t/packet-networking-library/3573907. The DevForum couldn't be reached from the build environment, so this reference was written from the v1.7.x **library source**, taken from a public mirror of the module. Check it against your copy.
- Luau: https://luau.org
- Roblox Engine API: https://create.roblox.com/docs/reference/engine. Newer APIs are marked *verify* in the skills.
