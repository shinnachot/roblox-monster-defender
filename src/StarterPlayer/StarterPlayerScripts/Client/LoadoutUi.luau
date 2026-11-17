-- LoadoutUi: หน้าคลังอาวุธใน Lobby (GDD ข้อ 3) — จัด loadout 12 แต้ม + อัพเกรดไอเท็ม
-- การ์ดแต่ละใบ: โมเดล 3D นิ่ง (ViewportFrame), ชื่อ, แต้ม, เลเวลอัพเกรด, แถบชิ้นส่วน, ปุ่มอัพเกรด
-- ไอเท็มที่ยังไม่ปลดล็อค: สีเทา + กุญแจ + rank ที่ปลดล็อค; ไอเท็มที่ยังไม่มีระบบ: "เร็ว ๆ นี้"
-- server ตรวจทุกอย่างซ้ำ (Remotes.SetLoadout / UpgradeItem) — หน้านี้แค่แสดงผลและส่งคำขอ
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Assets = ReplicatedStorage:WaitForChild("Assets")
local CameraController = require(script.Parent:WaitForChild("CameraController"))

local LoadoutUi = {}

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local PANEL_COLOR = Color3.fromRGB(24, 26, 32)
local CARD_COLOR = Color3.fromRGB(44, 48, 58)
local ACCENT = Color3.fromRGB(255, 196, 64)
local GREEN = Color3.fromRGB(80, 190, 100)
local GREY = Color3.fromRGB(120, 122, 128)
local CARD_SIZE = Vector2.new(156, 214)

local REASON_TEXT = {
	Points = "แต้มเกิน 12",
	Weapons = "ต้องมีอาวุธ 1–5 ชิ้น",
	Armor = "ใส่เกราะได้ชุดเดียว",
	Duplicate = "ใส่ไอเท็มนี้ซ้ำไม่ได้",
	Locked = "มีไอเท็มที่ยังไม่ปลดล็อค",
	Unavailable = "มีไอเท็มที่ยังใช้ไม่ได้",
	InMatch = "จัด Loadout ได้เฉพาะใน Lobby",
	NotEnoughParts = "ชิ้นส่วนไม่พอ",
	MaxLevel = "เลเวลเต็มแล้ว",
	Busy = "รอสักครู่",
	NotLoaded = "กำลังโหลดข้อมูลผู้เล่น...",
}

local player = Players.LocalPlayer
local gui, pointsLabel, messageLabel, saveButton, grid
local profile -- snapshot ล่าสุดจาก server
local draft -- loadout ที่กำลังจัด (รายการ id)
local cards = {} -- [itemId] = ui refs
local busy = false

local function make(className, props, parent)
	local inst = Instance.new(className)
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function corner(parent, radius)
	make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function text(props, parent)
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.FontFace = FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	return make("TextLabel", props, parent)
end

local function button(props, parent)
	props.FontFace = FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.BorderSizePixel = 0
	local b = make("TextButton", props, parent)
	corner(b, 8)
	return b
end

local function count(list, id)
	local n = 0
	for _, other in list do
		if other == id then
			n += 1
		end
	end
	return n
end

local function same(a, b)
	if #a ~= #b then
		return false
	end
	for index, id in a do
		if b[index] ~= id then
			return false
		end
	end
	return true
end

