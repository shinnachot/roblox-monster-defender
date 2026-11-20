-- PartyUi: ทีมใน Lobby (เฟส 4) — แผงสมาชิกทีม (ซ้าย), หน้าทีม/ชวนเพื่อน (P), คำชวนที่เข้ามา (Y รับ / N ปฏิเสธ), ข้อความแจ้ง
-- เก็บสถานะทีมล่าสุดจาก server (Remotes.PartyState) ให้ LobbyUi ใช้: PartyUi.GetState(), PartyUi.Changed
-- คำสั่งทั้งหมดผ่าน PartyUi.Action(name, arg) -> Remotes.PartyAction (server ตรวจทุกอย่าง)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CameraController = require(script.Parent:WaitForChild("CameraController"))

local PartyUi = {}

local changedEvent = Instance.new("BindableEvent")
PartyUi.Changed = changedEvent.Event
PartyUi.IsBlocked = nil -- ตั้งโดย Client: มีหน้าอื่นเปิดอยู่ (Loadout/หีบ)

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local PANEL_COLOR = Color3.fromRGB(20, 22, 28)
local ACCENT = Color3.fromRGB(255, 196, 64)
local GREEN = Color3.fromRGB(70, 160, 80)
local GREY = Color3.fromRGB(55, 58, 66)
local RED = Color3.fromRGB(170, 60, 55)
local ERROR_TEXT = {
	NotLeader = "เฉพาะหัวหน้าทีม",
	Busy = "ทำตอนนี้ไม่ได้",
	Full = "ทีมเต็มแล้ว (3 คน)",
	NoTarget = "ไม่พบผู้เล่น",
	TargetBusy = "ผู้เล่นนี้อยู่ในทีมอื่นหรือกำลังเล่นอยู่",
	NoInvite = "คำชวนหมดอายุแล้ว",
	Expired = "คำชวนหมดอายุแล้ว",
	Gone = "ทีมนั้นไม่ว่างแล้ว",
	Locked = "ด่านนี้ยังไม่ปลดล็อค",
	NotLoaded = "กำลังโหลดข้อมูลผู้เล่น...",
	NoCharacter = "รอทุกคนในทีมเกิดก่อน",
	FortBusy = "มีแมตช์กำลังเล่นอยู่ที่ป้อม — รอสักครู่",
}

local player = Players.LocalPlayer
local state = nil
local touch = false
local gui, teamPanel, teamTitle, teamRows, teamButton
local menu, lobbyList, memberList, leaveButton, friendButton, menuTitle
local invitePanel, inviteLabel
local toast
local toastUntil = 0
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

local function rankOf(rankId)
	for _, rank in Config.Ranks do
		if rank.Id == rankId then
			return rank
		end
	end
	return Config.Ranks[1]
end

local function inLobby()
	return workspace:GetAttribute("ServerMode") ~= "Match" and player:GetAttribute("InMatch") ~= true
end

---------------------------------------------------------------- สถานะ

function PartyUi.GetState()
	return state
end

function PartyUi.IsLeader()
	return state ~= nil and state.LeaderId == player.UserId
end

function PartyUi.Notice(message, seconds)
	if not toast then
		return
	end
	toast.Text = message
	toast.Visible = message ~= ""
	toastUntil = os.clock() + (seconds or 3)
end

function PartyUi.Action(name, arg)
	if busy then
		return false, "Busy"
	end
	busy = true
	local ok, reason = Remotes:WaitForChild("PartyAction"):InvokeServer(name, arg)
	busy = false
	if not ok and reason then
		PartyUi.Notice(ERROR_TEXT[reason] or "ทำไม่ได้", 3)
	end
	return ok, reason
end

local function setState(snapshot)
	state = snapshot
	PartyUi.Refresh()
	changedEvent:Fire(state)
end

---------------------------------------------------------------- หน้าทีม (P)

