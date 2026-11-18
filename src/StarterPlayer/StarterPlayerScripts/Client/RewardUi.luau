-- RewardUi: หน้าเปิดหีบหลังจบแมตช์ (GDD ข้อ 5) + เอฟเฟกต์เลื่อนแรงก์ (GDD ข้อ 4)
-- server ส่งผลรางวัลมาทาง Remotes.MatchRewards ตอนจบแมตช์ (สุ่มและเซฟไว้แล้ว) — หน้านี้แค่เล่นแอนิเมชัน
-- เปิดเองเมื่อกลับถึง Lobby: หีบสั่น → ฝาเด้งเปิด → การ์ดชิ้นส่วนทีละใบ → แถบ EXP วิ่ง → (rank up) → ตกลง
-- คอม: คลิกหรือกด E / Enter เพื่อเปิดหีบและปิดหน้า; มือถือ: แตะ
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Assets = ReplicatedStorage:WaitForChild("Assets")
local CameraController = require(script.Parent:WaitForChild("CameraController"))
local LoadoutUi = require(script.Parent:WaitForChild("LoadoutUi"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local RewardUi = {}

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local PANEL_COLOR = Color3.fromRGB(24, 26, 32)
local CARD_COLOR = Color3.fromRGB(44, 48, 58)
local ACCENT = Color3.fromRGB(255, 196, 64)
local GREEN = Color3.fromRGB(110, 220, 130)
local RED = Color3.fromRGB(235, 90, 80)
local OPEN_DELAY = 1.2 -- รอหลังกลับ Lobby ก่อนเด้งหน้าหีบ
local AUTO_OPEN = 6 -- ไม่กดเปิดเอง หีบเปิดเองหลังกี่วินาที
local LID_ANGLE = 105

local player = Players.LocalPlayer
local gui, overlay, panel, panelScale, titleLabel, hintLabel, chestHolder, chestButton, rays
local partsRow, expPanel, rankLabel, expFill, expLabel, expDelta, stageLabel, okButton
local rankUp, rankUpScale, rankUpName, rankUpItems, rankUpGlow
local viewport, chestModel, lidClosed, hingeCF
local pending -- ผลรางวัลที่ยังไม่ได้เปิด
local state = "Closed" -- Closed / Waiting / Opening / Done
local openToken = 0

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

local function tween(inst, seconds, props, style, direction)
	local t = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function rankColor(id)
	for _, rank in Config.Ranks do
		if rank.Id == id then
			return rank.Color or ACCENT
		end
	end
	return ACCENT
end

---------------------------------------------------------------- หีบ 3D

local function setLid(angle)
	if chestModel then
		chestModel.Lid.CFrame = hingeCF * CFrame.Angles(math.rad(angle), 0, 0) * hingeCF:Inverse() * lidClosed
	end
end

local function setChestTilt(cf)
	if chestModel then
		chestModel:PivotTo(cf)
		lidClosed = chestModel.Lid.CFrame
	end
end

local function resetChest()
	if viewport then
		viewport:Destroy()
	end
	viewport = make("ViewportFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
		Ambient = Color3.fromRGB(170, 160, 150), LightColor = Color3.new(1, 0.95, 0.85), LightDirection = Vector3.new(0.4, -1, 0.6),
	}, chestHolder)
	chestModel = Assets:WaitForChild("Props"):WaitForChild("RewardChest"):Clone()
	chestModel:PivotTo(CFrame.new())
	chestModel.Parent = viewport
	lidClosed = chestModel.Lid.CFrame
	hingeCF = CFrame.new(chestModel.Base.Hinge.WorldPosition)
	-- หน้าหีบ (ด้านกุญแจ) หันไป -Z: มองจากด้านหน้าเฉียงบนลงมา
	local camera = make("Camera", { FieldOfView = 40 }, viewport)
	camera.CFrame = CFrame.lookAt(Vector3.new(4.4, 8.4, -10.6), Vector3.new(0, 2.9, 0))
	viewport.CurrentCamera = camera
end

---------------------------------------------------------------- การ์ดชิ้นส่วน

local function partCard(id, count, owned, level, order)
	local item = Config.Items[id]
	local card = make("Frame", { Size = UDim2.fromOffset(104, 138), BackgroundColor3 = CARD_COLOR, BorderSizePixel = 0, LayoutOrder = order }, partsRow)
	corner(card, 10)
	local stroke = make("UIStroke", { Thickness = 2, Color = ACCENT, Transparency = 0.2 }, card)
	local scale = make("UIScale", { Scale = 0 }, card)
	local preview = make("Frame", { Size = UDim2.fromOffset(84, 64), Position = UDim2.fromOffset(10, 6), BackgroundTransparency = 1 }, card)
	LoadoutUi.BuildPreview(preview, item)
	text({ Size = UDim2.new(1, -8, 0, 20), Position = UDim2.fromOffset(4, 70), Text = item.Name, TextSize = 15, TextScaled = true }, card)
	text({ Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 90), Text = "+" .. count, TextSize = 22, TextColor3 = ACCENT }, card)
	local cost = Progression.UpgradeCost(id, level)
	local progress
	if not cost then
		progress = text({ Text = "เลเวลเต็ม", TextColor3 = Color3.fromRGB(180, 180, 190) }, card)
	elseif owned >= cost then
		progress = text({ Text = "อัพเกรดได้!", TextColor3 = GREEN }, card)
		stroke.Color = GREEN
	else
		progress = text({ Text = string.format("%d / %d", owned, cost), TextColor3 = Color3.fromRGB(200, 200, 210) }, card)
	end
	progress.Size = UDim2.new(1, 0, 0, 18)
	progress.Position = UDim2.fromOffset(0, 114)
	progress.TextSize = 14
	return scale
