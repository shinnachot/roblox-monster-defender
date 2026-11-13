-- Hud: UI บนจอระหว่างต่อสู้ (ภาษาไทย) — สถานะ wave, HP ฐาน, HP ผู้เล่น, ช่องอาวุธ, คูลดาวน์กลิ้ง, ขอบจอแดง
-- ชื่อไอเท็มเก็บเป็น key (Sword/Bow) แยกจากข้อความที่แสดง
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local Hud = {}

local ITEM_NAMES = {
	Sword = "ดาบ",
	Bow = "ธนู",
}

-- ฟอนต์นี้ไม่มีอักษรไทยในตัว — Roblox จะ fallback ไปฟอนต์ไทยให้เอง (ตรวจใน playtest แล้วว่าแสดงผลถูก)
local FONT = Font.fromEnum(Enum.Font.GothamBold)
local PANEL_COLOR = Color3.fromRGB(20, 22, 28)
local ACCENT = Color3.fromRGB(255, 196, 64)

local player = Players.LocalPlayer
local gui
local waveLabel, statusLabel, baseFill, baseLabel
local hpFill, hpLabel
local chargeBar, chargeFill
local banner, bannerTitle, bannerSub
local rollOverlay, rollLabel
local hurtEdges = {}
local slots = {}
local rollReadyAt = 0
local rollDuration = 1

local function make(className, props, parent)
	local instance = Instance.new(className)
	for key, value in props do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end

local function corner(parent, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
end

local function text(props, parent)
	props.BackgroundTransparency = 1
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	local label = make("TextLabel", props, parent)
	make("UIStroke", { Thickness = 1.5, Color = Color3.new(0, 0, 0), Transparency = 0.3 }, label)
	return label
end

local function bar(parent, size, position, anchor, fillColor)
	local back = make("Frame", {
		Size = size, Position = position, AnchorPoint = anchor,
		BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.25, BorderSizePixel = 0,
	}, parent)
	corner(back)
	local fill = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = fillColor, BorderSizePixel = 0 }, back)
	corner(fill)
	local label = text({ Size = UDim2.fromScale(1, 1), TextSize = 16, ZIndex = 2 }, back)
	return fill, label, back
end

local function buildSlot(parent, index, weaponName)
	local frame = make("Frame", {
		Size = UDim2.fromOffset(84, 64), LayoutOrder = index,
		BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.25, BorderSizePixel = 0,
	}, parent)
	corner(frame, 8)
	local stroke = make("UIStroke", { Thickness = 2, Color = ACCENT, Enabled = false }, frame)
	text({ Size = UDim2.fromOffset(22, 20), Position = UDim2.fromOffset(4, 2), Text = tostring(index), TextSize = 15, TextColor3 = ACCENT }, frame)
	text({ Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 14), Text = ITEM_NAMES[weaponName] or weaponName, TextSize = 22 }, frame)
	local ammo = text({ Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 42), Text = "", TextSize = 15, TextColor3 = Color3.fromRGB(210, 210, 210) }, frame)
	slots[weaponName] = { Frame = frame, Stroke = stroke, Ammo = ammo }
end

