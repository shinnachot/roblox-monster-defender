-- BowAim: ท่าง้างธนู + ทิศทางปล่อยลูกธนู
-- ท่าง้างตั้งมุมข้อต่อแขน/คอโดยตรงทุกเฟรม (ทับ animation เฉพาะช่วงบน ขายังเดินปกติ):
--   ลำตัวหันข้าง, แขนซ้ายเหยียดตรงถือคันธนูชี้ไปตามทิศยิง, แขนขวางอศอกถอยหลังตามแรงง้าง,
--   ศีรษะหันไปทางเป้า, มีลูกธนูพาดสาย
-- เป็นท่าโดยประมาณ (มือขวาไม่ได้จับหางลูกธนูเป๊ะ) — ไม่ใช้ IK เพราะ IK ทำให้มือหมุนมั่วตอนเดิน
-- หมายเหตุ: เห็นเฉพาะฝั่งตัวเอง — เฟส 4 (multiplayer) ต้องส่งสถานะง้างให้ client อื่นจัดท่าตาม
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))

local BowCfg = Config.Weapons.Bow
local Pose = BowCfg.DrawPose
local arrowTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons"):WaitForChild("Arrow")

local BowAim = {}

local camera = workspace.CurrentCamera
local BLEND_SPEED = 12
local ARROW_HALF_LENGTH = 1.95

local character, head, upperTorso, leftHand
local joints = {}
local nockedArrow
local drawStart
local weight = 0 -- 0 = animation ปกติ, 1 = ท่าง้างเต็ม

local JOINTS = {
	LeftShoulder = "LeftUpperArm",
	LeftElbow = "LeftLowerArm",
	LeftWrist = "LeftHand",
	RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm",
	RightWrist = "RightHand",
	Neck = "Head",
}

function BowAim.SetCharacter(newCharacter)
	BowAim.Stop()
	weight = 0
	table.clear(joints)
	character = newCharacter
	head = newCharacter:WaitForChild("Head")
	upperTorso = newCharacter:WaitForChild("UpperTorso")
	leftHand = newCharacter:WaitForChild("LeftHand")
	for jointName, partName in JOINTS do
		local part = newCharacter:WaitForChild(partName, 10)
		joints[jointName] = part and part:WaitForChild(jointName, 10)
	end
end

local function chargeNow()
	return drawStart and math.clamp((os.clock() - drawStart) / BowCfg.ChargeTime, 0, 1) or 0
end

-- ทิศปล่อยลูกธนู: ยกมุมชดเชยแรงโน้มถ่วงให้ลูกธนูไปตกที่จุดเล็งกลางจอ
-- ถ้าเป้าไกลเกินแรงง้าง จะยิงโค้ง 45 องศา (ไกลสุดเท่าที่แรงนั้นไปถึง)
function BowAim.GetLaunchDirection(charge)
	local look = camera.CFrame.LookVector
	if not head then
		return look
	end
	local aimPoint, didHit = CameraController.GetAimPoint()
	local offset = aimPoint - head.Position
	if offset.Magnitude < 6 then
		return look
	end
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local distance = flat.Magnitude
	if not didHit or distance < 1 then
		return offset.Unit
	end
	local speed = BowCfg.MinSpeed + (BowCfg.MaxSpeed - BowCfg.MinSpeed) * charge
	local gravity = BowCfg.Gravity
	local v2 = speed * speed
	local discriminant = v2 * v2 - gravity * (gravity * distance * distance + 2 * offset.Y * v2)
	if discriminant < 0 then
		return (flat.Unit + Vector3.yAxis).Unit
	end
	local tangent = (v2 - math.sqrt(discriminant)) / (gravity * distance)
	return (flat.Unit + Vector3.yAxis * tangent).Unit
end

-- การหมุนของชิ้นส่วนแขน ที่ทำให้ปลายแขน (แกน -Y ของชิ้นส่วน) ชี้ไปทาง direction
-- และแกน -Z (ด้านหน้าของมือ = แนวคันธนู) ชี้ใกล้ front ที่สุด
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

