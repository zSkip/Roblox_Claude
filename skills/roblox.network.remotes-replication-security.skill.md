---
name: roblox.network.remotes-replication-security
description: Roblox client-server model - replication rules (what replicates which way), RemoteEvent / UnreliableRemoteEvent / RemoteFunction / BindableEvent / BindableFunction APIs and limits, argument serialization rules, StreamingEnabled, attribute replication, network ownership, server authority, exploit-proofing and validation checklist, rate limiting, and latency handling (prediction, reconciliation). Use when designing anything that crosses the network (pairs with lib.packet.networking).
---

# Roblox — Networking, Replication, Security

## 1. Model

- Server is authoritative. Each client runs its own copy of replicated instances.
- **Server -> client**: instance creation/property changes in replicated containers (Workspace, ReplicatedStorage, Players, Lighting, Teams, SoundService, ReplicatedFirst, PlayerGui/Backpack for that player) replicate automatically.
- **Client -> server**: almost nothing replicates (FilteringEnabled). Exceptions: physics of parts the client **network-owns** (its character!), Animator tracks on its own character, some Humanoid states, `Sound` playback when `SoundService.RespectFilteringEnabled = false`, Tool reparenting by owner.
- ServerStorage / ServerScriptService never replicate.

## 2. Remote objects

| Class | Direction | Notes |
|---|---|---|
| `RemoteEvent` | both | reliable, ordered; `FireServer(...)`, `FireClient(player, ...)`, `FireAllClients(...)`; `OnServerEvent(player, ...)`, `OnClientEvent(...)` |
| `UnreliableRemoteEvent` | both | same API; may drop/reorder; payload limit ~900 bytes (larger is dropped); for cosmetic high-rate data |
| `RemoteFunction` | both | `InvokeServer(...)` (yields, returns), `OnServerInvoke = fn(player, ...)`; **never** `InvokeClient` from server (client can hang it forever / error) |
| `BindableEvent` / `BindableFunction` | same machine | `Fire`/`Event`, `Invoke`/`OnInvoke`; copies tables (no metatables) |

Wrap one RemoteEvent in typed, batched channels (the NetChannel contract in core.contracts.interfaces has a built-in implementation) and use it for all gameplay traffic.

### Argument serialization rules (raw remotes)
- Allowed: nil, boolean, number, string, buffer, tables, Instances (as references), Roblox datatypes (Vector3, CFrame, Color3, EnumItem...).
- Functions / threads -> nil. Metatables stripped.
- Tables: mixed keys -> only one part survives; non-string keys in dictionaries converted/dropped; `nil` holes truncate arrays.
- Instances the receiver can't see (ServerStorage, not streamed in) arrive as `nil`.
- Roughly: keep each remote call small; Roblox throttles total bandwidth per player (~50 KB/s is a practical ceiling). Packing numbers into a `buffer` keeps payloads tiny.

## 3. Attributes & ValueObjects for state replication

- `Instance:SetAttribute` on the server replicates to all clients - easy "public" state (`Blocking`, `Stunned`, `Stamina`). Changes coalesce per frame.
- Clients listen via `GetAttributeChangedSignal`.
- For private state (stamina of local player only), send via a channel's `FireClient`.

## 4. StreamingEnabled

`Workspace.StreamingEnabled = true` (default for new places): clients only have nearby parts. Consequences:
- `WaitForChild` on workspace descendants may never resolve on the client - use `ModelStreamingMode` (`Atomic`/`Persistent`) for important models, or tags + `GetInstanceAddedSignal`.
- Characters of far-away players may not exist on a client; Instance arguments referencing them arrive nil -> handle nil.
- `Player:RequestStreamAroundAsync(pos)` (server) to preload.

## 5. Security - never trust the client

Assume an exploiter can: fire any remote with any arguments at any rate, read all client code and replicated instances, move their character anywhere (they own its physics), change their WalkSpeed, play any animation, spoof timestamps.

Validation checklist for every incoming combat message:
1. **Types & ranges**: the channel layer checks types; still check enum ranges (`action <= MAX`), finite numbers (`x == x and x ~= math.huge`), instance class (`typeof(x) == "Instance" and x:IsA("Model")`).
2. **State**: is the player alive, holding this weapon, in a state that allows the action (not stunned, not mid-attack unless cancel window)?
3. **Cooldown / rate**: server-side timestamps (`os.clock()` on server), not client times.
4. **Resources**: stamina/exhaustion checked and deducted on the server.
5. **Spatial**: distance/angle/line-of-sight checks with leniency.
6. **Timestamps**: client-provided `GetServerTimeNow()` only for *lag compensation bounded by* `[serverNow - maxRewind, serverNow]`; clamp.
7. **Idempotence**: ignore duplicate/old sequence ids.
8. **Server computes damage** from the schema - never accept damage numbers from the client.

Rate limiter:
```luau
local Buckets: {[Player]: {Tokens: number, Last: number}} = {}
local RATE, BURST = 12, 6        -- tokens/sec, max burst
local function Allow(player: Player): boolean
	local now = os.clock()
	local b = Buckets[player]
	if not b then b = { Tokens = BURST, Last = now } ; Buckets[player] = b end
	b.Tokens = math.min(BURST, b.Tokens + (now - b.Last) * RATE)
	b.Last = now
	if b.Tokens < 1 then return false end
	b.Tokens -= 1
	return true
end
Players.PlayerRemoving:Connect(function(p) Buckets[p] = nil end)
```

## 6. Latency handling for responsive combat

- **Client prediction**: on input, the client immediately plays the animation / enters the state locally, fires intent to server. Server validates; if rejected, server tells client to cancel (reconcile).
- **Server reconciliation**: server sends authoritative state changes (`StateChanged(actor, state, serverTime)`); client snaps to it if different.
- **Other players**: their animations come through their Animator replication; their state through channels/attributes. Expect ~ping/2 + frame delays.
- **Parry fairness**: defender's parry press is judged at server receive time (biased against the defender by their ping) unless you accept the client's timestamp with bounded rewind. Common: `effectiveTime = clamp(clientTime, serverRecv - min(ping, 0.2), serverRecv)`.
- **Hit confirmation**: show hit FX only when the server confirms (consistent) or predictively with rollback (snappy). Damage numbers always from server.

### Custom replication (this project's direction)
- **Combat state** (state leaf, timelines, stats, effects, meters, loadout) travels as components over our own `Net`, keyed by `U16` entity ids, with deltas + acks and per-client interest. Attributes and server-built Instances are not used for gameplay.
- **Shared frame clock:** `Frame = floor(GetServerTimeNow() × 60)`. All timings cross the wire as frames.
- **Stays on Roblox:** player character physics (network ownership). The server records it into its own position history.
- Design: `docs/replication-and-validation.md`.

## 7. Patterns

- One `Net` shared module that defines all packets; both entry scripts require it.
- Server -> clients broadcast of combat actions: send small ids (actor instance, action id, direction id, combo index), each client looks up the schema locally to know animations/VFX.
- Don't replicate per-frame positions yourself - character physics already replicates.
- Use `UnreliableRemoteEvent` (or an unreliable channel) for cosmetic spam like trails or camera shake of others.
