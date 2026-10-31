local Combat = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Combat")
local Timeline = require(Combat:WaitForChild("Timeline"))
local LinkedSword = require(Combat:WaitForChild("Weapons"):WaitForChild("LinkedSword"))

local Linear = { Fps = 60, HitFrames = 16, WindupModifier = 1, MaxWindupShare = 0.9 }
local Half = { Fps = 60, HitFrames = 16, WindupModifier = 0.5, MaxWindupShare = 0.9 }
local Spec = { Startup = 0.2, Active = 0.1, Recovery = 0.3 }

return function(Describe, It, Expect)
	Describe("Timeline", function()
		It("scales every phase evenly with WindupModifier 1", function()
			local T = Timeline.Compute(Spec, nil, 2, Linear)
			Expect(T.Startup).ToBeNear(0.1)
			Expect(T.Active).ToBeNear(0.05)
			Expect(T.Total).ToBeNear(0.3)
			Expect(T.WindupSpeed).ToBeNear(2)
		end)

		It("shrinks the windup slower with WindupModifier 0.5 (LoL rule)", function()
			-- Windup = 0.2 + (0.3 × 0.2/0.6 − 0.2) × 0.5 = 0.15; the rest splits 1 : 3
			local T = Timeline.Compute(Spec, nil, 2, Half)
			Expect(T.Total).ToBeNear(0.3)
			Expect(T.Startup).ToBeNear(0.15)
			Expect(T.Active).ToBeNear(0.0375)
			Expect(T.Recovery).ToBeNear(0.1125)
			Expect(T.WindupSpeed).ToBeNear(0.2 / 0.15)
			Expect(T.ActiveSpeed).ToBeNear(0.1 / 0.0375)
		end)

		It("grows the windup less when slowed", function()
			local T = Timeline.Compute(Spec, nil, 0.5, Half)
			Expect(T.Total).ToBeNear(1.2)
			Expect(T.Startup).ToBeNear(0.3)
		end)

		It("keeps the windup with WindupModifier 0 and caps its share", function()
			Expect(Timeline.Compute(Spec, nil, 2, { Fps = 60, HitFrames = 16, WindupModifier = 0, MaxWindupShare = 0.9 }).Startup).ToBeNear(0.2)
			local T = Timeline.Compute({ Startup = 1, Active = 0, Recovery = 0 }, nil, 2, { Fps = 60, HitFrames = 16, WindupModifier = 0, MaxWindupShare = 0.9 })
			Expect(T.Startup).ToBeNear(0.45)
		end)

		It("takes the last HitFrames of an animation as the hit", function()
			local W, A, R = Timeline.Base({ Recovery = 0.35 }, { Length = 0.9 }, Linear)
			Expect(W).ToBeNear(0.9 - 16 / 60)
			Expect(A).ToBeNear(16 / 60)
			Expect(R).ToBeNear(0.35)
		end)

		It("prefers Windup / HitEnd markers; frames after HitEnd count as recovery", function()
			local W, A, R = Timeline.Base({ Recovery = 0.1 }, { Length = 1, Markers = { Windup = 0.4, HitEnd = 0.6 } }, Linear)
			Expect(W).ToBeNear(0.4)
			Expect(A).ToBeNear(0.2)
			Expect(R).ToBeNear(0.5)
		end)

		It("finds LinkedSword's W_Hit in the manifest", function()
			local Spec = LinkedSword.Schema.Directional.Front
			local T = Timeline.ForAttack(LinkedSword.Schema, Spec, 1)
			Expect(T.AnimationId).ToBe("rbxassetid://77985045543593")
			Expect(T.Startup).ToBeNear(0.9 - 16 / 60)
			Expect(T.WindupSpeed).ToBeNear(1)
		end)

		It("falls back to spec timings for placeholder animations", function()
			local Spec = LinkedSword.Schema.Combo.Attacks[1]
			local T = Timeline.ForAttack(LinkedSword.Schema, Spec, 1)
			Expect(T.AnimationId).ToBeNil()
			Expect(T.Startup).ToBeNear(Spec.Startup)
		end)
	end)
end