-- โมเดลจริงของไอเท็มแบบนิ่ง (วางเฉียง 45 องศาให้เต็มกรอบ) หรือไอคอนถ้าไม่มีโมเดล
local function buildPreview(parent, item)
	local template = item.Model and Assets:WaitForChild("Weapons"):FindFirstChild(item.Model)
	if not template then
		text({ Size = UDim2.fromScale(1, 1), Text = item.Icon or "?", TextSize = 52 }, parent)
		return
	end
	local viewport = make("ViewportFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
		Ambient = Color3.fromRGB(200, 200, 200), LightColor = Color3.new(1, 1, 1), LightDirection = Vector3.new(-1, -1, -1),
	}, parent)
	local model = template:Clone()
	for _, d in model:GetDescendants() do
		if d:IsA("Trail") or d:IsA("ParticleEmitter") then
			d:Destroy()
		end
	end
	model.Parent = viewport
	local cf, size = model:GetBoundingBox()
	local axes = { { size.X, cf.RightVector }, { size.Y, cf.UpVector }, { size.Z, cf.LookVector } }
	table.sort(axes, function(a, b)
		return a[1] < b[1]
	end)
	local viewDir, longDir, length = axes[1][2], axes[3][2], axes[3][1]
	local camera = make("Camera", { FieldOfView = 30 }, viewport)
	local distance = math.max(length, axes[2][1] * 1.6) / (2 * math.tan(math.rad(15))) * 0.85
	camera.CFrame = CFrame.lookAt(cf.Position + viewDir * distance, cf.Position, longDir) * CFrame.Angles(0, 0, math.rad(45))
	viewport.CurrentCamera = camera
end

---------------------------------------------------------------- การจัด

local function toggle(id)
	local item = Config.Items[id]
	local index = table.find(draft, id)
	if index and not item.Repeatable then
		table.remove(draft, index)
	elseif not item.Repeatable then
		if item.Kind == "Armor" then
			-- เกราะใส่ได้ชุดเดียว: เปลี่ยนชุด
			for i = #draft, 1, -1 do
				local other = Config.Items[draft[i]]
				if other and other.Kind == "Armor" then
					table.remove(draft, i)
				end
			end
		end
		table.insert(draft, id)
	else
		table.insert(draft, id)
	end
	LoadoutUi.Refresh()
end

local function removeOne(id)
	local index = table.find(draft, id)
	if index then
		table.remove(draft, index)
	end
	LoadoutUi.Refresh()
end

local messageUntil = 0 -- ข้อความผลลัพธ์ (บันทึก/อัพเกรด) ค้างไว้ช่วงหนึ่งก่อนกลับไปแสดงสถานะ

local function setMessage(message, isError)
	messageUntil = (message and message ~= "") and os.clock() + 3 or 0
	messageLabel.Text = message or ""
	messageLabel.TextColor3 = isError and Color3.fromRGB(255, 110, 100) or Color3.fromRGB(150, 230, 150)
end

local function save()
	if busy then
		return
	end
	busy = true
	saveButton.Text = "กำลังบันทึก..."
	local ok, reason = Remotes.SetLoadout:InvokeServer(draft)
	busy = false
	saveButton.Text = "บันทึก"
	if ok then
		setMessage("บันทึก Loadout แล้ว")
	else
		setMessage(REASON_TEXT[reason] or "บันทึกไม่ได้", true)
	end
	LoadoutUi.Refresh()
end

local function upgrade(id)
	if busy then
		return
	end
	busy = true
	local ok, reason = Remotes.UpgradeItem:InvokeServer(id)
	busy = false
	if ok then
		setMessage(string.format("อัพเกรด %s แล้ว!", Config.Items[id].Name))
	else
		setMessage(REASON_TEXT[reason] or "อัพเกรดไม่ได้", true)
	end
	LoadoutUi.Refresh()
end

---------------------------------------------------------------- การ์ด

