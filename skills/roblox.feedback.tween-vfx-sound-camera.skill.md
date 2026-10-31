---
name: roblox.feedback.tween-vfx-sound-camera
description: Roblox game-feel and feedback - TweenService (Create, Tween, TweenInfo, Enum.EasingStyle/EasingDirection, GetValue), Debris, ParticleEmitter (Emit), Beam/Trail, Highlight, Sound/SoundService/SoundGroup, Camera (CurrentCamera, CFrame, FieldOfView, shake), screen UI (BillboardGui damage numbers, ScreenGui bars), hitstop and flash recipes. Use for hit feedback, UI bars, VFX and camera effects (client side).
---

# Roblox — Feedback: Tweens, VFX, Sound, Camera, UI

Feedback is cosmetic -> run it on **clients** (each client renders its own), triggered by local prediction or server-confirmed events.

## 1. TweenService

```luau
local TweenService = game:GetService("TweenService")
local info = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0)
local tween = TweenService:Create(frame, info, { Size = UDim2.fromScale(0.5, 1), BackgroundTransparency = 0.2 })
tween:Play() ; tween:Pause() ; tween:Cancel()
tween.Completed:Connect(function(state: Enum.PlaybackState) end)
tween.PlaybackState
local alpha = TweenService:GetValue(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)  -- easing math
TweenService:SmoothDamp(current, target, velocity, smoothTime, maxSpeed?, dt?)  -- newer API, verify
```
Tweenable property types: number, boolean (snaps at end), CFrame, Rect, Color3, UDim, UDim2, Vector2, Vector2int16, Vector3. Not tweenable: EnumItem, NumberSequence, ColorSequence, strings.
`Enum.EasingStyle`: `Linear, Sine, Back, Quad, Quart, Quint, Bounce, Elastic, Exponential, Circular, Cubic`. `Enum.EasingDirection`: `In, Out, InOut`.
Same-property tweens on one instance override the previous one.

## 2. Debris

`game:GetService("Debris"):AddItem(instance, lifetimeSeconds)` - non-yielding timed destroy (good for VFX parts, movers).

## 3. Particles & effects

| Class | Key members |
|---|---|
| `ParticleEmitter` | `Enabled`, `Rate`, `Lifetime: NumberRange`, `Speed`, `SpreadAngle`, `Color: ColorSequence`, `Size/Transparency: NumberSequence`, `Texture`, `LightEmission`, `Rotation`, `RotSpeed`, `Drag`, `Acceleration`, `LockedToPart`, `EmissionDirection`, `Shape`, `ZOffset`, `TimeScale`; `:Emit(count)` burst, `:Clear()` |
| `Trail` | `Attachment0`, `Attachment1`, `Lifetime`, `Color`, `Transparency`, `WidthScale`, `FaceCamera`, `Enabled` - weapon swing trails (enable during swing) |
| `Beam` | `Attachment0/1`, `CurveSize0/1`, `Segments`, `Width0/1`, `Texture`, `TextureSpeed` |
| `Highlight` | `Adornee`, `FillColor`, `FillTransparency`, `OutlineColor`, `OutlineTransparency`, `DepthMode` (`AlwaysOnTop`/`Occluded`) - hit flash, parry flash (limit ~31 simultaneous) |
| `PointLight` / `SpotLight` | flashes |
| `Attachment` | anchor for effects on parts: `WorldPosition`, `WorldCFrame` |

Hit spark recipe:
```luau
local function HitSpark(template: Attachment, pos: Vector3)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.Transparency = true, false, false, false, 1
	p.Size = Vector3.one * 0.1
	p.Position = pos
	local att = template:Clone() ; att.Parent = p
	p.Parent = workspace.Effects
	for _, e in att:GetDescendants() do if e:IsA("ParticleEmitter") then e:Emit(e:GetAttribute("EmitCount") or 10) end end
	game:GetService("Debris"):AddItem(p, 2)
end
```
Pool parts for frequent effects instead of creating each time.

