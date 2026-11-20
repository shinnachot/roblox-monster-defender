-- LeaderboardService: กระดานอันดับ EXP ทั้งเกม (GDD เฟส 5)
-- เขียน: DataService เรียก Submit ทุกครั้งที่เซฟโปรไฟล์สำเร็จ (ทั้ง Lobby และ server แมตช์) -> OrderedDataStore
-- อ่าน: เฉพาะ Lobby ดึง 10 อันดับแรกทุก REFRESH_INTERVAL วิ แล้ววาดลงกระดานในลาน
-- กระดาน: ใช้ part workspace.Lobby.Leaderboard ถ้ามี (ย้าย/หมุนใน Studio ได้ — วาดที่หน้า Front)
--   ไม่มี -> สร้างป้ายไม้ห่างจาก LobbySpawn ไปข้างหน้า หันหน้าเข้าหาจุดเกิด
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Progression = require(ReplicatedStorage.Shared.Progression)

local LeaderboardService = {}

local STORE_NAME = "ExpLeaderboard_v1"
local TOP_COUNT = 10
local REFRESH_INTERVAL = 60
local FONT = Font.fromEnum(Enum.Font.GothamBold)
local BOARD_SIZE = Vector3.new(14, 10, 0.6)
local PIXELS_PER_STUD = 50

local store = nil
local lastSubmitted = {} -- [userId] = exp ที่เขียนไปล่าสุด (ไม่เขียนซ้ำถ้าไม่เปลี่ยน)
local nameCache = {} -- [userId] = DisplayName
local rows = {} -- TextLabel ต่อแถว: { Place, Name, Rank, Exp }
local statusLabel = nil

local function getStore()
	if store == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetOrderedDataStore(STORE_NAME)
		end)
		store = ok and result or false
		if not ok then
			warn("[Leaderboard] OrderedDataStore unavailable:", result)
		end
	end
	return store or nil
end

-- บันทึก EXP ล่าสุดของผู้เล่น (เรียกจาก DataService หลังเซฟสำเร็จ — โปรไฟล์ชั่วคราวไม่ส่งมา)
function LeaderboardService.Submit(userId, exp)
	if userId <= 0 or lastSubmitted[userId] == exp then
		return
	end
	local ordered = getStore()
	if not ordered then
		return
	end
	lastSubmitted[userId] = exp
	task.spawn(function()
		local ok, err = pcall(function()
			ordered:SetAsync(tostring(userId), math.floor(exp))
		end)
		if not ok then
			lastSubmitted[userId] = nil -- ลองใหม่รอบเซฟหน้า
			warn("[Leaderboard] submit failed:", err)
		end
	end)
end

---------------------------------------------------------------- กระดาน

local function make(className, props, parent)
	local inst = Instance.new(className)
	for key, value in props do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function text(props, parent)
	props.BackgroundTransparency = 1
	props.FontFace = FONT
	props.TextColor3 = props.TextColor3 or Color3.new(1, 1, 1)
	props.TextScaled = false
	return make("TextLabel", props, parent)
end

local function findOrBuildBoard()
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then
		return nil
	end
	local existing = lobby:FindFirstChild("Leaderboard")
	if existing and existing:IsA("BasePart") then
		return existing
	end
	local spawn = lobby:FindFirstChild("LobbySpawn")
	if not spawn then
		return nil
	end
	local model = make("Model", { Name = "LeaderboardStand" }, lobby)
	local look = spawn.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.zAxis
	local ground = spawn.Position + Vector3.new(0, spawn.Size.Y / 2, 0)
	local center = ground + look * 24 + Vector3.new(0, 2 + BOARD_SIZE.Y / 2, 0)
	local boardCFrame = CFrame.lookAt(center, center - look) -- หน้า Front หันกลับหาจุดเกิด
	local board = make("Part", {
		Name = "Leaderboard",
		Size = BOARD_SIZE,
		CFrame = boardCFrame,
		Anchored = true,
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(70, 48, 32),
	}, model)
	for _, side in { -1, 1 } do
		local postHeight = 2 + BOARD_SIZE.Y
		make("Part", {
			Name = "Post",
			Size = Vector3.new(0.8, postHeight, 0.8),
			CFrame = boardCFrame * CFrame.new(side * (BOARD_SIZE.X / 2 + 0.4), -(BOARD_SIZE.Y / 2 + 2) + postHeight / 2, 0),
			Anchored = true,
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(90, 62, 40),
		}, model)
	end
	return board
