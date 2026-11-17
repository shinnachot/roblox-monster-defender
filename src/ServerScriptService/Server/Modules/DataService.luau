-- DataService: โหลด/เซฟโปรไฟล์ผู้เล่นใน DataStore (GDD เฟส 3)
-- โปรไฟล์: Exp, Parts {[itemId]=n}, Levels {[itemId]=lv}, Loadout {itemId...} (nil = ชุดเริ่มต้น), UnlockedStage
-- session lock: เก็บ JobId ของ server ที่ถือโปรไฟล์ไว้ กัน 2 server เขียนทับกันตอน teleport (เฟส 4)
-- ถ้า DataStore ใช้ไม่ได้ (เช่น Studio ไม่เปิด API access) ใช้โปรไฟล์ชั่วคราวและไม่เซฟทับของจริง
-- เผยแพร่ให้ client: attribute บน Player (Exp, Rank, UnlockedStage, ProfileLoaded) + Remotes.ProfileChanged(snapshot)
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Progression = require(ReplicatedStorage.Shared.Progression)

local DataService = {}

local STORE_NAME = "PlayerData_v1"
local VERSION = 1
local AUTOSAVE_INTERVAL = 120
local LOCK_TIMEOUT = 600 -- lock เก่ากว่านี้ (วินาที) ถือว่า server นั้นตายไปแล้ว
local LOCK_RETRIES = 6
local LOCK_RETRY_WAIT = 3
local CALL_RETRIES = 3

local store = nil
local profiles = {} -- [player] = { Data = table, Persistent = bool, Dirty = bool }
local loadedSignal = Instance.new("BindableEvent")
local jobId = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(math.random(1, 1e9)))

local function defaultData()
	return {
		Version = VERSION,
		Exp = 0,
		Parts = {},
		Levels = {},
		Loadout = nil,
		UnlockedStage = 1,
	}
end

