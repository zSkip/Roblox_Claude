--!strict
-- LinkedSword: the first weapon definition (plan §4). Pure data + builder sugar; no side-specific code.
-- Animations: the directional M1s and dodges use ReplicatedStorage.Assets.Animations (60 fps, frame data
-- from the baked AnimationManifest). Combo M1s reuse the directional hit animations (matched by swing
-- side) at AnimationSpeed > 1, so they stay faster than the directionals (G9). The rest are placeholders
-- (rbxassetid://0): those fall back to procedural weapon swings and the spec's Startup / Active / Recovery.

local WeaponClass = require(script.Parent.Parent.WeaponClass)
local WeaponModel = require(script.Parent.Parent.WeaponModel)

local Box = Vector3.new(5, 5, 6)
local Ahead = CFrame.new(0, 0, -3.5)

local LinkedSword = WeaponClass.Define({
	Id = "LinkedSword",

	-- weapon part -> body part links (Combat/WeaponModel). Each becomes a Motor6D the animations can drive;
	-- add { Part = "Scabbard", Body = "Left Arm" } once the model has one. C0 must match the rig the
	-- weapon animations were authored on (identity for a Tool6D-style rig).
	Motors = {
		{ Part = "Handle", Body = "Right Arm", C0 = WeaponModel.GripC0 },
	},

	-- no model asset yet: Combat/WeaponModel builds one from this description
	ModelSpec = {
		HandleSize = Vector3.new(0.3, 1.1, 0.3),
		BladeSize = Vector3.new(0.2, 3.6, 0.55),
		HandleColor = Color3.fromRGB(90, 60, 40),
		BladeColor = Color3.fromRGB(200, 205, 215),
	},

	Stats = {
		AttackSpeed = 1,
		WalkSpeedMultiplier = 0.9,
		MaxPosture = 100,
		PostureRegen = 15,
		PostureRegenDelay = 1.5,
		Armor = 0,
		MagicResist = 0,
		Tenacity = 0,
	},

	Damage = { Type = "Physical", Amount = 8 },

	Animations = {
		Idle = "rbxassetid://0",
		-- W/A/S/D + M1
		Directional = {
			Front = "rbxassetid://77985045543593", -- W_Hit
			Left = "rbxassetid://128553011522756", -- A_Hit
			Back = "rbxassetid://80985889711180", -- S_Hit
			Right = "rbxassetid://119438740435237", -- D_Hit
		},
		Parry = { Front = "rbxassetid://0", Back = "rbxassetid://0", Left = "rbxassetid://0", Right = "rbxassetid://0" },
		Block = "rbxassetid://0",
		-- W/A/S/D + Q
		Dodge = {
			Front = "rbxassetid://132645008089719", -- Crouch
			Left = "rbxassetid://109384176902426", -- A_SideStep
			Back = "rbxassetid://82135177215001", -- BackDodge
			Right = "rbxassetid://128034216892920", -- D_SideStep
		},
		FollowUp = { CounterSlash = "rbxassetid://0" },
	},

	Keybinds = {
		Attack = Enum.UserInputType.MouseButton1,
		Defend = Enum.KeyCode.F,
		Dodge = Enum.KeyCode.Q,
		Directions = { [Enum.KeyCode.W] = "Front", [Enum.KeyCode.S] = "Back", [Enum.KeyCode.A] = "Left", [Enum.KeyCode.D] = "Right" },
	},

	Combo = {
		ResetTime = 1.1,
		-- same clips as the directionals; AnimationSpeed + WindupModifier 1 keep the windup shorter than theirs
		Attacks = {
			{ Animation = "Directional.Right", AnimationSpeed = 1.5, WindupModifier = 1, Swing = "Right", Startup = 0.18, Active = 0.12, Recovery = 0.22, Hitstun = 0.35, PostureDamage = 10, Hitbox = { Size = Box, Offset = Ahead } },
			{ Animation = "Directional.Left", AnimationSpeed = 1.5, WindupModifier = 1, Swing = "Left", Startup = 0.18, Active = 0.12, Recovery = 0.22, Hitstun = 0.35, PostureDamage = 10, Hitbox = { Size = Box, Offset = Ahead } },
			{ Animation = "Directional.Right", AnimationSpeed = 1.5, WindupModifier = 1, Swing = "Right", Startup = 0.18, Active = 0.12, Recovery = 0.22, Hitstun = 0.35, PostureDamage = 10, Hitbox = { Size = Box, Offset = Ahead } },
			{
				Animation = "Directional.Front", AnimationSpeed = 1.25, WindupModifier = 1, Swing = "Front", Startup = 0.25, Active = 0.14, Recovery = 0.55, Hitstun = 0.6, PostureDamage = 35,
				Damage = { Type = "Physical", Amount = 12 },
				Knockback = { Speed = 55, Up = 18, Duration = 0.2 },
				Tags = { Finisher = true },
				Hitbox = { Size = Vector3.new(6, 5, 7), Offset = CFrame.new(0, 0, -4) },
			},
		},
	},

	-- startup is longer than a combo M1 so the defender can read the direction and react (G9)
	Directional = {
		Front = { Animation = "Directional.Front", Swing = "Front", Startup = 0.38, Active = 0.12, Recovery = 0.35, Hitstun = 0.5, PostureDamage = 20, Hitbox = { Size = Vector3.new(4, 5, 8), Offset = CFrame.new(0, 0, -4.5) } },
		Left = { Animation = "Directional.Left", Swing = "Left", Startup = 0.38, Active = 0.12, Recovery = 0.35, Hitstun = 0.5, PostureDamage = 20, Hitbox = { Size = Vector3.new(7, 5, 5), Offset = CFrame.new(0, 0, -3) } },
		Right = { Animation = "Directional.Right", Swing = "Right", Startup = 0.38, Active = 0.12, Recovery = 0.35, Hitstun = 0.5, PostureDamage = 20, Hitbox = { Size = Vector3.new(7, 5, 5), Offset = CFrame.new(0, 0, -3) } },
		Back = {
			Animation = "Directional.Back", Swing = "Back", Startup = 0.42, Active = 0.12, Recovery = 0.5, Hitstun = 0.6, PostureDamage = 40,
			Knockback = { Speed = 60, Up = 20, Duration = 0.2 }, -- S+M1 always knocks back
			Hitbox = { Size = Box, Offset = Ahead },
		},
	},

	-- perfect counter-dodge opens CombatConfig.FollowUpWindow; the next M1 becomes this
	FollowUps = {
		CounterSlash = {
			Animation = "FollowUp.CounterSlash", Swing = "Left", Startup = 0.08, Active = 0.12, Recovery = 0.3, Hitstun = 0.7, PostureDamage = 25,
			Damage = { Type = "Physical", Amount = 14 },
			Hitbox = { Size = Vector3.new(6, 5, 6), Offset = Ahead },
		},
	},

	Defense = {
		ParryWindow = 0.2,
		ParryCooldown = 0.6,
		BlockDamageMultiplier = 0.15,
		BlockWalkSpeedMultiplier = 0.5,
		DodgeIFrames = 0.25,
		DodgeDuration = 0.3,
		DodgeSpeed = 45,
		DodgeCooldown = 0.9,
		PerfectDodgeWindow = 0.12,
	},

	Timings = { DirectionalWindow = 0.25, InputBuffer = 0.2 },

	-- mirrored, R6 (decision log: W and S both target the Torso; Legs/Head reserved)
	LimbTargets = { Right = "Left Arm", Left = "Right Arm", Front = "Torso", Back = "Torso" },
	Limbs = {
		["Left Arm"] = { Max = 100, PerHit = 25, BurstDamage = 15 },
		["Right Arm"] = { Max = 100, PerHit = 25, BurstDamage = 15 },
		Torso = { Max = 120, PerHit = 25, BurstDamage = 20 },
	},

	Feint = { Enabled = true, ExhaustionStacks = 1, Window = 0.2 },
})

-- builder sugar from the original API: hooks run on every runtime of this weapon, on both sides.
-- Keep them side-neutral; side-specific reactions go in the entry scripts.
LinkedSword:CreateState({ StateName = "Idle" })

return LinkedSword
