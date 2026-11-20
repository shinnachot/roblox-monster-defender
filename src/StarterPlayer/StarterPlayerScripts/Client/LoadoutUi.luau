-- LoadoutUi: หน้าคลังอาวุธใน Lobby (GDD ข้อ 3) — จัด loadout 12 แต้ม + อัพเกรดไอเท็ม
-- ซ้าย: แต้มที่ใช้ (แถบ 12 ช่อง) + ช่องอุปกรณ์ที่เลือกแล้ว (อาวุธ 1–5 ตามลำดับปุ่ม, ลูกธนู, เกราะ, ไอเท็มเสริม)
-- ขวา: แท็บกรองประเภท + การ์ดไอเท็ม (โมเดล 3D นิ่ง) + แผงรายละเอียด/อัพเกรดของการ์ดที่เลือก
-- ลูกธนู: ไม่มีการ์ด — โผล่ในช่องซ้ายเมื่อใส่ธนู (เริ่ม 1 ชุด = 12 ดอก, ปุ่ม + ชุดละ 1 แต้ม)
-- บันทึกอัตโนมัติเมื่อ loadout ถูกกติกา; server ตรวจทุกอย่างซ้ำ (Remotes.SetLoadout / UpgradeItem)
local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Assets = ReplicatedStorage:WaitForChild("Assets")
local CameraController = require(script.Parent:WaitForChild("CameraController"))

local LoadoutUi = {}

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local FONT_REGULAR = Font.fromEnum(Enum.Font.GothamMedium)
local PANEL_COLOR = Color3.fromRGB(20, 23, 30)
local ROW_COLOR = Color3.fromRGB(34, 38, 48)
local EMPTY_COLOR = Color3.fromRGB(27, 30, 39)
local CARD_COLOR = Color3.fromRGB(34, 38, 50)
local CARD_ON = Color3.fromRGB(28, 48, 78)
local DARK = Color3.fromRGB(14, 16, 21)
local BLUE = Color3.fromRGB(45, 145, 255)
local ACCENT = Color3.fromRGB(255, 196, 64)
local GREEN = Color3.fromRGB(110, 220, 120)
local RED = Color3.fromRGB(255, 110, 100)
local MUTED = Color3.fromRGB(150, 156, 168)
local ARROWS = "ExtraArrows"

local REASON_TEXT = {
	Points = "แต้มเกิน 12",
	Weapons = "ต้องมีอาวุธ 1–5 ชิ้น",
	Armor = "ใส่เกราะได้ชุดเดียว",
	Duplicate = "ใส่ไอเท็มนี้ซ้ำไม่ได้",
	Locked = "มีไอเท็มที่ยังไม่ปลดล็อค",
	Unavailable = "มีไอเท็มที่ยังใช้ไม่ได้",
	NeedsBow = "ลูกธนูต้องใส่คู่กับธนู",
	NoArrows = "ธนูต้องมีลูกธนูอย่างน้อย 1 ชุด",
	InMatch = "จัด Loadout ได้เฉพาะใน Lobby",
	NotEnoughParts = "ชิ้นส่วนไม่พอ",
	MaxLevel = "เลเวลเต็มแล้ว",
	Busy = "รอสักครู่",
	NotLoaded = "กำลังโหลดข้อมูลผู้เล่น...",
}

local TABS = {
	{ Id = "All", Text = "ทั้งหมด" },
	{ Id = "Weapon", Text = "อาวุธ" },
	{ Id = "Armor", Text = "เกราะ" },
	{ Id = "Consumable", Text = "ไอเท็ม" },
}
local KIND_TEXT = { Weapon = "อาวุธ", Armor = "เกราะ", Consumable = "ไอเท็มเสริม", Ammo = "ลูกธนู" }

local player = Players.LocalPlayer
local gui
local profile -- snapshot ล่าสุดจาก server
local draft -- loadout ที่กำลังจัด (รายการ id; ลำดับอาวุธ = ปุ่ม 1–5)
local cards = {} -- [itemId] = ui refs
local tabs = {} -- [tabId] = ปุ่ม
local filter = "All"
local selectedId = nil
local busy, pendingSave, saveError = false, false, nil
local saveToken = 0
local message, messageIsError, messageUntil = "", false, 0

-- ui refs
local pointsLabel, pointsSub, segments, slotList, statusLabel
local detail = {}
-- มือถือ (จอเตี้ย): แสดงทีละหน้า "Equipped" (แต้ม + ช่องที่ใส่) / "Inventory" (การ์ด + รายละเอียด)
local compact = false
local pages, pageTabs = {}, {}
local page = "Equipped"

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
	props.FontFace = props.FontFace or FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	return make("TextLabel", props, parent)
end

local function button(props, parent, radius)
	props.FontFace = FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.BorderSizePixel = 0
	props.AutoButtonColor = props.AutoButtonColor ~= false
	local b = make("TextButton", props, parent)
	corner(b, radius or 8)
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

-- โมเดลจริงของไอเท็มแบบนิ่ง (อาวุธวางเฉียง 45 องศาให้เต็มกรอบ, เกราะมองจากด้านหน้าเฉียงนิดหน่อย)
-- หรือไอคอนถ้าไม่มีโมเดล
local function buildPreview(parent, item)
	local isArmor = item.Kind == "Armor"
	local folder = Assets:WaitForChild(isArmor and "Armors" or "Weapons", 5)
	local template = item.Model and folder and folder:FindFirstChild(item.Model)
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
	if isArmor then
		-- ด้านหน้าของเกราะ = -Z ของชิ้นลำตัว (PrimaryPart)
		local front = model.PrimaryPart and model.PrimaryPart.CFrame or cf
		local center = cf.Position
		local fit = math.max(size.X, size.Y, size.Z) / (2 * math.tan(math.rad(15))) * 1.25
		local dir = (front.LookVector + front.RightVector * 0.45 + Vector3.new(0, 0.25, 0)).Unit
		camera.CFrame = CFrame.lookAt(center + dir * fit, center)
		viewport.CurrentCamera = camera
		return
	end
	local distance = math.max(length, axes[2][1] * 1.6) / (2 * math.tan(math.rad(15))) * 0.85
	camera.CFrame = CFrame.lookAt(cf.Position + viewDir * distance, cf.Position, longDir) * CFrame.Angles(0, 0, math.rad(45))
	viewport.CurrentCamera = camera
