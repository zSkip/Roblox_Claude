# Combat System — V2

V2 has four goals:
- restructure the code into a **single-script architecture**
- wire up the **real animations**, with frame data both sides agree on
- add **LoL-style attack speed**
- add a **tiered animation lock**

Sources:
- the Trello cards *Animation Locking* and *League of Legends Stats* (GameIdeasDoc), and *Indexer (Remote Events)* (CombatTestGame)
- the three SSA DevForum threads (listed in `skills/roblox.architecture.single-script-ssa.skill.md`)

## 1. Done in this iteration

### Single-script architecture
- **Two entry scripts only:** `ServerScriptService/Main` and `StarterPlayerScripts/Main`. `Core/Loader` runs every module in `Services/` and `Controllers/` in two phases: `Init` (sync; errors if it yields; dependencies come from `Get("Name")`), then `Start` (own thread).
- **New layout:** `ReplicatedStorage/{Core, Shared/Combat, Assets/Animations}`. The `TestKit` module moved into `Core`, and `Combat/Net` became `Shared/Combat/CombatNet`.
- **The old `CombatServer` entry script was split** into `PlayerService`, `IntentService` and `DummyService`. The old `CombatService` module was split into `CombatService` (state) and `HitService` (hits, claims, resolution).
- **The old `CombatClient` entry script was split** into `CombatController`, `InputController`, `AnimationController` and `MovementController`. `Fx` and `Hud` became `FxController` and `HudController`.
- **The old `RunTests` script became `TestService`** (Studio only).
- **Indexer standard:** `Core/Net` routes by a numeric id hashed from the channel name, instead of sending the name string.

### Animations and frame data
- **Animation mapping** (60 fps):
  - Attacks: W_Hit / A_Hit / S_Hit / D_Hit = W / A / S / D + M1.
  - Dodges: Crouch = W+Q, A_SideStep = A+Q, BackDodge = S+Q, D_SideStep = D+Q.
- **Baked manifest:** `Tools/AnimationBake` writes `Shared/Combat/AnimationManifest` (length, loop flag and markers per id) from KeyframeSequenceProvider.
- **Hit frames:** the **last 16 frames** of an attack animation are the hit (active) frames, and everything before is windup (`CombatConfig.Animation.HitFrames`). `Windup` / `HitEnd` KeyframeMarkers override this once you add them. The spec's `Recovery` follows the clip.
- **Playback and validation:**
  - The client plays your own character's animations, and the server plays NPCs' animations (`AnimationPlayer`).
  - Both sides preload the tracks and warn if a track's real length is off from the manifest by more than one frame.
  - The server validates hit-claim timing from the same `Timeline` math, never from tracks.
- **The procedural sword swing now only runs** for attacks whose animation is still a placeholder.

### Attack speed (LoL rule)
`Shared/Combat/Timeline`:
```
AttackTime = BaseTime / AttackSpeed
Windup     = BaseWindup + (AttackTime × WindupPercent − BaseWindup) × WindupModifier
```
- `WindupModifier = 0.5` for every attack (`CombatConfig`; a spec may override it). The windup shrinks half as fast as the rest of the swing, so the telegraph stays readable when attacks get faster.
- The animation plays its windup at `WindupSpeed`, then `AdjustSpeed(ActiveSpeed)` takes over on the first hit frame.
- Exhaustion already lowers `AttackSpeed` through the StatBlock, so tired attackers' swings slow down on screen and in validation.

### Tiered animation lock
`Shared/Combat/LockProfile`, applied by `MovementController` every frame:

| Tier | When | Effect |
|---|---|---|
| Free | Idle | full movement |
| Steer | attack windup | walk speed eases linearly from 100% to 0 by the last windup frame; turning toward the camera narrows to 35% |
| Rooted | hit frames, recovery | no movement or turning; movement ramps back over the last half of recovery |
| Locked | stun, guard break | nothing |
| Forced | reserved | knockback / airborne |

- **Server side:** it sends a per-state `WalkCap` attribute.
- **Anti-slide:** `HitService` rejects hit claims from attackers who moved further during the windup than the curve allows (`MaxTravel` + 3 studs of slack).
- **Input buffer:** an M1 pressed while busy is kept for `Timings.InputBuffer` (0.2 s) and sent when you return to Idle.

### Checked in Studio
- **Tests:** 116 specs pass (new specs: Loader, Timeline, LockProfile).
- **W+M1 playtest:**
  - W_Hit plays at 1.0×.
  - Walk speed goes 14.4 → 0 over the 38 windup frames, the character is rooted through the 16 hit frames, and movement ramps back during recovery.
  - The attack returns to Idle at 1.25 s.
- **A+Q** plays A_SideStep stretched to the 0.3 s dodge, and **W+Q** plays the looped Crouch.
- Tracks loaded on the client and the server match the manifest lengths.

## 2. Known gaps / needs you
- **Avatar type must be R6.** The test place currently spawns R15 avatars (`TimeForBeastMode is not R6`), so the R6 animations won't pose correctly on players until **Game Settings → Avatar → R6** is set. NPC dummies are already R6.
- **Missing animations:** block and parry have no animations yet. They use spec timings and the procedural swing. Combo M1s reuse the directional hit clips (M1.1/M1.3 = D_Hit, M1.2 = A_Hit, M1.4 = W_Hit) at `AnimationSpeed` 1.5 / 1.25 with `WindupModifier = 1`, so their windup stays shorter than the directionals'.
- **Weapon Motor6Ds** follow the Tool6D pattern (`skills/roblox.animation.motor6d-weapon-rigging.skill.md`): `Schema.Motors` links, `Weapon/Motors/Link_<i>`, RightGrip removed, cleared on detach/destroy.
- **Directional spec timings are only a fallback now.** The schema's `Startup` / `Active` numbers for directionals are ignored while the animations exist (the animation is the source of truth). `Recovery` is still used.
- **Shift-lock interplay** with the `CombatTurn` AlignOrientation has only been checked without shift-lock. Try a windup with shift-lock on.
- **Studio is pushed from git by hand.** Rojo isn't installed and the place has HTTP requests disabled. Changes were made in Studio through MCP and mirrored into `src/`, and both were checked for byte parity.

## 3. Next (from the V2 plan)
1. **StatusEffects system** (EffectService + `Shared/StatusEffects`), designed in `docs/status-effect-system.md`:
   - CC types: Stun, Root, Slow, Cripple (cuts AS), Disarm, Silence, Airborne/Knockup, Knockback.
   - Tenacity with LoL's 0.3 s minimum.
   - Stunned and GuardBroken migrate onto it, and each effect maps to a lock tier.
2. **Stats:**
   - Offense: AD/AP scaling, crit chance and damage (a "Black flash" hook), life steal, physical vamp, omnivamp.
   - Defense and utility: HP5, heal and shield power (plus a Shield effect), slow resist, attack range feeding hitbox reach.
3. **Hitstop** on contact (2–4 frames, scaled by damage), **feints** (`Feint` is already in the schema), combo breaker.
4. **Frame-data debug overlay:** phase, frame N/M, AS, lock tier, client vs server drift.
5. **Scheduler:** one Heartbeat with per-combatant timelines instead of `task.delay` chains, so attack speed can change mid-swing.
6. **Later:** limb HP / bleed (*Advanced medical system*, *Cut Condition*), movement tech (*Movement Ideas*, *Jumps Having Weight*).