end

---------------------------------------------------------------- แถบ EXP

local function showExp(exp)
	local rank = Progression.Rank(exp)
	local nextRank = Progression.NextRank(exp)
	rankLabel.Text = rank.Name
	rankLabel.TextColor3 = rankColor(rank.Id)
	if nextRank then
		local span = nextRank.MinExp - rank.MinExp
		expFill.Size = UDim2.fromScale(math.clamp((exp - rank.MinExp) / span, 0, 1), 1)
		expLabel.Text = string.format("EXP %d / %d", math.floor(exp), nextRank.MinExp)
	else
		expFill.Size = UDim2.fromScale(1, 1)
		expLabel.Text = string.format("EXP %d  (rank สูงสุด)", math.floor(exp))
	end
end

-- นับ EXP จาก a ไป b แบบลื่น ๆ (ไม่ข้าม rank — ถ้าข้ามจะเรียกสองช่วง)
local function rollExp(a, b, seconds, token)
	local start = os.clock()
	while token == openToken do
		local t = math.min((os.clock() - start) / seconds, 1)
		local eased = 1 - (1 - t) ^ 3
		showExp(a + (b - a) * eased)
		if t >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
end

---------------------------------------------------------------- rank up

local function rankUpBurst(color)
	-- เอฟเฟกต์รอบตัวละคร: แสงพุ่งขึ้น + ประกาย (เห็นเฉพาะเครื่องตัวเอง)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local holder = make("Part", {
		Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, Transparency = 1,
		Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(root.Position - Vector3.new(0, 2.8, 0)),
	}, workspace)
	local pillar = make("Part", {
		Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false,
		Shape = Enum.PartType.Cylinder, Material = Enum.Material.Neon, Color = color, Transparency = 0.3,
		Size = Vector3.new(0.1, 5, 5), CFrame = holder.CFrame * CFrame.Angles(0, 0, math.rad(90)),
	}, holder)
	tween(pillar, 0.5, { Size = Vector3.new(40, 6, 6), CFrame = holder.CFrame * CFrame.new(0, 20, 0) * CFrame.Angles(0, 0, math.rad(90)) })
	tween(pillar, 1.6, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local attachment = make("Attachment", { Position = Vector3.new(0, 0.5, 0) }, holder)
	local sparkles = make("ParticleEmitter", {
		Color = ColorSequence.new(color, Color3.new(1, 1, 1)), LightEmission = 1, Rate = 0,
		Lifetime = NumberRange.new(1, 1.8), Speed = NumberRange.new(14, 28), SpreadAngle = Vector2.new(35, 35),
		Acceleration = Vector3.new(0, -14, 0), Drag = 1.5,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) }),
		EmissionDirection = Enum.NormalId.Top, Texture = "rbxasset://textures/particles/sparkles_main.dds",
	}, attachment)
	sparkles:Emit(90)
	local light = make("PointLight", { Color = color, Range = 22, Brightness = 6 }, holder)
	tween(light, 1.8, { Brightness = 0 })
	game:GetService("Debris"):AddItem(holder, 3)
