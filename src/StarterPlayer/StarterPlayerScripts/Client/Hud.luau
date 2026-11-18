-- Hud: UI บนจอระหว่างต่อสู้ (ภาษาไทย) — สถานะ wave, HP ฐาน, HP ผู้เล่น, ช่องอาวุธ, คูลดาวน์กลิ้ง, ขอบจอแดง
-- ชื่อไอเท็มเก็บเป็น key (Sword/Bow) แยกจากข้อความที่แสดง
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Assets = ReplicatedStorage:WaitForChild("Assets")

local Hud = {}

-- เรียกเมื่อแตะ/คลิกช่องอาวุธ: function(weaponName) — ตั้งโดย Client
Hud.OnSlotActivated = nil

local SLOT_SIZE = 76
local SHIELD_HINT = "คลิกขวา: โล่"
local touch = false -- จอสัมผัส: ซ่อนคำแนะนำปุ่มคีย์บอร์ด และย้ายสิ่งที่ชนกับปุ่มควบคุม

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
local armorFill, armorLabel
local chargeBar, chargeFill
local banner, bannerTitle, bannerSub, bannerStats
local bossBack, bossFill, bossLabel
local downedFrame, downedSub
local promptFrame, promptLabel, promptFill
local reviveCandidate -- เพื่อนที่ล้มอยู่ใกล้ ๆ ที่ชุบได้ตอนนี้
local rollOverlay, rollLabel
local hurtEdges = {}
local slots = {}
local matchTop, baseBack -- ส่วนที่แสดงเฉพาะตอนอยู่ในแมตช์
local lastReward -- รางวัลแมตช์ล่าสุด (Remotes.MatchRewards)
local slotBar -- แถวช่องอาวุธด้านล่าง
local currentEquipped
local rebuildSlots
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

-- รูปอาวุธในช่อง: โมเดลจริงจาก Assets.Weapons แสดงใน ViewportFrame (วางเฉียง 45 องศาให้เต็มช่อง)
local function buildIcon(parent, weaponName)
	local item = Config.Items[weaponName]
	local template = Assets:WaitForChild("Weapons"):FindFirstChild(item and item.Model or weaponName)
	if not template then
		local icon = item and item.Icon
		text({ Size = UDim2.fromScale(1, 1), Text = icon or ITEM_NAMES[weaponName] or weaponName, TextSize = icon and 36 or 20 }, parent)
		return
	end
	local viewport = make("ViewportFrame", {
		Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4), BackgroundTransparency = 1,
		Ambient = Color3.new(1, 1, 1), LightColor = Color3.new(1, 1, 1), LightDirection = Vector3.new(-1, -1, -1),
	}, parent)
	local model = template:Clone()
	model.Parent = viewport
	local cf, size = model:GetBoundingBox()
	-- มองตามแกนที่บางที่สุด (เห็นด้านกว้างของอาวุธ) โดยให้แกนที่ยาวที่สุดชี้ขึ้น แล้วเอียงกล้อง 45 องศา
	local axes = { { size.X, cf.RightVector }, { size.Y, cf.UpVector }, { size.Z, cf.LookVector } }
	table.sort(axes, function(a, b)
		return a[1] < b[1]
	end)
	local viewDir, longDir, length = axes[1][2], axes[3][2], axes[3][1]
	local camera = make("Camera", { FieldOfView = 30 }, viewport)
	local distance = length / (2 * math.tan(math.rad(15))) * 0.82
	camera.CFrame = CFrame.lookAt(cf.Position + viewDir * distance, cf.Position, longDir) * CFrame.Angles(0, 0, math.rad(45))
	viewport.CurrentCamera = camera
end

-- รายการอาวุธตาม loadout (attribute Weapons จาก server) ตามลำดับปุ่ม 1-5
function Hud.GetWeapons()
	local list = {}
	for id in string.gmatch(player:GetAttribute("Weapons") or "", "[^,]+") do
		table.insert(list, id)
	end
	return list
end

