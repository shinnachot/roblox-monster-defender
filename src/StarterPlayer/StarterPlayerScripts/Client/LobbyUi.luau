-- LobbyUi: UI ตอนอยู่ Lobby — rank + แถบ EXP, เลือกด่าน (ได้ถึงด่านที่ปลดล็อค), ปุ่ม เล่น
-- ซ่อนทั้งหมดเมื่ออยู่ในแมตช์ (attribute InMatch บน Player)
-- Invite / Party มาในเฟส 4
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local LobbyUi = {}

-- เรียกเมื่อผู้เล่นเปิดคลังอาวุธ (ตั้งโดย Client) — nil = ยังไม่มีหน้า Loadout
LobbyUi.OnOpenLoadout = nil

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local PANEL_COLOR = Color3.fromRGB(20, 22, 28)
local ACCENT = Color3.fromRGB(255, 196, 64)
local RANK_COLORS = {
	Bronze = Color3.fromRGB(205, 127, 50),
	Silver = Color3.fromRGB(200, 205, 215),
	Gold = Color3.fromRGB(255, 205, 60),
	Platinum = Color3.fromRGB(120, 225, 230),
	Legend = Color3.fromRGB(200, 110, 255),
}
local ERROR_TEXT = {
	Busy = "มีแมตช์กำลังเล่นอยู่ — รอสักครู่",
	Locked = "ด่านนี้ยังไม่ปลดล็อค",
	NotLoaded = "กำลังโหลดข้อมูลผู้เล่น...",
	NoCharacter = "รอตัวละครเกิดก่อน",
}

local player = Players.LocalPlayer
local gui
local rankLabel, expFill, expLabel
local stageLabel, stageHint, playButton, statusLabel, leftButton, rightButton
local selectedStage = nil
local statusUntil = 0
local requesting = false

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
	local count = #Config.Waves.Stages
	selectedStage = math.clamp((selectedStage or 1) + delta, 1, count)
	LobbyUi.Refresh()
end

local function play()
	if requesting or not selectedStage then
		return
	end
	requesting = true
	setStatus("กำลังเริ่ม...", 10)
	local ok, reason = Remotes:WaitForChild("StartMatch"):InvokeServer(selectedStage)
	requesting = false
	if ok then
		setStatus("", 0)
	else
		setStatus(ERROR_TEXT[reason] or "เริ่มไม่ได้", 3)
	end
end

function LobbyUi.Refresh()
	if not gui then
		return
	end
	gui.Enabled = player:GetAttribute("InMatch") ~= true
	if not gui.Enabled then
		return
	end

	-- rank + EXP
	local exp = player:GetAttribute("Exp") or 0
	local rank = Progression.Rank(exp)
	local nextRank = Progression.NextRank(exp)
	rankLabel.Text = rank.Name
	rankLabel.TextColor3 = RANK_COLORS[rank.Id] or ACCENT
	if nextRank then
		local span = nextRank.MinExp - rank.MinExp
		expFill.Size = UDim2.fromScale(math.clamp((exp - rank.MinExp) / span, 0, 1), 1)
		expLabel.Text = string.format("EXP %d / %d  → %s", exp, nextRank.MinExp, nextRank.Name)
	else
		expFill.Size = UDim2.fromScale(1, 1)
		expLabel.Text = string.format("EXP %d  (rank สูงสุด)", exp)
	end

	-- เลือกด่าน
	local unlocked = unlockedStage()
	if not selectedStage then
		selectedStage = unlocked
	end
	local locked = selectedStage > unlocked
	stageLabel.Text = (locked and "🔒 " or "") .. string.format("ด่าน %d", selectedStage)
	stageLabel.TextColor3 = locked and Color3.fromRGB(150, 150, 150) or Color3.new(1, 1, 1)
	stageHint.Text = locked and string.format("ชนะด่าน %d ก่อนเพื่อปลดล็อค", selectedStage - 1)
		or string.format("5 คลื่น — คลื่นสุดท้ายมี Boss")
	leftButton.Visible = selectedStage > 1
	rightButton.Visible = selectedStage < #Config.Waves.Stages

	local phase = workspace:GetAttribute("MatchPhase")
	local busy = phase ~= nil and phase ~= "Lobby"
	local canPlay = not locked and not busy and not requesting
	playButton.Active = canPlay
	playButton.AutoButtonColor = canPlay
	playButton.BackgroundColor3 = canPlay and Color3.fromRGB(70, 160, 80) or Color3.fromRGB(70, 74, 80)
	if os.clock() > statusUntil then
		statusLabel.Text = busy and "มีผู้เล่นอื่นกำลังสู้อยู่ที่ป้อม — รอจบแมตช์" or ""
	end
end

function LobbyUi.Init(options)
	local touch = options ~= nil and options.Touch == true
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
	local panel = make("Frame", { Size = UDim2.fromOffset(280, 196), Position = touch and UDim2.new(1, -16, 0.3, 0) or UDim2.new(1, -24, 0.5, 0), AnchorPoint = Vector2.new(1, touch and 0 or 0.5), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, gui)
	corner(panel, 12)
	text({ Size = UDim2.new(1, 0, 0, 28), Position = UDim2.fromOffset(0, 8), Text = "เลือกด่าน", TextSize = 18, TextColor3 = Color3.fromRGB(210, 210, 210) }, panel)
	leftButton = button({ Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(14, 40), Text = "◀", TextSize = 20, BackgroundColor3 = Color3.fromRGB(55, 58, 66) }, panel)
	rightButton = button({ Size = UDim2.fromOffset(40, 40), Position = UDim2.new(1, -54, 0, 40), Text = "▶", TextSize = 20, BackgroundColor3 = Color3.fromRGB(55, 58, 66) }, panel)
	stageLabel = text({ Size = UDim2.new(1, -120, 0, 40), Position = UDim2.fromOffset(60, 40), Text = "", TextSize = 28 }, panel)
	stageHint = text({ Size = UDim2.new(1, -20, 0, 20), Position = UDim2.fromOffset(10, 84), Text = "", TextSize = 14, TextColor3 = Color3.fromRGB(200, 200, 200) }, panel)
	playButton = button({ Size = UDim2.new(1, -28, 0, 52), Position = UDim2.fromOffset(14, 110), Text = touch and "เล่น" or "เล่น (K)", TextSize = 28, BackgroundColor3 = Color3.fromRGB(70, 160, 80) }, panel)
	statusLabel = text({ Size = UDim2.new(1, -20, 0, 24), Position = UDim2.fromOffset(10, 166), Text = "", TextSize = 14, TextWrapped = true, TextColor3 = Color3.fromRGB(255, 200, 120) }, panel)

	leftButton.Activated:Connect(function()
		changeStage(-1)
	end)
	rightButton.Activated:Connect(function()
		changeStage(1)
	end)
	playButton.Activated:Connect(function()
		if playButton.Active then
			task.spawn(play)
		end
	end)
	-- คอม: เมาส์ถูกล็อกกลางจอ จึงใช้ปุ่ม K เริ่มด่านที่เลือกอยู่
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.K and gui.Enabled and playButton.Active then
			task.spawn(play)
		end
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

	-- ปลดล็อคด่านใหม่ -> เลื่อนไปด่านสูงสุดให้เอง
	player:GetAttributeChangedSignal("UnlockedStage"):Connect(function()
		selectedStage = unlockedStage()
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