end

local function showRankUp(rankId, newItems, token)
	local color = rankColor(rankId)
	rankUpName.Text = rankId
	rankUpName.TextColor3 = color
	rankUpGlow.BackgroundColor3 = color
	local names = {}
	for _, id in newItems do
		local item = Config.Items[id]
		table.insert(names, item.Available == false and (item.Name .. " (เร็ว ๆ นี้)") or item.Name)
	end
	rankUpItems.Text = #names > 0 and ("ปลดล็อคใหม่: " .. table.concat(names, ", ")) or ""
	rankUp.Visible = true
	rankUpScale.Scale = 0.3
	rankUpGlow.BackgroundTransparency = 0.2
	rankUpGlow.Size = UDim2.fromOffset(120, 120)
	tween(rankUpScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(rankUpGlow, 0.9, { Size = UDim2.fromOffset(900, 900), BackgroundTransparency = 1 })
	Sfx.Play("BossRoar", nil, 1.6)
	Sfx.Play("Headshot", nil, 0.8)
	rankUpBurst(color)
	local start = os.clock()
	while token == openToken and os.clock() - start < 2.6 do
		rankUpGlow.Rotation += 1
		RunService.RenderStepped:Wait()
	end
	if token == openToken then
		tween(rankUpScale, 0.25, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Wait()
	end
	rankUp.Visible = false
end

---------------------------------------------------------------- ลำดับการเปิด

local function openChest()
	if state ~= "Waiting" then
		return
	end
	state = "Opening"
	local token = openToken
	local r = pending
	hintLabel.Text = ""
	chestButton.Active = false

	-- หีบสั่น 3 ครั้ง แรงขึ้นเรื่อย ๆ
	for i = 1, 3 do
		Sfx.Play("SwordHit", nil, 0.7 + i * 0.12)
		local start = os.clock()
		while os.clock() - start < 0.28 and token == openToken do
			local t = (os.clock() - start) / 0.28
			local wobble = math.sin(t * math.pi * 6) * (1 - t) * (4 + i * 3)
			setChestTilt(CFrame.Angles(0, 0, math.rad(wobble)) * CFrame.new(0, math.sin(t * math.pi) * 0.25 * i, 0))
			RunService.RenderStepped:Wait()
		end
		setChestTilt(CFrame.new())
		task.wait(0.18)
	end
	if token ~= openToken then
		return
	end

	-- ฝาเด้งเปิด + แสงวาบ + รัศมีหมุน
	Sfx.Play("ShieldBlock", nil, 1.2)
	Sfx.Play("Pickup", nil, 0.8)
	rays.Visible = true
	rays.ImageTransparency = 1
	for _, ray in rays:GetChildren() do
		if ray:IsA("Frame") then
			ray.BackgroundTransparency = 1
			tween(ray, 0.3, { BackgroundTransparency = 0.55 })
		end
	end
	local flash = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(255, 240, 200), BackgroundTransparency = 0.2, BorderSizePixel = 0, ZIndex = 5 }, chestHolder)
	corner(flash, 16)
	tween(flash, 0.5, { BackgroundTransparency = 1 })
	game:GetService("Debris"):AddItem(flash, 0.6)
	local start = os.clock()
	while token == openToken do
		local t = math.min((os.clock() - start) / 0.4, 1)
		local back = 1 + 2.2 * (t - 1) ^ 3 + 1.2 * (t - 1) ^ 2 -- easeOutBack
		setLid(LID_ANGLE * back)
		if t >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end

	-- การ์ดชิ้นส่วนทีละใบ
	local profile = Remotes.GetProfile:InvokeServer()
	local ids = {}
	for id in r.Parts do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		return Config.Items[a].Order < Config.Items[b].Order
	end)
	for index, id in ids do
		if token ~= openToken then
			return
		end
		local owned = profile and profile.Parts[id] or r.Parts[id]
		local level = profile and profile.Levels[id] or 0
		local scale = partCard(id, r.Parts[id], owned, level, index)
		tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		Sfx.Play("Pickup", nil, 1 + index * 0.08)
		task.wait(0.3)
	end
	if #ids == 0 then
		text({ Size = UDim2.fromOffset(300, 40), Text = "หีบว่างเปล่า...", TextSize = 20 }, partsRow)
	end
	task.wait(0.3)

	-- EXP: วิ่งทีละ rank ถ้าเลื่อนแรงก์
	expPanel.Visible = true
	if r.ExpDelta == 0 and not r.Won then
		expDelta.Text = "+0 EXP (ไม่ตกแรงก์)"
		expDelta.TextColor3 = Color3.fromRGB(180, 180, 190)
	else
		expDelta.Text = r.ExpDelta >= 0 and string.format("+%d EXP", r.ExpDelta) or string.format("%d EXP", r.ExpDelta)
		expDelta.TextColor3 = r.ExpDelta >= 0 and GREEN or RED
	end
	showExp(r.ExpBefore)
	task.wait(0.25)
	local exp = r.ExpBefore
	while token == openToken and exp ~= r.Exp do
		local nextRank = Progression.NextRank(exp)
		if r.Exp > exp and nextRank and r.Exp >= nextRank.MinExp then
			rollExp(exp, nextRank.MinExp - 0.01, 0.8, token)
			local before = Progression.UnlockedItems(exp)
			exp = nextRank.MinExp
			showExp(exp)
			local newItems = {}
			for _, id in Progression.UnlockedItems(exp) do
				if not table.find(before, id) then
					table.insert(newItems, id)
				end
			end
			table.sort(newItems, function(a, b)
				return Config.Items[a].Order < Config.Items[b].Order
			end)
			showRankUp(nextRank.Id, newItems, token)
		else
			rollExp(exp, r.Exp, 0.9, token)
			exp = r.Exp
		end
	end
	if token ~= openToken then
		return
	end
	if r.UnlockedStage > (r.UnlockedBefore or r.UnlockedStage) then
		stageLabel.Text = string.format("ปลดล็อคด่าน %d แล้ว!", r.UnlockedStage)
		Sfx.Play("Pickup", nil, 1.4)
	end
	state = "Done"
	okButton.Visible = true
