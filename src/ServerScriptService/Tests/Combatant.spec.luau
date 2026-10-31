local Combat = game:GetService("ReplicatedStorage"):WaitForChild("Combat")
local Combatant = require(Combat:WaitForChild("Combatant"))
local Config = require(Combat:WaitForChild("CombatConfig"))
local Limbs = require(Combat:WaitForChild("Limbs"))
local Resolver = require(Combat:WaitForChild("Resolver"))
local Exhaustion = require(Combat:WaitForChild("Exhaustion"))
local LinkedSword = require(Combat:WaitForChild("Weapons"):WaitForChild("LinkedSword"))

return function(Describe, It, Expect)
	-- plain tables stand in for the character parts
	local function New()
		return Combatant.new({
			Model = {},
			Root = { CFrame = CFrame.new(), Position = Vector3.new() },
			Humanoid = { Health = 100 },
			Definition = LinkedSword,
			BaseWalkSpeed = 16,
		})
	end

	Describe("posture", function()
		It("starts full and breaks at zero", function()
			local C = New()
			Expect(C.Posture).ToBe(100)
			Expect(C:TakePosture(60, 0)).ToBe(false)
			Expect(C:TakePosture(40, 0)).ToBe(true)
		end)
		It("regenerates only after the delay", function()
			local C = New()
			C:TakePosture(50, 0)
			C:Regen(1, 1, Config)
			Expect(C.Posture).ToBe(50)
			C:Regen(2, 1, Config)
			Expect(C.Posture).ToBe(65)
		end)
	end)

	Describe("snapshot", function()
		It("feeds the resolver", function()
			local C = New()
			C.Runtime:SetState("Blocking")
			local Attacker = { Direction = nil, AttackerPosition = Vector3.new(0, 0, -4), PostureDamage = 10 }
			Expect(Resolver.Resolve(Attacker, C:Snapshot(0), 0, Config.Resolver)).ToBe("Blocked")
		end)
		It("only exposes parry timing while parrying", function()
			local C = New()
			C.ParryStart = 0
			C.ParryDirection = "Front"
			Expect(C:Snapshot(0).ParryStart).ToBeNil()
			C.Runtime:SetState("Parrying")
			Expect(C:Snapshot(0).ParryStart).ToBe(0)
		end)
		It("reports the attack phase", function()
			local C = New()
			C.Attack = { ActiveStart = 1, ActiveEnd = 2 }
			Expect(C:Snapshot(0.5).Phase).ToBe("Startup")
			Expect(C:Snapshot(1.5).Phase).ToBe("Active")
			Expect(C:Snapshot(3).Phase).ToBe("Recovery")
		end)
		It("follow-up window changes the match state", function()
			local C = New()
			C.FollowUpUntil = 1
			Expect(C:MatchState(0.5)).ToBe("FollowUp")
			Expect(C:MatchState(1.5)).ToBe("Idle")
			Expect(C.Runtime:MatchAttack(nil, 0.5, C:MatchState(0.5)).Id).ToBe("LinkedSword.FollowUp.CounterSlash")
		end)
	end)

	Describe("exhaustion debuff", function()
		It("applies and clears modifiers with the stack count", function()
			local C = New()
			Exhaustion.Add(C.Exhaustion, Config.Exhaustion, Config.Exhaustion.Threshold + 1, 0) -- level 2
			Expect(C:RefreshExhausted(Config)).ToBe(2)
			Expect(C.Stats:Get("AttackSpeed")).ToBeNear(1 - 2 * Config.ExhaustedPerLevel.AttackSpeed)
			Expect(C.Stats:Get("PostureTaken")).ToBeNear(1 + 2 * Config.ExhaustedPerLevel.PostureTaken)
			C.Exhaustion.Stacks = 0
			Expect(C:RefreshExhausted(Config)).ToBe(0)
			Expect(C.Stats:Get("AttackSpeed")).ToBe(1)
		end)
		It("exhausted defenders take more posture damage", function()
			local C = New()
			Exhaustion.Add(C.Exhaustion, Config.Exhaustion, Config.Exhaustion.Threshold, 0) -- level 1
			C:RefreshExhausted(Config)
			C:TakePosture(10, 0)
			Expect(C.Posture).ToBeNear(100 - 10 * (1 + Config.ExhaustedPerLevel.PostureTaken))
		end)
	end)

	Describe("movement", function()
		It("walk speed follows the state", function()
			local C = New()
			local Base = 16 * LinkedSword.Schema.Stats.WalkSpeedMultiplier
			Expect(C:WalkSpeed(Config)).ToBeNear(Base)
			C.Runtime:SetState("Stunned")
			Expect(C:WalkSpeed(Config)).ToBe(0)
			C.Runtime:SetState("Blocking")
			Expect(C:WalkSpeed(Config)).ToBeNear(Base * Config.StateWalk.Blocking * LinkedSword.Schema.Defense.BlockWalkSpeedMultiplier)
		end)
	end)

	Describe("hit chain and limbs", function()
		It("counts consecutive hits and resets after a pause", function()
			local C = New()
			Expect(C:RegisterHitTaken(0, 1)).ToBe(0)
			Expect(C:RegisterHitTaken(0.5, 1)).ToBe(1)
			Expect(C:RegisterHitTaken(3, 1)).ToBe(0)
		end)
		It("limb meter fills and bursts with the weapon's overrides", function()
			local C = New()
			local Fill, Burst = C:AddLimbHit("Torso", 0) -- LinkedSword: Max 120, PerHit 25
			Expect(Burst).ToBe(false)
			Expect(Fill).ToBe(Limbs.Fill(25, Limbs.Config("Torso", LinkedSword.Schema.Limbs)))
			for _ = 1, 3 do
				C:AddLimbHit("Torso", 0)
			end
			local _, Last = C:AddLimbHit("Torso", 0)
			Expect(Last).ToBe(true)
			Expect(C.LimbMeters.Torso).ToBe(0)
		end)
		It("limb meters decay after the delay", function()
			local C = New()
			C:AddLimbHit("Left Arm", 0)
			Expect(next(C:Regen(1, 1, Config))).ToBeNil()
			local Changed = C:Regen(Config.LimbDecayDelay + 1, 1, Config)
			Expect(Changed["Left Arm"]).Never.ToBeNil()
			Expect(C.LimbMeters["Left Arm"]).ToBe(20)
		end)
		It("unknown limb groups are ignored", function()
			Expect((New():AddLimbHit("Tail", 0))).ToBeNil()
		end)
	end)
end