local function buildCard(id)
	local item = Config.Items[id]
	local frame = make("TextButton", {
		Name = id, Text = "", AutoButtonColor = false, LayoutOrder = item.Order,
		BackgroundColor3 = CARD_COLOR, BorderSizePixel = 0,
	}, grid)
	corner(frame, 10)
	local stroke = make("UIStroke", { Thickness = 3, Color = GREEN, Enabled = false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)

	local preview = make("Frame", { Size = UDim2.new(1, -16, 0, 92), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = Color3.fromRGB(30, 33, 40), BorderSizePixel = 0 }, frame)
	corner(preview, 8)
	buildPreview(preview, item)
	local cost = text({ Size = UDim2.fromOffset(52, 22), Position = UDim2.fromOffset(12, 12), Text = item.Cost .. " แต้ม", TextSize = 13, BackgroundTransparency = 0.2, BackgroundColor3 = Color3.fromRGB(15, 15, 20), ZIndex = 3 }, frame)
	corner(cost, 6)
	local level = text({ Size = UDim2.fromOffset(44, 22), Position = UDim2.new(1, -56, 0, 12), Text = "", TextSize = 13, TextColor3 = ACCENT, BackgroundTransparency = 0.2, BackgroundColor3 = Color3.fromRGB(15, 15, 20), ZIndex = 3 }, frame)
	corner(level, 6)
	local countBadge = text({ Size = UDim2.fromOffset(34, 22), Position = UDim2.new(1, -46, 0, 76), Text = "", TextSize = 15, TextColor3 = GREEN, BackgroundTransparency = 0.2, BackgroundColor3 = Color3.fromRGB(15, 15, 20), ZIndex = 3, Visible = false }, frame)
	corner(countBadge, 6)

	text({ Size = UDim2.new(1, -12, 0, 22), Position = UDim2.fromOffset(6, 104), Text = item.Name, TextSize = 17 }, frame)
	text({ Size = UDim2.new(1, -12, 0, 30), Position = UDim2.fromOffset(6, 125), Text = item.Desc or "", TextSize = 12, TextWrapped = true, TextColor3 = Color3.fromRGB(190, 190, 195), TextYAlignment = Enum.TextYAlignment.Top }, frame)

	-- แถบชิ้นส่วน + ปุ่มอัพเกรด (เฉพาะไอเท็มที่อัพได้)
	local partsBack = make("Frame", { Size = UDim2.new(1, -16, 0, 16), Position = UDim2.fromOffset(8, 158), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.4, BorderSizePixel = 0, Visible = item.Upgradable == true }, frame)
	corner(partsBack, 5)
	local partsFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(110, 170, 255), BorderSizePixel = 0 }, partsBack)
	corner(partsFill, 5)
	local partsLabel = text({ Size = UDim2.fromScale(1, 1), Text = "", TextSize = 11, ZIndex = 2 }, partsBack)

	local action = button({ Size = UDim2.new(1, -16, 0, 30), Position = UDim2.new(0, 8, 1, -36), Text = "", TextSize = 14, BackgroundColor3 = Color3.fromRGB(64, 70, 84), ZIndex = 3 }, frame)
	-- ลูกธนูเพิ่ม (ใส่ซ้ำได้): ปุ่ม − / +
	local minus, plus
	if item.Repeatable then
		action.Size = UDim2.new(0.5, -12, 0, 30)
		minus = action
		minus.Text = "−"
		minus.TextSize = 22
		plus = button({ Size = UDim2.new(0.5, -12, 0, 30), Position = UDim2.new(0.5, 4, 1, -36), Text = "+", TextSize = 22, BackgroundColor3 = Color3.fromRGB(64, 70, 84), ZIndex = 3 }, frame)
		minus.Activated:Connect(function()
			removeOne(id)
		end)
		plus.Activated:Connect(function()
			toggle(id)
		end)
	end

	-- ไอเท็มล็อค / ยังไม่มีระบบ: ทับด้วยแผ่นสีเทา
	local lockCover = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(10, 10, 14), BackgroundTransparency = 0.35, BorderSizePixel = 0, ZIndex = 5, Visible = false }, frame)
	corner(lockCover, 10)
	local lockLabel = text({ Size = UDim2.new(1, -10, 0, 60), Position = UDim2.new(0, 5, 0.5, -30), Text = "", TextSize = 16, TextWrapped = true, ZIndex = 6 }, lockCover)

	cards[id] = {
		Frame = frame, Stroke = stroke, Level = level, Count = countBadge, PartsBack = partsBack, PartsFill = partsFill,
		PartsLabel = partsLabel, Action = action, Plus = plus, Minus = minus, LockCover = lockCover, LockLabel = lockLabel,
	}

	-- คลิกการ์ด = ใส่/ถอด (ปุ่มอัพเกรดแยกต่างหาก)
	frame.Activated:Connect(function()
		local card = cards[id]
		if card.Locked or item.Repeatable then
			return
		end
		toggle(id)
	end)
	if not item.Repeatable then
		action.Activated:Connect(function()
			local card = cards[id]
			if card.Locked then
				return
			end
			if card.CanUpgrade then
				upgrade(id)
			else
				toggle(id)
			end
		end)
	end