end

---------------------------------------------------------------- เปิด/ปิดหน้า

local function build()
	gui = make("ScreenGui", { Name = "RewardUi", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 20, Enabled = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
	overlay = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, BorderSizePixel = 0 }, gui)
	panel = make("Frame", { Size = UDim2.fromOffset(640, 560), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.1, BorderSizePixel = 0 }, gui)
	corner(panel, 16)
	make("UIStroke", { Thickness = 2, Color = ACCENT, Transparency = 0.5 }, panel)
	panelScale = make("UIScale", { Scale = 1 }, panel)
	make("UISizeConstraint", { MaxSize = Vector2.new(640, 560) }, panel)
	-- จอเล็ก (มือถือ): ย่อทั้งหน้า
	local function fit()
		local view = workspace.CurrentCamera.ViewportSize
		panel:SetAttribute("Fit", math.min(1, (view.X - 20) / 640, (view.Y - 20) / 560))
	end
	fit()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)

	titleLabel = text({ Size = UDim2.new(1, 0, 0, 44), Position = UDim2.fromOffset(0, 12), Text = "", TextSize = 32, TextColor3 = ACCENT }, panel)

	chestHolder = make("Frame", { Size = UDim2.fromOffset(300, 210), Position = UDim2.new(0.5, 0, 0, 58), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1, ClipsDescendants = false }, panel)
	-- รัศมีแสงหลังหีบ (แท่งสีทองหมุน)
	rays = make("ImageLabel", { Size = UDim2.fromOffset(10, 10), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Visible = false, ZIndex = 0 }, chestHolder)
	for i = 1, 8 do
		local ray = make("Frame", { Size = UDim2.fromOffset(22, 340), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = i * 22.5, BackgroundColor3 = ACCENT, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 0 }, rays)
		make("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) }), Rotation = 90 }, ray)
	end
	chestButton = make("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 6 }, chestHolder)
	chestButton.Activated:Connect(function()
		task.spawn(openChest)
	end)
	hintLabel = text({ Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 270), Text = "", TextSize = 18, TextColor3 = Color3.fromRGB(220, 220, 230) }, panel)

	partsRow = make("Frame", { Size = UDim2.new(1, -24, 0, 140), Position = UDim2.fromOffset(12, 270), BackgroundTransparency = 1 }, panel)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, partsRow)

	expPanel = make("Frame", { Size = UDim2.new(1, -60, 0, 70), Position = UDim2.fromOffset(30, 418), BackgroundTransparency = 1, Visible = false }, panel)
	rankLabel = text({ Size = UDim2.new(0.5, 0, 0, 28), Text = "", TextSize = 24, TextXAlignment = Enum.TextXAlignment.Left }, expPanel)
	expDelta = text({ Size = UDim2.new(0.5, 0, 0, 28), Position = UDim2.fromScale(0.5, 0), Text = "", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Right }, expPanel)
	local expBack = make("Frame", { Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, 32), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, BorderSizePixel = 0 }, expPanel)
	corner(expBack, 6)
	expFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, expBack)
	corner(expFill, 6)
	expLabel = text({ Size = UDim2.fromScale(1, 1), Text = "", TextSize = 15, ZIndex = 2 }, expBack)
	stageLabel = text({ Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 54), Text = "", TextSize = 16, TextColor3 = GREEN }, expPanel)

	okButton = make("TextButton", { Size = UDim2.fromOffset(200, 44), Position = UDim2.new(0.5, 0, 1, -14), AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = Color3.fromRGB(70, 160, 80), BorderSizePixel = 0, FontFace = FONT, TextSize = 22, TextColor3 = Color3.new(1, 1, 1), Text = "ตกลง", Visible = false }, panel)
	corner(okButton, 8)
	okButton.Activated:Connect(RewardUi.Close)

	-- ป้าย RANK UP กลางจอ
	rankUp = make("Frame", { Size = UDim2.fromOffset(520, 260), Position = UDim2.fromScale(0.5, 0.45), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Visible = false, ZIndex = 20 }, gui)
	rankUpScale = make("UIScale", { Scale = 1 }, rankUp)
	rankUpGlow = make("Frame", { Size = UDim2.fromOffset(120, 120), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = ACCENT, BorderSizePixel = 0, ZIndex = 20 }, rankUp)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, rankUpGlow)
	local plate = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(14, 14, 20), BackgroundTransparency = 0.1, BorderSizePixel = 0, ZIndex = 21 }, rankUp)
	corner(plate, 18)
	make("UIStroke", { Thickness = 3, Color = ACCENT }, plate)
	text({ Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, 22), Text = "เลื่อนแรงก์!", TextSize = 30, TextColor3 = Color3.fromRGB(240, 240, 240), ZIndex = 22 }, plate)
	rankUpName = text({ Size = UDim2.new(1, 0, 0, 90), Position = UDim2.fromOffset(0, 66), Text = "", TextSize = 80, ZIndex = 22 }, plate)
	make("UIStroke", { Thickness = 2, Color = Color3.new(0, 0, 0), Transparency = 0.3 }, rankUpName)
	rankUpItems = text({ Size = UDim2.new(1, -40, 0, 70), Position = UDim2.fromOffset(20, 168), Text = "", TextSize = 18, TextWrapped = true, TextColor3 = Color3.fromRGB(230, 230, 230), ZIndex = 22 }, plate)

	-- คีย์บอร์ด: E / Enter = เปิดหีบ หรือ ตกลง
	UserInputService.InputBegan:Connect(function(input)
		if not gui.Enabled then
			return
		end
		if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
			if state == "Waiting" then
				task.spawn(openChest)
			elseif state == "Done" then
				RewardUi.Close()
			end
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		if not gui.Enabled then
			return
		end
		panelScale.Scale = (panel:GetAttribute("Fit") or 1) * (panel:GetAttribute("Pop") or 1)
		if rays.Visible then
			rays.Rotation += dt * 25
		end
		if state == "Waiting" and chestModel then
			-- หีบลอยขึ้นลงเบา ๆ รอให้กดเปิด
			local t = os.clock()
			setChestTilt(CFrame.new(0, math.sin(t * 3) * 0.15, 0) * CFrame.Angles(0, math.sin(t * 1.3) * 0.12, 0))
		end
	end)
