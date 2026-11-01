---
name: roblox.animation.animator-tracks
description: Roblox animation - Animation, Animator, AnimationTrack (props, methods, events, markers), AnimationController, Enum.AnimationPriority, KeyframeSequence/markers, ContentProvider preloading, track Length loading gotcha, replication rules (client-owned characters), server-side timing without playing, and combat patterns (track cache per character, hit frames via markers, cancel windows, attack speed). Use for anything animation-related.
---

# Roblox — Animation (Animator, AnimationTrack)

## 1. Objects

| Class | Role |
|---|---|
| `Animation` | asset reference: `AnimationId = "rbxassetid://123"` |
| `Animator` | lives under `Humanoid` or `AnimationController`; loads & plays tracks; replicates |
| `AnimationTrack` | a loaded, playable instance of an Animation for one Animator |
| `AnimationController` | animator host for non-Humanoid rigs (props, dummies, weapon models) |
| `KeyframeSequence` / `Keyframe` / `KeyframeMarker` | authoring data (Animation Editor) |
| `Motor6D` | the joints animations drive (C0/C1/Transform) |

## 2. Animator

| Member | Notes |
|---|---|
| `:LoadAnimation(animation: Animation) -> AnimationTrack` | cache the result; loading many times wastes memory (limit ~256 tracks per animator warns) |
| `:GetPlayingAnimationTracks() -> {AnimationTrack}` | |
| `:StepAnimations(dt)` | manual stepping (Studio/plugins) |
| `:ApplyJointVelocities(motors)` | |
| `AnimationPlayed(track)` | event; fires when a track starts on this Animator, including tracks replicated from another machine |
| `.PreferLodEnabled`, `.EvaluationThrottled` | perf |

`Humanoid:LoadAnimation` is deprecated - always use `humanoid:FindFirstChildOfClass("Animator")`. The default `Animate` LocalScript creates the Animator; wait for it: `humanoid:WaitForChild("Animator")`.

## 3. AnimationTrack

Properties:
| Prop | Notes |
|---|---|
| `Animation` | source Animation |
| `Length: number` | seconds; **0 until the asset has loaded** |
| `IsPlaying: boolean` | |
| `Looped: boolean` | overridable per track |
| `Priority: Enum.AnimationPriority` | overridable per track |
| `Speed: number` (ro) | change via `AdjustSpeed` |
| `TimePosition: number` | read/write (seek) |
| `WeightCurrent`, `WeightTarget` | |

Methods:
| Method | Notes |
|---|---|
| `:Play(fadeTime = 0.1, weight = 1, speed = 1)` | |
| `:Stop(fadeTime = 0.1)` | |
| `:AdjustSpeed(speed)` | 0 = freeze (hitstop), >1 faster (attack speed stat) |
| `:AdjustWeight(weight, fadeTime?)` | |
| `:GetMarkerReachedSignal(name) -> RBXScriptSignal(param: string)` | animation events (KeyframeMarker) |
| `:GetTimeOfKeyframe(keyframeName) -> number` | named keyframe time |

Events: `Ended` (fully stopped incl. fade out), `Stopped` (stop begins), `DidLoop`, `KeyframeReached(name)` (legacy named keyframes).

## 4. Enum.AnimationPriority (low -> high)