end

function LoadoutUi.Refresh()
	if not gui or not profile then
		return
	end
	local exp = profile.Exp
	local used = Progression.LoadoutCost(draft)
	local valid, reason = Progression.ValidateLoadout(draft, exp)
	pointsLabel.Text = string.format("แต้ม %d / %d", used, Config.Loadout.Points)
	pointsLabel.TextColor3 = used > Config.Loadout.Points and Color3.fromRGB(255, 110, 100) or ACCENT

	for id, card in cards do
		local item = Config.Items[id]
		local unlocked = Progression.IsUnlocked(id, exp)
		local available = item.Available ~= false
		card.Locked = not unlocked or not available
		card.LockCover.Visible = card.Locked
		if not unlocked then
			card.LockLabel.Text = "🔒\nปลดล็อคที่ " .. item.Rank
		elseif not available then
			card.LockLabel.Text = "เร็ว ๆ นี้"
		end

		local n = count(draft, id)
		card.Stroke.Enabled = n > 0
		card.Count.Visible = item.Repeatable == true and n > 0
		card.Count.Text = "×" .. n

		local lv = profile.Levels[id] or 0
		card.Level.Visible = item.Upgradable == true
		card.Level.Text = "Lv " .. lv
		local costParts = Progression.UpgradeCost(id, lv)
		local have = profile.Parts[id] or 0
		card.CanUpgrade = costParts ~= nil and have >= costParts and unlocked
		if item.Upgradable then
			if costParts then
				card.PartsFill.Size = UDim2.fromScale(math.clamp(have / costParts, 0, 1), 1)
				card.PartsLabel.Text = string.format("ชิ้นส่วน %d / %d", have, costParts)
			else
				card.PartsFill.Size = UDim2.fromScale(1, 1)
				card.PartsLabel.Text = string.format("เลเวลเต็ม (ชิ้นส่วน %d)", have)
			end
		end

		if not item.Repeatable then
			if card.CanUpgrade then
				card.Action.Text = string.format("อัพเกรด → Lv %d", lv + 1)
				card.Action.BackgroundColor3 = Color3.fromRGB(200, 140, 30)
			elseif n > 0 then
				card.Action.Text = "✓ ใส่อยู่"
				card.Action.BackgroundColor3 = Color3.fromRGB(50, 120, 65)
			else
				card.Action.Text = "ใส่"
				card.Action.BackgroundColor3 = Color3.fromRGB(64, 70, 84)
			end
		end
	end

	local changed = not same(draft, profile.Loadout)
	saveButton.Active = valid and changed and not busy
	saveButton.AutoButtonColor = saveButton.Active
	saveButton.BackgroundColor3 = saveButton.Active and GREEN or Color3.fromRGB(70, 74, 80)
	if not valid then
		messageLabel.Text = REASON_TEXT[reason] or "Loadout ไม่ถูกต้อง"
		messageLabel.TextColor3 = Color3.fromRGB(255, 110, 100)
	elseif os.clock() > messageUntil then
		messageLabel.Text = changed and "ยังไม่ได้บันทึก" or ""
		messageLabel.TextColor3 = Color3.fromRGB(230, 200, 120)
	end
end

