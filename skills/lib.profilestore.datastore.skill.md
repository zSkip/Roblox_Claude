---
name: lib.profilestore.datastore
description: MadStudio ProfileStore (loleris) - session-locked, auto-saving DataStore wrapper. Module members, ProfileStore/Profile/VersionQuery API, exported types, signals, constants, request costs, Mock store, data rules (what can't be saved), player-join template, dev product handling, and combat-game data layout. Use for any player persistence.
---

# ProfileStore (MadStudio / loleris)

> **Optional adapter.** Nothing in this skill set requires ProfileStore. Persistence uses the `SessionStore` contract (core.contracts.interfaces §4), which has a built-in session-locked DataStore implementation. ProfileStore is the production-grade drop-in: faster cross-server hand-off, critical-state handling, mock store and message queue. The data rules in §6 apply to any DataStore-backed store.

Repo: `https://github.com/MadStudioRoblox/ProfileStore` (single ModuleScript `ProfileStore.luau`).
**Server only** -> put in `ServerScriptService` (or ServerStorage). Uses DataStoreService + MessagingService.
Methods ending in `Async` **yield**.

## 1. Module members

| Member | Type | Notes |
|---|---|---|
| `ProfileStore.IsClosing` | boolean (read-only) | true after `game:BindToClose`; most methods silently fail |
| `ProfileStore.IsCriticalState` | boolean (read-only) | true after too many DataStore errors |
| `ProfileStore.OnError` | Signal `(message, store_name, profile_key)` | log DataStore errors |
| `ProfileStore.OnOverwrite` | Signal `(store_name, profile_key)` | key held invalid/non-profile data and was overwritten |
| `ProfileStore.OnCriticalToggle` | Signal `(is_critical)` | |
| `ProfileStore.DataStoreState` | `"NotReady" \| "NoInternet" \| "NoAccess" \| "Access"` | starts NotReady, changes once |
| `ProfileStore.New(store_name, template?)` | -> `ProfileStore<T>` | template deep-copied into new profiles' `Data` |
| `ProfileStore.SetConstant(name, value)` | | see constants |

Constants (`SetConstant`): `"AUTO_SAVE_PERIOD"` (300s), `"LOAD_REPEAT_PERIOD"` (10s), `"FIRST_LOAD_REPEAT"` (5s), `"SESSION_STEAL"` (40s), `"ASSUME_DEAD"`, `"START_SESSION_TIMEOUT"`, `"CRITICAL_STATE_ERROR_COUNT"`, `"CRITICAL_STATE_ERROR_EXPIRE"`, `"CRITICAL_STATE_EXPIRE"`, `"MAX_MESSAGE_QUEUE"` (1000).

## 2. ProfileStore object

| Member | Signature | Notes |
|---|---|---|
| `.Name` | string | DataStore name |
| `.Mock` | ProfileStore | same API, in-memory fake store (isolated from live, forgotten on shutdown) |
| `:StartSessionAsync(key, params?)` | -> `Profile?` | params `{ Cancel: (() -> boolean)?, Steal: boolean? }`. Session lock: other servers asked to release. `Cancel` returning true aborts (and disables default timeout). **Never use `Steal` for normal loads** (debug only, breaks dupe protection). Can return nil -> kick player. |
| `:MessageAsync(key, message)` | -> boolean | Reliable cross-server message into a profile (gifts). 1 UpdateAsync + 1 PublishAsync (+1 UpdateAsync on the owning server). |
| `:GetAsync(key, version?)` | -> `Profile?` | Read without session. No autosave, no EndSession needed. nil if no data. |
| `:VersionQuery(key, sortDirection?, minDate?, maxDate?)` | -> `VersionQuery` | `Enum.SortDirection`, dates `DateTime` or epoch ms |
| `:RemoveAsync(key)` | -> boolean | erase key |

`VersionQuery:NextAsync() -> Profile?` - use `profile:SetAsync()` on a result to roll back.

## 3. Profile object

| Member | Type | Notes |
|---|---|---|
| `.Data` | T | your saved table. Writes guaranteed to save only while `IsActive()`; don't yield between check and write |
| `.LastSavedData` | T (read-only) | what has actually been saved; use for dev-product verification |
| `.FirstSessionTime` | number | unix time of creation |
| `.SessionLoadCount` | number | |
| `.Session` | `{PlaceId: number, JobId: string}?` | |
| `.RobloxMetaData` | table | DataStore key metadata (~300 chars limit!) |
| `.UserIds` | `{number}` | GDPR associations |
| `.KeyInfo` | DataStoreKeyInfo | |
| `.ProfileStore` | ProfileStore | owner store |
| `.Key` | string | |
| `.OnSave` | Signal `()` | before every save; changes made synchronously here are saved |
| `.OnLastSave` | Signal `(reason: "Manual" \| "External" \| "Shutdown")` | before final save - logout penalties (combat logging!) |
| `.OnSessionEnd` | Signal `()` | session ended (also on steal); don't modify Data here; kick player |
| `.OnAfterSave` | Signal `(last_saved_data)` | after each UpdateAsync |
| `:IsActive()` | -> boolean | |
| `:Reconcile()` | | fill missing keys from template (recursive, doesn't overwrite) |
| `:EndSession()` | | final save + release lock. **Always call on PlayerRemoving** |
| `:AddUserId(userId)` / `:RemoveUserId(userId)` | | GDPR |
| `:MessageHandler(fn(message, processed))` | | must call `processed()` or message is re-delivered |
| `:Save()` | | immediate save (1 UpdateAsync); use after dev product purchases |
| `:SetAsync()` | | only for GetAsync/VersionQuery profiles; overwrites & ends active session |

## 4. Exported types (from source)

```luau
export type JSONAcceptable = { JSONAcceptable } | { [string]: JSONAcceptable } | number | string | boolean | buffer

export type Profile<T> = {
	Data: T & JSONAcceptable,
	LastSavedData: T & JSONAcceptable,
	FirstSessionTime: number,
	SessionLoadCount: number,
	Session: {PlaceId: number, JobId: string}?,
	RobloxMetaData: JSONAcceptable,
	UserIds: {number},
	KeyInfo: DataStoreKeyInfo,
	OnSave: {Connect: (self: any, listener: () -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnLastSave: {Connect: (self: any, listener: (reason: "Manual" | "External" | "Shutdown") -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnSessionEnd: {Connect: (self: any, listener: () -> ()) -> ({Disconnect: (self: any) -> ()})},
	OnAfterSave: {Connect: (self: any, listener: (last_saved_data: T & JSONAcceptable) -> ()) -> ({Disconnect: (self: any) -> ()})},
	ProfileStore: JSONAcceptable,
	Key: string,
	IsActive: (self: any) -> (boolean),
	Reconcile: (self: any) -> (),
	EndSession: (self: any) -> (),
	AddUserId: (self: any, user_id: number) -> (),
	RemoveUserId: (self: any, user_id: number) -> (),
	MessageHandler: (self: any, fn: (message: JSONAcceptable, processed: () -> ()) -> ()) -> (),
	Save: (self: any) -> (),
	SetAsync: (self: any) -> (),
}
export type VersionQuery<T> = { NextAsync: (self: any) -> (Profile<T>?) }
export type ProfileStore<T> = { Mock: ProfileStoreStandard<T> } & ProfileStoreStandard<T>
-- ProfileStoreStandard<T> = { Name, StartSessionAsync, MessageAsync, GetAsync, VersionQuery, RemoveAsync }
```

Typed profile table: `local Profiles: {[Player]: typeof(PlayerStore:StartSessionAsync(""))} = {}`.

ProfileStore embeds its own copy of stravant's signal (same LIFO prepend linked list; fields `head`, `listener_count`, `next`, `is_connected`; extra `:GetListenerCount()`; `Connect` errors if listener isn't a function).

## 5. Standard player loader (official pattern)

```luau
local ProfileStore = require(game.ServerScriptService.ProfileStore)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PROFILE_TEMPLATE = {
	Cash = 0,
	Items = {},
}

local PlayerStore = ProfileStore.New("PlayerStore", PROFILE_TEMPLATE)
if RunService:IsStudio() then PlayerStore = PlayerStore.Mock end -- optional: don't touch live keys in Studio

local Profiles: {[Player]: typeof(PlayerStore:StartSessionAsync(""))} = {}

local function PlayerAdded(player: Player)
	local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function() return player.Parent ~= Players end,
	})
	if profile ~= nil then
		profile:AddUserId(player.UserId)
		profile:Reconcile()
		profile.OnSessionEnd:Connect(function()
			Profiles[player] = nil
			player:Kick(`Profile session end - Please rejoin`)
		end)
		if player.Parent == Players then
			Profiles[player] = profile
		else
			profile:EndSession()
		end
	else
		player:Kick(`Profile load fail - Please rejoin`)
	end
end

for _, player in Players:GetPlayers() do task.spawn(PlayerAdded, player) end
Players.PlayerAdded:Connect(PlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	local profile = Profiles[player]
	if profile ~= nil then profile:EndSession() end
end)
```

## 6. Data rules (DataStore limitations)

Cannot save: `NaN` (check `x ~= x`), non string/number keys, **mixed** string+number keys in one table, sparse arrays (use `tostring(id)` keys), cyclic tables, any userdata (`Vector3`, `CFrame`, `Color3`, `Instance`, `EnumItem`) -> serialize: `{x, y, z}`, `EnumItem.Name`. Functions not allowed. `buffer` IS allowed (JSONAcceptable) - pair with `Packet:Serialize()` for compact blobs.

## 7. Request cost summary

- Studio startup: 1 SetAsync (API access check).
- StartSessionAsync: usually 1 UpdateAsync; conflicts add PublishAsync + retries (5s, then every 10s, steal after 40s).
- Active session: 1 UpdateAsync every 300s + 1 MessagingService subscription.
- EndSession: usually 1 UpdateAsync.
- GetAsync 1 GetAsync; RemoveAsync 1 RemoveAsync; Save/SetAsync 1 UpdateAsync each.

## 8. Dev products (summary)

`MarketplaceService.ProcessReceipt`: wait for `Profiles[player]`, check `profile:IsActive()`, run handler in `pcall`, `profile:Save()` after granting, return `Enum.ProductPurchaseDecision.PurchaseGranted`; otherwise `NotProcessedYet`. Optionally store processed `PurchaseId`s in `Data` and verify against `LastSavedData` in `OnAfterSave` for the stricter variant.

## 9. Combat game data layout (suggested)

```luau
local PROFILE_TEMPLATE = {
	Version = 1,                    -- migrate in a function after Reconcile
	Stats = { Level = 1, Exp = 0 },
	Equipped = { Weapon = "LinkedSword" },   -- string ids, never Instances
	OwnedWeapons = { LinkedSword = true },   -- string-keyed set
	Keybinds = {                    -- user rebinding: store Enum *names*
		Block = "F", Dodge = "Q",
	},
	Settings = { ShiftLock = true },
	Combat = { Kills = 0, Deaths = 0, Parries = 0 },
}
```
- Keep live combat state (stamina, combo, cooldowns) **out** of the profile - it is per-session runtime, not persistence.
- Expose read-only replicated values via attributes on the Player or a Packet snapshot; never let the client write.
- Combat-logging: `profile.OnLastSave:Connect(function(reason) if reason ~= "Shutdown" and InCombat[player] then ... end end)`.
