-- WaveService: วงจรแมตช์ — 1 แมตช์ = 1 stage = 5 wave (wave 5 มี Boss)
-- สถานะแมตช์เผยแพร่เป็น attribute บน workspace:
--   MatchPhase (Lobby/Countdown/Wave/Break/Victory/Defeat), Stage, StageCount, Wave, WaveCount,
--   PhaseEndsAt, MonstersLeft, DefeatReason (Base/Team), MatchTime
-- แพ้เมื่อ HP ฐาน = 0 หรือผู้เล่นทั้งทีมล้มพร้อมกัน (GDD ข้อ 6)
-- เฟส 3: ผู้เล่นอยู่ที่ Lobby กด Play (Remotes.StartMatch(stage)) -> ย้ายไปป้อมแล้วเริ่มแมตช์
--   จบแมตช์ -> แจกรางวัล -> กลับ Lobby; server นี้มีป้อมเดียว จึงเล่นได้ทีละแมตช์ (เฟส 4 ย้ายไป reserved server)
--   ผู้เล่นในแมตช์มี attribute InMatch = true
-- ทดสอบ: ตั้ง attribute workspace.DebugWave = เลข wave เพื่อข้ามไปเริ่มที่ wave นั้น,
--          workspace.DebugUnlockAll = true เพื่อเลือก stage ที่ยังไม่ปลดล็อคได้ (เฉพาะใน Studio)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)

local PlayerService = require(script.Parent.PlayerService)
local MonsterService = require(script.Parent.MonsterService)
local BaseService = require(script.Parent.BaseService)
local ProgressionService = require(script.Parent.ProgressionService)
local DataService = require(script.Parent.DataService)
local RunService = game:GetService("RunService")

local WaveService = {}

local spawnPart = workspace:WaitForChild("Map"):WaitForChild("MonsterSpawn")
local rng = Random.new()

local function setPhase(phase, duration)
	workspace:SetAttribute("PhaseEndsAt", duration and (workspace:GetServerTimeNow() + duration) or 0)
	workspace:SetAttribute("MatchPhase", phase)
end

local function participantsLeft()
	for _, player in Players:GetPlayers() do
		if PlayerService.InMatch(player) then
			return true
		end
	end
	return false
end

-- คืนเหตุผลที่แพ้ ("Base" / "Team") หรือ nil ถ้ายังไม่แพ้
local function defeatReason()
	if BaseService.GetHP() <= 0 then
		return "Base"
	end
	if PlayerService.AllDowned() then
		return "Team"
	end
	if not participantsLeft() then
		return "Abandoned" -- ทุกคนออกเกมกลางแมตช์
	end
	return nil
end

local function lost()
	return defeatReason() ~= nil
end

local function waitSeconds(seconds)
	local deadline = os.clock() + seconds
	while os.clock() < deadline and not lost() do
		task.wait(0.1)
	end
end

local pendingRequest = nil -- { Player, Stage }
local matchRunning = false

-- Play จาก Lobby: คืน (ok, reason)
local function onStartMatch(player, stage)
	if matchRunning or pendingRequest then
		return false, "Busy"
	end
	if typeof(stage) ~= "number" or not Config.Waves.Stages[stage] then
		return false, "Invalid"
	end
	local data = DataService.Get(player)
	if not data then
		return false, "NotLoaded"
	end
	local unlockAll = RunService:IsStudio() and workspace:GetAttribute("DebugUnlockAll") == true
	if stage > data.UnlockedStage and not unlockAll then
		return false, "Locked"
	end
	if not PlayerService.GetCharacterParts(player) then
		return false, "NoCharacter"
	end
	pendingRequest = { Player = player, Stage = stage }
	return true
end

local function spawnPosition()
	local half = spawnPart.Size / 2
	local offset = Vector3.new(rng:NextNumber(-half.X, half.X), 0, rng:NextNumber(-half.Z, half.Z))
	return Vector3.new(spawnPart.Position.X, 3.5, spawnPart.Position.Z) + offset
end

