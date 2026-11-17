-- SlashPose: ท่าฟันอาวุธระยะประชิดแบบจัดท่าด้วยโค้ด (ไม่ใช้คลิป animation)
-- แต่ละท่า (ใน Config.SlashPoses) คือ keyframe 3 จุด: ท่าเตรียม -> กลางวง -> จบวง
--   Arm   = ทิศแขนขวาจากไหล่ (ในพื้นที่ตัวละคร: ขวา, ขึ้น, หน้า)
--   Blade = ทิศใบดาบ (มือหมุนให้ใบดาบชี้ตามนี้พอดี)
--   Yaw   = บิดลำตัวที่เอว (องศา, บวก = บิดไปทางซ้าย)
-- จังหวะ: เงื้อ (Windup) เข้าท่าเตรียม -> ฟาด (Strike) ผ่านกลางวงไปจบวง -> ค้างสั้น ๆ แล้วคืนท่าปกติ (Recover)
-- ทับเฉพาะแขนขวาและเอว ขายังเดินตาม animation ปกติ
-- ทุก client จัดท่าให้ผู้เล่นทุกคน (ของคนอื่นเริ่มเมื่อ server แจ้ง attribute MeleeSwing)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local SlashPose = {}

local JOINTS = {
	RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm",
	RightWrist = "RightHand",
	Waist = "UpperTorso",
}

local rigs = {} -- [character] = state

local function getRig(char)
	local rig = rigs[char]
	if rig then
		return rig
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local lowerTorso = char:FindFirstChild("LowerTorso")
	if not root or not lowerTorso then
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
	rig = {
		Root = root,
		LowerTorso = lowerTorso,
		Joints = joints,
		Weight = 0,
		Pose = nil, -- ท่าปัจจุบัน { Arm, Blade, Yaw }
		Move = nil, -- ท่าฟันที่กำลังเล่น
	}
	rigs[char] = rig
	char.Destroying:Once(function()
		rigs[char] = nil
	end)
	return rig
end

-- ทิศในพื้นที่ตัวละคร (ขวา, ขึ้น, หน้า) -> Vector3 (หน้า = -Z)
local function dir(v)
	return Vector3.new(v[1], v[2], -v[3]).Unit
end

local function lerpDir(a, b, t)
	local v = a:Lerp(b, t)
	return v.Magnitude > 1e-3 and v.Unit or b
end

local function lerpPose(a, b, t)
	return {
		Arm = lerpDir(a.Arm, b.Arm, t),
		Blade = lerpDir(a.Blade, b.Blade, t),
		Yaw = a.Yaw + (b.Yaw - a.Yaw) * t,
	}
end

local function keyPose(key)
	return { Arm = dir(key.Arm), Blade = dir(key.Blade), Yaw = key.Yaw or 0 }
end

local function easeOut(t)
	return 1 - (1 - t) * (1 - t)
end

local function easeInOut(t)
	return t * t * (3 - 2 * t)
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

-- มือ: ใบดาบอยู่ตามแกน -Z ของมือ -> หันแกน -Z ไปตาม blade พอดี แล้วให้แกน -Y (ทิศนิ้ว) ใกล้ทิศแขนที่สุด
local function handRotation(arm, blade)
	local zAxis = -blade
	local yAxis = -arm
	yAxis -= yAxis:Dot(zAxis) * zAxis
	if yAxis.Magnitude < 1e-3 then
		yAxis = Vector3.yAxis - Vector3.yAxis:Dot(zAxis) * zAxis
	end
	yAxis = yAxis.Unit
	return CFrame.fromMatrix(Vector3.zero, yAxis:Cross(zAxis), yAxis, zAxis)
end

local function applyJoint(rig, jointName, parentRotation, desiredRotation)
	local joint = rig.Joints[jointName]
	local target = joint.C0.Rotation:Inverse() * parentRotation:Inverse() * desiredRotation * joint.C1.Rotation
	joint.Transform = joint.Transform:Lerp(target, rig.Weight)
