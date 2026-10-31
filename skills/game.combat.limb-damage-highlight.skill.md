---
name: game.combat.limb-damage-highlight
description: Directional limb-targeting system for R6 - direction-to-limb mapping (mirrored, configurable), per-limb damage meters, chip damage, red Highlight that grows to solid then bursts (limb break effect), white Highlight telegraph for incoming attacks, Highlight API and the 31-highlight budget, overlay fallback, server-authoritative limb state and replication. Use when implementing directional M1 limb hits, limb breaks or combat highlights.
---

# Limb Damage & Combat Highlights (R6)

## 1. Concept (as interpreted)

- Every **directional M1** (W/A/S/D tapped inside the window, then M1) targets one **limb** of the defender.
- A landed directional hit does **small chip damage** to health and adds to that limb's **limb meter**.
- The limb shows a **red Highlight** whose opacity follows the meter: faint → solid.
- At 100%, the limb **bursts**: burst damage + a limb-break status effect (see game.status-effects.lol-stats-cc), then the meter resets (or the limb stays "lost" for a duration).
- Blocked hits add **posture**, not limb damage. Parried/dodged hits add nothing.
- Separately, an attacker in **startup** of an attack flashes a **white Highlight** on their body for the defender (incoming-attack telegraph).

## 2. R6 limbs and mapping

R6 parts: `Head`, `Torso`, `Left Arm`, `Right Arm`, `Left Leg`, `Right Leg` (+ `HumanoidRootPart`).

Limb **groups** are registered data. Attacks reference a group by key through `AttackDef.Target` (game.combat.architecture-patterns §6), so the mapping lives on the attacks, not in limb code.

Current directional M1 targets (mirrored because the fighters face each other):

| Attacker input | Defender limb group | Notes |
|---|---|---|
| D + M1 (Right) | **Left Arm** | swing from attacker's right lands on defender's left |
| A + M1 (Left) | **Right Arm** | |
| W + M1 (Front) | **Torso** | |
| S + M1 (Back) | **Torso** | still knockback |
| *(future attacks)* | **Legs**, **Head** | registered now, targeted by later AttackDefs (e.g. a sweep, an overhead) |

```luau
-- Limbs registry (shared, data only)
local LimbGroups = {
	["Left Arm"]  = { Parts = { "Left Arm" } ;  Max = 100 ; PerHit = 25 ; Chip = 3 ; BurstDamage = 15 ; Decay = 5 ; OnBreak = "LeftArmBreak" } ;
	["Right Arm"] = { Parts = { "Right Arm" } ; Max = 100 ; PerHit = 25 ; Chip = 3 ; BurstDamage = 15 ; Decay = 5 ; OnBreak = "RightArmBreak" } ;
	Torso         = { Parts = { "Torso" } ;     Max = 120 ; PerHit = 20 ; Chip = 4 ; BurstDamage = 20 ; Decay = 4 ; OnBreak = "TorsoBreak" } ;
	Legs          = { Parts = { "Left Leg", "Right Leg" } ; Max = 100 ; PerHit = 30 ; Chip = 3 ; BurstDamage = 12 ; Decay = 5 ; OnBreak = "LegsBreak" } ;   -- reserved
	Head          = { Parts = { "Head" } ;      Max = 80 ;  PerHit = 25 ; Chip = 5 ; BurstDamage = 25 ; Decay = 5 ; OnBreak = "HeadBreak" } ;    -- reserved
}
-- Per-weapon overrides: Schema.Limbs[group] merges over these defaults.
```
`OnBreak` names a **break handler** (§7). What a break actually does is decided later, without touching the meter code.

## 3. Server state

```luau
-- per combatant runtime (server)
LimbMeters = {} ;   -- [group] = number, created lazily for any registered group
LimbLastHit = {} ;   -- for decay delay

local function ApplyLimbHit(defender, limb: string, cfg, now)
	local v = math.min((defender.LimbMeters[limb] or 0) + cfg.PerHit, cfg.Max)
	defender.LimbMeters[limb] = v
	defender.LimbLastHit[limb] = now
	DealDamage(defender, cfg.Chip, "Physical")
	if v >= cfg.Max then
		DealDamage(defender, cfg.BurstDamage, "True")
		BreakHandlers[cfg.OnBreak](defender, attacker, limb, now)   -- pluggable: effect, reset policy, visuals
		Net.LimbBurst:Fire(defender.Model, LimbId[limb])
	end
	Net.Limb:Fire(defender.Model, LimbId[limb], math.floor(v / cfg.Max * 255))  -- U8 fraction for visuals
end
```
Decay: after `DecayDelay` (e.g. 3 s) without hits, reduce by `Decay`/s in the shared Heartbeat loop; send updates only when the U8 value changes.

