-- DamageNumbers: ตัวเลข damage ลอยขึ้นจาก monster แล้วจางหายใน ~0.8 วิ (GDD ข้อ 9)
-- เห็นเฉพาะตัวเลขของตัวเอง (server ส่งให้เฉพาะคนที่ทำดาเมจ)
-- แดง = ปกติ, เหลืองตัวใหญ่ x1.5 + เด้ง = โดนหัว
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local DamageNumbers = {}

local LIFETIME = 0.8
local BASE_TEXT_SIZE = 30
local NORMAL_COLOR = Color3.fromRGB(235, 60, 50)
local HEAD_COLOR = Color3.fromRGB(255, 220, 40)

local rng = Random.new()

function DamageNumbers.Show(position, amount, isHead)
	local anchor = Instance.new("Attachment")
	anchor.Parent = workspace.Terrain
	anchor.WorldPosition = position + Vector3.new(rng:NextNumber(-0.8, 0.8), 0, rng:NextNumber(-0.8, 0.8))

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 70)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 300
	gui.Adornee = anchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.Text = tostring(math.round(amount))
	label.TextColor3 = isHead and HEAD_COLOR or NORMAL_COLOR
	label.TextSize = isHead and BASE_TEXT_SIZE * 1.5 or BASE_TEXT_SIZE
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = label

	gui.Parent = anchor

	if isHead then
		scale.Scale = 1.9
		TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
	TweenService:Create(gui, TweenInfo.new(LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { StudsOffset = Vector3.new(0, 3, 0) }):Play()
	TweenService:Create(label, TweenInfo.new(LIFETIME * 0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, 0, false, LIFETIME * 0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, LIFETIME + 0.1)
end

return DamageNumbers
