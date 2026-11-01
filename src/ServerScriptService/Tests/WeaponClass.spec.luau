local Combat = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Combat")
local WeaponClass = require(Combat:WaitForChild("WeaponClass"))
local LinkedSword = require(Combat:WaitForChild("Weapons"):WaitForChild("LinkedSword"))

return function(Describe, It, Expect)
	local Counter = 0
	local function Schema(Patch)
		Counter += 1
		local Attack = { Startup = 0.2, Active = 0.1, Recovery = 0.3, Hitstun = 0.3, PostureDamage = 10, Hitbox = { Size = Vector3.new(4, 4, 4), Offset = CFrame.new(0, 0, -3) } }
		local S = {
			Id = `SpecWeapon{Counter}`,
			Stats = { MaxPosture = 100 },
			Damage = { Type = "Physical", Amount = 5 },
			Combo = { ResetTime = 1, Attacks = { table.clone(Attack), table.clone(Attack), table.clone(Attack) } },
			Directional = { Right = table.clone(Attack) },
			Defense = { ParryWindow = 0.2, ParryCooldown = 0.5, BlockDamageMultiplier = 0.1, DodgeIFrames = 0.2, DodgeDuration = 0.3, DodgeSpeed = 40, DodgeCooldown = 1 },
			Timings = { DirectionalWindow = 0.25 },
			LimbTargets = { Right = "Left Arm" },
		}
		if Patch then
			Patch(S)
		end
		return S
	end

	local function Define(Patch)
		local Def = WeaponClass.Define(Schema(Patch))
		return Def
	end

	Describe("Define", function()
		It("registers, freezes the schema and builds the attack registry", function()
			local Def = Define()
			Expect(WeaponClass.Get(Def.Id)).ToBe(Def)
			Expect(table.isfrozen(Def.Schema)).ToBe(true)
			Expect(table.isfrozen(Def.Schema.Combo.Attacks[1])).ToBe(true)
			Expect(Def.Registry:Get(`{Def.Id}.M1.3`)).Never.ToBeNil()
			WeaponClass.Undefine(Def.Id)
		end)
		It("rejects duplicates", function()
			local S = Schema()
			WeaponClass.Define(S)
			Expect(function()
				WeaponClass.Define(Schema(function(X)
					X.Id = S.Id
				end))
			end).ToThrow("duplicate")
			WeaponClass.Undefine(S.Id)
		end)
		It("validates timings, hitboxes and required sections", function()
			Expect(function()
				Define(function(S)
					S.Combo.Attacks[2].Startup = -1
				end)
			end).ToThrow("Combo.Attacks[2].Startup")
			Expect(function()
				Define(function(S)
					S.Directional.Up = S.Directional.Right
				end)
			end).ToThrow("not a direction")
			Expect(function()
				Define(function(S)
					S.Combo.Attacks[1].Hitbox = { Size = 5 }
				end)
			end).ToThrow("Hitbox.Size")
			Expect(function()
				Define(function(S)
					S.Defense = nil
				end)
			end).ToThrow("Defense")
		end)
		It("LinkedSword is a valid definition", function()
			Expect(LinkedSword.Id).ToBe("LinkedSword")
			Expect(LinkedSword.Registry:Get("LinkedSword.Directional.Back").Spec.Knockback).Never.ToBeNil()
			Expect(LinkedSword.Registry:Get("LinkedSword.FollowUp.CounterSlash")).Never.ToBeNil()
		end)
	end)

	Describe("Runtime", function()
		It("each owner gets its own runtime and states", function()
			local Def = Define()
			local A, B = Def:Instantiate("A"), Def:Instantiate("B")
			A:SetState("Attacking")
			Expect(A.Current).ToBe("Attacking")
			Expect(B.Current).ToBe("Idle")
			Expect(A.States.Attacking).Never.ToBe(B.States.Attacking)
			WeaponClass.Undefine(Def.Id)
		end)
		It("SetState bumps ActionId and runs builder hooks", function()
			local Def = Define()
			local Log = {}
			Def:CreateState({ StateName = "Attacking" })
				:BindFunction(function(_, Ctx)
					table.insert(Log, "enter " .. tostring(Ctx))
				end)
				:MaidFunction(function(_, _, Reason)
					table.insert(Log, "exit " .. tostring(Reason))
				end)
			local Rt = Def:Instantiate("A")
			local Id = Rt:SetState("Attacking", "ctx")
			Expect(Id).ToBe(1)
			Rt:SetState("Idle", nil, "Done")
			Expect(Rt.ActionId).ToBe(2)
			Expect(Log).ToEqual({ "enter ctx", "exit Done" })
			WeaponClass.Undefine(Def.Id)
		end)
		It("StateChanged reports new and old states", function()
			local Def = Define()
			local Rt = Def:Instantiate("A")
			local Seen = {}
			Rt.StateChanged:Connect(function(New, Old)
				table.insert(Seen, `{Old}->{New}`)
			end)
			Rt:SetState("Blocking")
			Rt:SetState("Idle")
			Expect(Seen).ToEqual({ "Idle->Blocking", "Blocking->Idle" })
			WeaponClass.Undefine(Def.Id)
		end)
		It("CanStart respects states and cooldowns", function()
			local Def = Define()
			local Rt = Def:Instantiate("A")
			Expect(Rt:CanStart("Attack", 0)).ToBe(true)
			Rt:SetState("Stunned")
			Expect(Rt:CanStart("Attack", 0)).ToBe(false)
			Rt:SetState("Blocking")
			Expect(Rt:CanStart("Dodge", 0)).ToBe(true)
			Rt:SetCooldown("Dodge", 5)
			Expect(Rt:CanStart("Dodge", 4)).ToBe(false)
			Expect(Rt:CanStart("Dodge", 5)).ToBe(true)
			WeaponClass.Undefine(Def.Id)
		end)
		It("combo advances, wraps and resets after ResetTime", function()
			local Def = Define()
			local Rt = Def:Instantiate("A")
			local Ids = {}
			for I = 1, 4 do
				table.insert(Ids, Rt:MatchAttack(nil, I * 0.5).Id)
			end
			Expect(Ids[1]).ToBe(`{Def.Id}.M1.1`)
			Expect(Ids[3]).ToBe(`{Def.Id}.M1.3`)
			Expect(Ids[4]).ToBe(`{Def.Id}.M1.1`) -- 3-hit combo wraps
			Expect(Rt:MatchAttack(nil, 10).Id).ToBe(`{Def.Id}.M1.1`) -- reset after a pause
			WeaponClass.Undefine(Def.Id)
		end)
		It("directional M1s don't advance or reset the chain", function()
			local Def = Define()
			local Rt = Def:Instantiate("A")
			Rt:MatchAttack(nil, 0)
			local D = Rt:MatchAttack("Right", 0.3)
			Expect(D.Id).ToBe(`{Def.Id}.Directional.Right`)
			Expect(D.Target).ToBe("Left Arm")
			Expect(Rt:MatchAttack(nil, 0.6).Id).ToBe(`{Def.Id}.M1.2`)
			Expect(Rt:MatchAttack("Front", 0.7)).ToBeNil() -- this weapon has no Front directional
			WeaponClass.Undefine(Def.Id)
		end)
		It("Destroy exits the current state once", function()
			local Def = Define()
			local Exits = 0
			Def:CreateState({ StateName = "Blocking" }):MaidFunction(function()
				Exits += 1
			end)
			local Rt = Def:Instantiate("A")
			Rt:SetState("Blocking")
			Rt:Destroy()
			Rt:Destroy()
			Expect(Exits).ToBe(1)
			Expect(Rt:CanStart("Attack", 0)).ToBe(false)
			WeaponClass.Undefine(Def.Id)
		end)
	end)

	Describe("helpers", function()
		It("AnimationId resolves keys and skips placeholders", function()
			local S = { Animations = { M1 = { "rbxassetid://0", "rbxassetid://123" }, Block = "rbxassetid://9" } }
			Expect(WeaponClass.AnimationId(S, "M1.2")).ToBe("rbxassetid://123")
			Expect(WeaponClass.AnimationId(S, "M1.1")).ToBeNil()
			Expect(WeaponClass.AnimationId(S, "Block")).ToBe("rbxassetid://9")
			Expect(WeaponClass.AnimationId(S, "Missing.Key")).ToBeNil()
		end)
	end)
end