end

local function buildGui(board)
	local gui = make("SurfaceGui", {
		Name = "LeaderboardGui",
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = PIXELS_PER_STUD,
		LightInfluence = 0,
		MaxDistance = 150,
	}, board)
	local root = make("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(20, 22, 28), BackgroundTransparency = 0.1, BorderSizePixel = 0 }, gui)
	make("UIPadding", { PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 16), PaddingLeft = UDim.new(0, 24), PaddingRight = UDim.new(0, 24) }, root)
	text({ Size = UDim2.new(1, 0, 0, 52), Text = "🏆 อันดับ EXP ทั้งเกม", TextSize = 40, TextColor3 = Color3.fromRGB(255, 196, 64) }, root)
	statusLabel = text({ Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 52), Text = "กำลังโหลด...", TextSize = 20, TextColor3 = Color3.fromRGB(170, 170, 170) }, root)
	local list = make("Frame", { Size = UDim2.new(1, 0, 1, -86), Position = UDim2.fromOffset(0, 86), BackgroundTransparency = 1 }, root)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	for index = 1, TOP_COUNT do
		local row = make("Frame", { Size = UDim2.new(1, 0, 1 / TOP_COUNT, -4), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = index % 2 == 1 and 0.94 or 1, BorderSizePixel = 0, LayoutOrder = index, Visible = false }, list)
		make("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
		rows[index] = {
			Frame = row,
			Place = text({ Size = UDim2.new(0, 60, 1, 0), Text = "#" .. index, TextSize = 26, TextColor3 = index <= 3 and Color3.fromRGB(255, 205, 60) or Color3.fromRGB(200, 200, 200) }, row),
			Name = text({ Size = UDim2.new(1, -330, 1, 0), Position = UDim2.fromOffset(66, 0), Text = "", TextSize = 26, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, row),
			Rank = text({ Size = UDim2.new(0, 150, 1, 0), Position = UDim2.new(1, -264, 0, 0), Text = "", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left }, row),
			Exp = text({ Size = UDim2.new(0, 110, 1, 0), Position = UDim2.new(1, -110, 0, 0), Text = "", TextSize = 24, TextXAlignment = Enum.TextXAlignment.Right }, row),
		}
	end
end

-- ชื่อที่แสดงของ userId ที่ยังไม่รู้จัก (ขอทีเดียวเป็นชุด)
local function resolveNames(userIds)
	local missing = {}
	for _, userId in userIds do
		if not nameCache[userId] then
			table.insert(missing, userId)
		end
	end
	if #missing > 0 then
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(missing)
		end)
		if ok then
			for _, info in infos do
				nameCache[info.Id] = info.DisplayName
			end
		end
	end
end

local function refreshBoard()
	local ordered = getStore()
	if not ordered then
		statusLabel.Text = "โหลดอันดับไม่ได้ (DataStore ใช้ไม่ได้)"
		return
	end
	local ok, entries = pcall(function()
		return ordered:GetSortedAsync(false, TOP_COUNT):GetCurrentPage()
	end)
	if not ok then
		warn("[Leaderboard] read failed:", entries)
		statusLabel.Text = "โหลดอันดับไม่ได้ — จะลองใหม่"
		return
	end
	local userIds = {}
	for _, entry in entries do
		local userId = tonumber(entry.key)
		if userId then
			table.insert(userIds, userId)
		end
	end
	resolveNames(userIds)
	for index, row in rows do
		local entry = entries[index]
		local userId = entry and tonumber(entry.key)
		row.Frame.Visible = userId ~= nil
		if userId then
			local rank = Progression.Rank(entry.value)
			row.Name.Text = nameCache[userId] or ("ผู้เล่น " .. userId)
			row.Rank.Text = string.format("%s %s", rank.Icon or "", rank.Name)
			row.Rank.TextColor3 = rank.Color
			row.Exp.Text = string.format("%d EXP", entry.value)
		end
	end
	statusLabel.Text = #entries == 0 and "ยังไม่มีใครติดอันดับ — ไปสู้กันเลย!" or "อัปเดตทุก 1 นาที"
end

-- เรียกเฉพาะ Lobby
function LeaderboardService.StartBoard()
	local board = findOrBuildBoard()
	if not board then
		warn("[Leaderboard] no Lobby/LobbySpawn — board not built")
		return
	end
	buildGui(board)
	task.spawn(function()
		while true do
			refreshBoard()
			task.wait(REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