function Hud.Init()
	gui = make("ScreenGui", { Name = "Hud", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5 }, player:WaitForChild("PlayerGui"))

	-- บน: wave + สถานะ + HP ฐาน
	local top = make("Frame", { Size = UDim2.fromOffset(420, 100), Position = UDim2.new(0.5, 0, 0, 44), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1 }, gui)
	waveLabel = text({ Size = UDim2.new(1, 0, 0, 32), Text = "", TextSize = 28 }, top)
	statusLabel = text({ Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 32), Text = "", TextSize = 19, TextColor3 = Color3.fromRGB(230, 230, 230) }, top)
	baseFill, baseLabel = bar(top, UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 62), Vector2.zero, Color3.fromRGB(70, 170, 255))

	-- ล่างซ้าย: HP ผู้เล่น
	hpFill, hpLabel = bar(gui, UDim2.fromOffset(260, 24), UDim2.new(0, 24, 1, -24), Vector2.new(0, 1), Color3.fromRGB(210, 60, 55))

	-- ล่างกลาง: ช่องอาวุธ + กลิ้งหลบ
	local bottom = make("Frame", { Size = UDim2.fromOffset(400, 64), Position = UDim2.new(0.5, 0, 1, -24), AnchorPoint = Vector2.new(0.5, 1), BackgroundTransparency = 1 }, gui)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, bottom)
	for index, weaponName in Config.DefaultLoadout.Weapons do
		buildSlot(bottom, index, weaponName)
	end
	local rollFrame = make("Frame", { Size = UDim2.fromOffset(84, 64), LayoutOrder = 99, BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.25, BorderSizePixel = 0, ClipsDescendants = true }, bottom)
	corner(rollFrame, 8)
	text({ Size = UDim2.fromOffset(22, 20), Position = UDim2.fromOffset(4, 2), Text = "Q", TextSize = 15, TextColor3 = ACCENT, ZIndex = 3 }, rollFrame)
	rollLabel = text({ Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 20), Text = "กลิ้งหลบ", TextSize = 19, ZIndex = 3 }, rollFrame)
	rollOverlay = make("Frame", { Size = UDim2.fromScale(1, 0), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 2 }, rollFrame)

	-- กลางจอ: จุดเล็ง + แถบง้างธนู
	local dot = make("Frame", { Size = UDim2.fromOffset(6, 6), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, gui)
	corner(dot, 3)
	make("UIStroke", { Thickness = 1, Color = Color3.new(0, 0, 0), Transparency = 0.4 }, dot)
	chargeBar = make("Frame", { Size = UDim2.fromOffset(90, 7), Position = UDim2.new(0.5, 0, 0.5, 26), AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.3, BorderSizePixel = 0, Visible = false }, gui)
	corner(chargeBar, 3)
	chargeFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, chargeBar)
	corner(chargeFill, 3)

	-- ป้ายผลแมตช์
	banner = make("Frame", { Size = UDim2.new(1, 0, 0, 150), Position = UDim2.fromScale(0.5, 0.32), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, Visible = false }, gui)
	bannerTitle = text({ Size = UDim2.new(1, 0, 0, 84), Position = UDim2.fromOffset(0, 14), Text = "", TextSize = 68 }, banner)
	bannerSub = text({ Size = UDim2.new(1, 0, 0, 32), Position = UDim2.fromOffset(0, 102), Text = "", TextSize = 22, TextColor3 = Color3.fromRGB(230, 230, 230) }, banner)

	-- ขอบจอแดงวาบตอนโดนตี (ไม่มีตัวเลข)
	local edges = {
		{ UDim2.new(1, 0, 0.22, 0), UDim2.fromScale(0, 0), Vector2.zero, 90 },
		{ UDim2.new(1, 0, 0.22, 0), UDim2.fromScale(0, 1), Vector2.new(0, 1), -90 },
		{ UDim2.new(0.16, 0, 1, 0), UDim2.fromScale(0, 0), Vector2.zero, 0 },
		{ UDim2.new(0.16, 0, 1, 0), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180 },
	}
	for _, edge in edges do
		local frame = make("Frame", { Size = edge[1], Position = edge[2], AnchorPoint = edge[3], BackgroundColor3 = Color3.fromRGB(200, 0, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 10 }, gui)
		make("UIGradient", { Rotation = edge[4], Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) }) }, frame)
		table.insert(hurtEdges, frame)
	end

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= 0.1 then
			elapsed = 0
			Hud.Refresh()
		end
	end)
	Hud.Refresh()
end

local function secondsLeft()
	local endsAt = workspace:GetAttribute("PhaseEndsAt") or 0
	return math.max(0, math.ceil(endsAt - workspace:GetServerTimeNow()))
end

