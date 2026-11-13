-- BowAim: ท่าง้างธนูแบบคำนวณสด (IK) + ทิศทางปล่อยลูกธนู
-- generate_animation สร้างท่าง้างที่สมจริงไม่ได้ จึงจัดท่าเองทุกเฟรม:
--   ลำตัวหันข้าง, แขนซ้ายเหยียดถือคันธนูชี้ไปตามทิศยิง, มือขวาดึงสายถอยหลังตามแรงง้าง,
--   ศีรษะมองเป้า, มีลูกธนูพาดสาย — ขายังเล่น animation เดิน/ยืนปกติ จึงไม่ไถล
-- หมายเหตุ: เห็นเฉพาะฝั่งตัวเอง — เฟส 4 (multiplayer) ต้องส่งสถานะง้างให้ client อื่นจัดท่าตาม
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local CameraController = require(script.Parent:WaitForChild("CameraController"))

local BowCfg = Config.Weapons.Bow
local Pose = BowCfg.DrawPose
local arrowTemplate = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons"):WaitForChild("Arrow")

local BowAim = {}

local camera = workspace.CurrentCamera
local BLEND = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ARROW_HALF_LENGTH = 1.95

local character, head, upperTorso, leftShoulder, gripAttachment
local controls = {}
local targets = {}
local nockedArrow
local drawStart

local function makeTarget(name)
	local attachment = Instance.new("Attachment")
	attachment.Name = "BowAim_" .. name
	attachment.Parent = workspace.Terrain
	return attachment
end

local function makeControl(humanoid, name, controlType, chainRoot, endEffector, target)
	local control = Instance.new("IKControl")
	control.Name = "BowAim_" .. name
	control.Type = controlType
	control.ChainRoot = chainRoot
	control.EndEffector = endEffector
	control.Target = target
	control.SmoothTime = 0
	control.Weight = 0
	control.Enabled = false
	control.Parent = humanoid
	return control
end

local function setControlsActive(active)
	for _, control in controls do
		if active then
			control.Enabled = true
		end
		local tween = TweenService:Create(control, BLEND, { Weight = active and 1 or 0 })
		tween:Play()
		if not active then
			tween.Completed:Once(function()
				if not drawStart then
					control.Enabled = false
				end
			end)
		end
	end
end

function BowAim.SetCharacter(newCharacter)
	BowAim.Stop()
	for _, target in targets do
		target:Destroy()
	end
	table.clear(targets)
	table.clear(controls)

	character = newCharacter
	local humanoid = newCharacter:WaitForChild("Humanoid")
	head = newCharacter:WaitForChild("Head")
	upperTorso = newCharacter:WaitForChild("UpperTorso")
	local leftUpperArm = newCharacter:WaitForChild("LeftUpperArm")
	local leftHand = newCharacter:WaitForChild("LeftHand")
	local rightUpperArm = newCharacter:WaitForChild("RightUpperArm")
	local rightHand = newCharacter:WaitForChild("RightHand")
	leftShoulder = leftUpperArm:WaitForChild("LeftShoulder")
	gripAttachment = leftHand:WaitForChild("LeftGripAttachment")

	targets.Left = makeTarget("Left")
	targets.Right = makeTarget("Right")
	targets.Head = makeTarget("Head")
	controls.Left = makeControl(humanoid, "Left", Enum.IKControlType.Transform, leftUpperArm, leftHand, targets.Left)
	controls.Right = makeControl(humanoid, "Right", Enum.IKControlType.Position, rightUpperArm, rightHand, targets.Right)
	controls.Head = makeControl(humanoid, "Head", Enum.IKControlType.LookAt, head, head, targets.Head)
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

local function update()
	if not drawStart or not character or not character.Parent then
		return
	end
	local charge = chargeNow()
	local aim = BowAim.GetLaunchDirection(charge)

	local right = aim:Cross(Vector3.yAxis)
	right = right.Magnitude > 0.01 and right.Unit or camera.CFrame.RightVector
	local up = right:Cross(aim)

	-- เส้นลูกธนู: ผ่านเหนือไหล่ซ้ายเล็กน้อย (ระดับคาง) ชี้ไปตามทิศยิง
	local shoulder = upperTorso.CFrame:PointToWorldSpace(leftShoulder.C0.Position)
	local bowPosition = shoulder + Vector3.yAxis * Pose.Raise + aim * Pose.ArmReach
	local bowCFrame = CFrame.fromMatrix(bowPosition, right, up, -aim) -- คันธนูตั้งตรง หันหน้าไปทางเป้า
	targets.Left.WorldCFrame = bowCFrame * gripAttachment.CFrame:Inverse()

	-- มือขวาดึงสายถอยหลังตามแรงง้าง
	local handPosition = bowPosition - aim * (Pose.StringRest + Pose.DrawLength * charge)
	targets.Right.WorldPosition = handPosition
	targets.Head.WorldPosition = head.Position + aim * 60

	if nockedArrow then
		local center = handPosition + aim * ARROW_HALF_LENGTH
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
	nockedArrow.Parent = workspace:FindFirstChild("ArrowVisuals") or workspace
	update()
	setControlsActive(true)
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
	setControlsActive(false)
end

-- หลังกล้องและการหมุนตัวละคร (CameraController ใช้ Camera + 1)
RunService:BindToRenderStep("MD_BowAim", Enum.RenderPriority.Camera.Value + 2, update)

return BowAim
