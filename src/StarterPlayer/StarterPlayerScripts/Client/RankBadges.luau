-- RankBadges: ป้าย rank เหนือหัวผู้เล่นคนอื่น (GDD เฟส 5) — ทำงานเอง แค่ require
-- อ่าน attribute Rank บน Player (DataService ตั้งให้ทั้ง Lobby และ server แมตช์) เปลี่ยน rank แล้วป้ายเปลี่ยนตาม
-- สร้างฝั่ง client ล้วน (BillboardGui ใน PlayerGui ผูก Adornee กับหัว) ไม่ต้อง replicate
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Progression = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Progression"))

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local MAX_DISTANCE = 80

local localPlayer = Players.LocalPlayer
-- ใส่ BillboardGui ตรงใต้ PlayerGui (ResetOnSpawn = false) — ห้ามห่อด้วย Folder: ตอนเราเกิดใหม่ PlayerGui ล้าง Folder ทิ้งทั้งก้อน
local playerGui = localPlayer:WaitForChild("PlayerGui")

local badges = {} -- [player] = BillboardGui

local function build(player)
	local gui = Instance.new("BillboardGui")
	gui.Name = "RankBadge_" .. player.Name
	gui.Size = UDim2.fromOffset(120, 26)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0) -- เหนือชื่อผู้เล่นของ Roblox
	gui.MaxDistance = MAX_DISTANCE
	gui.AlwaysOnTop = false
	gui.ResetOnSpawn = false
	gui.LightInfluence = 0

	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.5)
	pill.Size = UDim2.fromScale(0, 1)
	pill.AutomaticSize = Enum.AutomaticSize.X
	pill.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
	pill.BackgroundTransparency = 0.25
	pill.BorderSizePixel = 0
	pill.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = pill
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Stroke"
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = pill
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = pill

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0, 1)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.FontFace = FONT
	label.TextSize = 15
	label.TextStrokeTransparency = 0.6
	label.Parent = pill
	return gui
end

local function refresh(player)
	local gui = badges[player]
	if not gui then
		return
	end
	local rankId = player:GetAttribute("Rank")
	local head = player.Character and player.Character:FindFirstChild("Head")
	gui.Adornee = head
	gui.Enabled = rankId ~= nil and head ~= nil
	if rankId then
		local rank = Progression.RankById(rankId)
		gui.Pill.Label.Text = string.format("%s %s", rank.Icon or "", rank.Name)
		gui.Pill.Label.TextColor3 = rank.Color
		gui.Pill.Stroke.Color = rank.Color
	end
end

local function watch(player)
	-- ป้ายของตัวเองไม่แสดง (rank ตัวเองดูที่ Lobby UI) — กันป้ายบังมุมกล้องตอนเล็งธนู
	if player == localPlayer or badges[player] then
		return
	end
	badges[player] = build(player)
	badges[player].Parent = playerGui
	player:GetAttributeChangedSignal("Rank"):Connect(function()
		refresh(player)
	end)
	player.CharacterAdded:Connect(function(char)
		char:WaitForChild("Head", 10)
		refresh(player)
	end)
	refresh(player)
end

Players.PlayerAdded:Connect(watch)
Players.PlayerRemoving:Connect(function(player)
	if badges[player] then
		badges[player]:Destroy()
		badges[player] = nil
	end
end)
for _, player in Players:GetPlayers() do
	task.spawn(watch, player)
end

return {}
