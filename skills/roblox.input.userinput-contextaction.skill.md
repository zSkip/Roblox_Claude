---
name: roblox.input.userinput-contextaction
description: Roblox input - UserInputService (events, polling, mouse/gamepad/touch), InputObject, Enum.KeyCode / UserInputType / UserInputState / ContextActionResult / ContextActionPriority, ContextActionService binding with priorities and touch buttons, newer Input Action System (InputContext/InputAction/InputBinding), gameProcessedEvent, rebinding, and combat input patterns (tap vs hold, directional buffers, camera-relative directions). Use for keybinds and input handling.
---

# Roblox — Input (UserInputService, ContextActionService, Input Actions)

All input is **client-only** (LocalScripts / Client RunContext). The server only receives what you send.

## 1. UserInputService

```luau
local UserInputService = game:GetService("UserInputService")
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then return end      -- typing in chat / UI consumed it
end)
UserInputService.InputEnded:Connect(function(input, gp) end)
UserInputService.InputChanged:Connect(function(input, gp) end)   -- mouse move, wheel, thumbsticks
```

| Member | Notes |
|---|---|
| `InputBegan / InputEnded / InputChanged (input, gameProcessedEvent)` | core events |
| `JumpRequest` | fires on jump input (any device) |
| `LastInputTypeChanged(lastType)` / `:GetLastInputType()` | device switching UI |
| `TouchTap, TouchStarted, TouchEnded, TouchMoved, TouchSwipe, TouchLongPress, TouchPinch, TouchRotate, TouchPan` | mobile |
| `GamepadConnected / GamepadDisconnected (gamepadNum)` | |
| `TextBoxFocused / TextBoxFocusReleased` | |
| `WindowFocused / WindowFocusReleased` | clear held keys on focus loss |
| `:IsKeyDown(Enum.KeyCode)` | polling |
| `:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)` | |
| `:GetKeysPressed()` -> {InputObject} | |
| `:GetMouseButtonsPressed()` | |
| `:GetMouseLocation()` -> Vector2 (includes top bar inset) | |
| `:GetMouseDelta()` -> Vector2 (only when MouseBehavior locked) | |
| `:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonX)` | |
| `:GetGamepadState(gamepad)` | |
| `:GetStringForKeyCode(keyCode)` | layout-aware label ("Q" vs "A" on AZERTY) |
| `:GetFocusedTextBox()` | |
| `.MouseBehavior` | `Enum.MouseBehavior.Default / LockCenter / LockCurrentPosition` |
| `.MouseIconEnabled`, `.MouseDeltaSensitivity` | |
| `.KeyboardEnabled`, `.MouseEnabled`, `.TouchEnabled`, `.GamepadEnabled`, `.VREnabled` | capabilities |
| `.PreferredInput` (newer) | `Enum.PreferredInput.KeyboardAndMouse / Gamepad / Touch` - verify availability |

## 2. InputObject

| Property | Notes |
|---|---|
| `KeyCode: Enum.KeyCode` | `Enum.KeyCode.Unknown` for mouse buttons |
| `UserInputType: Enum.UserInputType` | `Keyboard`, `MouseButton1`, `Gamepad1`, `Touch`... |
| `UserInputState: Enum.UserInputState` | `Begin`, `Change`, `End`, `Cancel`, `None` |
| `Position: Vector3` | mouse/touch position (X,Y) or thumbstick (X,Y) / trigger (Z) |
| `Delta: Vector3` | movement |
| `:IsModifierKeyDown(Enum.ModifierKey.Shift)` | |

Normalise keyboard/mouse into one key:
```luau
local function InputKey(input: InputObject): Enum.KeyCode | Enum.UserInputType
	if input.UserInputType == Enum.UserInputType.Keyboard or input.KeyCode ~= Enum.KeyCode.Unknown then
		return input.KeyCode
	end
	return input.UserInputType
end
```

## 3. Enums you'll use

`Enum.KeyCode`: `W A S D Q E F R G T Z X C V Space LeftShift RightShift LeftControl LeftAlt Tab One Two Three Four Five Escape Return Backspace Up Down Left Right` - gamepad: `ButtonA ButtonB ButtonX ButtonY ButtonL1 ButtonR1 ButtonL2 ButtonR2 ButtonL3 ButtonR3 ButtonStart ButtonSelect DPadUp DPadDown DPadLeft DPadRight Thumbstick1 Thumbstick2`.

`Enum.UserInputType`: `MouseButton1 MouseButton2 MouseButton3 MouseWheel MouseMovement Touch Keyboard Focus Accelerometer Gyro Gamepad1..Gamepad8 TextInput InputMethod None`.

`Enum.UserInputState`: `Begin Change End Cancel None`.

`Enum.ContextActionResult`: `Pass` (let lower-priority bindings/other handlers see it), `Sink` (consume; default if nil returned).

`Enum.ContextActionPriority`: `Low (1000)`, `Medium (2000)`, `Default (2000)`, `High (3000)`.

`Enum.MouseBehavior`: `Default LockCenter LockCurrentPosition`.

`Enum.ModifierKey`: `Shift Ctrl Alt Meta`.

## 4. ContextActionService

