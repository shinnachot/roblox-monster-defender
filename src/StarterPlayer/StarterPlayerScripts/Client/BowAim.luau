-- BowAim: ท่าง้างธนู + ทิศทางปล่อยลูกธนู
-- ท่าง้างตั้งมุมข้อต่อแขน/คอโดยตรงทุกเฟรม (ทับ animation เฉพาะช่วงบน ขายังเดินปกติ):
--   ลำตัวหันข้าง, แขนซ้ายเหยียดตรงถือคันธนูชี้ไปตามทิศยิง, แขนขวางอศอกถอยหลังตามแรงง้าง,
--   ศีรษะหันไปทางเป้า, มีลูกธนูพาดสาย
-- เป็นท่าโดยประมาณ (มือขวาไม่ได้จับหางลูกธนูเป๊ะ) — ไม่ใช้ IK เพราะ IK ทำให้มือหมุนมั่วตอนเดิน
-- ผู้เล่นคนอื่น: server ตั้ง attribute BowDraw (เวลาเริ่มง้าง) + BowPitch (มุมเงย) ให้ทุก client จัดท่าตาม
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))

local BowCfg = Config.Weapons.Bow
local Pose = BowCfg.DrawPose
local arrowTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons"):WaitForChild("Arrow")

local BowAim = {}

local camera = workspace.CurrentCamera
local localPlayer = Players.LocalPlayer
local BLEND_SPEED = 12
local ARROW_HALF_LENGTH = 1.95
local PITCH_SEND_INTERVAL = 0.1

local JOINTS = {
	LeftShoulder = "LeftUpperArm",
	LeftElbow = "LeftLowerArm",
	LeftWrist = "LeftHand",
	RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm",
	RightWrist = "RightHand",
	Neck = "Head",
}

local character, head -- ตัวละครของเราเอง
local drawStart
local rigs = {} -- [character] = { Weight, Joints, UpperTorso, LeftHand, Root, Arrow }
local lastPitchSent, nextPitchSendAt = nil, 0

local pitchRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("BowAimPitch", 10)

local function getRig(char)
	local rig = rigs[char]
	if rig then
		return rig
	end
	local upperTorso = char:FindFirstChild("UpperTorso")
	local leftHand = char:FindFirstChild("LeftHand")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not upperTorso or not leftHand or not root then
		return nil
	end
	local joints = {}
	for jointName, partName in JOINTS do
		local part = char:FindFirstChild(partName)
		joints[jointName] = part and part:FindFirstChild(jointName)
	end
	rig = { Weight = 0, Joints = joints, UpperTorso = upperTorso, LeftHand = leftHand, Root = root }
	rigs[char] = rig
	char.Destroying:Connect(function()
		if rig.Arrow then
			rig.Arrow:Destroy()
		end
		rigs[char] = nil
	end)
	return rig
end

local function setArrow(rig, show)
	if show and not rig.Arrow then
		local arrow = arrowTemplate:Clone()
		arrow.PrimaryPart.Anchored = true
		for _, part in arrow:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide, part.CanQuery, part.CanTouch = false, false, false
			end
		end
		arrow:PivotTo(CFrame.new(0, -500, 0)) -- ซ่อนไว้จนกว่าเฟรมแรกจะจัดตำแหน่ง
		arrow.Parent = workspace:FindFirstChild("ArrowVisuals") or workspace
		rig.Arrow = arrow
	elseif not show and rig.Arrow then
		rig.Arrow:Destroy()
		rig.Arrow = nil
	end
end

function BowAim.SetCharacter(newCharacter)
	BowAim.Stop()
	character = newCharacter
	head = newCharacter:WaitForChild("Head")
	newCharacter:WaitForChild("UpperTorso")
	newCharacter:WaitForChild("LeftHand")
	newCharacter:WaitForChild("HumanoidRootPart")
	for _, partName in JOINTS do
		newCharacter:WaitForChild(partName, 10)
	end
	rigs[newCharacter] = nil
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
local function pose(rig, jointName, parentRotation, desiredRotation)
	local joint = rig.Joints[jointName]
	if not joint then
		return
	end
	local target = joint.C0.Rotation:Inverse() * parentRotation:Inverse() * desiredRotation * joint.C1.Rotation
	joint.Transform = joint.Transform:Lerp(target, rig.Weight)
end