`Core` (lowest; default rig animations - note its `.Value` is 1000, so don't compare priorities by `.Value`) < `Idle` (0) < `Movement` (1) < `Action` (2) < `Action2` (3) < `Action3` (4) < `Action4` (5).
Typical: weapon idle = `Idle`, walk/run = `Movement`, M1s = `Action`, block hold = `Action`, hit reaction/stun = `Action2`, parry/dodge = `Action3`, guard break / finisher = `Action4`.
Higher priority overrides lower on the joints it animates; equal priority blends by weight.

## 5. Loading & Length gotcha

```luau
local ContentProvider = game:GetService("ContentProvider")
ContentProvider:PreloadAsync({ animA, animB })            -- yields until assets fetched (accepts Instances or content strings)

local track = animator:LoadAnimation(animA)
if track.Length == 0 then
	-- wait for asset metadata
	local t0 = os.clock()
	repeat task.wait() until track.Length > 0 or os.clock() - t0 > 5
end
```
`ContentProvider:PreloadAsync(contentIdList, callback?)` - callback `(contentId, Enum.AssetFetchStatus)`; also `ContentProvider:GetAssetFetchStatus(id)`.

**Store timing data in the schema** (hit start/end times, total length) instead of reading `Length` at runtime on the server. This avoids needing a server "Loader" AnimationController just to read lengths and keeps server logic animation-independent.

## 6. Replication rules

- An Animator under a player's **Humanoid** replicates tracks played by **that player's client** to the server and other clients. So: play local character animations on the client (instant feedback), they show for everyone.
- Tracks played by the **server** on a character replicate to all clients (with latency for the owner - feels delayed).
- `GetMarkerReachedSignal` fires only on the machine that **plays** the track (and replicated tracks fire markers on other clients inconsistently) - don't use markers on the server for client-played animations. Use schema timings on the server.
- NPC/dummy animations: play on the server (or on each client for cosmetics).
- `AnimationController` + `Animator` on a non-character model: server-played tracks replicate.
- Animation assets must be owned by the experience owner (user/group) or they fail to load in live games.

## 7. Project (V2): manifest, frame data, two-speed playback

- **Frame data never comes from playing tracks.** `ServerScriptService/Tools/AnimationBake` (Studio command bar) reads every Animation in `ReplicatedStorage/Assets/Animations` with `KeyframeSequenceProvider:GetKeyframeSequenceAsync` and writes `Shared/Combat/AnimationManifest`: `{ Fps = 60, ById = { [id] = { Name, Length, Looped, Markers } } }`. Both sides read it, so the server validates timing without an Animator.
- **Hit frames:** the `Windup` / `HitEnd` KeyframeMarkers if present; otherwise the last `CombatConfig.Animation.HitFrames` (16) frames. Everything before is windup (Combat/Timeline).
- **Runtime check:** `Shared/Combat/AnimationPlayer` loads tracks on either side and warns once per id if `Track.Length` differs from the manifest by more than one frame (a stale bake).
- **Attack speed:** `AnimationPlayer:PlayAttack(Id, Timeline)` plays at `Timeline.WindupSpeed`, then `AdjustSpeed(Timeline.ActiveSpeed)` at the first hit frame (LoL windup rule, game.combat.architecture-patterns + Combat/Timeline). Dodges use `PlayFor(Id, Duration)` (one-shot clips are stretched to fit, looped ones are stopped when the duration ends).
- **Who plays what:** the owner client animates its own character (AnimationController), and the server animates NPCs (AnimationService). Each track replicates once.
- The client preloads every asset with `ContentProvider:PreloadAsync` and loads every track on spawn, so the first swing doesn't stall.

## 8. Combat patterns

### Track cache per character (load once)
```luau
local function LoadTracks(animator: Animator, anims: {[string]: Animation}): {[string]: AnimationTrack}
	local tracks = {}
	for name, anim in anims do
		local track = animator:LoadAnimation(anim)
		tracks[name] = track
	end
	return tracks
end
-- Reload on respawn (new Animator per character).
```

### Attack speed
```luau
track:Play(0.05, 1, Schema.Stats.AttackSpeed)   -- or track:AdjustSpeed(x) after Play
-- server-side windows must scale by the same factor: hitStart / AttackSpeed
```

### Hitstop on hit
```luau
track:AdjustSpeed(0) ; task.delay(0.06, function() if track.IsPlaying then track:AdjustSpeed(speed) end end)
```

### Markers for client VFX/sounds
```luau
track:GetMarkerReachedSignal("Swing"):Connect(function() PlaySwingSound() end)
track:GetMarkerReachedSignal("Hit"):Connect(function(param) -- param string from marker
end)
```

### Cancel / interrupt
```luau
local function StopAll(tracks, fade)
	for _, t in tracks do if t.IsPlaying then t:Stop(fade or 0.1) end end
end
```

### Directional sets in schema
```luau
Animations = {
	Idle = "rbxassetid://1",
	M1 = { "rbxassetid://11", "rbxassetid://12", "rbxassetid://13", "rbxassetid://14" },
	Directional = { Front = "rbxassetid://21", Back = "rbxassetid://22", Left = "rbxassetid://23", Right = "rbxassetid://24" },
	Parry = { Front = ..., Back = ..., Left = ..., Right = ... },
	Block = "rbxassetid://31", BlockHit = "rbxassetid://32",
	Dodge = { Front = ..., Back = ..., Left = ..., Right = ... },
	HitReact = { Front = ..., Back = ..., Left = ..., Right = ... },
	Stun = "...", GuardBreak = "...", Knockback = "...",
}
```
Store ids (strings) in shared schema; each context creates `Animation` instances (`Instance.new("Animation")`, set `AnimationId`) and loads them into the relevant Animator.

### Other clients' animations
When another player's attack is replicated through their Animator you don't need to play it again. Play only *reaction* animations you control (your own hit-react on your character, or server-driven ones for NPCs).
