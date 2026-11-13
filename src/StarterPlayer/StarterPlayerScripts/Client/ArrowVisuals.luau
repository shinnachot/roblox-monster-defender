-- ArrowVisuals: ลูกธนูที่มองเห็น (เฉพาะภาพ) — วิถีเดียวกับที่ server จำลอง แต่ดาเมจคิดที่ server เท่านั้น
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local template = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Weapons"):WaitForChild("Arrow")

local ArrowVisuals = {}

local MAX_FLIGHT_TIME = 6
local STICK_TIME = 4 -- ปักคาไว้ให้เห็นว่าโดนตรงไหน / พลาดไปตกตรงไหน
local VISUAL_SCALE = 1.3 -- ขยายเล็กน้อยให้มองเห็นตอนบิน
local HALF_LENGTH = 1.95 * VISUAL_SCALE

-- หางแสงตามลูกธนู: ลูกธนูบางและเร็วมาก ถ้าไม่มีหางจะมองไม่เห็นวิถี
local function addTrail(root)
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, 0.16, HALF_LENGTH * 0.6)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -0.16, HALF_LENGTH * 0.6)
	bottom.Parent = root
	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Lifetime = 0.35
	trail.MinLength = 0.05
	trail.FaceCamera = true
	trail.LightEmission = 0.7
	trail.LightInfluence = 0
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 250, 225), Color3.fromRGB(255, 215, 130))
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.2) })
	trail.Parent = root
	return trail
end

local folder = Instance.new("Folder")
folder.Name = "ArrowVisuals"
folder.Parent = workspace

local flying = {}

function ArrowVisuals.Spawn(origin, velocity, gravity)
	local model = template:Clone()
	model:ScaleTo(VISUAL_SCALE)
	model.PrimaryPart.Anchored = true
	local trail = addTrail(model.PrimaryPart)
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
		Trail = trail,
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
			if result then
				-- ปักคาจุดที่โดน (หัวลูกธนูฝังเข้าไปเล็กน้อย)
				local direction = arrow.Velocity.Unit
				arrow.Model:PivotTo(CFrame.lookAt(result.Position - direction * (HALF_LENGTH - 0.5), result.Position))
				arrow.Trail.Enabled = false
				local hitPart = result.Instance
				if not hitPart.Anchored then
					-- โดน monster: ให้ลูกธนูติดไปกับส่วนที่โดน
					local root = arrow.Model.PrimaryPart
					local weld = Instance.new("WeldConstraint")
					weld.Part0 = hitPart
					weld.Part1 = root
					weld.Parent = root
					root.Anchored = false
				end
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
