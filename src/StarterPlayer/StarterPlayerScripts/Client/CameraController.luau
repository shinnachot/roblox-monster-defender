-- CameraController: มุมกล้อง third-person แบบ shift-lock ถาวร (GDD ข้อ 1)
-- ล็อกเมาส์กลางจอ, กล้องเยื้องไหล่ขวา, ตัวละครหันตามกล้อง — เล็งด้วยจุดกลางจอ
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CameraController = {}

CameraController.FaceCamera = true -- ปิดชั่วคราวตอนกลิ้งหลบ

local SHOULDER_OFFSET = Vector3.new(1.75, 0.5, 0)
local AIM_DISTANCE = 600

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
	return result and result.Position or (origin + direction)
end

function CameraController.Init()
	player.CameraMode = Enum.CameraMode.Classic
	player.CameraMaxZoomDistance = 14
	player.CameraMinZoomDistance = 8

	-- รันหลัง CameraModule ของ Roblox เพื่อให้ค่า MouseBehavior ของเรามีผล
	RunService:BindToRenderStep("MD_ShiftLock", Enum.RenderPriority.Camera.Value + 1, function()
		if not character or not character.Parent or not humanoid or humanoid.Health <= 0 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			return
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		if CameraController.FaceCamera then
			local look = camera.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude > 0.01 then
				local position = rootPart.Position
				rootPart.CFrame = CFrame.lookAt(position, position + flat)
			end
		end
	end)
end

return CameraController
