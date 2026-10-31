---
name: roblox.instance.hierarchy-services
description: Roblox Instance API and DataModel layout - Instance properties/methods/events, attributes, tags (CollectionService), cloning/destroying, script types and RunContext, ModuleScript require rules, where code runs (ReplicatedStorage, ServerScriptService, StarterPlayerScripts, StarterCharacterScripts), service list, Tool class. Use when structuring a project or manipulating instances.
---

# Roblox — Instances, Hierarchy, Services

## 1. Instance (base class) — key members

Properties: `Name: string`, `Parent: Instance?`, `ClassName: string` (ro), `Archivable: boolean`.

| Method | Returns / notes |
|---|---|
| `Instance.new(className, parent?)` | set Parent **last** for performance (avoid passing parent arg) |
| `:Clone()` | deep copy (Archivable descendants), Parent nil |
| `:Destroy()` | Parent locked to nil, disconnects connections, fires `Destroying` |
| `:ClearAllChildren()` | |
| `:FindFirstChild(name, recursive?)` | `Instance?` |
| `:FindFirstChildOfClass(className)` | exact class |
| `:FindFirstChildWhichIsA(className, recursive?)` | `IsA` match |
| `:FindFirstAncestor(name)`, `:FindFirstAncestorOfClass(c)`, `:FindFirstAncestorWhichIsA(c)` | |
| `:FindFirstDescendant(name)` | |
| `:WaitForChild(name, timeout?)` | yields; nil after timeout (warns after 5s without timeout) |
| `:GetChildren()`, `:GetDescendants()` | new arrays |
| `:IsA(className)` | inheritance-aware; refines types |
| `:IsDescendantOf(x)`, `:IsAncestorOf(x)` | |
| `:GetFullName()` | `"Workspace.Model.Part"` |
| `:GetAttribute(name)`, `:SetAttribute(name, value)`, `:GetAttributes()` | |
| `:GetAttributeChangedSignal(name)` | RBXScriptSignal |
| `:GetPropertyChangedSignal(prop)` | |
| `:AddTag(tag)`, `:RemoveTag(tag)`, `:HasTag(tag)`, `:GetTags()` | |
| `:GetActor()` | Parallel Luau |
| `:GetStyled(...)`, `:QueryDescendants(selector)` | newer APIs - verify availability |

Events: `ChildAdded(child)`, `ChildRemoved(child)`, `DescendantAdded(d)`, `DescendantRemoving(d)`, `AncestryChanged(child, parent)`, `AttributeChanged(name)`, `Changed(prop)`, `Destroying()`.

### Attributes
Allowed types: `string, boolean, number, UDim, UDim2, BrickColor, Color3, Vector2, Vector3, CFrame, NumberSequence, ColorSequence, NumberRange, Rect, Font, EnumItem`. Replicate server->client (client-set attributes stay local). Name: alphanumeric + `_`, ≤100 chars, no `RBX` prefix.
Good for: replicated read-only state (`Character:SetAttribute("Stamina", 80)`, `"Blocking"`, `"Stunned"`) that UI can listen to. Not for high-frequency data.

## 2. CollectionService (tags)

```luau
local CollectionService = game:GetService("CollectionService")
for _, inst in CollectionService:GetTagged("Hittable") do Setup(inst) end
CollectionService:GetInstanceAddedSignal("Hittable"):Connect(Setup)
CollectionService:GetInstanceRemovedSignal("Hittable"):Connect(Teardown)
CollectionService:AddTag(inst, "Hittable") ; CollectionService:HasTag(inst, "Hittable") ; CollectionService:GetAllTags()
```
Tags replicate. Use tags for "dummies", "breakables", hitbox-ignore parts.

## 3. Script containers & where code runs

| Container | Server Script | LocalScript | ModuleScript |
|---|---|---|---|
| `ServerScriptService` | runs | — | server-only requires (hidden from clients) |
| `ServerStorage` | doesn't run | — | server-only modules/assets |
| `ReplicatedStorage` | doesn't run (unless RunContext) | doesn't run | **shared modules** (both sides) |
| `ReplicatedFirst` | — | runs first on client (loading screens) | |
| `StarterPlayer.StarterPlayerScripts` | — | runs once per player (persists respawn) | |
| `StarterPlayer.StarterCharacterScripts` | runs in character (server) | runs per character spawn | |
| `StarterGui` | — | runs in PlayerGui (reset on spawn unless `ResetOnSpawn=false`) | |
| `Workspace` | runs | only inside the local character | |
| `StarterPack` / Tool | Script runs in Backpack/char | LocalScript runs when in local player's Backpack/char | |

