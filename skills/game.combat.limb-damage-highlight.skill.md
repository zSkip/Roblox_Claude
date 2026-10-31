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

Default mapping (attacker's input → defender limb), **mirrored** because the fighters face each other:

| Attacker input | Swing comes from | Defender limb | Break effect (suggested) |
|---|---|---|---|
| D + M1 (Right) | attacker's right | defender's **Left Arm** | `Disarm`-lite: that arm's block is weaker / `Cripple` |
| A + M1 (Left) | attacker's left | defender's **Right Arm** (weapon arm) | `Disarm` (no M1 for N s) |
| W + M1 (Front) | straight on | defender's **Torso** (or Head) | `Bleed` DoT + `GrievousWounds` (or `Blind` if Head) |
| S + M1 (Back) | low / sweep | defender's **Legs** (one meter for both, or the leg on the attacker's weapon side) | `Slow` + `Grounded` (no dodge). S+M1 still knocks back |

Keep the mapping in the weapon schema so it is configurable:
```luau
LimbTargets = {
	Right = "Left Arm" ; Left = "Right Arm" ; Front = "Torso" ; Back = "Legs" ;
} ;
Limbs = {
	["Left Arm"]  = { Max = 100 ; PerHit = 25 ; Chip = 3 ; BurstDamage = 15 ; Effect = "ArmBroken" ; Decay = 5 } ;
	["Right Arm"] = { Max = 100 ; PerHit = 25 ; Chip = 3 ; BurstDamage = 15 ; Effect = "Disarmed" ; Decay = 5 } ;
	Torso         = { Max = 120 ; PerHit = 25 ; Chip = 4 ; BurstDamage = 20 ; Effect = "Bleeding" ; Decay = 4 } ;
	Legs          = { Max = 100 ; PerHit = 30 ; Chip = 3 ; BurstDamage = 12 ; Effect = "Hobbled" ; Decay = 5 } ;
} ;
```
`Legs` is a logical limb group → highlight both `Left Leg` and `Right Leg`.

## 3. Server state

```luau
-- per combatant runtime (server)
LimbMeters = { ["Left Arm"] = 0, ["Right Arm"] = 0, Torso = 0, Legs = 0 } ;
LimbLastHit = {} ;   -- for decay delay

local function ApplyLimbHit(defender, limb: string, cfg, now)
	local v = math.min(defender.LimbMeters[limb] + cfg.PerHit, cfg.Max)
	defender.LimbMeters[limb] = v
	defender.LimbLastHit[limb] = now
	DealDamage(defender, cfg.Chip, "Physical")
	if v >= cfg.Max then
		DealDamage(defender, cfg.BurstDamage, "True")
		defender.Status:Apply(Effects[cfg.Effect], attacker, now)
		defender.LimbMeters[limb] = 0                    -- or keep at Max while the effect lasts ("lost limb")
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

Net.Limb.OnClientEvent:Connect(function(model: Model?, limbId: number, value: number)
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

Net.LimbBurst.OnClientEvent:Connect(function(model, limbId)
	-- flash solid, burst particles at limb, sound, then fade out
end)
```

### Incoming-attack telegraph (white)
```luau
Net.Action.OnClientEvent:Connect(function(actor: Model?, action, direction, comboIndex)
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

## 7. Rules to confirm with the design

- Whether non-directional (combo) M1s also add limb damage (default: no, they only chip HP).
- Whether broken limbs stay broken until death or recover after the effect.
- Whether `Head` is a separate target (e.g. W+M1 while the target is staggered).
