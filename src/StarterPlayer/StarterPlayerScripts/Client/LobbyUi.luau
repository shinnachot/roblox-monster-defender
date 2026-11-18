-- LobbyUi: UI ตอนอยู่ Lobby — rank + แถบ EXP, เลือกด่าน (ได้ถึงด่านที่ปลดล็อค), ปุ่ม เล่น
-- ซ่อนทั้งหมดเมื่ออยู่ในแมตช์ (attribute InMatch บน Player) หรืออยู่ใน server แมตช์ (workspace.ServerMode = "Match")
-- เฟส 4: ด่านกับปุ่มเล่นเป็นของทีม (PartyUi) — หัวหน้าเลือกด่าน/กดเล่น, ไม่ครบ 3 คน -> หาผู้เล่น 30 วิ
--   คอม: K = เล่น / เริ่มเลย, X = ยกเลิกการหา
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PartyUi = require(script.Parent:WaitForChild("PartyUi"))

local LobbyUi = {}

-- เรียกเมื่อผู้เล่นเปิดคลังอาวุธ (ตั้งโดย Client) — nil = ยังไม่มีหน้า Loadout
LobbyUi.OnOpenLoadout = nil

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local PANEL_COLOR = Color3.fromRGB(20, 22, 28)
local ACCENT = Color3.fromRGB(255, 196, 64)

local player = Players.LocalPlayer
local gui
local rankLabel, expFill, expLabel
local stageLabel, stageHint, playButton, cancelButton, statusLabel, leftButton, rightButton
local statusUntil = 0
local playAction = nil
local touch = false -- คำสั่งของปุ่มเล่นตอนนี้: "Play" / "StartNow" / nil

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
	props.TextStrokeTransparency = props.TextStrokeTransparency or 0.5
	return make("TextLabel", props, parent)
end

local function button(props, parent)
	props.FontFace = FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.AutoButtonColor = true
	props.BorderSizePixel = 0
	local b = make("TextButton", props, parent)
	corner(b, 8)
	return b
end

local function unlockedStage()
	local unlocked = player:GetAttribute("UnlockedStage") or 1
	if RunService:IsStudio() and workspace:GetAttribute("DebugUnlockAll") == true then
		unlocked = workspace:GetAttribute("StageCount") or #Config.Waves.Stages
	end
	return unlocked
end

local function setStatus(message, seconds)
	statusLabel.Text = message
	statusUntil = os.clock() + (seconds or 3)
end