end

function RewardUi.Open()
	if not pending or player:GetAttribute("InMatch") or RewardUi.IsOpen() then
		return
	end
	if not gui then
		build()
	end
	openToken += 1
	local r = pending
	state = "Waiting"
	for _, child in partsRow:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	resetChest()
	titleLabel.Text = r.Won and string.format("หีบรางวัล — ชนะด่าน %d", r.Stage) or string.format("หีบปลอบใจ — ด่าน %d", r.Stage)
	titleLabel.TextColor3 = r.Won and ACCENT or Color3.fromRGB(200, 200, 210)
	hintLabel.Text = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and "แตะหีบเพื่อเปิด" or "คลิกหีบหรือกด E เพื่อเปิด"
	rays.Visible = false
	expPanel.Visible = false
	stageLabel.Text = ""
	okButton.Visible = false
	rankUp.Visible = false
	chestButton.Active = true
	gui.Enabled = true
	CameraController.MenuOpen = true
	panel:SetAttribute("Pop", 0.6)
	local pop = Instance.new("NumberValue")
	pop.Value = 0.6
	pop.Changed:Connect(function(v)
		panel:SetAttribute("Pop", v)
	end)
	tween(pop, 0.35, { Value = 1 }, Enum.EasingStyle.Back).Completed:Connect(function()
		pop:Destroy()
	end)
	local token = openToken
	task.delay(AUTO_OPEN, function()
		if token == openToken and state == "Waiting" then
			openChest()
		end
	end)
