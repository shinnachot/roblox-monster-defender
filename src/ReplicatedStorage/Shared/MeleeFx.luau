-- MeleeFx: ความรู้สึกของอาวุธระยะประชิด — ใช้กับอาวุธประชิดทุกชิ้น (ปัจจุบันและที่จะเพิ่มในอนาคต)
--   server: AddTrails ใส่ Trail ให้โมเดลอาวุธตอนถือ (ปิดไว้ก่อน, replicate ให้ทุกคน)
--   client: PlaySlash เล่นท่าฟันแบบ 3 ช่วง (เงื้อ -> ฟาดเร็ว -> ดึงกลับ) และเปิดแสงเฉพาะช่วงฟาด
--           ShowTrail เปิดแสงของอาวุธคนอื่นตามจังหวะที่ server แจ้ง
-- อาวุธประชิดชิ้นใหม่: ใส่ Strike/StrikeEnd/StrikeSpeed ในทุกท่าใน Combo และ Trail = { Base, Tip } ใน config
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local MeleeFx = {}

local tokens = setmetatable({}, { __mode = "k" })

---------------------------------------------------------------- server

-- ใส่แสงตามอาวุธ 2 ชั้น: ริบบิ้นกว้างเต็มใบ + เส้นสว่างที่ขอบปลาย
function MeleeFx.AddTrails(model, weaponCfg)
	local trailCfg = weaponCfg.Trail
	local grip = model.PrimaryPart
	if not trailCfg or not grip then
		return
	end
	local style = Config.MeleeTrail
	local colors = trailCfg.Color or style.Color

	local function attachment(name, y)
		local a = Instance.new("Attachment")
		a.Name = name
		a.Position = Vector3.new(0, y, 0)
		a.Parent = grip
		return a
	end
	local base = attachment("TrailBase", trailCfg.Base)
	local tip = attachment("TrailTip", trailCfg.Tip)
	local edge = attachment("TrailEdge", trailCfg.Tip - style.EdgeWidth)

	local function trail(name, a0, a1, color, transparency, emission, lifetime)
		local t = Instance.new("Trail")
		t.Name = name
		t.Attachment0 = a0
		t.Attachment1 = a1
		t.Color = color
		t.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, transparency),
			NumberSequenceKeypoint.new(0.6, (transparency + 1) / 2),
			NumberSequenceKeypoint.new(1, 1),
		})
		t.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0.35), -- หางเรียวลง
		})
		t.Lifetime = lifetime
		t.LightEmission = emission
		t.LightInfluence = 0.3
		t.MinLength = 0
		t.FaceCamera = false
		t.Enabled = false
		t.Parent = grip
		return t
	end
	trail("SlashTrail", base, tip, ColorSequence.new(colors[1], colors[2]), style.Transparency, style.LightEmission, style.Lifetime)
	trail("SlashEdge", edge, tip, ColorSequence.new(style.EdgeColor), 0, 1, style.Lifetime * 0.8)
end

---------------------------------------------------------------- client

local function setTrails(model, enabled)
	if not model or not model.Parent then
		return
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Trail") then
			d.Enabled = enabled
		end
	end
end

-- เปิดแสงของอาวุธช่วง [onAt, offAt] วินาทีนับจากตอนนี้
function MeleeFx.ShowTrail(model, onAt, offAt)
	if not model or not onAt then
		return
	end
	local token = {}
	tokens[model] = token
	setTrails(model, false) -- ท่าใหม่เริ่มก่อนท่าเก่าจบฟาด: ปิดแสงของท่าเก่าทันที (ไม่ให้ค้างช่วงเงื้อ)
	task.delay(onAt, function()
		if tokens[model] == token then
			setTrails(model, true)
		end
	end)
	task.delay(offAt, function()
		if tokens[model] == token then
			setTrails(model, false)
		end
	end)
end

-- เล่นท่าฟันหนึ่งจังหวะ: ปรับความเร็วคลิปตามช่วง และเปิดแสงช่วงฟาด
-- ท่าที่ไม่มี Strike เล่นด้วยความเร็วเดียวเหมือนเดิม
function MeleeFx.PlaySlash(track, seg, weaponModel)
	local token = {}
	tokens[track] = token
	local _, duration, strikeAt, strikeEndAt = Config.SegmentTiming(seg)
	track:Play(0.05, 1, seg.Speed or 1)
	track.TimePosition = seg.Start
	local function at(time, fn)
		task.delay(time, function()
			if tokens[track] == token then
				fn()
			end
		end)
	end
	if strikeAt then
		at(strikeAt, function()
			track:AdjustSpeed(seg.StrikeSpeed)
		end)
		at(strikeEndAt, function()
			track:AdjustSpeed(seg.RecoverSpeed or seg.Speed or 1)
		end)
		MeleeFx.ShowTrail(weaponModel, strikeAt, strikeEndAt)
	end
	at(duration, function()
		tokens[track] = nil
		track:Stop(0.12)
	end)
end

return MeleeFx