end

LoadoutUi.BuildPreview = buildPreview -- ใช้ซ้ำในหน้าเปิดหีบ (RewardUi)

---------------------------------------------------------------- กติกาการจัด (ฝั่ง UI)

local function setMessage(textValue, isError)
	message = textValue or ""
	messageIsError = isError == true
	messageUntil = message ~= "" and os.clock() + 3 or 0
	if message ~= "" then
		task.delay(3.1, function()
			LoadoutUi.Refresh()
		end)
	end
end

local function isLocked(id)
	local item = Config.Items[id]
	return not Progression.IsUnlocked(id, profile.Exp) or item.Available == false
end

local function weaponCount()
	local n = 0
	for _, id in draft do
		if Config.Items[id].Kind == "Weapon" then
			n += 1
		end
	end
	return n
end

local save -- ประกาศล่วงหน้า (scheduleSave เรียก)
local showPage -- ประกาศล่วงหน้า (แถวช่องอุปกรณ์เรียก)

-- เปลี่ยน draft แล้ว: วาดใหม่ + บันทึกอัตโนมัติหลังหยุดกดสักครู่
local function changed()
	saveError = nil
	saveToken += 1
	local mine = saveToken
	LoadoutUi.Refresh()
	task.delay(0.6, function()
		if mine == saveToken then
			save()
		end
	end)
end

local function addItem(id)
	local item = Config.Items[id]
	if not item or isLocked(id) then
		return
	end
	local points = Config.Loadout.Points
	local used = Progression.LoadoutCost(draft)
	if item.Kind == "Ammo" then
		if not table.find(draft, "Bow") then
			return
		end
		if used + item.Cost > points then
			setMessage("แต้มไม่พอ", true)
			LoadoutUi.Refresh()
			return
		end
		table.insert(draft, id)
		changed()
		return
	end
	if table.find(draft, id) then
		return
	end
	-- เกราะใส่ได้ชุดเดียว: ชุดเดิมถูกแทนที่ (คืนแต้มก่อนคิด)
	local replaced = nil
	if item.Kind == "Armor" then
		for _, other in draft do
			if Config.Items[other].Kind == "Armor" then
				replaced = other
			end
		end
	end
	local need = item.Cost + (id == "Bow" and Config.Items[ARROWS].Cost or 0)
	local free = points - used + (replaced and Config.Items[replaced].Cost or 0)
	if need > free then
		setMessage(string.format("แต้มไม่พอ — ต้องการอีก %d แต้ม", need - free), true)
		LoadoutUi.Refresh()
		return
	end
	if item.Kind == "Weapon" and weaponCount() >= Config.Loadout.MaxWeapons then
		setMessage(string.format("ใส่อาวุธได้สูงสุด %d ชิ้น", Config.Loadout.MaxWeapons), true)
		LoadoutUi.Refresh()
		return
	end
	if replaced then
		table.remove(draft, table.find(draft, replaced))
	end
	table.insert(draft, id)
	if id == "Bow" then
		table.insert(draft, ARROWS) -- ธนูมาพร้อมลูกธนู 1 ชุด
	end
	changed()
end

local function removeItem(id)
	local item = Config.Items[id]
	if item.Kind == "Ammo" then
		-- ลูกธนูต้องเหลืออย่างน้อย 1 ชุดตราบที่มีธนู
		if count(draft, id) > 1 then
			table.remove(draft, table.find(draft, id))
			changed()
		end
		return
	end
	for i = #draft, 1, -1 do
		if draft[i] == id or (id == "Bow" and draft[i] == ARROWS) then
			table.remove(draft, i)
		end
	end
	changed()
end

function save()
	if not profile or same(draft, profile.Loadout) then
		LoadoutUi.Refresh()
		return
	end
	if not Progression.ValidateLoadout(draft, profile.Exp) then
		LoadoutUi.Refresh() -- แสดงเหตุผลที่บันทึกไม่ได้
		return
	end
	if busy then
		pendingSave = true
		return
	end
	busy = true
	LoadoutUi.Refresh()
	local sent = table.clone(draft)
	local ok, reason = Remotes.SetLoadout:InvokeServer(sent)
	busy = false
	if ok then
		profile.Loadout = sent
		saveError = nil
	elseif reason == "Busy" then
		pendingSave = true
	else
		saveError = reason
	end
	if pendingSave then
		pendingSave = false
		task.delay(0.3, save)
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

local function selectItem(id)
	selectedId = id
	LoadoutUi.Refresh()
end

local function setFilter(tabId)
	filter = tabId
	LoadoutUi.Refresh()
end

-- มือถือ: สลับหน้า (คอมแสดงทั้งสองฝั่งพร้อมกัน -> ไม่ทำอะไร)
function showPage(name)
	if not compact then
		return
	end
	page = name
	for id, frame in pages do
		frame.Visible = id == name
	end
	for id, tab in pageTabs do
		local on = id == name
		tab.BackgroundColor3 = on and BLUE or Color3.fromRGB(38, 42, 54)
		tab.TextColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(200, 205, 215)
	end
end

---------------------------------------------------------------- ช่องอุปกรณ์ด้านซ้าย