-- ลำดับการ spawn ของ wave: Boss ออกก่อน ที่เหลือสลับกัน
local function buildQueue(waveDef, scale)
	local bosses, others = {}, {}
	for kind, count in waveDef do
		local cfg = Config.Monsters[kind]
		if cfg.Boss then
			for _ = 1, count do
				table.insert(bosses, kind)
			end
		else
			for _ = 1, math.max(1, math.ceil(count * scale)) do
				table.insert(others, kind)
			end
		end
	end
	for index = #others, 2, -1 do
		local swap = rng:NextInteger(1, index)
		others[index], others[swap] = others[swap], others[index]
	end
	return table.move(others, 1, #others, #bosses + 1, bosses)
end

local function runWave(waveDef, scale, options)
	local queue = buildQueue(waveDef, scale)
	local remainingToSpawn = #queue
	workspace:SetAttribute("MonstersLeft", remainingToSpawn)

	for _, kind in queue do
		if lost() then
			return
		end
		MonsterService.Spawn(kind, spawnPosition(), options)
		remainingToSpawn -= 1
		workspace:SetAttribute("MonstersLeft", remainingToSpawn + MonsterService.Count())
		waitSeconds(Config.Waves.SpawnInterval)
	end
	while MonsterService.Count() > 0 and not lost() do
		workspace:SetAttribute("MonstersLeft", MonsterService.Count())
		task.wait(0.2)
	end
	workspace:SetAttribute("MonstersLeft", MonsterService.Count())
end

-- คืน true ถ้าชนะ
local function runMatch(stage, participants)
	local waves = Config.Waves.Stages[stage]
	BaseService.Reset()
	MonsterService.ClearAll()
	workspace:SetAttribute("Stage", stage)
	workspace:SetAttribute("StageCount", #Config.Waves.Stages)
	workspace:SetAttribute("WaveCount", #waves)
	workspace:SetAttribute("Wave", 1)
	workspace:SetAttribute("MonstersLeft", 0)
	workspace:SetAttribute("DefeatReason", nil)
	workspace:SetAttribute("BossHP", nil)
	workspace:SetAttribute("BossMaxHP", nil)
	for _, player in participants do
		PlayerService.EnterMatch(player)
	end

	local playerCount = math.clamp(#participants, 1, #Config.Waves.PlayerScale)
	local scale = Config.Waves.PlayerScale[playerCount]
	local options = { Stage = stage, PlayerCount = playerCount }

	setPhase("Countdown", Config.Waves.StartDelay)
	waitSeconds(Config.Waves.StartDelay)
	local startedAt = os.clock()

	local firstWave = math.clamp(workspace:GetAttribute("DebugWave") or 1, 1, #waves)
	workspace:SetAttribute("DebugWave", nil)

	for index = firstWave, #waves do
		workspace:SetAttribute("Wave", index)
		setPhase("Wave")
		runWave(waves[index], scale, options)
		if lost() then
			break
		end
		-- จบ wave: คนที่ล้มและไม่มีใครชุบ respawn ที่ฐาน
		PlayerService.RespawnDowned()
		if index < #waves then
			setPhase("Break", Config.Waves.BreakTime)
			waitSeconds(Config.Waves.BreakTime)
			if lost() then
				break
			end
		end
	end

	local reason = defeatReason()
	local won = reason == nil
	workspace:SetAttribute("DefeatReason", reason)
	workspace:SetAttribute("MatchTime", math.floor(os.clock() - startedAt))
	setPhase(won and "Victory" or "Defeat", Config.Waves.ResultTime)
	local remaining = {}
	for _, player in participants do
		if player.Parent and PlayerService.InMatch(player) then
			table.insert(remaining, player)
		end
	end
	ProgressionService.AwardAll(stage, won, remaining)
	MonsterService.ClearAll()
	task.wait(Config.Waves.ResultTime)
end

local function returnToLobby()
	MonsterService.ClearAll()
	BaseService.Reset()
	for _, player in Players:GetPlayers() do
		if PlayerService.InMatch(player) then
			PlayerService.LeaveMatch(player)
		end
	end
	workspace:SetAttribute("BossHP", nil)
	workspace:SetAttribute("BossMaxHP", nil)
	setPhase("Lobby")
end

function WaveService.Start()
	local remote = Instance.new("RemoteFunction")
	remote.Name = "StartMatch"
	remote.Parent = ReplicatedStorage.Remotes
	remote.OnServerInvoke = onStartMatch
	workspace:SetAttribute("StageCount", #Config.Waves.Stages)
	setPhase("Lobby")

	task.spawn(function()
		while true do
			while not pendingRequest do
				task.wait(0.2)
			end
			local request = pendingRequest
			matchRunning = true
			pendingRequest = nil
			if request.Player.Parent then
				local ok, err = pcall(runMatch, request.Stage, { request.Player })
				if not ok then
					warn("[WaveService] match error:", err)
				end
			end
			pcall(returnToLobby)
			matchRunning = false
		end
	end)
end

return WaveService
