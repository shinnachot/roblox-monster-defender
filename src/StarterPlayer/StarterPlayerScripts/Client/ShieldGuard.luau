-- ShieldGuard: ท่ายกโล่ (ถือดาบอยู่ + กดค้างคลิกขวา)
-- ตั้งมุมข้อต่อแขนซ้ายโดยตรงทุกเฟรมแบบเดียวกับ BowAim (ทับ animation เฉพาะแขนซ้าย ขายังเดินปกติ):
--   ต้นแขนยื่นไปข้างหน้าเฉียงลง, ท่อนแขนล่างพาดขวางหน้าอก หน้าโล่ (ติดด้านนอกท่อนแขน) หันไปข้างหน้า
-- จัดท่าให้ผู้เล่นทุกคนที่มี attribute Blocking (server ตั้ง) — ตัวเองใช้สถานะในเครื่องเพื่อให้ตอบสนองทันที
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ShieldGuard = {}

local BLEND_SPEED = 14
local JOINTS = {
	LeftShoulder = "LeftUpperArm",
	LeftElbow = "LeftLowerArm",
	LeftWrist = "LeftHand",
}

local localPlayer = Players.LocalPlayer
local localBlocking = false
local rigs = {} -- [character] = { Weight, Joints, Torso, Root }

function ShieldGuard.SetLocalBlocking(blocking)
	localBlocking = blocking
end

local function getRig(char)
	local rig = rigs[char]
	if rig then
		return rig
	end
	local torso = char:FindFirstChild("UpperTorso")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not torso or not root then
		return nil
	end
	local joints = {}
	for jointName, partName in JOINTS do
		local part = char:FindFirstChild(partName)
		local joint = part and part:FindFirstChild(jointName)
		if not joint then
			return nil
		end
		joints[jointName] = joint
	end
	rig = { Weight = 0, Joints = joints, Torso = torso, Root = root }
	rigs[char] = rig
	char.Destroying:Once(function()
		rigs[char] = nil
	end)
	return rig
end

-- การหมุนของชิ้นส่วนแขนที่ทำให้แกน -Y ชี้ตาม direction และแกน -Z ชี้ใกล้ front ที่สุด
local function limbRotation(direction, front)
	local yAxis = -direction
	local zAxis = -front
	zAxis -= zAxis:Dot(yAxis) * yAxis
	if zAxis.Magnitude < 1e-3 then
		zAxis = Vector3.xAxis - Vector3.xAxis:Dot(yAxis) * yAxis
	end
	zAxis = zAxis.Unit
	return CFrame.fromMatrix(Vector3.zero, yAxis:Cross(zAxis), yAxis, zAxis)
end

local function pose(rig, jointName, parentRotation, desiredRotation)
	local joint = rig.Joints[jointName]
	local target = joint.C0.Rotation:Inverse() * parentRotation:Inverse() * desiredRotation * joint.C1.Rotation
	joint.Transform = joint.Transform:Lerp(target, rig.Weight)
end

local function updateRig(rig, blocking, dt)
	local goal = blocking and 1 or 0
	rig.Weight += (goal - rig.Weight) * math.min(1, dt * BLEND_SPEED)
	if goal == 0 and rig.Weight < 0.02 then
		rig.Weight = 0
		return
	end
	local look = rig.Root.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < 0.01 then
		return
	end
	look = look.Unit
	local up = Vector3.yAxis
	local right = look:Cross(up)
	local torso = rig.Torso.CFrame.Rotation

	-- ต้นแขน: ยื่นไปข้างหน้าเฉียงลง ศอกอยู่หน้าอกซ้าย
	local upperArm = limbRotation((look * 0.75 - up * 0.55 + right * 0.15).Unit, up)
	-- ท่อนแขนล่าง: พาดขวางหน้าอกไปทางขวา ด้านนอกแขน (หน้าโล่) หันไปข้างหน้า
	local foreArm = limbRotation((right * 0.85 + look * 0.25 + up * 0.25).Unit, up)
	pose(rig, "LeftShoulder", torso, upperArm)
	pose(rig, "LeftElbow", upperArm, foreArm)
	pose(rig, "LeftWrist", foreArm, foreArm)
end

-- Stepped ทำงานหลัง animation ของเฟรมนั้น จึงเขียนทับ Transform ของแขนได้
RunService.Stepped:Connect(function(_, dt)
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and char.Parent then
			local blocking
			if player == localPlayer then
				blocking = localBlocking
			else
				blocking = player:GetAttribute("Blocking") == true
			end
			local rig = rigs[char]
			if blocking or (rig and rig.Weight > 0) then
				rig = rig or getRig(char)
				if rig then
					updateRig(rig, blocking, dt)
				end
			end
		end
	end
end)

return ShieldGuard