## 4. Highlight API

| Property | Notes |
|---|---|
| `Adornee: Instance?` | a `Model` **or** a `BasePart` (one limb). nil → uses its Parent |
| `FillColor`, `FillTransparency` (0..1) | |
| `OutlineColor`, `OutlineTransparency` | |
| `DepthMode: Enum.HighlightDepthMode` | `AlwaysOnTop` / `Occluded` |
| `Enabled` | |

**Budget: only ~31 Highlights render at once per client.** Six limbs × several players plus telegraphs exceeds it fast.
Budget rules:
1. Highlights are **client-side cosmetics**: each client creates them locally for characters near it / in combat with it, never replicated from the server.
2. Prioritise: your own target and attackers targeting you > others by distance. Keep a pool of N ≤ 24 Highlight objects and assign them each frame or on change.
3. Fallback for overflow: an **overlay part** (clone limb size × 1.05, `Material = Enum.Material.ForceField` or `Neon`, `Color` red, `Transparency` driven by the meter, welded with `WeldConstraint`, `CanCollide/CanQuery/CanTouch = false`, `Massless = true`). No limit, slightly less clean.

## 5. Client visuals

```luau
local TweenService = game:GetService("TweenService")

local function MeterToTransparency(fraction: number): number
	return 1 - fraction ^ 1.4             -- slow start, quickly solid near the end
end

Net.Limb:OnClient(function(model: Model?, limbId: number, value: number)
	if not model then return end          -- not streamed in
	local fraction = value / 255
	for _, part in LimbParts(model, LimbName[limbId]) do       -- "Legs" -> both legs
		local h = HighlightPool:Get(part)                       -- may return overlay fallback
		h.FillColor = Color3.fromRGB(255, 30, 30)
		h.OutlineTransparency = 1
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		TweenService:Create(h, TweenInfo.new(0.15), { FillTransparency = MeterToTransparency(fraction) }):Play()
		if fraction <= 0 then HighlightPool:Release(part) end
	end
end)

Net.LimbBurst:OnClient(function(model, limbId)
	-- flash solid, burst particles at limb, sound, then fade out
end)
```

### Incoming-attack telegraph (white)
```luau
Net.Action:OnClient(function(actor: Model?, action, direction, comboIndex)
	if not actor or actor == LocalCharacter then return end
	local h = HighlightPool:Get(actor)                 -- whole model
	h.FillColor = Color3.new(1, 1, 1) ; h.FillTransparency = 0.6 ; h.OutlineTransparency = 0
	task.delay(StartupFor(actor, action, comboIndex), function() HighlightPool:Release(actor) end)
end)
```
- One model Highlight with a limb Highlight on the same model: the model one covers the limbs. Show the telegraph **instead** of the limb highlight for its short duration, or use the outline only (`FillTransparency = 1`, white `OutlineTransparency = 0`) so limb fills stay visible.
- Optionally tint the telegraph by direction or show only for attacks aimed at you.

## 6. Literal limb loss (optional)

To visually "lose" a limb on burst: set the limb `Transparency = 1` and spawn a detached copy with an impulse (debris). R6 shirts/pants render on the limb parts, so hiding the part hides its clothing. Restore on respawn or effect end. Gameplay effects come from the status effect, not the visual.

## 7. Break handlers (functionality decided later)

```luau
export type BreakHandler = (defender: any, attacker: any, group: string, now: number) -> ()

local BreakHandlers: { [string]: BreakHandler } = {}

-- default placeholder: reset meter, apply a generic "Broken" effect, play burst visuals
local function DefaultBreak(defender, attacker, group, now)
	defender.LimbMeters[group] = 0
	defender.Status:Apply(Effects.LimbBroken, attacker, now)    -- tags = { Limb = group }
end
for _, key in { "LeftArmBreak", "RightArmBreak", "TorsoBreak", "LegsBreak", "HeadBreak" } do
	BreakHandlers[key] = DefaultBreak
end
-- Later, e.g.: BreakHandlers.RightArmBreak = function(d, a, g, now) d.Status:Apply(Effects.Disarmed, a, now) ; keep meter at Max ... end
```
Policies a handler can choose: reset the meter, keep the limb "lost" until the effect ends, keep it until death, or hide the part (literal loss, §6). Combo (non-directional) M1s don't target a limb unless their AttackDef sets `Target`.
