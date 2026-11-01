local Combat = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Combat")
local ClaimRules = require(Combat:WaitForChild("ClaimRules"))

local Cfg = { ClaimEarlySlack = 0.05, ClaimLateSlack = 0.35, ClaimRangeSlack = 4, ClaimBehindSlack = 1.5 }
local Hitbox = { Size = Vector3.new(5, 5, 6), Offset = CFrame.new(0, 0, -3.5) }

return function(Describe, It, Expect)
	Describe("ClaimRules", function()
		It("rejects claims before the hit frames, beyond the early slack", function()
			Expect(ClaimRules.InWindow(10.0, 10.29, 10.47, Cfg)).ToBe(false)
			Expect(ClaimRules.InWindow(10.23, 10.29, 10.47, Cfg)).ToBe(false)
			Expect(ClaimRules.InWindow(10.25, 10.29, 10.47, Cfg)).ToBe(true)
		end)

		It("allows late claims within the latency slack", function()
			Expect(ClaimRules.InWindow(10.8, 10.29, 10.47, Cfg)).ToBe(true)
			Expect(ClaimRules.InWindow(10.83, 10.29, 10.47, Cfg)).ToBe(false)
		end)

		It("accepts a target in front, inside the hitbox plus slack", function()
			Expect(ClaimRules.Reach(CFrame.identity, Hitbox, Vector3.new(0, 0, -3), Cfg)).ToBe(nil)
			Expect(ClaimRules.Reach(CFrame.identity, Hitbox, Vector3.new(6, 0, -3), Cfg)).ToBe(nil)
		end)

		It("rejects a target behind the attacker", function()
			Expect(ClaimRules.Reach(CFrame.identity, Hitbox, Vector3.new(0, 0, 3), Cfg)).ToBe("Behind")
			Expect(ClaimRules.Reach(CFrame.identity, Hitbox, Vector3.new(0, 0, 1), Cfg)).ToBe(nil)
		end)

		It("rejects a target outside the hitbox plus slack", function()
			Expect(ClaimRules.Reach(CFrame.identity, Hitbox, Vector3.new(0, 0, -11), Cfg)).ToBe("OutOfRange")
			Expect(ClaimRules.Reach(CFrame.identity, Hitbox, Vector3.new(7, 0, -3), Cfg)).ToBe("OutOfRange")
		end)

		It("follows the attacker's facing", function()
			local TurnedAround = CFrame.Angles(0, math.pi, 0)
			Expect(ClaimRules.Reach(TurnedAround, Hitbox, Vector3.new(0, 0, 3), Cfg)).ToBe(nil)
			Expect(ClaimRules.Reach(TurnedAround, Hitbox, Vector3.new(0, 0, -3), Cfg)).ToBe("Behind")
		end)
	end)
end