`Script.RunContext` (`Enum.RunContext.Legacy | Server | Client | Plugin`): a Script with `RunContext = Client` runs on every client from anywhere it replicates (e.g. ReplicatedStorage). Useful, but keep one explicit entry point per side for clarity.

## 4. ModuleScripts & require

- `require(moduleScript)` runs the module **once per VM** (server is one VM; each client is one VM) and caches the return value. The same module required on server and client = two separate copies of state.
- Must return exactly one value.
- Cyclic requires error -> break cycles with lazy requires inside functions or dependency injection.
- Require by string path (newer): `require("./Signal")`, `require("@game/ReplicatedStorage/Packages/Packet")` - verify Studio support/aliases before relying on it.
- A module erroring during require = every future require of it errors.

"Dual context" module = ModuleScript in ReplicatedStorage with no `RunService:IsServer()` branches; side-specific code is **injected** by the server/client entry scripts (adapters, signal connections).

## 5. Services (game:GetService)

| Service | Use in a combat game |
|---|---|
| `Players` | players, characters, LocalPlayer |
| `RunService` | frame events, IsServer/IsClient/IsStudio |
| `UserInputService` | raw input |
| `ContextActionService` | bindable actions, mobile buttons |
| `ReplicatedStorage` / `ServerStorage` / `ServerScriptService` | code & assets |
| `Workspace` (`workspace`) | world, spatial queries, `GetServerTimeNow`, `CurrentCamera` |
| `TweenService` | tweens |
| `Debris` | `:AddItem(inst, seconds)` timed destroy |
| `CollectionService` | tags |
| `ContentProvider` | `:PreloadAsync(list)` assets |
| `SoundService` | sound groups |
| `PhysicsService` | collision groups |
| `DataStoreService`, `MessagingService`, `MemoryStoreService` | persistence/cross server |
| `MarketplaceService` | purchases |
| `TextChatService` | chat |
| `StarterGui` | `SetCoreGuiEnabled`, `SetCore` |
| `GuiService` | gamepad selection, insets |
| `HttpService` | `GenerateGUID`, `JSONEncode/Decode` |
| `Teams`, `Lighting`, `SoundService`, `PathfindingService`, `TeleportService` | |

```luau
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
RunService:IsServer() ; RunService:IsClient() ; RunService:IsStudio() ; RunService:IsRunning()
```

## 6. Tool (if weapons are Tools)

Properties: `RequiresHandle`, `CanBeDropped`, `ManualActivationOnly`, `Enabled`, `Grip`, `ToolTip`, `TextureId`.
Events: `Equipped(mouse)`, `Unequipped()`, `Activated()`, `Deactivated()`.
Methods: `Activate()`, `Deactivate()`. `Humanoid:EquipTool(tool)`, `Humanoid:UnequipTools()`.
Tools give free backpack UI but couple input to click; many fighting games instead attach a weapon Model to the character with a `Motor6D`/`WeldConstraint` and handle input themselves.

## 7. Welding a weapon model

```luau
local handle = weaponModel.PrimaryPart
local grip = Instance.new("Motor6D")        -- animatable
grip.Name = "WeaponGrip"
grip.Part0 = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
grip.Part1 = handle
grip.C0 = CFrame.new(0, -1, 0)
grip.Parent = grip.Part0
weaponModel.Parent = character
```
Mark weapon parts `CanCollide=false`, `Massless=true`, `CanQuery` as needed (false if hitboxes shouldn't detect it).

## 8. Suggested project layout

```
ReplicatedStorage
├─ Packages        (Packet, GoodSignal)
├─ Combat
│  ├─ WeaponClass  (dual-context constructor)
│  ├─ Types / Enums / Config
│  ├─ Resolver     (pure outcome logic)
│  ├─ Net          (Packet definitions)
│  └─ Weapons      (definition modules)
└─ Assets (Animations, VFX, Models)
ServerScriptService
├─ Packages/ProfileStore
└─ CombatServer (entry)   + Data (profiles)
StarterPlayerScripts
└─ CombatClient (entry)
```