local function poseRig(rig, aim, charge)
	local right = aim:Cross(Vector3.yAxis)
	right = right.Magnitude > 0.01 and right.Unit or rig.Root.CFrame.RightVector
	local up = right:Cross(aim)
	local torso = rig.UpperTorso.CFrame.Rotation

	-- แขนซ้าย: เหยียดตรงตามทิศยิง คันธนูตั้งตรง
	local bowArm = limbRotation(aim, up)
	pose(rig, "LeftShoulder", torso, bowArm)
	pose(rig, "LeftElbow", bowArm, bowArm)
	pose(rig, "LeftWrist", bowArm, bowArm)

	-- แขนขวา: เริ่มจากยื่นไปข้างหน้า แล้วงอศอกถอยหลังจนมือมาอยู่แถวคางเมื่อง้างสุด
	local upperStart = aim * 0.55 + right * 0.6 - up * 0.2
	local upperEnd = -aim * 0.25 + right * 0.7 + up * 0.35
	local foreStart = aim * 0.95 + up * 0.1
	local foreEnd = aim * 0.95 - right * 0.55 + up * 0.2
	local upperArm = limbRotation(upperStart:Lerp(upperEnd, charge).Unit, up)
	local foreArm = limbRotation(foreStart:Lerp(foreEnd, charge).Unit, up)
	pose(rig, "RightShoulder", torso, upperArm)
	pose(rig, "RightElbow", upperArm, foreArm)
	pose(rig, "RightWrist", foreArm, foreArm)

	-- ศีรษะหันไปทางเป้า (ลำตัวหันข้างอยู่)
	pose(rig, "Neck", torso, CFrame.lookAt(Vector3.zero, aim))

	-- ลูกธนูพาดสาย: หางลูกธนูถอยจากคันธนูตามแรงง้าง
	if rig.Arrow then
		local tail = rig.LeftHand.Position - aim * (Pose.StringRest + Pose.DrawLength * charge)
		local center = tail + aim * ARROW_HALF_LENGTH
		rig.Arrow:PivotTo(CFrame.lookAt(center, center + aim, up))
	end
end

-- ทิศเล็งของผู้เล่นคนอื่น: ลำตัวหันข้าง BodyYaw องศาจากทิศเป้า + มุมเงยที่ server ส่งมา
local function remoteAim(rig, pitch)
	local look = (rig.Root.CFrame * CFrame.Angles(0, math.rad(Pose.BodyYaw), 0)).LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.zAxis
	return (flat * math.cos(pitch) + Vector3.yAxis * math.sin(pitch)).Unit
end

local function updateRig(char, drawing, dt, aim, charge)
	local rig = (drawing or rigs[char]) and getRig(char)
	if not rig then
		return
	end
	local goal = drawing and 1 or 0
	rig.Weight += (goal - rig.Weight) * math.min(1, dt * BLEND_SPEED)
	setArrow(rig, drawing)
	if goal == 0 and rig.Weight < 0.02 then
		rigs[char] = nil
		return
	end
	poseRig(rig, aim(rig), charge)
end

-- มุมเงยของเราส่งให้ server (เฉพาะตอนง้าง ไม่เกิน 10 ครั้ง/วินาที และเฉพาะตอนมุมเปลี่ยน)
local function sendPitch(aim)
	local now = os.clock()
	if not pitchRemote or now < nextPitchSendAt then
		return
	end
	local pitch = math.floor(math.asin(math.clamp(aim.Y, -1, 1)) * 20 + 0.5) / 20
	if pitch ~= lastPitchSent then
		lastPitchSent = pitch
		nextPitchSendAt = now + PITCH_SEND_INTERVAL
		pitchRemote:FireServer(pitch)
	end
end

local function update(_, dt)
	if character and character.Parent then
		local charge = chargeNow()
		updateRig(character, drawStart ~= nil, dt, function()
			local aim = BowAim.GetLaunchDirection(charge)
			sendPitch(aim)
			return aim
		end, charge)
	end
	local serverNow = workspace:GetServerTimeNow()
	for _, other in Players:GetPlayers() do
		local char = other.Character
		if other ~= localPlayer and char and char.Parent then
			local started = other:GetAttribute("BowDraw")
			local charge = started and math.clamp((serverNow - started) / BowCfg.ChargeTime, 0, 1) or 0
			local pitch = other:GetAttribute("BowPitch") or 0
			updateRig(char, started ~= nil, dt, function(rig)
				return remoteAim(rig, pitch)
			end, charge)
		end
	end
end

function BowAim.Start(startTime)
	if not character or drawStart then
		return
	end
	drawStart = startTime
	lastPitchSent = nil
	CameraController.YawOffset = -math.rad(Pose.BodyYaw)
end

function BowAim.Stop()
	if not drawStart then
		return
	end
	drawStart = nil
	CameraController.YawOffset = 0
end

-- Stepped ทำงานหลัง animation ของเฟรมนั้น จึงเขียนทับ Transform ของแขนได้
RunService.Stepped:Connect(update)

return BowAim
