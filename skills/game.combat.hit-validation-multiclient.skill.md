---
name: game.combat.hit-validation-multiclient
description: Client-side hit detection with multi-client validation for Roblox melee - attacker client detects (any HitboxQuery), server validates claims with state/timing/rewind checks, victim client corroborates borderline claims through a request/response channel, optional witness clients sample claims for a per-player trust score. Covers position history ring buffers, leniency formulas, defender-state history for parry/dodge timing, packets, and flagging. Use when implementing or tuning hit registration.
---

# Client Hit Detection + Multi-Client Validation

## 1. Roles

| Role | Job | Can it lie? |
|---|---|---|
| **Attacker client** | runs the hitbox query (`Deps.Hitbox`, client-local) during the Active window and sends hit **claims** | yes - claims are untrusted |
| **Server** | judge: state, timing, cooldown, rewound geometry, outcome (block/parry/dodge), damage | authority |
| **Victim client** | owns its character physics; on request, reports its own view of the moment ("was I in range / in i-frames?") | yes - so its vote is only a tie-breaker |
| **Witness clients** (optional) | third parties near both, sampled to cross-check claims | yes individually; useful statistically |

Principle: a claim must pass the **server's hard checks** (always). Inside a **leniency band** (geometrically borderline), the server asks the **victim** to corroborate. **Witnesses** never block a hit; they feed a **trust score** that tightens or widens each player's leniency over time.

## 2. Flow

```
Attacker input ─► C_Intent(Attack, dir, t) ─► Server: validate, state=Attacking(ActionId), S_Action broadcast
Attacker client: Active window → Hitbox.Hit → C_HitClaim(ActionId, target, t, attackerCF)
Server:
  1. hard checks (fail → drop, maybe flag)
  2. geometric check at rewound time:  clear pass → resolve
                                         borderline → ask victim (S_HitCheck, ≤150 ms) → resolve/drop
  3. Resolve outcome vs defender STATE AT CLAIM TIME (history) → apply → S_Result broadcast
  4. Sometimes (e.g. 10% of claims, or always for low-trust players) ask a witness → trust update (async)
```

## 3. Channels (core.contracts.interfaces NetChannel)

```luau
HitClaim = Net.Define("C_HitClaim", { "U16", "Instance", "F64", "CFrame" })                    -- ActionId, Target, ClientServerTime, AttackerCF
HitCheck = Net.Request("S_HitCheck", { "Instance", "F64", "U8" }, { "U8" }, 0.15)               -- Attacker, Time, SpecId -> 0 no opinion / 1 agree / 2 disagree
Witness  = Net.Request("S_Witness", { "Instance", "Instance", "F64" }, { "F32" }, 0.5)          -- Attacker, Target, Time -> distance seen
```
A timeout returns the default (`0` = no opinion). The server must never wait on a client without a timeout.

## 4. Position history (server)

```luau
local HISTORY = 64                                  -- ~1 s at 60 Hz
local History: { [Model]: { Times: {number}, CFrames: {CFrame}, Head: number } } = {}

RunService.PostSimulation:Connect(function()
	local now = workspace:GetServerTimeNow()
	for model, h in History do
		local root = model.PrimaryPart
		if root then
			h.Head = h.Head % HISTORY + 1
			h.Times[h.Head] = now ; h.CFrames[h.Head] = root.CFrame
		end
	end
end)

local function SampleAt(h, t: number): CFrame?           -- linear search is fine for 64 entries
	local bestBefore, bestAfter
	for i = 1, HISTORY do
		local ti = h.Times[i]
		if ti then
			if ti <= t and (not bestBefore or ti > h.Times[bestBefore]) then bestBefore = i end
			if ti >= t and (not bestAfter or ti < h.Times[bestAfter]) then bestAfter = i end
		end
	end
	if not bestBefore then return bestAfter and h.CFrames[bestAfter] end
	if not bestAfter then return h.CFrames[bestBefore] end
	local t0, t1 = h.Times[bestBefore], h.Times[bestAfter]
	local a = if t1 > t0 then (t - t0) / (t1 - t0) else 0
	return h.CFrames[bestBefore]:Lerp(h.CFrames[bestAfter], a)
end
```
Also record a **state history** per combatant (`{Time, State, Dir}` on every server state change), so parry/dodge/block are judged at the claim time, not the arrival time.

## 5. Hard checks (always)