-- ตั้ง Transform ของข้อต่อให้ชิ้นส่วนลูกหันตาม desired (world) โดยรู้การหมุนของชิ้นส่วนแม่
local function pose(jointName, parentRotation, desiredRotation)
	local joint = joints[jointName]
	if not joint then
		return
	end
	local target = joint.C0.Rotation:Inverse() * parentRotation:Inverse() * desiredRotation * joint.C1.Rotation
	joint.Transform = joint.Transform:Lerp(target, weight)
end

local function update(_, dt)
	local goal = drawStart and 1 or 0
	weight += (goal - weight) * math.min(1, dt * BLEND_SPEED)
	if goal == 0 and weight < 0.02 then
		weight = 0
		return
	end
	if not character or not character.Parent then
		return
	end

	local charge = chargeNow()
	local aim = BowAim.GetLaunchDirection(charge)
	local right = aim:Cross(Vector3.yAxis)
	right = right.Magnitude > 0.01 and right.Unit or camera.CFrame.RightVector
	local up = right:Cross(aim)
	local torso = upperTorso.CFrame.Rotation

	-- แขนซ้าย: เหยียดตรงตามทิศยิง คันธนูตั้งตรง
	local bowArm = limbRotation(aim, up)
	pose("LeftShoulder", torso, bowArm)
	pose("LeftElbow", bowArm, bowArm)
	pose("LeftWrist", bowArm, bowArm)

	-- แขนขวา: เริ่มจากยื่นไปข้างหน้า แล้วงอศอกถอยหลังจนมือมาอยู่แถวคางเมื่อง้างสุด
	local upperStart = aim * 0.55 + right * 0.6 - up * 0.2
	local upperEnd = -aim * 0.25 + right * 0.7 + up * 0.35
	local foreStart = aim * 0.95 + up * 0.1
	local foreEnd = aim * 0.95 - right * 0.55 + up * 0.2
	local upperArm = limbRotation(upperStart:Lerp(upperEnd, charge).Unit, up)
	local foreArm = limbRotation(foreStart:Lerp(foreEnd, charge).Unit, up)
	pose("RightShoulder", torso, upperArm)
	pose("RightElbow", upperArm, foreArm)
	pose("RightWrist", foreArm, foreArm)

	-- ศีรษะหันไปทางเป้า (ลำตัวหันข้างอยู่)
	pose("Neck", torso, CFrame.lookAt(Vector3.zero, aim))

	-- ลูกธนูพาดสาย: หางลูกธนูถอยจากคันธนูตามแรงง้าง
	if nockedArrow then
		local tail = leftHand.Position - aim * (Pose.StringRest + Pose.DrawLength * charge)
		local center = tail + aim * ARROW_HALF_LENGTH
		nockedArrow:PivotTo(CFrame.lookAt(center, center + aim, up))
	end
end

function BowAim.Start(startTime)
	if not character or drawStart then
		return
	end
	drawStart = startTime
	CameraController.YawOffset = -math.rad(Pose.BodyYaw)

	nockedArrow = arrowTemplate:Clone()
	nockedArrow.PrimaryPart.Anchored = true
	nockedArrow:PivotTo(CFrame.new(0, -500, 0)) -- ซ่อนไว้จนกว่าเฟรมแรกจะจัดตำแหน่ง
	nockedArrow.Parent = workspace:FindFirstChild("ArrowVisuals") or workspace
end

function BowAim.Stop()
	if not drawStart then
		return
	end
	drawStart = nil
	CameraController.YawOffset = 0
	if nockedArrow then
		nockedArrow:Destroy()
		nockedArrow = nil
	end
end

-- Stepped ทำงานหลัง animation ของเฟรมนั้น จึงเขียนทับ Transform ของแขนได้
RunService.Stepped:Connect(update)

return BowAim