## 4. Sound

```luau
local s = Instance.new("Sound")
s.SoundId = "rbxassetid://..."
s.Volume = 0.6 ; s.PlaybackSpeed = 1 + (math.random() - 0.5) * 0.1   -- pitch variance
s.RollOffMaxDistance = 80 ; s.RollOffMode = Enum.RollOffMode.InverseTapered
s.Parent = rootPart                                                    -- positional
s:Play()
s.Ended:Once(function() s:Destroy() end)
```
Members: `IsPlaying`, `TimeLength`, `TimePosition`, `Looped`, `SoundGroup`, `Play/Stop/Pause/Resume`, `Played`, `Ended`, `Loaded`, `IsLoaded`. `SoundService:PlayLocalSound(sound)` for UI sounds. `SoundGroup` for volume categories (SFX, Music). `SoundService.RespectFilteringEnabled` true = client-played sounds don't replicate (keep true). Newer audio API: `AudioPlayer`, `AudioEmitter`, `AudioListener`, `Wire`.

## 5. Camera (client)

```luau
local camera = workspace.CurrentCamera
camera.CFrame ; camera.Focus ; camera.FieldOfView ; camera.CameraType (Enum.CameraType.Custom / Scriptable / ...)
camera.ViewportSize ; camera:WorldToViewportPoint(pos) -> (Vector3, onScreen) ; camera:ScreenPointToRay(x, y)
```
Shake (additive offset after the default camera updates):
```luau
local shake = 0
local function AddShake(amount: number) shake = math.min(shake + amount, 1) end
RunService:BindToRenderStep("Shake", Enum.RenderPriority.Camera.Value + 1, function(dt)
	if shake <= 0 then return end
	local t = os.clock() * 40
	local m = shake * shake * 0.5
	camera.CFrame *= CFrame.Angles(math.noise(t, 0) * m * 0.05, math.noise(0, t) * m * 0.05, 0)
	shake = math.max(0, shake - dt * 2)
end)
```
FOV punch: tween `FieldOfView` 70 -> 74 -> 70 on heavy hits. `Humanoid.CameraOffset` for subtle offsets.
Shift-lock style combat camera: `UserInputService.MouseBehavior = LockCenter` + rotate root to camera yaw each frame, or enable `Player.DevEnableMouseLock`.

## 6. UI for combat

- Stamina/posture bar: `ScreenGui` -> `Frame` with child fill `Frame`, tween `Size = UDim2.fromScale(pct, 1)`. `ScreenGui.ResetOnSpawn = false`, `IgnoreGuiInset` as needed.
- Damage numbers: `BillboardGui` (`Adornee = root`, `Size = UDim2.fromOffset(100, 40)`, `StudsOffset`, `AlwaysOnTop`) with `TextLabel`; tween up & fade, Debris 1s.
- Directional indicator (incoming attack side): 4 arrows around crosshair; flash the side from the server's `Action` broadcast so defenders can react (core to a reaction-based system).
- `UIStroke`, `UICorner`, `UIGradient`, `UIScale`, `UIAspectRatioConstraint` for styling; `TextLabel.TextScaled`, `FontFace`.

## 7. Game-feel checklist per outcome

| Outcome | Attacker client | Defender client | Everyone |
|---|---|---|---|
| Hit | hitstop 50-80ms, small shake | hit-react anim, red Highlight flash, shake | spark, sound, damage number |
| Blocked | recoil anim, dull clank | block-impact anim, stamina bar flash | small spark, block sound |
| Parried | stagger anim, big flash | parry anim, white flash, slow-mo 0.1s (local) | bright spark + ring, parry sound |
| Dodged / Perfect dodge | whiff | afterimage, blue flash on perfect | whoosh |
| Knockback | heavy shake | launch + ragdoll/tumble | dust burst on land |
| Guard break | | big stun, bar shatter | glass break sound |
