-- CameraController: มุมกล้อง third-person แบบ shift-lock ถาวร (GDD ข้อ 1)
-- ล็อกเมาส์กลางจอ, กล้องเยื้องไหล่ขวา, ตัวละครหันตามกล้อง — เล็งด้วยจุดกลางจอ
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local CameraController = {}

CameraController.FaceCamera = true -- ปิดชั่วคราวตอนกลิ้งหลบ

-- หมุนลำตัวเทียบกับทิศกล้อง (เรเดียน) — ตอนง้างธนูตัวละครยืนหันข้างให้เป้า
CameraController.YawOffset = 0
local currentYaw = 0
local currentOffset = Vector3.new(1.75, 0.5, 0)

local SHOULDER_OFFSET = Vector3.new(1.75, 0.5, 0)
local AIM_DISTANCE = 600

-- โหมดเล็ง (ตอนง้างธนู): ขยับกล้องไปทางขวา/ขึ้นบน และซูมเข้า เพื่อไม่ให้ตัวละครบังเป้า
local AIM_OFFSET = Vector3.new(2.8, 1.4, 0)
local NORMAL_FOV = 70
local AIM_FOV = 52
local AIM_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local aiming = false

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local character, humanoid, rootPart

function CameraController.SetCharacter(newCharacter)
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid")
	rootPart = newCharacter:WaitForChild("HumanoidRootPart")
	humanoid.CameraOffset = SHOULDER_OFFSET
	humanoid.AutoRotate = false
	CameraController.FaceCamera = true
	aiming = false
	camera.FieldOfView = NORMAL_FOV
end

function CameraController.SetAiming(enabled)
	if aiming == enabled then
		return
	end
	aiming = enabled
	TweenService:Create(camera, AIM_TWEEN, { FieldOfView = enabled and AIM_FOV or NORMAL_FOV }):Play()
	-- ระยะเยื้องกล้องค่อย ๆ เลื่อนใน render step (ต้องหมุนชดเชยตามลำตัวทุกเฟรม)
end

-- จุดที่กลางจอเล็งอยู่ในโลก (ไม่นับตัวผู้เล่นและลูกธนู)
function CameraController.GetAimPoint()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local arrows = workspace:FindFirstChild("ArrowVisuals")
	if arrows then
		table.insert(ignore, arrows)
	end
	params.FilterDescendantsInstances = ignore

	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector * AIM_DISTANCE
	local result = workspace:Raycast(origin, direction, params)
	return result and result.Position or (origin + direction), result ~= nil
end

function CameraController.Init()
	player.CameraMode = Enum.CameraMode.Classic
	player.CameraMaxZoomDistance = 14
	player.CameraMinZoomDistance = 8

	-- รันหลัง CameraModule ของ Roblox เพื่อให้ค่า MouseBehavior ของเรามีผล
	RunService:BindToRenderStep("MD_ShiftLock", Enum.RenderPriority.Camera.Value + 1, function(dt)
		if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			return
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		-- CameraOffset อยู่ในแกนของตัวละคร: หมุนกลับตามมุมลำตัว ให้กล้องเยื้องไปทางขวาของจอเสมอ
		currentOffset = currentOffset:Lerp(aiming and AIM_OFFSET or SHOULDER_OFFSET, math.min(1, dt * 12))
		humanoid.CameraOffset = CFrame.Angles(0, -currentYaw, 0) * currentOffset
		if CameraController.FaceCamera then
			local look = camera.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude > 0.01 then
				currentYaw += (CameraController.YawOffset - currentYaw) * math.min(1, dt * 14)
				local position = rootPart.Position
				rootPart.CFrame = CFrame.lookAt(position, position + flat) * CFrame.Angles(0, currentYaw, 0)
			end
		end
	end)
end

return CameraController