local function buildSlot(parent, index, weaponName)
	local frame = make("TextButton", {
		Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE), LayoutOrder = index, Text = "", AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(52, 58, 72), BackgroundTransparency = 0.35, BorderSizePixel = 0,
	}, parent)
	corner(frame, 12)
	local stroke = make("UIStroke", { Thickness = 3, Color = ACCENT, Enabled = false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)
	buildIcon(frame, weaponName)
	if not touch then
		text({ Size = UDim2.fromOffset(20, 20), Position = UDim2.fromOffset(4, 2), Text = weaponName == "Potion" and "F" or tostring(index), TextSize = 15, TextColor3 = ACCENT, ZIndex = 3 }, frame)
	end
	-- มุมล่างขวา: จำนวนลูกธนู/ยา; อาวุธที่มีโล่ (และใส่โล่ใน loadout) ใช้บรรทัดล่างบอกสถานะโล่
	local hasShield = player:GetAttribute("HasShield") == true and Config.Weapons[weaponName] ~= nil and Config.Weapons[weaponName].Shield ~= nil
	local ammo = text({
		Size = UDim2.new(1, -8, 0, 20), Position = UDim2.new(0, 4, 1, -22), Text = "", ZIndex = 3,
		TextSize = hasShield and 12 or 19,
		TextXAlignment = hasShield and Enum.TextXAlignment.Center or Enum.TextXAlignment.Right,
		TextColor3 = hasShield and Color3.fromRGB(210, 210, 210) or Color3.new(1, 1, 1),
	}, frame)
	slots[weaponName] = { Frame = frame, Stroke = stroke, Ammo = ammo }
	if hasShield and not touch then
		ammo.Text = SHIELD_HINT
	end
	frame.Activated:Connect(function()
		if Hud.OnSlotActivated then
			Hud.OnSlotActivated(weaponName)
		end
	end)
end

-- options: { Touch = จอสัมผัสหรือไม่ }
function Hud.Init(options)
	touch = options ~= nil and options.Touch == true
	gui = make("ScreenGui", { Name = "Hud", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5 }, player:WaitForChild("PlayerGui"))

	-- บน: wave + สถานะ + HP ฐาน
	local top = make("Frame", { Size = UDim2.fromOffset(420, 130), Position = UDim2.new(0.5, 0, 0, 44), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1 }, gui)
	matchTop = top
	waveLabel = text({ Size = UDim2.new(1, 0, 0, 32), Text = "", TextSize = 28 }, top)
	statusLabel = text({ Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 32), Text = "", TextSize = 19, TextColor3 = Color3.fromRGB(230, 230, 230) }, top)
	bossFill, bossLabel, bossBack = bar(top, UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 62), Vector2.zero, Color3.fromRGB(190, 45, 45))
	bossBack.Visible = false

	-- ล่างซ้าย: HP ผู้เล่น
	-- ขวาบน: HP คริสตัล (ฐาน) ขนาดเท่าแถบ HP ผู้เล่น
	local barSize = touch and UDim2.fromOffset(180, 22) or UDim2.fromOffset(220, 24)
	baseFill, baseLabel, baseBack = bar(gui, barSize, UDim2.new(1, -24, 0, 64), Vector2.new(1, 0), Color3.fromRGB(70, 170, 255))

	-- ซ้ายบน: แถบเกราะ (บาง สีน้ำเงิน ไม่มีตัวเลข) แล้วตามด้วยแถบ HP
	local armorSize = UDim2.new(barSize.X, UDim.new(0, 10))
	armorFill, armorLabel = bar(gui, armorSize, UDim2.fromOffset(24, 64), Vector2.zero, Color3.fromRGB(45, 120, 235))
	armorLabel.Visible = false
	hpFill, hpLabel = bar(gui, barSize, UDim2.fromOffset(24, 64 + armorSize.Y.Offset + 4), Vector2.zero, Color3.fromRGB(210, 60, 55))

	-- ล่างกลาง: ช่องอาวุธ + กลิ้งหลบ
	local bottom = make("Frame", { Size = UDim2.fromOffset(400, SLOT_SIZE), Position = UDim2.new(0.5, 0, 1, touch and -14 or -24), AnchorPoint = Vector2.new(0.5, 1), BackgroundTransparency = 1 }, gui)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, bottom)
	slotBar = bottom
	rebuildSlots()
	-- loadout เปลี่ยน (ใน Lobby) -> สร้างช่องใหม่ (defer: รอ server ตั้ง attribute ที่เหลือให้ครบก่อน)
	local pending = false
	local function scheduleRebuild()
		if not pending then
			pending = true
			task.defer(function()
				pending = false
				rebuildSlots()
			end)
		end
	end
	player:GetAttributeChangedSignal("Weapons"):Connect(scheduleRebuild)
	player:GetAttributeChangedSignal("HasShield"):Connect(scheduleRebuild)
	player:GetAttributeChangedSignal("Potions"):Connect(function()
		if (player:GetAttribute("Potions") or 0) > 0 and not slots.Potion then
			scheduleRebuild()
		end
	end)
	local rollFrame = make("Frame", { Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE), LayoutOrder = 99, BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.25, BorderSizePixel = 0, ClipsDescendants = true }, bottom)
	corner(rollFrame, 12)
	rollFrame.Visible = not touch -- จอสัมผัสมีปุ่มกลิ้งของตัวเอง (TouchControls)
	text({ Size = UDim2.fromOffset(22, 20), Position = UDim2.fromOffset(4, 2), Text = "Q", TextSize = 15, TextColor3 = ACCENT, ZIndex = 3 }, rollFrame)
	rollLabel = text({ Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 28), Text = "กลิ้งหลบ", TextSize = 17, ZIndex = 3 }, rollFrame)
	rollOverlay = make("Frame", { Size = UDim2.fromScale(1, 0), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 2 }, rollFrame)

	-- กลางจอ: จุดเล็ง + แถบง้างธนู
	local dot = make("Frame", { Size = UDim2.fromOffset(6, 6), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0 }, gui)
	corner(dot, 3)
	make("UIStroke", { Thickness = 1, Color = Color3.new(0, 0, 0), Transparency = 0.4 }, dot)
	chargeBar = make("Frame", { Size = UDim2.fromOffset(70, 5), Position = UDim2.new(0.5, 0, 0.5, 70), AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.3, BorderSizePixel = 0, Visible = false }, gui)
	corner(chargeBar, 3)
	chargeFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, chargeBar)
	corner(chargeFill, 3)

	-- ป้ายผลแมตช์
	banner = make("Frame", { Size = UDim2.new(1, 0, 0, 270), Position = UDim2.fromScale(0.5, 0.4), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, Visible = false }, gui)
	bannerTitle = text({ Size = UDim2.new(1, 0, 0, 84), Position = UDim2.fromOffset(0, 14), Text = "", TextSize = 68 }, banner)
	bannerSub = text({ Size = UDim2.new(1, 0, 0, 32), Position = UDim2.fromOffset(0, 102), Text = "", TextSize = 22, TextColor3 = Color3.fromRGB(230, 230, 230) }, banner)
	-- สรุปผล: สถิติของผู้เล่นแต่ละคน + นับถอยหลัง
	ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("MatchRewards").OnClientEvent:Connect(function(summary)
		lastReward = summary
	end)
	banner.Size = UDim2.new(1, 0, 0, 330)
	bannerStats = text({ Size = UDim2.new(1, 0, 0, 180), Position = UDim2.fromOffset(0, 140), Text = "", TextSize = 20, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = Color3.fromRGB(235, 235, 235) }, banner)

	-- ล้ม: ข้อความกลางจอส่วนล่าง
	downedFrame = make("Frame", { Size = UDim2.fromOffset(520, 80), Position = UDim2.fromScale(0.5, 0.7), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(60, 0, 0), BackgroundTransparency = 0.35, BorderSizePixel = 0, Visible = false }, gui)
	corner(downedFrame, 10)
	text({ Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, 6), Text = "คุณล้มแล้ว", TextSize = 32, TextColor3 = Color3.fromRGB(255, 110, 100) }, downedFrame)
	downedSub = text({ Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 46), Text = "", TextSize = 19, TextColor3 = Color3.fromRGB(235, 235, 235) }, downedFrame)

	-- ชุบเพื่อน: ข้อความ + แถบความคืบหน้า
	promptFrame = make("Frame", { Size = UDim2.fromOffset(360, 50), Position = UDim2.new(0.5, 0, 1, -110), AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.25, BorderSizePixel = 0, Visible = false }, gui)
	corner(promptFrame, 8)
	promptLabel = text({ Size = UDim2.new(1, 0, 0, 30), Position = UDim2.fromOffset(0, 4), Text = "", TextSize = 20 }, promptFrame)
	local promptBack = make("Frame", { Size = UDim2.new(1, -24, 0, 8), Position = UDim2.fromOffset(12, 36), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, BorderSizePixel = 0 }, promptFrame)
	corner(promptBack, 4)
	promptFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(110, 220, 130), BorderSizePixel = 0 }, promptBack)
	corner(promptFill, 4)

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