end

function RewardUi.Close()
	if not gui or state == "Opening" then
		return
	end
	openToken += 1
	state = "Closed"
	pending = nil
	gui.Enabled = false
	CameraController.MenuOpen = false
end

function RewardUi.IsOpen()
	return gui ~= nil and gui.Enabled
end

function RewardUi.HasPending()
	return pending ~= nil
end

function RewardUi.Init()
	Remotes:WaitForChild("MatchRewards").OnClientEvent:Connect(function(summary)
		pending = summary
		if not player:GetAttribute("InMatch") then
			task.delay(OPEN_DELAY, RewardUi.Open)
		end
	end)
	-- กลับจาก server แมตช์: รางวัลติดมากับ teleport (server เก็บไว้ให้)
	task.spawn(function()
		local remote = Remotes:WaitForChild("GetPendingReward", 30)
		local summary = remote and remote:InvokeServer()
		if summary and not pending then
			pending = summary
			if not player:GetAttribute("InMatch") then
				task.delay(OPEN_DELAY, RewardUi.Open)
			end
		end
	end)
	player:GetAttributeChangedSignal("InMatch"):Connect(function()
		if not player:GetAttribute("InMatch") and pending then
			task.delay(OPEN_DELAY, RewardUi.Open)
		end
	end)
end

return RewardUi