local function clearRows(container)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function memberRow(parent, member, order)
	local rank = rankOf(member.Rank)
	local row = make("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = GREY, BackgroundTransparency = 0.3, BorderSizePixel = 0, LayoutOrder = order }, parent)
	corner(row, 6)
	local leader = state and member.UserId == state.LeaderId
	text({ Size = UDim2.new(1, -90, 1, 0), Position = UDim2.fromOffset(10, 0), Text = (leader and "👑 " or "") .. member.Name, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, row)
	text({ Size = UDim2.new(0, 80, 1, 0), Position = UDim2.new(1, -86, 0, 0), Text = rank.Name, TextSize = 14, TextColor3 = rank.Color, TextXAlignment = Enum.TextXAlignment.Right }, row)
	return row
end

local function rebuildMenu()
	if not menu or not menu.Visible or not state then
		return
	end
	local leader = PartyUi.IsLeader()
	local idle = state.Status == "Idle"
	local full = #state.Members >= state.MaxSize
	menuTitle.Text = string.format("ทีม %d / %d", #state.Members, state.MaxSize)

	clearRows(memberList)
	for index, member in state.Members do
		local row = memberRow(memberList, member, index)
		if leader and member.UserId ~= player.UserId then
			row:FindFirstChildOfClass("TextLabel").Size = UDim2.new(1, -150, 1, 0)
			local kick = button({ Size = UDim2.fromOffset(54, 26), Position = UDim2.new(1, -146, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Text = "เตะ", TextSize = 14, BackgroundColor3 = RED }, row)
			local userId = member.UserId
			kick.Activated:Connect(function()
				PartyUi.Action("Kick", userId)
			end)
		end
	end

	clearRows(lobbyList)
	local count = 0
	for _, other in Players:GetPlayers() do
		if other == player or other:GetAttribute("PartyId") == state.Id then
			continue
		end
		count += 1
		local rank = Progression.Rank(other:GetAttribute("Exp") or 0)
		local row = make("Frame", { Size = UDim2.new(1, 0, 0, 36), BackgroundColor3 = GREY, BackgroundTransparency = 0.3, BorderSizePixel = 0, LayoutOrder = count }, lobbyList)
		corner(row, 6)
		text({ Size = UDim2.new(1, -170, 1, 0), Position = UDim2.fromOffset(10, 0), Text = other.DisplayName, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, row)
		text({ Size = UDim2.fromOffset(70, 36), Position = UDim2.new(1, -160, 0, 0), Text = rank.Name, TextSize = 13, TextColor3 = rank.Color }, row)
		local available = (other:GetAttribute("PartySize") or 1) <= 1 and other:GetAttribute("InMatch") ~= true
		local canInvite = leader and idle and not full and available
		local invite = button({ Size = UDim2.fromOffset(80, 26), Position = UDim2.new(1, -86, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Text = available and "ชวน" or "มีทีมแล้ว", TextSize = 14, BackgroundColor3 = canInvite and GREEN or GREY }, row)
		invite.Active = canInvite
		invite.AutoButtonColor = canInvite
		local userId = other.UserId
		local name = other.DisplayName
		invite.Activated:Connect(function()
			if invite.Active and PartyUi.Action("Invite", userId) then
				PartyUi.Notice(string.format("ส่งคำชวนให้ %s แล้ว", name), 3)
				invite.Text = "ส่งแล้ว"
				invite.Active = false
				invite.BackgroundColor3 = GREY
			end
		end)
	end
	if count == 0 then
		text({ Size = UDim2.new(1, 0, 0, 40), Text = "ยังไม่มีผู้เล่นคนอื่นใน Lobby นี้", TextSize = 15, TextColor3 = Color3.fromRGB(190, 190, 190), LayoutOrder = 1 }, lobbyList)
	end

	friendButton.Visible = leader and idle and not full
	leaveButton.Visible = #state.Members > 1 and (idle or state.Status == "Searching" or state.Status == "Found")
end

function PartyUi.Open()
	if not menu or not inLobby() then
		return
	end
	menu.Visible = true
	CameraController.MenuOpen = true
	rebuildMenu()
end

function PartyUi.Close()
	if menu and menu.Visible then
		menu.Visible = false
		CameraController.MenuOpen = false
	end
end

function PartyUi.IsOpen()
	return menu ~= nil and menu.Visible
end

function PartyUi.Toggle()
	if PartyUi.IsOpen() then
		PartyUi.Close()
	else
		PartyUi.Open()
	end
end

local function inviteFriends()
	local ok, canSend = pcall(SocialService.CanSendGameInviteAsync, SocialService, player)
	if ok and canSend then
		pcall(SocialService.PromptGameInvite, SocialService, player)
	else
		PartyUi.Notice("ส่งคำชวนเพื่อน Roblox ไม่ได้ในตอนนี้", 3)
	end
end

---------------------------------------------------------------- วาดใหม่

function PartyUi.Refresh()
	if not gui then
		return
	end
	gui.Enabled = inLobby()
	if not gui.Enabled then
		PartyUi.Close()
		return
	end
	if os.clock() > toastUntil then
		toast.Visible = false
	end
	if not state then
		teamPanel.Visible = false
		invitePanel.Visible = false
		return
	end

	-- แผงทีมด้านซ้าย
	teamPanel.Visible = true
	teamTitle.Text = string.format("ทีม %d / %d", #state.Members, state.MaxSize)
	clearRows(teamRows)
	for index, member in state.Members do
		memberRow(teamRows, member, index)
	end
	local rows = #state.Members
	teamPanel.Size = UDim2.fromOffset(240, 82 + rows * 40)
	teamButton.Position = UDim2.new(0, 10, 1, -40)

	-- คำชวนที่เข้ามา
	local invite = state.Invite
	invitePanel.Visible = invite ~= nil
	if invite then
		local left = math.max(0, invite.ExpiresAt - os.time())
		inviteLabel.Text = string.format("%s ชวนคุณเข้าทีม (%d)", invite.FromName, left)
	end

	rebuildMenu()
end

---------------------------------------------------------------- สร้าง UI

-- จอสัมผัส: ย่อแผงตามความสูงจอ (มือถือแนวนอนสูง ~340-400 px → 0.65 เท่า, แท็บเล็ตเต็มขนาด)
-- ไม่ย่อต่ำกว่า 0.65: ตัวหนังสือ 12 px เหลือ ~8 px (0.55 เดิมเล็กจนอ่านไม่ออกบน Galaxy A06)
local function touchScale(target)
	local scale = Instance.new("UIScale")
	local camera = workspace.CurrentCamera
	local function rescale()
		scale.Scale = math.clamp(camera.ViewportSize.Y / 660, 0.65, 1)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	rescale()
	scale.Parent = target
end

function PartyUi.Init(options)
	touch = options ~= nil and options.Touch == true
	gui = make("ScreenGui", { Name = "PartyUi", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
	-- Sibling: ลูกวาดทับพื้นหลังของแม่เสมอ (Global ทำให้พื้นหน้าทีม ZIndex 5 บังเนื้อหาข้างใน)

	-- ซ้ายกลาง: สมาชิกทีม + ปุ่มเปิดหน้าทีม (จอสัมผัส: ใต้แถบ HP ซึ่งจบที่ y = 100 — เดิม 27% ของจอทับแถบ HP บนมือถือจอเตี้ย)
	teamPanel = make("Frame", { Size = UDim2.fromOffset(240, 122), Position = touch and UDim2.new(0, 12, 0, 108) or UDim2.new(0, 24, 0.5, 0), AnchorPoint = Vector2.new(0, touch and 0 or 0.5), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0.2, BorderSizePixel = 0, Visible = false }, gui)
	corner(teamPanel, 12)
	teamTitle = text({ Size = UDim2.new(1, 0, 0, 28), Position = UDim2.fromOffset(0, 6), Text = "ทีม", TextSize = 18, TextColor3 = Color3.fromRGB(210, 210, 210) }, teamPanel)
	teamRows = make("Frame", { Size = UDim2.new(1, -20, 1, -82), Position = UDim2.fromOffset(10, 36), BackgroundTransparency = 1 }, teamPanel)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, teamRows)
	teamButton = button({ Size = UDim2.new(1, -20, 0, 32), Text = touch and "ชวนเพื่อน / ทีม" or "ชวนเพื่อน / ทีม (P)", TextSize = 16, BackgroundColor3 = Color3.fromRGB(60, 110, 170) }, teamPanel)
	teamButton.Activated:Connect(PartyUi.Toggle)
	if touch then
		touchScale(teamPanel)
	end

	-- กลางจอ: หน้าทีม
	menu = make("Frame", { Size = UDim2.fromOffset(640, 400), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = PANEL_COLOR, BackgroundTransparency = 0, BorderSizePixel = 0, Visible = false, ZIndex = 5 }, gui)
	make("UISizeConstraint", { MaxSize = Vector2.new(640, 400) }, menu)
	menu.Size = UDim2.new(0.94, 0, 0.8, 0)
	corner(menu, 14)
	menuTitle = text({ Size = UDim2.new(1, 0, 0, 40), Position = UDim2.fromOffset(0, 8), Text = "ทีม", TextSize = 26 }, menu)
	local close = button({ Size = UDim2.fromOffset(40, 40), Position = UDim2.new(1, -50, 0, 8), Text = "X", TextSize = 22, BackgroundColor3 = GREY }, menu)
	close.Activated:Connect(PartyUi.Close)

	local left = make("Frame", { Size = UDim2.new(0.5, -21, 1, -110), Position = UDim2.fromOffset(14, 56), BackgroundTransparency = 1 }, menu)
	text({ Size = UDim2.new(1, 0, 0, 24), Text = "ผู้เล่นใน Lobby", TextSize = 16, TextColor3 = Color3.fromRGB(200, 200, 200), TextXAlignment = Enum.TextXAlignment.Left }, left)
	lobbyList = make("ScrollingFrame", { Size = UDim2.new(1, 0, 1, -28), Position = UDim2.fromOffset(0, 28), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y }, left)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, lobbyList)

	local right = make("Frame", { Size = UDim2.new(0.5, -21, 1, -110), Position = UDim2.new(0.5, 7, 0, 56), BackgroundTransparency = 1 }, menu)
	text({ Size = UDim2.new(1, 0, 0, 24), Text = "สมาชิกทีม", TextSize = 16, TextColor3 = Color3.fromRGB(200, 200, 200), TextXAlignment = Enum.TextXAlignment.Left }, right)
	memberList = make("Frame", { Size = UDim2.new(1, 0, 1, -28), Position = UDim2.fromOffset(0, 28), BackgroundTransparency = 1 }, right)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, memberList)

	friendButton = button({ Size = UDim2.new(0.5, -21, 0, 40), Position = UDim2.new(0, 14, 1, -50), Text = "ชวนเพื่อน Roblox", TextSize = 17, BackgroundColor3 = Color3.fromRGB(60, 110, 170) }, menu)
	friendButton.Activated:Connect(inviteFriends)
	leaveButton = button({ Size = UDim2.new(0.5, -21, 0, 40), Position = UDim2.new(0.5, 7, 1, -50), Text = "ออกจากทีม", TextSize = 17, BackgroundColor3 = RED }, menu)
	leaveButton.Activated:Connect(function()
		PartyUi.Action("Leave")
	end)

	-- บนกลาง (ใต้แถบ rank): คำชวนที่เข้ามา
	invitePanel = make("Frame", { Size = UDim2.fromOffset(380, 96), Position = UDim2.new(0.5, 0, 0, 130), AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = Color3.fromRGB(30, 50, 80), BackgroundTransparency = 0.1, BorderSizePixel = 0, Visible = false, ZIndex = 6 }, gui)
	corner(invitePanel, 12)
	inviteLabel = text({ Size = UDim2.new(1, -20, 0, 36), Position = UDim2.fromOffset(10, 6), Text = "", TextSize = 18, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6 }, invitePanel)
	local accept = button({ Size = UDim2.new(0.5, -18, 0, 40), Position = UDim2.new(0, 12, 0, 46), Text = touch and "รับ" or "รับ (Y)", TextSize = 18, BackgroundColor3 = GREEN, ZIndex = 6 }, invitePanel)
	local decline = button({ Size = UDim2.new(0.5, -18, 0, 40), Position = UDim2.new(0.5, 6, 0, 46), Text = touch and "ปฏิเสธ" or "ปฏิเสธ (N)", TextSize = 18, BackgroundColor3 = GREY, ZIndex = 6 }, invitePanel)
	accept.Activated:Connect(function()
		PartyUi.Action("Respond", true)
	end)
	decline.Activated:Connect(function()
		PartyUi.Action("Respond", false)
	end)

	-- ล่างกลาง: ข้อความแจ้ง
	toast = text({ Size = UDim2.fromOffset(520, 36), Position = UDim2.new(0.5, 0, 1, touch and -230 or -150), AnchorPoint = Vector2.new(0.5, 1), BackgroundTransparency = 0.3, BackgroundColor3 = PANEL_COLOR, Text = "", TextSize = 17, TextColor3 = Color3.fromRGB(255, 220, 140), Visible = false, ZIndex = 7 }, gui)
	corner(toast, 8)

	-- คีย์บอร์ด (เมาส์ถูกล็อกกลางจอบนคอม)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not gui.Enabled then
			return
		end
		local blocked = PartyUi.IsBlocked and PartyUi.IsBlocked()
		if input.KeyCode == Enum.KeyCode.P and not blocked then
			PartyUi.Toggle()
		elseif state and state.Invite and input.KeyCode == Enum.KeyCode.Y then
			PartyUi.Action("Respond", true)
		elseif state and state.Invite and input.KeyCode == Enum.KeyCode.N then
			PartyUi.Action("Respond", false)
		end
	end)

	-- server แมตช์ไม่มีระบบทีม (ไม่มี remote เหล่านี้) — ห้ามรอแบบบล็อกสคริปต์หลัก
	if workspace:GetAttribute("ServerMode") == "Match" then
		gui.Enabled = false
		return
	end
	task.spawn(function()
		Remotes:WaitForChild("PartyState").OnClientEvent:Connect(setState)
		Remotes:WaitForChild("PartyNotice").OnClientEvent:Connect(function(message)
			PartyUi.Notice(message, 4)
		end)
	end)
	-- ผู้เล่นเข้า/ออก/เปลี่ยนทีม -> รายชื่อในหน้าทีมเปลี่ยน
	local function watch(other)
		other:GetAttributeChangedSignal("PartySize"):Connect(rebuildMenu)
	end
	Players.PlayerAdded:Connect(function(other)
		watch(other)
		rebuildMenu()
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(rebuildMenu)
	end)
	for _, other in Players:GetPlayers() do
		watch(other)
	end

	task.spawn(function()
		local getState = Remotes:WaitForChild("GetPartyState", 30)
		if getState and not state then
			local snapshot = getState:InvokeServer()
			if snapshot and not state then
				setState(snapshot)
			end
		end
	end)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= 0.5 then
			elapsed = 0
			-- นับถอยหลังคำชวน / ซ่อนข้อความแจ้ง (ไม่วาดหน้าทีมใหม่ทุกรอบ)
			gui.Enabled = inLobby()
			if not gui.Enabled then
				PartyUi.Close()
			end
			if os.clock() > toastUntil then
				toast.Visible = false
			end
			if state and state.Invite then
				local left = math.max(0, state.Invite.ExpiresAt - os.time())
				inviteLabel.Text = string.format("%s ชวนคุณเข้าทีม (%d)", state.Invite.FromName, left)
			end
		end
	end)
end

return PartyUi