function Hud.Refresh()
	local phase = workspace:GetAttribute("MatchPhase") or "Waiting"
	local wave = workspace:GetAttribute("Wave") or 1
	local waveCount = workspace:GetAttribute("WaveCount") or 5
	waveLabel.Text = string.format("คลื่นที่ %d / %d", wave, waveCount)

	local showBanner = false
	if phase == "Countdown" then
		statusLabel.Text = string.format("มอนสเตอร์จะบุกใน %d วิ", secondsLeft())
	elseif phase == "Wave" then
		statusLabel.Text = string.format("มอนสเตอร์เหลือ %d ตัว", workspace:GetAttribute("MonstersLeft") or 0)
	elseif phase == "Break" then
		statusLabel.Text = string.format("พัก — คลื่นถัดไปใน %d วิ", secondsLeft())
	elseif phase == "Victory" or phase == "Defeat" then
		showBanner = true
		statusLabel.Text = ""
		if phase == "Victory" then
			bannerTitle.Text = "ชนะ!"
			bannerTitle.TextColor3 = ACCENT
			bannerSub.Text = string.format("ป้องกันคริสตัลสำเร็จ — เริ่มใหม่ใน %d วิ", secondsLeft())
		else
			bannerTitle.Text = "แพ้..."
			bannerTitle.TextColor3 = Color3.fromRGB(235, 70, 60)
			bannerSub.Text = string.format("คริสตัลถูกทำลาย — เริ่มใหม่ใน %d วิ", secondsLeft())
		end
	else
		statusLabel.Text = "รอผู้เล่น..."
	end
	banner.Visible = showBanner

	local base = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Base")
	local baseHP = base and base:GetAttribute("HP") or 0
	local baseMax = base and base:GetAttribute("MaxHP") or Config.Base.MaxHP
	baseFill.Size = UDim2.fromScale(math.clamp(baseHP / baseMax, 0, 1), 1)
	baseLabel.Text = string.format("คริสตัล %d / %d", baseHP, baseMax)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local hp = humanoid and math.max(0, humanoid.Health) or 0
	local maxHP = humanoid and humanoid.MaxHealth or Config.Player.MaxHP
	hpFill.Size = UDim2.fromScale(math.clamp(hp / maxHP, 0, 1), 1)
	hpLabel.Text = string.format("HP %d / %d", math.ceil(hp), maxHP)

	if slots.Bow then
		slots.Bow.Ammo.Text = string.format("ลูกธนู %d", player:GetAttribute("Arrows") or 0)
	end

	local remaining = rollReadyAt - os.clock()
	if remaining > 0 then
		rollOverlay.Size = UDim2.fromScale(1, math.clamp(remaining / rollDuration, 0, 1))
		rollLabel.Text = string.format("%.1f", remaining)
	else
		rollOverlay.Size = UDim2.fromScale(1, 0)
		rollLabel.Text = "กลิ้งหลบ"
	end
end

function Hud.SetEquipped(weaponName)
	for name, slot in slots do
		slot.Stroke.Enabled = name == weaponName
		slot.Frame.BackgroundTransparency = name == weaponName and 0.05 or 0.35
	end
end

-- charge: nil = ซ่อนแถบ, 0..1 = ระดับการง้าง
function Hud.SetCharge(charge)
	if not chargeBar then
		return
	end
	chargeBar.Visible = charge ~= nil
	if charge then
		chargeFill.Size = UDim2.fromScale(charge, 1)
		chargeFill.BackgroundColor3 = charge >= 1 and Color3.fromRGB(255, 90, 60) or ACCENT
	end
end

function Hud.SetRollCooldown(duration)
	rollDuration = duration
	rollReadyAt = os.clock() + duration
end

function Hud.FlashHurt()
	for _, frame in hurtEdges do
		frame.BackgroundTransparency = 0
		TweenService:Create(frame, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
	end
end

function Hud.FlashAmmo()
	local slot = slots.Bow
	if not slot then
		return
	end
	slot.Ammo.TextColor3 = Color3.fromRGB(255, 70, 60)
	TweenService:Create(slot.Ammo, TweenInfo.new(0.5), { TextColor3 = Color3.fromRGB(210, 210, 210) }):Play()
end

return Hud
