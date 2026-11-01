local Combat = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Combat")
local Resolver = require(Combat:WaitForChild("Resolver"))

return function(Describe, It, Expect)
	-- defender at the origin facing -Z; attackers stand 4 studs away
	local Origin = CFrame.new()
	local Front = Vector3.new(0, 0, -4)
	local Behind = Vector3.new(0, 0, 4)
	local LeftFlank = Vector3.new(-4, 0, 0)

	local function Attack(Direction, Position, PostureDamage)
		return { Direction = Direction, AttackerPosition = Position or Front, PostureDamage = PostureDamage or 10 }
	end

	local function Defender(Fields)
		local D = { CFrame = Origin, State = "Idle", Posture = 100 }
		for K, V in Fields or {} do
			D[K] = V
		end
		return D
	end

	Describe("IncomingSide", function()
		It("mirrors a directional swing from the front", function()
			Expect(Resolver.IncomingSide(Origin, Front, "Right")).ToBe("Left")
			Expect(Resolver.IncomingSide(Origin, Front, "Left")).ToBe("Right")
			Expect(Resolver.IncomingSide(Origin, Front, "Back")).ToBe("Back")
		end)
		It("uses the geometric side for combo M1s and flank attacks", function()
			Expect(Resolver.IncomingSide(Origin, Front, nil)).ToBe("Front")
			Expect(Resolver.IncomingSide(Origin, LeftFlank, "Right")).ToBe("Left")
			Expect(Resolver.IncomingSide(Origin, Behind, "Front")).ToBe("Back")
		end)
	end)

	Describe("matrix (plan §7)", function()
		local Now = 10
		local Cases = {
			-- name, attack, defender, expected
			{ "idle vs combo M1", Attack(nil), Defender(), "Hit" },
			{ "idle vs directional", Attack("Right"), Defender(), "Hit" },
			{ "stunned is always hit", Attack(nil), Defender({ State = "Stunned" }), "Hit" },
			{ "block vs combo M1", Attack(nil), Defender({ State = "Blocking" }), "Blocked" },
			{ "block vs knockback, full posture", Attack("Back", Front, 40), Defender({ State = "Blocking", Posture = 100 }), "Blocked" },
			{ "block vs knockback, low posture", Attack("Back", Front, 40), Defender({ State = "Blocking", Posture = 30 }), "GuardBreak" },
			{ "posture exactly emptied breaks", Attack(nil, Front, 10), Defender({ State = "Blocking", Posture = 10 }), "GuardBreak" },
			{ "exhausted takes more posture damage", Attack(nil, Front, 10), Defender({ State = "Blocking", Posture = 15, PostureDamageTaken = 1.6 }), "GuardBreak" },
			{ "omni block covers the flank", Attack(nil, LeftFlank), Defender({ State = "Blocking" }), "Blocked" },
			{ "block from behind is hit", Attack(nil, Behind), Defender({ State = "Blocking" }), "Hit" },
			{ "mirrored parry matches", Attack("Right"), Defender({ State = "Parrying", ParryStart = Now - 0.1, ParryDirection = "Left" }), "Parried" },
			{ "wrong-direction parry is punished", Attack("Right"), Defender({ State = "Parrying", ParryStart = Now - 0.1, ParryDirection = "Right" }), "Hit" },
			{ "parry W vs W", Attack("Front"), Defender({ State = "Parrying", ParryStart = Now, ParryDirection = "Front" }), "Parried" },
			{ "parry S vs S+M1", Attack("Back"), Defender({ State = "Parrying", ParryStart = Now, ParryDirection = "Back" }), "Parried" },
			{ "parry vs combo M1 needs the front", Attack(nil), Defender({ State = "Parrying", ParryStart = Now, ParryDirection = "Front" }), "Parried" },
			{ "parry held past the window blocks", Attack("Right"), Defender({ State = "Parrying", ParryStart = Now - 1, ParryDirection = "Right" }), "Blocked" },
			{ "dodge i-frames", Attack("Right"), Defender({ State = "Dodging", DodgeStart = Now - 0.2, IFramesUntil = Now + 0.05, DodgeDirection = "Back" }), "Dodged" },
			{ "counter-direction dodge in window", Attack("Right"), Defender({ State = "Dodging", DodgeStart = Now - 0.05, IFramesUntil = Now + 0.2, DodgeDirection = "Right" }), "PerfectDodge" },
			{ "counter-direction dodge after window", Attack("Right"), Defender({ State = "Dodging", DodgeStart = Now - 0.2, IFramesUntil = Now + 0.05, DodgeDirection = "Right" }), "Dodged" },
			{ "dodge after i-frames is hit", Attack(nil), Defender({ State = "Dodging", DodgeStart = Now - 1, IFramesUntil = Now - 0.5, DodgeDirection = "Back" }), "Hit" },
			{ "breaker i-frames dodge everything", Attack("Back"), Defender({ State = "Idle", IFramesUntil = Now + 0.3 }), "Dodged" },
			{ "clash is off by default", Attack(nil), Defender({ State = "Attacking", Phase = "Active" }), "Hit" },
		}
		for _, Case in Cases do
			It(Case[1], function()
				Expect(Resolver.Resolve(Case[2], Case[3], Now)).ToBe(Case[4])
			end)
		end
	end)

	Describe("config", function()
		It("Same parry rule uses the attacker's key", function()
			local Config = table.clone(Resolver.DefaultConfig)
			Config.ParryRule = "Same"
			local D = Defender({ State = "Parrying", ParryStart = 0, ParryDirection = "Right" })
			Expect(Resolver.Resolve(Attack("Right"), D, 0, Config)).ToBe("Parried")
		end)
		It("clash when enabled and both are active", function()
			local Config = table.clone(Resolver.DefaultConfig)
			Config.ClashEnabled = true
			Expect(Resolver.Resolve(Attack(nil), Defender({ State = "Attacking", Phase = "Active" }), 0, Config)).ToBe("Clash")
			Expect(Resolver.Resolve(Attack(nil), Defender({ State = "Attacking", Phase = "Startup" }), 0, Config)).ToBe("Hit")
		end)
		It("per-weapon parry window override", function()
			local D = Defender({ State = "Parrying", ParryStart = 0, ParryDirection = "Front", ParryWindow = 0.4 })
			Expect(Resolver.Resolve(Attack(nil), D, 0.3)).ToBe("Parried")
			Expect(Resolver.Resolve(Attack(nil), D, 0.5)).ToBe("Blocked")
		end)
	end)

	Describe("Consequences", function()
		local Spec = {
			Damage = { Type = "Physical", Amount = 12 },
			PostureDamage = 35,
			Hitstun = 0.6,
			Knockback = { Speed = 55 },
			Target = "Torso",
		}
		local Defense = { BlockDamageMultiplier = 0.15 }

		It("hit: damage, hitstun, knockback and limb target", function()
			local C = Resolver.Consequences("Hit", Spec, Defense)
			Expect(C.Damage).ToBe(12)
			Expect(C.Hitstun).ToBeNear(0.6)
			Expect(C.Knockback).ToBe(Spec.Knockback)
			Expect(C.LimbTarget).ToBe("Torso")
			Expect(C.PostureDamage).ToBe(0)
		end)
		It("hitstun diminishes per consecutive hit", function()
			Expect(Resolver.Consequences("Hit", Spec, Defense, 2).Hitstun).ToBeNear(0.6 * 0.85 * 0.85)
		end)
		It("blocked: chip damage and posture, no limb, no knockback", function()
			local C = Resolver.Consequences("Blocked", Spec, Defense)
			Expect(C.Damage).ToBeNear(1.8)
			Expect(C.PostureDamage).ToBe(35)
			Expect(C.LimbTarget).ToBeNil()
			Expect(C.Knockback).ToBeNil()
		end)
		It("guard break resets posture", function()
			Expect(Resolver.Consequences("GuardBreak", Spec, Defense).ResetPosture).ToBe(true)
		end)
		It("parried staggers the attacker, perfect dodge opens the follow-up", function()
			Expect(Resolver.Consequences("Parried", Spec).AttackerStagger).ToBe(true)
			Expect(Resolver.Consequences("Parried", Spec).Damage).ToBe(0)
			Expect(Resolver.Consequences("PerfectDodge", Spec).FollowUp).ToBe(true)
			Expect(Resolver.Consequences("Dodged", Spec).Damage).ToBe(0)
		end)
	end)

	Describe("ids", function()
		It("every outcome has a unique network id", function()
			local Seen = {}
			for Index, Outcome in Resolver.Outcomes do
				local Id = Resolver.OutcomeIds[Outcome]
				Expect(Id).ToBe(Index)
				Expect(Seen[Id]).ToBeNil()
				Seen[Id] = true
			end
		end)
	end)
end
