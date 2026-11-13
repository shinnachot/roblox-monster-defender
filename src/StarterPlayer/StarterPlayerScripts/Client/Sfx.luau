-- Sfx: เล่นเสียงจาก ReplicatedStorage.Assets.Sounds
-- ไม่ใส่ position = เสียง 2D (ของตัวเอง), ใส่ position = เสียง 3D ในโลก
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local sounds = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Sounds")

local Sfx = {}

function Sfx.Play(name, position)
	local template = sounds:FindFirstChild(name)
	if not template then
		return
	end
	local sound = template:Clone()
	local holder = sound
	if position then
		holder = Instance.new("Attachment")
		holder.Parent = workspace.Terrain
		holder.WorldPosition = position
		sound.Parent = holder
	else
		sound.Parent = SoundService
	end
	sound:Play()
	Debris:AddItem(holder, math.max(sound.TimeLength, 2) + 1)
end

return Sfx
