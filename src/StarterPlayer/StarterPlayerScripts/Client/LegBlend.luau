-- LegBlend: ให้ขาเดิน/วิ่งต่อระหว่างเล่นท่าโจมตี (เช่นฟันดาบ) ขณะเคลื่อนที่
-- คลิปโจมตีที่ generate มามีท่าของขาติดมาด้วย จึงทับท่าเดินทั้งตัว (ขาหยุดนิ่งแต่ตัวไถล)
-- Roblox ไม่มี animation mask และอัปโหลดคลิปที่ตัดขาออกผ่านสคริปต์ไม่ได้
-- จึงอ่านท่าขาจาก animation เดิน/วิ่งที่กำลังเล่นอยู่จริง (ตำแหน่งเวลาเดียวกัน) แล้วเขียนทับข้อต่อขาหลัง animation
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
local RunService = game:GetService("RunService")

local LegBlend = {}

local BLEND_SPEED = 14

-- ชื่อชิ้นส่วน (= ชื่อ Pose) -> ชื่อข้อต่อที่ต่อกับชิ้นส่วนแม่
local LEG_JOINTS = {
	LeftUpperLeg = "LeftHip",
	LeftLowerLeg = "LeftKnee",
	LeftFoot = "LeftAnkle",
	RightUpperLeg = "RightHip",
	RightLowerLeg = "RightKnee",
	RightFoot = "RightAnkle",
}

local sequences = {} -- [animationId] = false (กำลังโหลด/โหลดไม่ได้) | { [partName] = { {time, cframe}, ... } }
local locomotionIds = {}
local joints = {}
local actionTracks = {}
local humanoid, animator
local weight = 0

local function loadSequence(animationId)
	sequences[animationId] = false
	task.spawn(function()
		local ok, sequence = pcall(function()
			return KeyframeSequenceProvider:GetKeyframeSequenceAsync(animationId)
		end)
		if not ok or not sequence then
			-- โหลดไม่ได้: ระหว่างนี้ขาจะเป็นไปตามคลิปโจมตี แล้วลองใหม่ภายหลัง
			task.wait(3)
			sequences[animationId] = nil
			return
		end
		local keyframes = sequence:GetKeyframes()
		table.sort(keyframes, function(a, b)
			return a.Time < b.Time
		end)
		local parts = {}
		for _, keyframe in keyframes do
			for _, pose in keyframe:GetDescendants() do
				if pose:IsA("Pose") and LEG_JOINTS[pose.Name] and pose.Weight > 0 then
					local list = parts[pose.Name]
					if not list then
						list = {}
						parts[pose.Name] = list
					end
					table.insert(list, { keyframe.Time, pose.CFrame })
				end
			end
		end
		sequences[animationId] = parts
	end)
end

local function sample(list, time)
	local previous = list[1]
	for index = 2, #list do
		local key = list[index]
		if key[1] >= time then
			local span = key[1] - previous[1]
			return previous[2]:Lerp(key[2], span > 0 and (time - previous[1]) / span or 0)
		end
		previous = key
	end
	return previous[2]
end

-- tracks = รายการ AnimationTrack ท่าโจมตีที่ต้องการให้ขาเดินต่อระหว่างเล่น
function LegBlend.SetCharacter(character, tracks)
	humanoid = character:WaitForChild("Humanoid")
	animator = humanoid:WaitForChild("Animator")
	actionTracks = tracks
	weight = 0
	table.clear(joints)
	table.clear(locomotionIds)

	for partName, jointName in LEG_JOINTS do
		local part = character:WaitForChild(partName, 10)
		joints[partName] = part and part:WaitForChild(jointName, 10)
	end

	-- animation เดิน/วิ่งของตัวละคร (อาจเป็นแพ็ก animation ของ avatar ผู้เล่นเอง)
	local animate = character:WaitForChild("Animate", 10)
	if animate then
		for _, stateName in { "run", "walk" } do
			local state = animate:FindFirstChild(stateName)
			for _, animation in (state and state:GetChildren() or {}) do
				if animation:IsA("Animation") then
					locomotionIds[animation.AnimationId] = true
					if sequences[animation.AnimationId] == nil then
						loadSequence(animation.AnimationId)
					end
				end
			end
		end
	end
end

local function update(_, dt)
	if not humanoid or not humanoid.Parent then
		return
	end

	local attacking = false
	for _, track in actionTracks do
		if track.IsPlaying then
			attacking = true
			break
		end
	end
	local goal = (attacking and humanoid.MoveDirection.Magnitude > 0.1) and 1 or 0
	weight += (goal - weight) * math.min(1, dt * BLEND_SPEED)
	if weight < 0.02 then
		weight = goal == 0 and 0 or weight
		return
	end

	-- ท่าเดิน/วิ่งที่กำลังเล่นอยู่ (ถูกท่าโจมตีทับ แต่เวลาในคลิปยังเดินต่อ)
	local layers = {}
	for _, track in animator:GetPlayingAnimationTracks() do
		local animation = track.Animation
		local isLocomotion = animation and locomotionIds[animation.AnimationId]
		if isLocomotion and sequences[animation.AnimationId] == nil then
			loadSequence(animation.AnimationId) -- ลองโหลดซ้ำหลังครั้งก่อนล้มเหลว
		end
		local parts = isLocomotion and sequences[animation.AnimationId]
		if parts and track.WeightCurrent > 0.01 then
			table.insert(layers, { parts, track.TimePosition, track.WeightCurrent })
		end
	end
	if #layers == 0 then
		return
	end

	for partName, joint in joints do
		local blended
		local accumulated = 0
		for _, layer in layers do
			local list = layer[1][partName]
			if list then
				local pose = sample(list, layer[2])
				accumulated += layer[3]
				blended = blended and blended:Lerp(pose, layer[3] / accumulated) or pose
			end
		end
		if blended then
			joint.Transform = joint.Transform:Lerp(blended, weight)
		end
	end
end

-- Stepped ทำงานหลัง animation ของเฟรมนั้น
RunService.Stepped:Connect(update)

return LegBlend