local function clearRows()
	for _, child in slotList:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function iconBox(parent, id, keyNumber)
	local box = make("Frame", { Size = UDim2.fromOffset(34, 34), Position = UDim2.new(0, 4, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = Color3.fromRGB(52, 60, 78), BorderSizePixel = 0 }, parent)
	corner(box, 7)
	buildPreview(box, Config.Items[id])
	if keyNumber then
		local key = text({ Size = UDim2.fromOffset(15, 15), Position = UDim2.fromOffset(-3, -3), Text = tostring(keyNumber), TextSize = 10, BackgroundTransparency = 0, BackgroundColor3 = BLUE, ZIndex = 3 }, box)
		corner(key, 4)
	end
	return box
end

local function filledRow(id, order, keyNumber)
	local item = Config.Items[id]
	local row = button({ Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = id == selectedId and Color3.fromRGB(40, 50, 68) or ROW_COLOR, Text = "", LayoutOrder = order, AutoButtonColor = false }, slotList)
	iconBox(row, id, keyNumber)
	text({ Size = UDim2.new(1, -150, 1, 0), Position = UDim2.fromOffset(48, 0), Text = item.Name, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, row)
	local cost = text({ Size = UDim2.fromOffset(54, 22), Position = UDim2.new(1, -96, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Text = item.Cost .. " แต้ม", TextSize = 12, TextColor3 = Color3.fromRGB(205, 210, 220), BackgroundTransparency = 0, BackgroundColor3 = DARK }, row)
	corner(cost, 11)
	local remove = button({ Size = UDim2.fromOffset(32, 32), Position = UDim2.new(1, -4, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), Text = "X", TextSize = 15, BackgroundColor3 = Color3.fromRGB(48, 53, 66) }, row)
	remove.Activated:Connect(function()
		removeItem(id)
	end)
	row.Activated:Connect(function()
		selectItem(id)
		showPage("Inventory") -- มือถือ: ไปดูรายละเอียด/อัพเกรด
	end)
end

local function emptyRow(label, order, highlight, tabId)
	local row = button({ Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = EMPTY_COLOR, Text = "", LayoutOrder = order, AutoButtonColor = true }, slotList)
	local plus = text({ Size = UDim2.fromOffset(26, 26), Position = UDim2.new(0, 8, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Text = "+", TextSize = 18, TextColor3 = highlight and Color3.new(1, 1, 1) or MUTED, BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(44, 49, 62) }, row)
	corner(plus, 13)
	text({ Size = UDim2.new(1, -50, 1, 0), Position = UDim2.fromOffset(46, 0), Text = label, TextSize = 14, FontFace = FONT_REGULAR, TextColor3 = highlight and Color3.fromRGB(215, 220, 230) or MUTED, TextXAlignment = Enum.TextXAlignment.Left }, row)
	if tabId then
		row.Activated:Connect(function()
			setFilter(tabId)
			showPage("Inventory") -- มือถือ: ไปเลือกจากคลัง
		end)
	end
end

local function arrowRow(order)
	local item = Config.Items[ARROWS]
	local bundles = count(draft, ARROWS)
	local row = make("Frame", { Size = UDim2.new(1, 0, 0, 46), BackgroundColor3 = ROW_COLOR, BorderSizePixel = 0, LayoutOrder = order }, slotList)
	corner(row, 8)
	iconBox(row, ARROWS)
	local name = text({ Size = UDim2.new(1, -170, 0, 22), Position = UDim2.fromOffset(48, 3), Text = "", RichText = true, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left }, row)
	name.Text = string.format('%s <font color="#FFC440">×%d</font>', item.Name, bundles * item.Arrows)
	text({ Size = UDim2.new(1, -170, 0, 16), Position = UDim2.fromOffset(48, 25), Text = string.format("%d ดอกต่อชุด · ชุดละ %d แต้ม", item.Arrows, item.Cost), TextSize = 11, FontFace = FONT_REGULAR, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left }, row)
	local canAdd = Progression.LoadoutCost(draft) + item.Cost <= Config.Loadout.Points
	local minus = button({ Size = UDim2.fromOffset(32, 32), Position = UDim2.new(1, -112, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Text = "−", TextSize = 20, BackgroundColor3 = Color3.fromRGB(48, 53, 66), TextColor3 = bundles > 1 and Color3.new(1, 1, 1) or MUTED }, row)
	text({ Size = UDim2.fromOffset(40, 32), Position = UDim2.new(1, -78, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Text = tostring(bundles), TextSize = 18 }, row)
	local plus = button({ Size = UDim2.fromOffset(32, 32), Position = UDim2.new(1, -4, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), Text = "+", TextSize = 20, BackgroundColor3 = canAdd and Color3.fromRGB(48, 53, 66) or Color3.fromRGB(36, 39, 48), TextColor3 = canAdd and Color3.new(1, 1, 1) or MUTED }, row)
	minus.Activated:Connect(function()
		removeItem(ARROWS)
	end)
	plus.Activated:Connect(function()
		addItem(ARROWS)
	end)
end

local function refreshSlots()
	clearRows()
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end
	-- อาวุธตามลำดับปุ่ม 1–5 แล้วตามด้วยช่องว่าง
	local weapons, armor, extras = {}, nil, {}
	for _, id in draft do
		local kind = Config.Items[id].Kind
		if kind == "Weapon" then
			table.insert(weapons, id)
		elseif kind == "Armor" then
			armor = id
		elseif kind == "Consumable" then
			table.insert(extras, id)
		end
	end
	for index, id in weapons do
		filledRow(id, nextOrder(), index)
	end
	for index = #weapons + 1, Config.Loadout.MaxWeapons do
		emptyRow(index == #weapons + 1 and (compact and "แตะเพื่อเลือกอาวุธจากคลัง" or "เลือกอาวุธทางขวา") or "ว่าง", nextOrder(), index == #weapons + 1, "Weapon")
	end
	if table.find(draft, "Bow") then
		arrowRow(nextOrder())
	end
	if armor then
		filledRow(armor, nextOrder())
	else
		emptyRow("เกราะ (ไม่ใส่ก็ได้)", nextOrder(), false, "Armor")
	end
	for _, id in extras do
		filledRow(id, nextOrder())
	end
	if #extras == 0 then
		emptyRow("ไอเท็มเสริม (ไม่ใส่ก็ได้)", nextOrder(), false, "Consumable")
	end
end

---------------------------------------------------------------- การ์ดด้านขวา

local function buildCard(id, grid)
	local item = Config.Items[id]
	local frame = button({ Name = id, Text = "", AutoButtonColor = false, LayoutOrder = item.Order, BackgroundColor3 = CARD_COLOR }, grid, 10)
	local stroke = make("UIStroke", { Thickness = 2, Color = BLUE, Enabled = false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, frame)
	local preview = make("Frame", { Size = UDim2.new(1, -20, 0, 70), Position = UDim2.fromOffset(10, 26), BackgroundTransparency = 1 }, frame)
	buildPreview(preview, item)
	local level = text({ Size = UDim2.fromOffset(40, 20), Position = UDim2.fromOffset(8, 8), Text = "", TextSize = 11, BackgroundTransparency = 0, BackgroundColor3 = DARK, ZIndex = 3 }, frame)
	corner(level, 10)
	local cost = text({ Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -8, 0, 6), AnchorPoint = Vector2.new(1, 0), Text = tostring(item.Cost), TextSize = 13, BackgroundTransparency = 0, BackgroundColor3 = DARK, ZIndex = 3 }, frame)
	corner(cost, 12)
	text({ Size = UDim2.new(1, -16, 0, 20), Position = UDim2.fromOffset(9, 100), Text = item.Name, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3 }, frame)
	local status = text({ Size = UDim2.new(1, -16, 0, 16), Position = UDim2.fromOffset(9, 121), Text = "", TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3 }, frame)
	local dim = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 2, Visible = false }, frame)
	corner(dim, 10)
	cards[id] = { Frame = frame, Stroke = stroke, Level = level, Status = status, Dim = dim }

	-- คลิก = ดูรายละเอียด + สลับใส่/ถอด (ใส่อยู่ -> ถอดออก, ยังไม่ได้ใส่และใส่ได้ -> ใส่)
	frame.Activated:Connect(function()
		selectedId = id
		if isLocked(id) then
			LoadoutUi.Refresh()
		elseif table.find(draft, id) then
			removeItem(id)
		else
			addItem(id)
		end
	end)
end

local function refreshCards()
	local free = Config.Loadout.Points - Progression.LoadoutCost(draft)
	for id, card in cards do
		local item = Config.Items[id]
		card.Frame.Visible = filter == "All" or item.Kind == filter
		local equipped = table.find(draft, id) ~= nil
		local locked = isLocked(id)
		local lv = profile.Levels[id] or 0
		card.Level.Visible = item.Upgradable == true and not locked
		local max = lv >= Progression.MaxLevel()
		card.Level.Text = max and "MAX" or ("Lv " .. lv)
		card.Level.BackgroundColor3 = max and ACCENT or DARK
		card.Level.TextColor3 = max and DARK or Color3.new(1, 1, 1)
		card.Dim.Visible = locked
		card.Frame.BackgroundColor3 = equipped and CARD_ON or CARD_COLOR
		card.Stroke.Enabled = equipped or id == selectedId
		card.Stroke.Color = id == selectedId and Color3.new(1, 1, 1) or BLUE

		-- ข้อความล่างการ์ด
		local need = item.Cost + (id == "Bow" and Config.Items[ARROWS].Cost or 0)
		if item.Kind == "Armor" then
			for _, other in draft do
				if Config.Items[other].Kind == "Armor" then
					need -= Config.Items[other].Cost
				end
			end
		end
		if item.Available == false then
			card.Status.Text, card.Status.TextColor3 = "เร็ว ๆ นี้", MUTED
		elseif locked then
			card.Status.Text, card.Status.TextColor3 = "🔒 ปลดล็อคที่ " .. item.Rank, MUTED
		elseif equipped then
			card.Status.Text, card.Status.TextColor3 = "✓ ใส่อยู่ · แตะเพื่อถอด", BLUE
		elseif need > free then
			card.Status.Text, card.Status.TextColor3 = string.format("ต้องการอีก %d แต้ม", need - free), MUTED
		elseif item.Kind == "Armor" and need < item.Cost then
			card.Status.Text, card.Status.TextColor3 = "แตะเพื่อเปลี่ยนชุด", Color3.fromRGB(200, 205, 215)
		else
			card.Status.Text, card.Status.TextColor3 = "แตะเพื่อใส่", Color3.fromRGB(200, 205, 215)
		end
	end
	for tabId, tab in tabs do
		local on = tabId == filter
		tab.BackgroundColor3 = on and BLUE or Color3.fromRGB(38, 42, 54)
		tab.TextColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(200, 205, 215)
	end
end

---------------------------------------------------------------- แผงรายละเอียด

-- ค่าสถานะในแผงรายละเอียด คำนวณจาก Config จริง (รวมโบนัสเลเวลอัพเกรด): { { ชื่อ, แถบ 0..1, ข้อความ } }
local BASE_WALK = 16 -- ความเร็วเดินปกติของ Humanoid
local function statsFor(id, level)
	local item = Config.Items[id]
	local bonus = Progression.Bonus(level)
	if item.Kind == "Armor" then
		local armor = Config.Armors[id]
		if not armor then
			return {}
		end
		local value = math.round(armor.Durability * bonus)
		return { { "ค่าเกราะ", value / 100, tostring(value) } }
	elseif item.Kind == "Consumable" then
		return { { "ฟื้น HP", (item.Heal or 0) / 100, string.format("+%d × %d ขวด", item.Heal or 0, item.Charges or 1) } }
	end
	local w = Config.Weapons[id]
	if not w then
		return {} -- อาวุธที่ยังไม่มีระบบต่อสู้
	end
	local minDamage, maxDamage, speedScore, speedText, range, slowWalk, slowText
	if w.Kind == "Melee" then
		local total = 0
		minDamage, maxDamage = math.huge, 0
		for _, hit in w.Combo do
			minDamage = math.min(minDamage, hit.Damage)
			maxDamage = math.max(maxDamage, hit.Damage)
			total += hit.Windup + hit.Strike + hit.Recover
		end
		local perSecond = #w.Combo / total
		speedScore, speedText = perSecond / 3, string.format("%.1f ครั้ง/วิ", perSecond)
		range = w.Range
		slowWalk, slowText = w.Shield and w.Shield.WalkSpeed, "ยกโล่"
	else
		minDamage, maxDamage = w.MinDamage, w.MaxDamage
		speedScore, speedText = 1 / w.ChargeTime / 3, string.format("ง้างสุด %.1f วิ", w.ChargeTime)
		range = w.MaxSpeed ^ 2 / w.Gravity -- ระยะไกลสุดบนพื้นราบ
		slowWalk, slowText = w.DrawWalkSpeed, "ตอนง้าง"
	end
	minDamage, maxDamage = math.round(minDamage * bonus), math.round(maxDamage * bonus)
	local rangeText = range >= 100 and string.format("~%d studs", math.round(range / 100) * 100) or string.format("%g studs", range)
	return {
		{ "ดาเมจ", maxDamage / 50, string.format("%d–%d", minDamage, maxDamage) },
		{ "ความเร็ว", speedScore, speedText },
		{ "ระยะ", math.log10(range) / 3, rangeText },
		{ "ความเร็ววิ่ง", (slowWalk or BASE_WALK) / BASE_WALK, slowWalk and string.format("%s %d", slowText, slowWalk) or "ปกติ" },
	}
end

local function refreshDetail()
	local id = selectedId
	local item = id and Config.Items[id]
	detail.Root.Visible = item ~= nil
	if not item then
		return
	end
	if detail.ShownId ~= id then
		detail.ShownId = id
		for _, child in detail.Preview:GetChildren() do
			if not child:IsA("UICorner") then
				child:Destroy()
			end
		end
		buildPreview(detail.Preview, item)
	end
	detail.Name.Text = item.Name

	local locked = isLocked(id)
	local lv = profile.Levels[id] or 0
	local parts = { KIND_TEXT[item.Kind] or item.Kind, item.Cost .. " แต้ม" }
	if item.Upgradable then
		local bonus = math.round(lv * Config.Upgrade.BonusPerLevel * 100)
		table.insert(parts, 1, string.format("Lv %d", lv))
		if bonus > 0 then
			table.insert(parts, 2, string.format("+%d%% %s", bonus, item.Kind == "Armor" and "เกราะ" or "ดาเมจ"))
		end
	end
	detail.Info.Text = table.concat(parts, "  ·  ")
	detail.Desc.Text = item.Desc or ""
	local stats = statsFor(id, lv)
	for index, ui in detail.Stats do
		local stat = stats[index]
		ui.Cell.Visible = stat ~= nil
		if stat then
			ui.Label.Text = stat[1]
			ui.Fill.Size = UDim2.fromScale(math.clamp(stat[2], 0.03, 1), 1)
			ui.Value.Text = stat[3]
		end
	end

	-- ชิ้นส่วน / อัพเกรด
	local costParts = Progression.UpgradeCost(id, lv)
	local have = profile.Parts[id] or 0
	local canUpgrade = costParts ~= nil and have >= costParts and not locked
	detail.PartsBack.Visible = item.Upgradable == true
	detail.Upgrade.Visible = item.Upgradable == true
	if costParts then
		detail.PartsFill.Size = UDim2.fromScale(math.clamp(have / costParts, 0, 1), 1)
		detail.PartsLabel.Text = string.format("ชิ้นส่วน %d / %d", have, costParts)
		detail.Upgrade.Text = canUpgrade and string.format("อัพเกรด → Lv %d", lv + 1) or "ชิ้นส่วนไม่พอ"
	else
		detail.PartsFill.Size = UDim2.fromScale(1, 1)
		detail.PartsLabel.Text = string.format("เต็ม (%d)", have)
		detail.Upgrade.Text = "เลเวลเต็ม"
	end
	detail.CanUpgrade = canUpgrade
	detail.Upgrade.AutoButtonColor = canUpgrade
	detail.Upgrade.BackgroundColor3 = canUpgrade and Color3.fromRGB(215, 150, 35) or Color3.fromRGB(48, 53, 66)
	detail.Upgrade.TextColor3 = canUpgrade and Color3.new(1, 1, 1) or MUTED

	-- ใส่ / ถอด
	local equipped = table.find(draft, id) ~= nil
	local action = detail.Action
	if item.Available == false then
		action.Text, action.BackgroundColor3 = "เร็ว ๆ นี้", Color3.fromRGB(48, 53, 66)
	elseif locked then
		action.Text, action.BackgroundColor3 = "🔒 " .. item.Rank, Color3.fromRGB(48, 53, 66)
	elseif equipped then
		action.Text, action.BackgroundColor3 = "ถอดออก", Color3.fromRGB(60, 66, 82)
	else
		action.Text, action.BackgroundColor3 = "ใส่", BLUE
	end
end

---------------------------------------------------------------- วาดใหม่ทั้งหน้า

function LoadoutUi.Refresh()
	if not gui or not profile or not draft then
		return
	end
	local points = Config.Loadout.Points
	local used = Progression.LoadoutCost(draft)
	local over = used > points
	pointsLabel.Text = string.format("%d / %d", used, points)
	pointsLabel.TextColor3 = over and RED or Color3.new(1, 1, 1)
	pointsSub.Text = string.format("ใช้ไป %d จาก %d แต้ม · เหลือ %d", used, points, math.max(0, points - used))
	for index, segment in segments do
		segment.BackgroundColor3 = index <= used and (over and RED or BLUE) or Color3.fromRGB(40, 44, 56)
	end
	if pageTabs.Equipped then
		pageTabs.Equipped.Text = string.format("ที่ใส่อยู่ %d/%d", used, points)
	end

	refreshSlots()
	refreshCards()
	refreshDetail()

	-- สถานะการบันทึก (มุมขวาบนของแท็บ)
	local valid, reason = Progression.ValidateLoadout(draft, profile.Exp)
	local textValue, color
	if os.clock() < messageUntil then
		textValue, color = message, messageIsError and RED or GREEN
	elseif not valid then
		textValue, color = (REASON_TEXT[reason] or "Loadout ไม่ถูกต้อง") .. " — ยังไม่บันทึก", RED
	elseif saveError then
		textValue, color = (REASON_TEXT[saveError] or "บันทึกไม่ได้"), RED
	elseif busy or not same(draft, profile.Loadout) then
		textValue, color = "กำลังบันทึก...", ACCENT
	else
		textValue, color = "✓ บันทึกแล้ว", GREEN
	end
	statusLabel.Text = textValue
	statusLabel.TextColor3 = color
end

---------------------------------------------------------------- สร้างหน้า

local PANEL_SIZE = Vector2.new(980, 620)
local LEFT_W = 330
-- มือถือแนวนอน (จอเตี้ย): หน้าต่างเล็กลงและแสดงทีละหน้า (ที่ใส่อยู่ / คลัง) — ย่อน้อยลง ตัวหนังสืออ่านออก
-- (หน้าเต็ม 980×620 บนจอสูง 338 ถูกย่อเหลือ 0.41 เท่า ตัวหนังสือเหลือ 4-6 px)
local COMPACT_SIZE = Vector2.new(640, 340)
local COMPACT_MAX_HEIGHT = 520

-- ตำแหน่งชิ้นส่วนในแผงรายละเอียด: คอม = แถวยาวใต้ตาราง, มือถือ = คอลัมน์แคบข้างตาราง
local DETAIL_LAYOUT = {
	Wide = {
		Preview = { UDim2.fromOffset(76, 76), UDim2.fromOffset(12, 12) },
		Name = { UDim2.fromOffset(140, 22), UDim2.fromOffset(98, 10), 17 },
		Info = { UDim2.fromOffset(140, 14), UDim2.fromOffset(98, 34), 11 },
		Desc = { UDim2.fromOffset(140, 60), UDim2.fromOffset(98, 52), 10 },
		Stat = { Width = 212, X = 252, Y = 12, Step = 26, Height = 22, LabelW = 66, BarX = 68, BarW = 62, ValueW = 78, TextSize = 11 },
		Action = { UDim2.fromOffset(100, 40), UDim2.new(1, -12, 0, 12), Vector2.new(1, 0), 16 },
		Upgrade = { UDim2.fromOffset(100, 30), UDim2.new(1, -12, 0, 58), Vector2.new(1, 0), 11 },
		Parts = { UDim2.fromOffset(100, 14), UDim2.new(1, -12, 0, 96), Vector2.new(1, 0), 9 },
	},
	Compact = {
		Preview = { UDim2.fromOffset(60, 60), UDim2.fromOffset(10, 10) },
		Name = { UDim2.fromOffset(98, 22), UDim2.fromOffset(76, 10), 16 },
		Info = { UDim2.fromOffset(98, 32), UDim2.fromOffset(76, 34), 11 },
		Desc = { UDim2.fromOffset(160, 44), UDim2.fromOffset(10, 76), 11 },
		Stat = { Width = 160, X = 10, Y = 124, Step = 21, Height = 20, LabelW = 58, BarX = 58, BarW = 30, ValueW = 72, TextSize = 11 },
		Action = { UDim2.fromOffset(76, 36), UDim2.fromOffset(10, 210), Vector2.zero, 15 },
		Upgrade = { UDim2.fromOffset(78, 36), UDim2.fromOffset(92, 210), Vector2.zero, 11 },
		Parts = { UDim2.fromOffset(160, 16), UDim2.fromOffset(10, 254), Vector2.zero, 10 },
	},
}

local function buildDetail(box)
	local L = compact and DETAIL_LAYOUT.Compact or DETAIL_LAYOUT.Wide
	detail.Root = box
	detail.Preview = make("Frame", { Size = L.Preview[1], Position = L.Preview[2], BackgroundColor3 = Color3.fromRGB(40, 58, 86), BorderSizePixel = 0 }, box)
	corner(detail.Preview, 10)
	detail.Name = text({ Size = L.Name[1], Position = L.Name[2], Text = "", TextSize = L.Name[3], TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, box)
	detail.Info = text({ Size = L.Info[1], Position = L.Info[2], Text = "", TextSize = L.Info[3], TextColor3 = Color3.fromRGB(110, 175, 255), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = compact, TextTruncate = compact and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd }, box)
	detail.Desc = text({ Size = L.Desc[1], Position = L.Desc[2], Text = "", TextSize = L.Desc[3], FontFace = FONT_REGULAR, TextColor3 = Color3.fromRGB(200, 205, 215), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top }, box)
	detail.Stats = {}
	local S = L.Stat
	for index = 1, 4 do
		local cell = make("Frame", { Size = UDim2.fromOffset(S.Width, S.Height), Position = UDim2.fromOffset(S.X, S.Y + (index - 1) * S.Step), BackgroundTransparency = 1 }, box)
		local label = text({ Size = UDim2.fromOffset(S.LabelW, S.Height), Text = "", TextSize = S.TextSize, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left }, cell)
		local back = make("Frame", { Size = UDim2.fromOffset(S.BarW, 8), Position = UDim2.new(0, S.BarX, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = DARK, BorderSizePixel = 0 }, cell)
		corner(back, 4)
		local fill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(80, 190, 255), BorderSizePixel = 0 }, back)
		corner(fill, 4)
		local value = text({ Size = UDim2.fromOffset(S.ValueW, S.Height), Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0), Text = "", TextSize = S.TextSize, TextXAlignment = Enum.TextXAlignment.Right }, cell)
		detail.Stats[index] = { Cell = cell, Label = label, Fill = fill, Value = value }
	end
	detail.Action = button({ Size = L.Action[1], Position = L.Action[2], AnchorPoint = L.Action[3], Text = "", TextSize = L.Action[4], BackgroundColor3 = BLUE }, box, 10)
	detail.Upgrade = button({ Size = L.Upgrade[1], Position = L.Upgrade[2], AnchorPoint = L.Upgrade[3], Text = "", TextSize = L.Upgrade[4], TextWrapped = true, BackgroundColor3 = Color3.fromRGB(48, 53, 66) }, box, 8)
	detail.PartsBack = make("Frame", { Size = L.Parts[1], Position = L.Parts[2], AnchorPoint = L.Parts[3], BackgroundColor3 = DARK, BorderSizePixel = 0 }, box)
	corner(detail.PartsBack, 7)
	detail.PartsFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(110, 170, 255), BorderSizePixel = 0 }, detail.PartsBack)
	corner(detail.PartsFill, 7)
	detail.PartsLabel = text({ Size = UDim2.fromScale(1, 1), Text = "", TextSize = L.Parts[4], ZIndex = 2 }, detail.PartsBack)
end

local function build()
	gui = make("ScreenGui", { Name = "LoadoutUi", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 10, Enabled = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
	make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0 }, gui)

	compact = workspace.CurrentCamera.ViewportSize.Y < COMPACT_MAX_HEIGHT
	local size = compact and COMPACT_SIZE or PANEL_SIZE
	local panel = make("Frame", { Size = UDim2.fromOffset(size.X, size.Y), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = PANEL_COLOR, BorderSizePixel = 0 }, gui)
	corner(panel, 16)
	make("UIStroke", { Color = Color3.fromRGB(50, 56, 72), Thickness = 1.5 }, panel)
	-- ย่อให้พอดีจอเล็ก (มือถือ)
	local scale = make("UIScale", {}, panel)
	local function fit()
		local view = workspace.CurrentCamera.ViewportSize
		-- เว้นแถบปุ่มของ Roblox ด้านบน (inset) ไม่ให้ทับหัวหน้าต่าง
		local inset = GuiService:GetGuiInset().Y
		local margin = compact and 8 or 24
		scale.Scale = math.min(compact and 1.2 or 1, (view.X - margin) / size.X, (view.Y - inset - margin) / size.Y)
		panel.Position = UDim2.new(0.5, 0, 0.5, inset / 2)
	end
	fit()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)

	-- หัว
	local close = button({ Size = UDim2.fromOffset(44, 44), Position = UDim2.new(1, compact and -8 or -16, 0, compact and 6 or 12), AnchorPoint = Vector2.new(1, 0), Text = "X", TextSize = 22, BackgroundColor3 = Color3.fromRGB(40, 44, 56) }, panel, 10)
	close.Activated:Connect(LoadoutUi.Close)
	local left, right
	if compact then
		-- แท็บหน้า: ที่ใส่อยู่ / คลัง
		local pageBar = make("Frame", { Size = UDim2.fromOffset(330, 40), Position = UDim2.fromOffset(12, 8), BackgroundTransparency = 1 }, panel)
		make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, pageBar)
		for index, id in { "Equipped", "Inventory" } do
			local b = button({ Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X, Text = id == "Equipped" and "ที่ใส่อยู่" or "คลัง", TextSize = 17, LayoutOrder = index, BackgroundColor3 = Color3.fromRGB(38, 42, 54) }, pageBar, 20)
			make("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 18) }, b)
			b.Activated:Connect(function()
				showPage(id)
			end)
			pageTabs[id] = b
		end
		statusLabel = text({ Size = UDim2.fromOffset(220, 40), Position = UDim2.new(1, -60, 0, 8), AnchorPoint = Vector2.new(1, 0), Text = "", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, TextWrapped = true }, panel)
		make("Frame", { Size = UDim2.new(1, -24, 0, 1), Position = UDim2.fromOffset(12, 54), BackgroundColor3 = Color3.fromRGB(46, 51, 64), BorderSizePixel = 0 }, panel)
		pages.Equipped = make("Frame", { Size = UDim2.new(1, -24, 1, -70), Position = UDim2.fromOffset(12, 62), BackgroundTransparency = 1 }, panel)
		pages.Inventory = make("Frame", { Size = UDim2.new(1, -24, 1, -70), Position = UDim2.fromOffset(12, 62), BackgroundTransparency = 1, Visible = false }, panel)
		left = make("Frame", { Size = UDim2.new(0, 190, 1, 0), BackgroundTransparency = 1 }, pages.Equipped)
		right = pages.Inventory
	else
		text({ Size = UDim2.fromOffset(300, 40), Position = UDim2.fromOffset(22, 12), Text = "LOADOUT", TextSize = 32, TextXAlignment = Enum.TextXAlignment.Left }, panel)
		text({ Size = UDim2.fromOffset(300, 20), Position = UDim2.fromOffset(170, 24), Text = "คลังอาวุธ", TextSize = 15, FontFace = FONT_REGULAR, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left }, panel)
		make("Frame", { Size = UDim2.new(1, -40, 0, 1), Position = UDim2.fromOffset(20, 64), BackgroundColor3 = Color3.fromRGB(46, 51, 64), BorderSizePixel = 0 }, panel)
		left = make("Frame", { Size = UDim2.new(0, LEFT_W, 1, -86), Position = UDim2.fromOffset(20, 76), BackgroundTransparency = 1 }, panel)
		local rightX = 20 + LEFT_W + 20
		right = make("Frame", { Size = UDim2.new(1, -(rightX + 20), 1, -86), Position = UDim2.fromOffset(rightX, 76), BackgroundTransparency = 1 }, panel)
	end

	-- ซ้าย: แต้ม + ช่องอุปกรณ์ (มือถือ: แต้มเป็นคอลัมน์ซ้าย ช่องอุปกรณ์เลื่อนได้ทางขวา)
	pointsLabel = text({ Size = UDim2.fromOffset(90, 34), Text = "", TextSize = 28, TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.X }, left)
	text({ Size = UDim2.fromOffset(60, 34), Position = UDim2.fromOffset(92, 2), Text = "แต้ม", TextSize = 14, TextColor3 = Color3.fromRGB(200, 205, 215), TextXAlignment = Enum.TextXAlignment.Left }, left)
	local bar = make("Frame", { Size = UDim2.new(1, 0, 0, 10), Position = UDim2.fromOffset(0, 40), BackgroundTransparency = 1 }, left)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, bar)
	segments = {}
	local points = Config.Loadout.Points
	for index = 1, points do
		local segment = make("Frame", { Size = UDim2.new(1 / points, -3 * (points - 1) / points, 1, 0), BackgroundColor3 = Color3.fromRGB(40, 44, 56), BorderSizePixel = 0, LayoutOrder = index }, bar)
		corner(segment, 3)
		segments[index] = segment
	end
	pointsSub = text({ Size = UDim2.new(1, 0, 0, compact and 36 or 16), Position = UDim2.fromOffset(0, 54), Text = "", TextSize = compact and 13 or 12, FontFace = FONT_REGULAR, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = compact }, left)
	if compact then
		slotList = make("ScrollingFrame", {
			Size = UDim2.new(1, -202, 1, 0), Position = UDim2.fromOffset(202, 0), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 4, ScrollBarImageColor3 = Color3.fromRGB(90, 96, 112), AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollingDirection = Enum.ScrollingDirection.Y,
		}, pages.Equipped)
	else
		slotList = make("Frame", { Size = UDim2.new(1, 0, 1, -128), Position = UDim2.fromOffset(0, 78), BackgroundTransparency = 1 }, left)
	end
	make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, slotList)
	local reset = button({ Size = UDim2.fromOffset(140, 36), Position = UDim2.new(0, 0, 1, -36), Text = "ชุดเริ่มต้น", TextSize = 14, BackgroundColor3 = Color3.fromRGB(40, 44, 56), TextColor3 = Color3.fromRGB(205, 210, 220) }, left)
	reset.Activated:Connect(function()
		draft = table.clone(Config.Loadout.Starter)
		changed()
	end)

	-- ขวา: แท็บ + การ์ด + รายละเอียด (มือถือ: รายละเอียดเป็นคอลัมน์ข้างตาราง)
	local DETAIL_W = 180
	local tabBar = make("Frame", { Size = compact and UDim2.new(1, -(DETAIL_W + 12), 0, 34) or UDim2.new(1, -170, 0, 36), BackgroundTransparency = 1 }, right)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, compact and 6 or 8), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)
	for index, tab in TABS do
		local b = button({ Size = UDim2.fromOffset(0, compact and 34 or 36), AutomaticSize = Enum.AutomaticSize.X, Text = tab.Text, TextSize = compact and 15 or 14, LayoutOrder = index, BackgroundColor3 = Color3.fromRGB(38, 42, 54) }, tabBar, 18)
		make("UIPadding", { PaddingLeft = UDim.new(0, compact and 14 or 18), PaddingRight = UDim.new(0, compact and 14 or 18) }, b)
		b.Activated:Connect(function()
			setFilter(tab.Id)
		end)
		tabs[tab.Id] = b
	end
	if not compact then
		statusLabel = text({ Size = UDim2.fromOffset(260, 36), Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0), Text = "", TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, TextWrapped = true }, right)
	end

	local grid = make("ScrollingFrame", {
		Size = compact and UDim2.new(1, -(DETAIL_W + 8), 1, -42) or UDim2.new(1, 0, 1, -180), Position = UDim2.fromOffset(0, compact and 42 or 46), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = compact and 4 or 5, ScrollBarImageColor3 = Color3.fromRGB(90, 96, 112), AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollingDirection = Enum.ScrollingDirection.Y,
	}, right)
	make("UIGridLayout", { CellSize = UDim2.fromOffset(136, 142), CellPadding = UDim2.fromOffset(compact and 6 or 10, compact and 6 or 10), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, compact and 1 or 3), PaddingBottom = UDim.new(0, 3) }, grid)
	for id, item in Config.Items do
		if item.Kind ~= "Ammo" then -- ลูกธนูจัดในช่องซ้ายเท่านั้น
			buildCard(id, grid)
		end
	end

	-- แผงรายละเอียดไอเท็มที่เลือก
	local box = make("Frame", {
		Size = compact and UDim2.new(0, DETAIL_W, 1, 0) or UDim2.new(1, 0, 0, 124),
		Position = compact and UDim2.new(1, 0, 0, 0) or UDim2.new(0, 0, 1, -124),
		AnchorPoint = compact and Vector2.new(1, 0) or Vector2.zero,
		BackgroundColor3 = Color3.fromRGB(28, 32, 42), BorderSizePixel = 0,
	}, right)
	corner(box, 12)
	make("UIStroke", { Color = Color3.fromRGB(48, 54, 70), Thickness = 1 }, box)
	buildDetail(box)
	showPage(page)
	detail.Action.Activated:Connect(function()
		local id = selectedId
		if not id or isLocked(id) then
			return
		end
		if table.find(draft, id) then
			removeItem(id)
		else
			addItem(id)
		end
	end)
	detail.Upgrade.Activated:Connect(function()
		if detail.CanUpgrade and selectedId then
			task.spawn(upgrade, selectedId)
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

---------------------------------------------------------------- เปิด / ปิด

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
	selectedId = selectedId or draft[1]
	saveError = nil
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