-- ข้อความรางวัลบนป้ายผล: EXP + บอกว่าได้หีบ (เปิดดูชิ้นส่วน/rank up ได้ที่ Lobby — RewardUi)
function Hud.FormatReward(r)
	local expText = r.ExpDelta >= 0 and string.format("EXP +%d", r.ExpDelta) or string.format("EXP %d", r.ExpDelta)
	return string.format("%s   —   ได้%s! เปิดได้ที่ Lobby", expText, r.Won and "หีบรางวัล" or "หีบปลอบใจ")
end

local function secondsLeft()
	local endsAt = workspace:GetAttribute("PhaseEndsAt") or 0
	return math.max(0, math.ceil(endsAt - workspace:GetServerTimeNow()))
end

function Hud.Refresh()
	local phase = workspace:GetAttribute("MatchPhase") or "Waiting"
	local wave = workspace:GetAttribute("Wave") or 1
	local waveCount = workspace:GetAttribute("WaveCount") or 5
	local stage = workspace:GetAttribute("Stage") or 1
	waveLabel.Text = string.format("ด่าน %d — คลื่นที่ %d / %d", stage, wave, waveCount)

	local inMatch = player:GetAttribute("InMatch") == true
	matchTop.Visible = inMatch
	baseBack.Visible = inMatch
	local showBanner = false
	if not inMatch then
		statusLabel.Text = ""
		lastReward = (phase == "Victory" or phase == "Defeat") and lastReward or nil
	elseif phase == "Waiting" then
		local left = secondsLeft()
		statusLabel.Text = left > 0 and string.format("รอเพื่อนร่วมทีมเข้าด่าน... (%d วิ)", left) or "รอเพื่อนร่วมทีมเข้าด่าน..."
	elseif phase == "Countdown" then
		statusLabel.Text = string.format("มอนสเตอร์จะบุกใน %d วิ", secondsLeft())
	elseif phase == "Wave" then
		statusLabel.Text = string.format("มอนสเตอร์เหลือ %d ตัว", workspace:GetAttribute("MonstersLeft") or 0)
	elseif phase == "Break" then
		statusLabel.Text = string.format("พัก — คลื่นถัดไปใน %d วิ", secondsLeft())
	elseif phase == "Victory" or phase == "Defeat" then
		showBanner = true
		statusLabel.Text = ""
		local matchTime = workspace:GetAttribute("MatchTime") or 0
		local footer
		if phase == "Victory" then
			bannerTitle.Text = "ชนะ!"
			bannerTitle.TextColor3 = ACCENT
			bannerSub.Text = string.format("ป้องกันคริสตัลสำเร็จ — ด่าน %d", stage)
		else
			bannerTitle.Text = "แพ้..."
			bannerTitle.TextColor3 = Color3.fromRGB(235, 70, 60)
			local reason = workspace:GetAttribute("DefeatReason")
			bannerSub.Text = reason == "Team" and "ทั้งทีมล้มพร้อมกัน" or "คริสตัลถูกทำลาย"
		end
		footer = string.format("กลับ Lobby ใน %d วิ", secondsLeft())
		local lines = { string.format("เวลา %d:%02d", matchTime // 60, matchTime % 60) }
		if lastReward then
			table.insert(lines, Hud.FormatReward(lastReward))
		end
		for _, other in Players:GetPlayers() do
			if other:GetAttribute("InMatch") ~= true then
				continue
			end
			table.insert(lines, string.format("%s   สังหาร %d   ดาเมจ %d   ล้ม %d ครั้ง", other.DisplayName,
				other:GetAttribute("StatKills") or 0, other:GetAttribute("StatDamage") or 0, other:GetAttribute("StatDowns") or 0))
		end
		table.insert(lines, footer)
		bannerStats.Text = table.concat(lines, "\n")
	else
		statusLabel.Text = "รอผู้เล่น..."
	end
	banner.Visible = showBanner

	local base = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Base")
	local baseHP = base and base:GetAttribute("HP") or 0
	local baseMax = base and base:GetAttribute("MaxHP") or Config.Base.MaxHP
	baseFill.Size = UDim2.fromScale(math.clamp(baseHP / baseMax, 0, 1), 1)
	baseLabel.Text = string.format("คริสตัล %d / %d", baseHP, baseMax)

	local bossHP = workspace:GetAttribute("BossHP")
	local bossMax = workspace:GetAttribute("BossMaxHP")
	bossBack.Visible = bossHP ~= nil and bossMax ~= nil
	if bossBack.Visible then
		bossFill.Size = UDim2.fromScale(math.clamp(bossHP / bossMax, 0, 1), 1)
		bossLabel.Text = string.format("Orc Warlord %d / %d", bossHP, bossMax)
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local isDowned = player:GetAttribute("Downed") == true
	local hp = (humanoid and not isDowned) and math.max(0, humanoid.Health) or 0
	local maxHP = humanoid and humanoid.MaxHealth or Config.Player.MaxHP
	hpFill.Size = UDim2.fromScale(math.clamp(hp / maxHP, 0, 1), 1)
	hpLabel.Text = string.format("HP %d / %d", math.ceil(hp), maxHP)

	local armor = player:GetAttribute("Armor") or 0
	local maxArmor = player:GetAttribute("MaxArmor") or 0
	local armorBack = armorFill.Parent
	armorBack.Visible = maxArmor > 0
	if maxArmor > 0 then
		armorFill.Size = UDim2.fromScale(math.clamp(armor / maxArmor, 0, 1), 1)
	end

	if slots.Bow then
		slots.Bow.Ammo.Text = tostring(player:GetAttribute("Arrows") or 0)
	end
	if slots.Potion then
		local potions = player:GetAttribute("Potions") or 0
		slots.Potion.Ammo.Text = tostring(potions)
		slots.Potion.Frame.BackgroundTransparency = potions > 0 and 0.35 or 0.7
	end

	-- ล้ม: บอกสถานะ + ความคืบหน้าถ้ามีคนกำลังชุบ
	local now = workspace:GetServerTimeNow()
	downedFrame.Visible = isDowned and not showBanner
	if isDowned then
		local endsAt = player:GetAttribute("ReviveEndsAt")
		if endsAt then
			downedSub.Text = string.format("เพื่อนกำลังชุบ... %.1f วิ", math.max(0, endsAt - now))
		else
			downedSub.Text = "คลานได้ช้า ๆ — รอเพื่อนมาชุบ หรือรอจนจบคลื่นนี้"
		end
	end

	-- เพื่อนที่ล้มอยู่ใกล้ที่สุดในระยะชุบ
	reviveCandidate = nil
	local myRoot = character and character:FindFirstChild("HumanoidRootPart")
	if myRoot and not isDowned and hp > 0 then
		local bestDistance = Config.Downed.ReviveRange
		for _, other in Players:GetPlayers() do
			local otherRoot = other ~= player and other:GetAttribute("Downed") == true and other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local distance = (otherRoot.Position - myRoot.Position).Magnitude
				if distance <= bestDistance then
					reviveCandidate, bestDistance = other, distance
				end
			end
		end
	end
	promptFrame.Visible = reviveCandidate ~= nil
	if reviveCandidate then
		local endsAt = reviveCandidate:GetAttribute("ReviveEndsAt")
		promptLabel.Text = string.format(touch and "กดปุ่ม ชุบ ค้างไว้เพื่อชุบ %s" or "กดค้าง E เพื่อชุบ %s", reviveCandidate.DisplayName)
		local progress = endsAt and math.clamp(1 - (endsAt - now) / Config.Downed.ReviveTime, 0, 1) or 0
		promptFill.Size = UDim2.fromScale(progress, 1)
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

-- สร้างช่องอาวุธ + ช่องยาใหม่ตาม loadout ปัจจุบัน
rebuildSlots = function()
	if not slotBar then
		return
	end
	for _, slot in slots do
		slot.Frame:Destroy()
	end
	table.clear(slots)
	for index, weaponName in Hud.GetWeapons() do
		buildSlot(slotBar, index, weaponName)
	end
	if (player:GetAttribute("Potions") or 0) > 0 then
		buildSlot(slotBar, 50, "Potion")
	end
	Hud.SetEquipped(currentEquipped)
end

-- เพื่อนที่กดชุบได้ตอนนี้ (nil ถ้าไม่มี)
function Hud.GetReviveCandidate()
	return reviveCandidate
end

function Hud.SetEquipped(weaponName)
	currentEquipped = weaponName
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

-- ยกโล่อยู่: เน้นข้อความในช่องดาบ
function Hud.SetBlocking(on)
	local slot = slots.Sword
	if not slot or player:GetAttribute("HasShield") ~= true then
		return -- ไม่ได้ใส่โล่ใน loadout: ไม่แสดงคำแนะนำโล่
	end
	slot.Ammo.Text = on and "ยกโล่อยู่" or (touch and "" or SHIELD_HINT)
	slot.Ammo.TextColor3 = on and ACCENT or Color3.fromRGB(210, 210, 210)
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
	TweenService:Create(slot.Ammo, TweenInfo.new(0.5), { TextColor3 = Color3.new(1, 1, 1) }):Play()
end

return Hud