end

local function applyPose(rig, pose)
	local look = rig.Root.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude < 0.01 then
		return
	end
	local rootRot = CFrame.lookAt(Vector3.zero, look.Unit)

	-- เอว: บิดลำตัว แล้วคำนวณการหมุนของลำตัวบนจากผลนั้น (ไม่รอเฟรมถัดไป)
	local waist = rig.Joints.Waist
	waist.Transform = waist.Transform:Lerp(CFrame.Angles(0, math.rad(pose.Yaw), 0), rig.Weight)
	local torso = rig.LowerTorso.CFrame.Rotation * waist.C0.Rotation * waist.Transform.Rotation * waist.C1.Rotation:Inverse()

	local arm = rootRot * pose.Arm
	local blade = rootRot * pose.Blade
	local armRot = limbRotation(arm, blade)
	local handRot = handRotation(arm, blade)
	applyJoint(rig, "RightShoulder", torso, armRot)
	applyJoint(rig, "RightElbow", armRot, armRot)
	applyJoint(rig, "RightWrist", armRot, handRot)
end

-- เริ่มท่าฟันหนึ่งจังหวะบนตัวละคร char (seg = ท่าใน Combo ที่มี Pose)
function SlashPose.Play(char, seg)
	local rig = char and getRig(char)
	local def = seg and seg.Pose and Config.SlashPoses[seg.Pose]
	if not rig or not def then
		return
	end
	local keys = {}
	for i, key in def do
		keys[i] = keyPose(key)
	end
	rig.Move = {
		Seg = seg,
		Keys = keys,
		Elapsed = 0,
		FromPose = rig.Pose or keys[1], -- ต่อจากท่าก่อนหน้าแบบลื่น ๆ
		FromWeight = rig.Weight,
	}
end

local function update(rig, dt)
	local move = rig.Move
	if not move then
		return
	end
	move.Elapsed += dt
	local seg, keys, t = move.Seg, move.Keys, move.Elapsed
	local pose
	if t < seg.Windup then
		-- เงื้อ: จากท่าเดิมเข้าท่าเตรียม
		local p = easeOut(t / seg.Windup)
		pose = lerpPose(move.FromPose, keys[1], p)
		rig.Weight = move.FromWeight + (1 - move.FromWeight) * p
	elseif t < seg.Windup + seg.Strike then
		-- ฟาด: ท่าเตรียม -> กลางวง -> จบวง
		local p = easeInOut((t - seg.Windup) / seg.Strike) * 2
		pose = p < 1 and lerpPose(keys[1], keys[2], p) or lerpPose(keys[2], keys[3], p - 1)
		rig.Weight = 1
	else
		-- ดึงกลับ: ค้างท่าจบวงสั้น ๆ แล้วค่อยคืนท่าปกติ
		local r = (t - seg.Windup - seg.Strike) / seg.Recover
		pose = keys[3]
		rig.Weight = r < 0.35 and 1 or math.max(0, 1 - (r - 0.35) / 0.65)
		if r >= 1 then
			rig.Move = nil
			rig.Pose = nil
			rig.Weight = 0
			return
		end
	end
	rig.Pose = pose
	applyPose(rig, pose)
end

-- Stepped ทำงานหลัง animation ของเฟรมนั้น จึงเขียนทับ Transform ได้
RunService.Stepped:Connect(function(_, dt)
	for char, rig in rigs do
		if char.Parent and rig.Move then
			update(rig, dt)
		end
	end
end)

-- หยุดท่า (เช่นกลิ้งหลบ / ล้ม) — ให้ animation ปกติกลับมาคุมทันที
function SlashPose.Stop(char)
	local rig = char and rigs[char]
	if rig then
		rig.Move = nil
		rig.Pose = nil
		rig.Weight = 0
	end
end

return SlashPose