```luau
local ContextActionService = game:GetService("ContextActionService")

local function OnBlock(actionName: string, inputState: Enum.UserInputState, input: InputObject)
	if inputState == Enum.UserInputState.Begin then StartBlock()
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then StopBlock() end
	return Enum.ContextActionResult.Sink
end

ContextActionService:BindAction("Block", OnBlock, true, Enum.KeyCode.F, Enum.KeyCode.ButtonL1)
ContextActionService:BindActionAtPriority("Dodge", OnDodge, true, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Q)
ContextActionService:SetTitle("Block", "Block")
ContextActionService:SetImage("Dodge", "rbxassetid://...")
ContextActionService:SetPosition("Block", UDim2.new(1, -150, 1, -150))
local btn = ContextActionService:GetButton("Block")      -- ImageButton on mobile
ContextActionService:UnbindAction("Block")
ContextActionService:UnbindAllActions()
ContextActionService:GetAllBoundActionInfo()
```
- 3rd arg `createTouchButton` = auto mobile button.
- Bindings **ignore `gameProcessedEvent`**: they don't fire while typing in a TextBox (CAS handles that), but do fire over GUI buttons.
- Binding the same key in multiple actions: newest/higher priority wins unless it returns `Pass`.
- Rebinding = Unbind + Bind with new keys.
- `Cancel` state fires when an action is unbound or overridden while held -> always handle it to stop blocking.

## 5. Input Action System (newer, 2025+)

Instance-based alternative: `InputContext` (container, `Enabled`, `Priority`, `Sink`) -> `InputAction` (`Type: Enum.InputActionType` e.g. `Bool`, `Direction1D`, `Direction2D`, `Direction3D`, `ViewportPosition`; events `Pressed`, `Released`, `StateChanged`; `:GetState()`) -> `InputBinding` (`KeyCode`, `PrimaryModifier`, `SecondaryModifier`, `UI` button, `Up/Down/Left/Right` composite keys for directional actions).
- Pros: designer-editable in Explorer, built-in rebinding, cross-device, composite WASD direction.
- Verify exact property/event names in the current Engine API docs before using; fall back to UIS/CAS which are stable.

## 6. Combat input patterns

### Tap vs hold (F: tap = parry, hold = block)
```luau
local HOLD_THRESHOLD = 0.18
local fDownAt: number? = nil
local holdThread: thread? = nil

local function FBegan()
	fDownAt = os.clock()
	holdThread = task.delay(HOLD_THRESHOLD, function()
		holdThread = nil
		StartBlock()                    -- became a hold
	end)
end
local function FEnded()
	if holdThread then                  -- released before threshold -> tap
		task.cancel(holdThread) ; holdThread = nil
		Parry(ConsumeDirection())
	else
		StopBlock()
	end
	fDownAt = nil
end
```
Alternative design: press F = start parry window immediately, holding past the window transitions into block (no input delay for parry). This is usually better feeling - "parry on press, block on hold".

### Directional buffer (W/A/S/D within a window)
```luau
local KeyToDirection = {
	[Enum.KeyCode.W] = "Front", [Enum.KeyCode.S] = "Back",
	[Enum.KeyCode.A] = "Left",  [Enum.KeyCode.D] = "Right",
}
local Buffer = { Direction = nil :: string?, Time = -math.huge }
local WINDOW = 0.25

UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	local dir = KeyToDirection[input.KeyCode]
	if dir then Buffer.Direction, Buffer.Time = dir, os.clock() return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		local d = (os.clock() - Buffer.Time <= WINDOW) and Buffer.Direction or nil
		Buffer.Direction = nil
		RequestAttack(d)                -- nil = neutral combo M1
	end
end)
```
- Use the **most recent** direction press (not the oldest).
- Option: also accept "currently held" (`UserInputService:IsKeyDown`) as a fallback for players who hold W while clicking - decide which feels right; the time window approach rewards intent.
- Diagonals: if two directions pressed within a few ms, pick the latest or define a priority.

### Camera/character relative directions
Raw keys are relative to the camera. For "relative to character facing" use the move vector:
```luau
local hum: Humanoid -- local character
local root = hum.RootPart
local move = hum.MoveDirection                       -- world space, camera-relative input
if move.Magnitude > 0.1 then
	local localDir = root.CFrame:VectorToObjectSpace(move)
	-- localDir.Z < 0 = forward, > 0 = back; X > 0 = right, < 0 = left
end
```
With shift-lock / `Humanoid.AutoRotate`, camera and character face the same way, so keys == character directions. Decide per game; most directional-combat games lock the character to camera while in combat.

### Input as a state machine
The directional buffer, the queued M1 and F tap-vs-hold are client states with timeouts (`DirectionBuffered`, `AttackQueued`, `DefendHeld`). Keybinds are a table from KeyCode / UserInputType to an input event, so the chart never sees keys. See `roblox.architecture.state-machines` §6.5.

### Input -> intent -> network
Client converts raw input into a small **intent** (`Action`, `Direction`, `Timestamp`) and fires a Net channel. Server validates against its own state. Never send key codes as authority.

### Rebinding storage
Store `Enum.KeyCode.Name` strings in the player's saved profile (`"F"`), restore with `Enum.KeyCode[name]` (wrap in `pcall` or check `Enum.KeyCode:FromName(name)`).

### Edge cases
- Clear held state on `UserInputService.WindowFocusReleased` (alt-tab while holding F).
- `gameProcessedEvent` is true when a TextBox has focus (chat) or a GUI element consumed the input; WASD/Space movement keys are not game-processed, so they still reach your handler.
- Shift-lock default key is LeftShift; Roblox reserves some keys (Esc, `/` chat, F9 console, F10/F11 etc.).
- Mobile: provide CAS buttons for M1, Block, Dodge; direction from thumbstick `MoveDirection`.