-- เติม field ที่ขาด / ตัดค่าเสีย (เช่น id ไอเท็มที่ถูกลบจาก config)
local function reconcile(data)
	local clean = defaultData()
	if typeof(data) ~= "table" then
		return clean
	end
	clean.Exp = typeof(data.Exp) == "number" and math.max(0, math.floor(data.Exp)) or 0
	clean.UnlockedStage = typeof(data.UnlockedStage) == "number"
			and math.clamp(math.floor(data.UnlockedStage), 1, #Config.Waves.Stages)
		or 1
	for _, field in { "Parts", "Levels" } do
		if typeof(data[field]) == "table" then
			for id, value in data[field] do
				if Config.Items[id] and typeof(value) == "number" and value > 0 then
					clean[field][id] = math.floor(value)
				end
			end
		end
	end
	if typeof(data.Loadout) == "table" and Progression.ValidateLoadout(data.Loadout, clean.Exp) then
		clean.Loadout = table.clone(data.Loadout)
	end
	return clean
end

local function keyFor(player)
	return "Player_" .. player.UserId
end

local function retry(fn)
	local lastErr
	for attempt = 1, CALL_RETRIES do
		local ok, a, b = pcall(fn)
		if ok then
			return true, a, b
		end
		lastErr = a
		task.wait(attempt)
	end
	return false, lastErr
end

---------------------------------------------------------------- ส่งให้ client

function DataService.Snapshot(player)
	local profile = profiles[player]
	if not profile then
		return nil
	end
	local data = profile.Data
	return {
		Exp = data.Exp,
		Rank = Progression.Rank(data.Exp).Id,
		Parts = table.clone(data.Parts),
		Levels = table.clone(data.Levels),
		Loadout = table.clone(DataService.GetLoadout(player)),
		UnlockedStage = data.UnlockedStage,
		Persistent = profile.Persistent,
	}
end

local function publish(player)
	local profile = profiles[player]
	if not profile or not player.Parent then
		return
	end
	local data = profile.Data
	player:SetAttribute("Exp", data.Exp)
	player:SetAttribute("Rank", Progression.Rank(data.Exp).Id)
	player:SetAttribute("UnlockedStage", data.UnlockedStage)
	ReplicatedStorage.Remotes.ProfileChanged:FireClient(player, DataService.Snapshot(player))
end

---------------------------------------------------------------- โหลด / เซฟ

-- คืน (data, persistent)
local function loadProfile(player)
	if not store then
		return defaultData(), false
	end
	local key = keyFor(player)
	for attempt = 1, LOCK_RETRIES do
		local locked = false
		local ok, result = retry(function()
			return store:UpdateAsync(key, function(old)
				locked = false
				old = typeof(old) == "table" and old or defaultData()
				local lock = old.Lock
				local stale = attempt == LOCK_RETRIES -- รอครบแล้ว = ยึด lock
				if lock and lock.JobId ~= jobId and os.time() - (lock.Time or 0) < LOCK_TIMEOUT and not stale then
					locked = true
					return nil -- ไม่เขียน
				end
				old.Lock = { JobId = jobId, Time = os.time() }
				return old
			end)
		end)
		if not ok then
			warn("[DataService] load failed for", player.Name, result)
			return defaultData(), false
		end
		if not locked then
			return reconcile(result), true
		end
		if not player.Parent then
			return nil, false
		end
		task.wait(LOCK_RETRY_WAIT)
	end
	return defaultData(), false
end

local function saveProfile(player, release)
	local profile = profiles[player]
	if not profile or not profile.Persistent then
		return true
	end
	local data = table.clone(profile.Data)
	local ok, err = retry(function()
		return store:UpdateAsync(keyFor(player), function(old)
			if typeof(old) == "table" and old.Lock and old.Lock.JobId ~= jobId then
				return nil -- server อื่นยึดโปรไฟล์ไปแล้ว: ไม่เขียนทับ
			end
			data.Lock = not release and { JobId = jobId, Time = os.time() } or nil
			return data
		end)
	end)
	if ok then
		profile.Dirty = false
	else
		warn("[DataService] save failed for", player.Name, err)
	end
	return ok
end

local function onPlayerAdded(player)
	local data, persistent = loadProfile(player)
	if not data then
		return
	end
	if not player.Parent then
		-- ออกไประหว่างโหลด: ปลด lock ที่เพิ่งตั้งทิ้ง
		if persistent then
			profiles[player] = { Data = data, Persistent = true, Dirty = false }
			saveProfile(player, true)
			profiles[player] = nil
		end
		return
	end
	profiles[player] = { Data = data, Persistent = persistent, Dirty = false }
	if not persistent then
		warn("[DataService] using a temporary profile for", player.Name, "(progress will not be saved)")
	end
	publish(player)
	player:SetAttribute("ProfileLoaded", true)
	loadedSignal:Fire(player)
end

local function onPlayerRemoving(player)
	if profiles[player] then
		saveProfile(player, true)
		profiles[player] = nil
	end
end

---------------------------------------------------------------- API

-- รอจนโปรไฟล์โหลด (หรือผู้เล่นออก) — คืนตาราง Data หรือ nil
function DataService.WaitForProfile(player)
	while player.Parent and not profiles[player] do
		loadedSignal.Event:Wait()
	end
	return profiles[player] and profiles[player].Data
end

function DataService.Get(player)
	return profiles[player] and profiles[player].Data
end

-- แก้โปรไฟล์ผ่าน fn(data) แล้วส่งให้ client (เซฟจริงตอน autosave / ออกเกม / saveNow)
function DataService.Update(player, fn, saveNow)
	local profile = profiles[player]
	if not profile then
		return false
	end
	fn(profile.Data)
	profile.Dirty = true
	publish(player)
	if saveNow then
		task.spawn(saveProfile, player, false)
	end
	return true
end

function DataService.GetLoadout(player)
	local data = DataService.Get(player)
	return data and data.Loadout or Config.Loadout.Starter
end

function DataService.GetLevel(player, itemId)
	local data = DataService.Get(player)
	return data and data.Levels[itemId] or 0
end

function DataService.Init()
	local remotes = ReplicatedStorage.Remotes
	for name, class in { ProfileChanged = "RemoteEvent", GetProfile = "RemoteFunction" } do
		if not remotes:FindFirstChild(name) then
			local remote = Instance.new(class)
			remote.Name = name
			remote.Parent = remotes
		end
	end
	remotes.GetProfile.OnServerInvoke = function(player)
		DataService.WaitForProfile(player)
		return DataService.Snapshot(player)
	end

	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[DataService] DataStore unavailable:", result)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for player, profile in profiles do
				if profile.Dirty then
					task.spawn(saveProfile, player, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		local pending = 0
		for player in profiles do
			pending += 1
			task.spawn(function()
				saveProfile(player, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + (RunService:IsStudio() and 5 or 25)
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
