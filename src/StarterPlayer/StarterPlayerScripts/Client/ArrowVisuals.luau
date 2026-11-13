-- ArrowVisuals: ลูกธนูที่มองเห็น (เฉพาะภาพ) — วิถีเดียวกับที่ server จำลอง แต่ดาเมจคิดที่ server เท่านั้น
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local template = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons"):WaitForChild("Arrow")

local ArrowVisuals = {}

local MAX_FLIGHT_TIME = 4
local STICK_TIME = 2

local folder = Instance.new("Folder")
folder.Name = "ArrowVisuals"
folder.Parent = workspace

local flying = {}

function ArrowVisuals.Spawn(origin, velocity, gravity)
	local model = template:Clone()
	model.PrimaryPart.Anchored = true
	model:PivotTo(CFrame.lookAt(origin, origin + velocity))
	model.Parent = folder

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { folder }
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	params.FilterDescendantsInstances = ignore

	table.insert(flying, {
		Model = model,
		Position = origin,
		Velocity = velocity,
		Gravity = Vector3.new(0, -gravity, 0),
		Elapsed = 0,
		Params = params,
	})
end

RunService.RenderStepped:Connect(function(dt)
	for index = #flying, 1, -1 do
		local arrow = flying[index]
		arrow.Elapsed += dt
		local step = arrow.Velocity * dt + 0.5 * arrow.Gravity * dt * dt
		local result = workspace:Raycast(arrow.Position, step, arrow.Params)
		if result or arrow.Elapsed > MAX_FLIGHT_TIME then
			table.remove(flying, index)
			local hitCharacter = result and result.Instance:FindFirstAncestorWhichIsA("Model")
			if result and not (hitCharacter and hitCharacter:FindFirstChildOfClass("Humanoid")) then
				-- ปักคาฉากสักครู่
				arrow.Model:PivotTo(CFrame.lookAt(result.Position - arrow.Velocity.Unit * 1.2, result.Position))
				Debris:AddItem(arrow.Model, STICK_TIME)
			else
				arrow.Model:Destroy()
			end
		else
			arrow.Position += step
			arrow.Velocity += arrow.Gravity * dt
			arrow.Model:PivotTo(CFrame.lookAt(arrow.Position, arrow.Position + arrow.Velocity))
		end
	end
end)

return ArrowVisuals
