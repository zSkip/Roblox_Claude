local Combat = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Combat")
local Attacks = require(Combat:WaitForChild("Attacks"))

return function(Describe, It, Expect)
	local Hitbox = { Size = Vector3.new(5, 5, 6), Offset = CFrame.new(0, 0, -3.5) }
	local function M1(Extra)
		local Spec = { Startup = 0.18, Active = 0.1, Recovery = 0.22, Hitstun = 0.35, PostureDamage = 10, Hitbox = Hitbox }
		for K, V in Extra or {} do
			Spec[K] = V
		end
		return Spec
	end

	-- trimmed LinkedSword schema (plan §4)
	local Schema = table.freeze({
		Id = "TestSword",
		Damage = { Type = "Physical", Amount = 8 },
		Combo = { ResetTime = 1.1, Attacks = { M1(), M1(), M1(), M1({ Damage = { Type = "Physical", Amount = 12 }, Knockback = { Speed = 55 } }) } },
		Directional = {
			Front = M1(),
			Left = M1(),
			Right = M1(),
			Back = M1({ Knockback = { Speed = 60 } }),
		},
		LimbTargets = { Right = "Left Arm", Left = "Right Arm", Front = "Torso", Back = "Torso" },
		FollowUps = { CounterSlash = M1({ Startup = 0.08 }) },
	})

	Describe("FromSchema", function()
		local Registry = Attacks.FromSchema(Schema)

		It("combo M1 matches by combo index", function()
			for Index = 1, 4 do
				local Def = Registry:Match({ Button = "M1", ComboIndex = Index, State = "Idle" })
				Expect(Def and Def.Id).ToBe(`TestSword.M1.{Index}`)
			end
		end)
		It("combo M1s have no limb target and inherit the default damage", function()
			local Def = Registry:Get("TestSword.M1.1")
			Expect(Def and Def.Target).ToBeNil()
			Expect(Def and Def.Spec.Damage.Amount).ToBe(8)
		end)
		It("the finisher keeps its own damage and knockback", function()
			local Def = Registry:Get("TestSword.M1.4")
			Expect(Def and Def.Spec.Damage.Amount).ToBe(12)
			Expect(Def and Def.Spec.Knockback).Never.ToBeNil()
		end)
		It("directional M1 beats the combo when a direction is buffered", function()
			local Def = Registry:Match({ Button = "M1", Direction = "Right", ComboIndex = 2, State = "Idle" })
			Expect(Def and Def.Id).ToBe("TestSword.Directional.Right")
			Expect(Def and Def.Target).ToBe("Left Arm")
		end)
		It("W and S target the Torso, S knocks back", function()
			Expect((Registry:Get("TestSword.Directional.Front") :: any).Target).ToBe("Torso")
			local Back = Registry:Get("TestSword.Directional.Back") :: any
			Expect(Back.Target).ToBe("Torso")
			Expect(Back.Spec.Knockback.Speed).ToBe(60)
		end)
		It("follow-up wins only in the FollowUp state, with or without a direction", function()
			Expect((Registry:Match({ Button = "M1", ComboIndex = 1, State = "FollowUp" }) :: any).Id).ToBe("TestSword.FollowUp.CounterSlash")
			Expect((Registry:Match({ Button = "M1", Direction = "Left", State = "FollowUp" }) :: any).Id).ToBe("TestSword.FollowUp.CounterSlash")
			Expect((Registry:Match({ Button = "M1", ComboIndex = 1, State = "Idle" }) :: any).Id).ToBe("TestSword.M1.1")
		end)
		It("unknown buttons match nothing", function()
			Expect(Registry:Match({ Button = "M2", Direction = "Back" })).ToBeNil()
		end)
	end)

	Describe("Register", function()
		It("a future leg sweep is one more def", function()
			local Registry = Attacks.FromSchema(Schema)
			Registry:Register({ Id = "Sweep", Input = { Button = "M2", Direction = "Back" }, Target = "Legs", Spec = M1() })
			Expect((Registry:Match({ Button = "M2", Direction = "Back" }) :: any).Target).ToBe("Legs")
			Expect(Registry:Match({ Button = "M2" })).ToBeNil()
		end)
		It("higher priority wins, equal priority keeps registration order", function()
			local Registry = Attacks.NewRegistry()
			Registry:Register({ Id = "A", Input = { Button = "M1", Direction = "Any" }, Spec = {} })
			Registry:Register({ Id = "B", Input = { Button = "M1", Direction = "Any" }, Spec = {} })
			Expect((Registry:Match({ Button = "M1" }) :: any).Id).ToBe("A")
			Registry:Register({ Id = "C", Input = { Button = "M1", Direction = "Any" }, Priority = 5, Spec = {} })
			Expect((Registry:Match({ Button = "M1", Direction = "Front" }) :: any).Id).ToBe("C")
		end)
		It("rejects duplicates and bad defs", function()
			local Registry = Attacks.NewRegistry()
			Registry:Register({ Id = "A", Input = { Button = "M1" }, Spec = {} })
			Expect(function()
				Registry:Register({ Id = "A", Input = { Button = "M1" }, Spec = {} })
			end).ToThrow("duplicate")
			Expect(function()
				Registry:Register({ Id = "B", Input = { Button = "M1", Direction = "Up" } :: any, Spec = {} })
			end).ToThrow("unknown direction")
			Expect(function()
				Registry:Register({ Id = "C", Spec = {} } :: any)
			end).ToThrow("Input.Button")
		end)
		It("registered defs are frozen", function()
			local Registry = Attacks.NewRegistry()
			local Def = Registry:Register({ Id = "A", Input = { Button = "M1" }, Spec = {} })
			Expect(table.isfrozen(Def)).ToBe(true)
		end)
	end)
end