```luau
local MAX_REWIND = 0.25

local function HardCheck(attacker, claim, serverNow): (boolean, string?, number?)
	local rt = attacker.Runtime
	if rt.ActionId ~= claim.ActionId then return false, "StaleAction" end
	if rt.Current ~= "Attacking" then return false, "NotAttacking" end
	if not claim.Target or not claim.Target:IsDescendantOf(AliveFolder) then return false, "BadTarget" end
	if claim.Target == attacker.Model then return false, "Self" end
	if rt.HitThisAction[claim.Target] then return false, "Duplicate" end
	if rt.HitCount >= rt.Spec.MaxTargets then return false, "TooMany" end
	local t = math.clamp(claim.Time, serverNow - math.min(attacker.Ping + 0.05, MAX_REWIND), serverNow)
	if t < rt.ActiveStart - 0.05 or t > rt.ActiveEnd + 0.05 then return false, "OutsideWindow" end
	return true, nil, t
end
```

## 6. Geometric check with leniency band

```luau
local function Geometry(attacker, target, spec, t)
	local aCF = SampleAt(History[attacker.Model], t)
	local vCF = SampleAt(History[target], t)
	if not aCF or not vCF then return "Fail" end
	local hb = aCF * spec.Hitbox.Offset
	local localPos = hb:PointToObjectSpace(vCF.Position)
	local half = spec.Hitbox.Size / 2
	-- distance outside the box (0 if inside)
	local outside = (localPos:Abs() - half):Max(Vector3.zero).Magnitude
	local lenience = BASE_LENIENCY + attacker.Ping * TARGET_SPEED_ESTIMATE * attacker.TrustScale
	if outside <= 0.5 then return "Pass" end
	if outside <= lenience then return "Borderline" end
	return "Fail"
end
```
- `BASE_LENIENCY` ≈ 2 studs, `TARGET_SPEED_ESTIMATE` ≈ 16-20 studs/s, `TrustScale` 0.5-1.5 from the trust score.
- Also check the claimed attacker CFrame against the server's sample (`(claim.AttackerCF.Position - aCF.Position).Magnitude <= 4`). A big mismatch is teleport/lag abuse.

## 7. Victim corroboration (borderline only)

```luau
-- server, inside a task.spawn so the claim handler doesn't block
local verdict = HitCheck:Invoke(victimPlayer, attacker.Model, t, specId) or 0     -- yields ≤ 0.15 s
if verdict == 2 then drop() elseif verdict == 1 or verdict == 0 then accept() end   -- no opinion → accept borderline
```
Victim client answers from its own interpolation buffer: was the attacker's hitbox (built from the schema) within X studs of my root at time t on my screen?
- Victims who disagree with **clear** hits (when sampled) lose trust, so a victim that always says "no" gains nothing.
- NPC victims: the server answers itself.

## 8. Witnesses & trust score

- Pick 1 random client within ~60 studs of both fighters (not attacker or victim). Ask `S_Witness` for the distance it saw. Compare with the claim.
- `Trust` per player starts at 1.0. Contradictions (witness strongly disagrees, lock-slide flags, out-of-window claims) reduce it (e.g. ×0.9). Agreements slowly restore it (+0.01, capped at 1.0).
- `TrustScale = math.clamp(Trust, 0.5, 1.2)` multiplies leniency. Very low trust → log for review / kick at a threshold.
- Witness checks are **async** and never delay damage.

## 9. Resolve against defender history

```luau
local defenderState = StateAt(defender, t)     -- from state history
local outcome = Resolver.Resolve(spec, attacker.Runtime.Direction, attackerCFAt_t, defenderCFAt_t, defenderState, t)  -- direction comes from the server-validated intent, never from the claim
```
This makes parries fair for the defender: their parry press (server-timestamped, with bounded client-time adjustment) is compared with the attacker's claimed hit time, not the time the claim packet arrived.

## 10. What the attacker sees

- Predict hit VFX locally (spark, hitstop) on the client hitbox hit. Damage numbers and the defender's reaction come from `S_Result`.
- On a rejected claim the server sends nothing (or `S_Cancel` for debug). The predicted spark already played, which is a small cosmetic cost.

## 11. Tuning checklist

- Log reasons for every dropped claim in Studio (`OutsideWindow`, `Fail`, `Disagree`) and tune leniency until honest players at 150-200 ms ping rarely drop.
- Test with Studio's simulated latency (Studio Settings → Network → Incoming Replication Lag).