---------------------------------------------------------------- เปิด / ปิด

local function build()
	gui = make("ScreenGui", { Name = "LoadoutUi", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 10, Enabled = false }, player:WaitForChild("PlayerGui"))
	make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0 }, gui)

	local panel = make("Frame", { Size = UDim2.fromOffset(880, 600), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = PANEL_COLOR, BorderSizePixel = 0 }, gui)
	corner(panel, 14)
	-- ย่อให้พอดีจอเล็ก (มือถือ)
	local scale = make("UIScale", {}, panel)
	local function fit()
		local view = workspace.CurrentCamera.ViewportSize
		scale.Scale = math.min(1, (view.X - 24) / 880, (view.Y - 24) / 600)
	end
	fit()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)

	text({ Size = UDim2.fromOffset(400, 40), Position = UDim2.fromOffset(22, 14), Text = "คลังอาวุธ — Loadout", TextSize = 28, TextXAlignment = Enum.TextXAlignment.Left }, panel)
	pointsLabel = text({ Size = UDim2.fromOffset(200, 40), Position = UDim2.new(1, -270, 0, 14), Text = "", TextSize = 24, TextXAlignment = Enum.TextXAlignment.Right }, panel)
	local close = button({ Size = UDim2.fromOffset(40, 40), Position = UDim2.new(1, -56, 0, 14), Text = "X", TextSize = 22, BackgroundColor3 = Color3.fromRGB(70, 50, 50) }, panel)
	close.Activated:Connect(LoadoutUi.Close)

	grid = make("ScrollingFrame", {
		Size = UDim2.new(1, -32, 1, -150), Position = UDim2.fromOffset(16, 64), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 6, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollingDirection = Enum.ScrollingDirection.Y,
	}, panel)
	make("UIGridLayout", { CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, grid)
	make("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, grid)
	for id in Config.Items do
		buildCard(id)
	end

	-- ล่าง: ข้อความ + ปุ่ม
	messageLabel = text({ Size = UDim2.new(1, -420, 0, 30), Position = UDim2.new(0, 22, 1, -66), Text = "", TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left }, panel)
	local reset = button({ Size = UDim2.fromOffset(170, 48), Position = UDim2.new(1, -384, 1, -72), Text = "ชุดเริ่มต้น", TextSize = 18, BackgroundColor3 = Color3.fromRGB(64, 70, 84) }, panel)
	reset.Activated:Connect(function()
		draft = table.clone(Config.Loadout.Starter)
		LoadoutUi.Refresh()
	end)
	saveButton = button({ Size = UDim2.fromOffset(190, 48), Position = UDim2.new(1, -204, 1, -72), Text = "บันทึก", TextSize = 22, BackgroundColor3 = GREEN }, panel)
	saveButton.Activated:Connect(function()
		if saveButton.Active then
			task.spawn(save)
		end
	end)

	Remotes:WaitForChild("ProfileChanged").OnClientEvent:Connect(function(snapshot)
		profile = snapshot
		LoadoutUi.Refresh()
	end)
	-- เข้าแมตช์แล้วปิดหน้านี้ (loadout ล็อค)
	player:GetAttributeChangedSignal("InMatch"):Connect(function()
		if player:GetAttribute("InMatch") then
			LoadoutUi.Close()
		end
	end)
end

function LoadoutUi.Open()
	if player:GetAttribute("InMatch") then
		return
	end
	if not gui then
		build()
	end
	profile = Remotes.GetProfile:InvokeServer()
	if not profile then
		return
	end
	draft = table.clone(profile.Loadout)
	setMessage("")
	gui.Enabled = true
	CameraController.MenuOpen = true
	LoadoutUi.Refresh()
end

function LoadoutUi.Close()
	if gui then
		gui.Enabled = false
	end
	CameraController.MenuOpen = false
end

function LoadoutUi.IsOpen()
	return gui ~= nil and gui.Enabled
end

return LoadoutUi
