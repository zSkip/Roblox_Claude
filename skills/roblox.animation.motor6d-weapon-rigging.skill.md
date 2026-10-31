---
name: roblox.animation.motor6d-weapon-rigging
description: Attaching weapons and props to a character with Motor6Ds so animations can pose them (Nilociety's Tool6D pattern, used by the user across weapon systems) - config-driven part→limb links, removing the Tool RightGrip weld, Part0/Part1/C0/C1 rules, how the Animator matches poses to joints, cleanup on unequip/destroy, multi-part weapons (handle + scabbard), the toolless variant in this repo (Combat/WeaponModel), Animation Editor rigging steps and gotchas. Use when a weapon doesn't follow animations, when adding a weapon part to animate, or when building equip/unequip code.
---

# Roblox — Motor6D weapon rigging (Tool6D pattern)

Source: the user's go-to script, **Tool6D by @Nilociety** (a remaster of Motor6DHandler, DevForum "Tool6D - Animate tool handles easily"). It's a free resource. The ideas below are what matter; this repo applies them without a `Tool` in `Shared/Combat/WeaponModel`.

## 1. Why Motor6D and not a weld

- A `Tool` attaches its `Handle` with a **`RightGrip` Weld** on the right arm/hand. Welds are not animatable: animations only drive `Motor6D.Transform`.
- A `Motor6D` between a limb and a weapon part makes that part a **joint in the rig**, so an animation authored with the weapon moves it.
- The Animator matches a pose to a joint **by the Part1 name under its Part0's pose**. An animation that keys `Right Arm → Handle` drives any Motor6D whose `Part0` is the `Right Arm` and `Part1` is named `Handle`. The Motor6D's own name doesn't matter, and neither does its parent, as long as it is a descendant of the character model.

## 2. The Tool6D pattern

**Config:** a list of links. Each link names a weapon part and the body part it attaches to:

```luau
local Configuration = {
	[1] = { Tool_Part = "Handle",   Body_Part = "Right Arm" },
	[2] = { Tool_Part = "Scabbard", Body_Part = "Left Arm" },
}
```

**On equip:**
1. Resolve the player and character from `Tool.Parent`. Re-resolve on every equip, because characters respawn.
2. If the tool has a `Handle`, **destroy `RightGrip`**. It's under `Right Arm` on R6 and `RightHand` on R15. Otherwise the weld fights the motor.
3. For each link, create a `Motor6D` named `Link_<index>`, put it in a `Motors` folder, and set `Part1 = Tool[Tool_Part]` and `Part0 = Character[Body_Part]`.
4. If a part is missing, **error with the configured name** so spelling mistakes show up right away.

**On unequip:** clear the motors. That means `Part1 = nil`, `Part0 = nil`, then `:Destroy()`.

**On destruction:** `Tool.ChildRemoved` covers removals that `Unequipped` misses. It runs the same clear.

**C0 / C1:** Tool6D leaves both at **identity**. The animation is then what places the weapon in the hand, which only works when the animation was authored on a rig with the same identity motor.

## 3. Rules that carry over to any system

| Rule | Why |
|---|---|
| Part0 = body part, Part1 = weapon part | Animation poses hang under the limb, keyed by the weapon part's name |
| Weapon part names must match the animation rig | `Handle`, `Scabbard`... A rename breaks every animation that keys it |
| C0/C1 must match the rig the animation was authored on | The animation stores `Transform` relative to C0/C1. A different C0 offsets the pose. Tool6D rigs use identity |
| Remove the `RightGrip` weld | A weld plus a motor on the same part means two constraints fighting |
| Clear Part0/Part1 before Destroy | Stops the joint from yanking parts or leaving the assembly half-joined during teardown |
| Clean up on every exit path | Unequip, tool removed, character respawn/destroy |
| Weapon parts: `Massless`, `CanCollide = false`, `Anchored = false` | Anchored parts freeze the character, collisions fling it, and mass changes movement |
| Create motors on the **server** | Client-made joints don't replicate. Other players see the weapon floating, and server hitboxes read the wrong CFrame |
| Re-resolve the character on equip | A cached `Character` is stale after a respawn |
| One link per animated part | A scabbard, shield or second blade each needs its own Motor6D to be animatable |

## 4. This repo: toolless Tool6D (`Shared/Combat/WeaponModel`)

There's no `Tool`. The weapon is a `Model` named `Weapon`, parented under the character. Links come from the weapon schema:

```luau
-- Weapons/LinkedSword.luau
Motors = {
	{ Part = "Handle", Body = "Right Arm", C0 = WeaponModel.GripC0 },
	-- { Part = "Scabbard", Body = "Left Arm" },   -- identity C0, Tool6D style
},
```

| API | Does |
|---|---|
| `WeaponModel.Attach(Character, Schema) -> Model?` | Detaches any old weapon, destroys `RightGrip`, builds or clones the model, then creates `Weapon/Motors/Link_<i>` per link (`Part0` = body, `Part1` = weapon part, C0/C1 default to identity). It **errors** on a missing weapon part and **warns + returns nil** on a missing body part (R15 rig in an R6 game). R6 limb names fall back to R15 (`Right Arm` → `RightHand`) |
| `WeaponModel.Detach(Character)` | Clears Part0/Part1, destroys the motors, then the model |
| `WeaponModel.GetMotor(Character, PartName?) -> Motor6D?` | The motor whose Part1 is named `PartName` (default `Handle`). `FxController` tweens its C0 for procedural swings |
| `Schema.Motors` missing | Falls back to one `Handle` link on `ModelSpec.Grip` with `GripC0` |

`Model.Destroying` also clears the motors, which covers the character being destroyed (the `ChildRemoved` equivalent).

`CombatService.Register` calls `Attach` on the server, so motors replicate to every client.

`GripC0` (`CFrame.new(0, -1, 0) * CFrame.Angles(-π/2, 0, 0)`) puts the handle at the bottom of the R6 arm, pointing forward. Use it only while the weapon animations don't key `Handle`. Once animations that key the handle are authored on a Tool6D rig (identity C0), **drop `C0` from the link**, or the pose ends up offset by `GripC0`.

## 5. Authoring animations that move the weapon

1. In Studio, put an R6 rig in Workspace and the weapon model under it.
2. Create the same Motor6Ds the game will create: `Part0 = Right Arm`, `Part1 = Handle`, with the same C0/C1 (identity for Tool6D). Run the Attach code on the rig, or use a rig-builder plugin.
3. Open the Animation Editor on the rig. `Handle` (and `Scabbard`...) now show up as animatable joints. Key them with the swing.
4. Publish, then add the id to the schema's `Animations` and run `Tools/AnimationBake`.
5. In game, the joints must match: same Part0 limb, same Part1 name, same C0/C1.

## 6. Troubleshooting

| Symptom | Cause |
|---|---|
| Body animates, weapon stays still | No Motor6D for that part, or Part1's name differs from the one in the animation, or a `RightGrip` weld is still present |
| Weapon offset or rotated during anims | C0/C1 differ from the authoring rig |
| Weapon floats for other players | Motors were created on the client |
| Character flung or stuck after equip | Weapon parts collide or are anchored |
| Error `weapon part "X" doesn't exist` | `Motors[i].Part` is misspelled or missing in the model |
| Warning `has no "Right Arm"` | R15 avatar in an R6 game. Set Game Settings → Avatar → R6 |
| Weapon left behind after respawn/unequip | Missing cleanup on one exit path |

See also: `roblox.animation.animator-tracks` (tracks, markers, replication) and `roblox.character.humanoid-players` (rigs, R6/R15).