local function changeStage(delta)
	local state = PartyUi.GetState()
	if not state or not PartyUi.IsLeader() or state.Status ~= "Idle" then
		return
	end
	local stage = math.clamp(state.Stage + delta, 1, #Config.Waves.Stages)
	if stage ~= state.Stage then
		task.spawn(PartyUi.Action, "SetStage", stage)
	end
end

local function press()
	if playAction then
		local action = playAction
		playAction = nil -- กันกดซ้ำจนกว่าสถานะใหม่จะมา
		task.spawn(PartyUi.Action, action)
	end
end

local function cancel()
	local state = PartyUi.GetState()
	if state and PartyUi.IsLeader() and (state.Status == "Searching" or state.Status == "Found") then
		task.spawn(PartyUi.Action, "Cancel")
	end
end

local function secondsUntil(serverTime)
	return math.max(0, math.ceil((serverTime or 0) - workspace:GetServerTimeNow()))
end

function LobbyUi.Refresh()
	if not gui then
		return
	end
	gui.Enabled = player:GetAttribute("InMatch") ~= true and workspace:GetAttribute("ServerMode") ~= "Match"
	if not gui.Enabled then
		return
	end

	-- rank + EXP
	local exp = player:GetAttribute("Exp") or 0
	local rank = Progression.Rank(exp)
	local nextRank = Progression.NextRank(exp)
	rankLabel.Text = rank.Name
	rankLabel.TextColor3 = rank.Color or ACCENT
	if nextRank then
		local span = nextRank.MinExp - rank.MinExp
		expFill.Size = UDim2.fromScale(math.clamp((exp - rank.MinExp) / span, 0, 1), 1)
		expLabel.Text = string.format("EXP %d / %d  → %s", exp, nextRank.MinExp, nextRank.Name)
	else
		expFill.Size = UDim2.fromScale(1, 1)
		expLabel.Text = string.format("EXP %d  (rank สูงสุด)", exp)
	end

	-- ด่าน + ปุ่มเล่นตามสถานะทีม
	local state = PartyUi.GetState()
	if not state then
		stageLabel.Text = "..."
		stageHint.Text = ""
		leftButton.Visible = false
		rightButton.Visible = false
		playButton.Visible = false
		cancelButton.Visible = false
		playAction = nil
		return
	end
	local leader = PartyUi.IsLeader()
	local status = state.Status
	local idle = status == "Idle"
	local stage = state.Stage
	stageLabel.Text = string.format("ด่าน %d", stage)
	stageLabel.TextColor3 = Color3.new(1, 1, 1)
	if leader then
		stageHint.Text = stage < unlockedStage() and "5 คลื่น — คลื่นสุดท้ายมี Boss" or "ด่านสูงสุดที่ปลดล็อค — ชนะเพื่อปลดด่านถัดไป"
	else
		stageHint.Text = stage > unlockedStage() and "หัวหน้าเลือก — ชนะแล้วคุณปลดล็อคด่านนี้ด้วย" or "หัวหน้าทีมเป็นคนเลือกด่าน"
	end
	leftButton.Visible = leader and idle and stage > 1
	rightButton.Visible = leader and idle and stage < math.min(unlockedStage(), #Config.Waves.Stages)

	local fortBusy = RunService:IsStudio() and (workspace:GetAttribute("MatchPhase") or "Lobby") ~= "Lobby"
	local label, action, info
	if idle then
		if leader then
			label = touch and "เล่น" or "เล่น (K)"
			action = not fortBusy and "Play" or nil
			info = fortBusy and "มีผู้เล่นอื่นกำลังสู้อยู่ที่ป้อม — รอจบแมตช์"
				or (#state.Members < state.MaxSize and "ทีมไม่ครบ 3 คน: จะหาผู้เล่นเพิ่ม 30 วิ" or "")
		else
			label = "รอหัวหน้าทีม"
			info = "หัวหน้าทีมจะเป็นคนกดเล่น"
		end
	elseif status == "Searching" then
		label = leader and (touch and "เริ่มเลย" or "เริ่มเลย (K)") or "กำลังหาผู้เล่น..."
		action = leader and "StartNow" or nil
		info = string.format("กำลังหาผู้เล่น %d / %d — เริ่มใน %d วิ", state.Found or #state.Members, state.MaxSize, secondsUntil(state.Deadline))
	elseif status == "Found" then
		label = "พบทีมแล้ว"
		info = "รวมกับผู้เล่นอื่นแล้ว — รอเริ่มด่าน..."
	else
		label = "กำลังเข้าด่าน..."
		info = "กำลังย้ายไปด่าน..."
	end
	playButton.Visible = true
	playButton.Text = label
	playAction = action
	playButton.Active = action ~= nil
	playButton.AutoButtonColor = action ~= nil
	playButton.BackgroundColor3 = action == "StartNow" and Color3.fromRGB(200, 140, 40)
		or (action and Color3.fromRGB(70, 160, 80) or Color3.fromRGB(70, 74, 80))
	cancelButton.Visible = leader and (status == "Searching" or status == "Found")
	if os.clock() > statusUntil then
		statusLabel.Text = info
	end
end

function LobbyUi.Init(options)
	touch = options ~= nil and options.Touch == true
	gui = make("ScreenGui", { Name = "LobbyUi", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 4 }, player:WaitForChild("PlayerGui"))

	-- บนกลาง: rank + แถบ EXP
	local rankPanel = make("Frame", { Size = UDim2.fromOffset(340, 74), Position = UDim2.new(0.5, 0, 0, 44), AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.25, BorderSizePixel = 0 }, gui)
	corner(rankPanel, 10)
	rankLabel = text({ Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 4), Text = "", TextSize = 28 }, rankPanel)
	local expBack = make("Frame", { Size = UDim2.new(1, -28, 0, 22), Position = UDim2.fromOffset(14, 42), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, BorderSizePixel = 0 }, rankPanel)
	corner(expBack, 6)
	expFill = make("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, expBack)
	corner(expFill, 6)
	expLabel = text({ Size = UDim2.fromScale(1, 1), Text = "", TextSize = 15, ZIndex = 2 }, expBack)

	-- ขวากลาง: เลือกด่าน + เล่น (จอสัมผัสยกขึ้นหนีปุ่มควบคุมมุมล่าง)
	local panel = make("Frame", { Size = UDim2.fromOffset(280, 236), Position = touch and UDim2.new(1, -16, 0.3, 0) or UDim2.new(1, -24, 0.5, 0), AnchorPoint = Vector2.new(1, touch and 0 or 0.5), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, gui)
	corner(panel, 12)
	text({ Size = UDim2.new(1, 0, 0, 28), Position = UDim2.fromOffset(0, 8), Text = "เลือกด่าน", TextSize = 18, TextColor3 = Color3.fromRGB(210, 210, 210) }, panel)
	leftButton = button({ Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(14, 40), Text = "◀", TextSize = 20, BackgroundColor3 = Color3.fromRGB(55, 58, 66) }, panel)
	rightButton = button({ Size = UDim2.fromOffset(40, 40), Position = UDim2.new(1, -54, 0, 40), Text = "▶", TextSize = 20, BackgroundColor3 = Color3.fromRGB(55, 58, 66) }, panel)
	stageLabel = text({ Size = UDim2.new(1, -120, 0, 40), Position = UDim2.fromOffset(60, 40), Text = "", TextSize = 28 }, panel)
	stageHint = text({ Size = UDim2.new(1, -20, 0, 20), Position = UDim2.fromOffset(10, 84), Text = "", TextSize = 14, TextColor3 = Color3.fromRGB(200, 200, 200) }, panel)
	playButton = button({ Size = UDim2.new(1, -28, 0, 52), Position = UDim2.fromOffset(14, 110), Text = touch and "เล่น" or "เล่น (K)", TextSize = 28, BackgroundColor3 = Color3.fromRGB(70, 160, 80) }, panel)
	cancelButton = button({ Size = UDim2.new(1, -28, 0, 30), Position = UDim2.fromOffset(14, 166), Text = touch and "ยกเลิก" or "ยกเลิก (X)", TextSize = 16, BackgroundColor3 = Color3.fromRGB(150, 60, 55), Visible = false }, panel)
	statusLabel = text({ Size = UDim2.new(1, -20, 0, 34), Position = UDim2.fromOffset(10, 198), Text = "", TextSize = 14, TextWrapped = true, TextColor3 = Color3.fromRGB(255, 200, 120) }, panel)

	leftButton.Activated:Connect(function()
		changeStage(-1)
	end)
	rightButton.Activated:Connect(function()
		changeStage(1)
	end)
	playButton.Activated:Connect(press)
	cancelButton.Activated:Connect(cancel)
	-- คอม: เมาส์ถูกล็อกกลางจอ จึงใช้ปุ่ม K เริ่ม / X ยกเลิก
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not gui.Enabled or (LobbyUi.IsBlocked and LobbyUi.IsBlocked()) then
			return
		end
		if input.KeyCode == Enum.KeyCode.K then
			press()
		elseif input.KeyCode == Enum.KeyCode.X then
			cancel()
		end
	end)
	PartyUi.Changed:Connect(function()
		statusUntil = 0
		LobbyUi.Refresh()
	end)

	-- คลังอาวุธใน Lobby
	local prompt = workspace:WaitForChild("Lobby"):WaitForChild("LoadoutStation"):WaitForChild("PromptPart"):WaitForChild("LoadoutPrompt")
	prompt.Triggered:Connect(function()
		if LobbyUi.OnOpenLoadout then
			LobbyUi.OnOpenLoadout()
		else
			setStatus("หน้า Loadout กำลังจะมาเร็ว ๆ นี้", 3)
		end
	end)

	-- หุ่นฝึกส่ายเมื่อโดน (server ตั้ง attribute HitAt)
	for _, dummy in game:GetService("CollectionService"):GetTagged("TrainingDummy") do
		local rest = dummy:GetPivot()
		local token = 0
		dummy:GetAttributeChangedSignal("HitAt"):Connect(function()
			token += 1
			local mine = token
			dummy:PivotTo(rest * CFrame.Angles(math.rad(-8), 0, 0))
			task.delay(0.12, function()
				if token == mine then
					dummy:PivotTo(rest)
				end
			end)
		end)
	end

	-- ปลดล็อคด่านใหม่ -> หัวหน้าทีมเลื่อนไปด่านสูงสุดให้เอง
	player:GetAttributeChangedSignal("UnlockedStage"):Connect(function()
		local state = PartyUi.GetState()
		if state and PartyUi.IsLeader() and state.Status == "Idle" and state.Stage < unlockedStage() then
			task.spawn(PartyUi.Action, "SetStage", unlockedStage())
		end
	end)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= 0.15 then
			elapsed = 0
			LobbyUi.Refresh()
		end
	end)
	LobbyUi.Refresh()
end

return LobbyUi
