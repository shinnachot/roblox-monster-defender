-- WaveService: วงจรแมตช์ (นับถอยหลัง -> wave -> พัก -> ... -> ชนะ/แพ้)
-- สถานะแมตช์เผยแพร่เป็น attribute บน workspace: MatchPhase, Wave, WaveCount, PhaseEndsAt, MonstersLeft
-- เฟส 1: เล่น stage 1 (Goblin ล้วน) วนซ้ำใน place เดียว — Boss/stage อื่น/ล้ม-ชุบ มาในเฟส 2
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)

local PlayerService = require(script.Parent.PlayerService)
local MonsterService = require(script.Parent.MonsterService)
local BaseService = require(script.Parent.BaseService)

local WaveService = {}

local spawnPart = workspace:WaitForChild("Map"):WaitForChild("MonsterSpawn")
local rng = Random.new()

local function setPhase(phase, duration)
	workspace:SetAttribute("PhaseEndsAt", duration and (workspace:GetServerTimeNow() + duration) or 0)
	workspace:SetAttribute("MatchPhase", phase)
end

local function lost()
	return BaseService.GetHP() <= 0
end

local function waitSeconds(seconds)
	local deadline = os.clock() + seconds
	while os.clock() < deadline and not lost() do
		task.wait(0.1)
	end
end

local function anyPlayerReady()
	for _, player in Players:GetPlayers() do
		if PlayerService.GetCharacterParts(player) then
			return true
		end
	end
	return false
end

local function spawnPosition()
	local half = spawnPart.Size / 2
	local offset = Vector3.new(rng:NextNumber(-half.X, half.X), 0, rng:NextNumber(-half.Z, half.Z))
	return Vector3.new(spawnPart.Position.X, 3.5, spawnPart.Position.Z) + offset
end

local function runWave(waveDef, scale)
	local queue = {}
	for kind, count in waveDef do
		for _ = 1, math.max(1, math.ceil(count * scale)) do
			table.insert(queue, kind)
		end
	end
	local remainingToSpawn = #queue
	workspace:SetAttribute("MonstersLeft", remainingToSpawn)

	for _, kind in queue do
		if lost() then
			return
		end
		MonsterService.Spawn(kind, spawnPosition())
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

local function runMatch(stage)
	local waves = Config.Waves.Stages[stage]
	BaseService.Reset()
	MonsterService.ClearAll()
	PlayerService.ResetMatch()
	workspace:SetAttribute("Stage", stage)
	workspace:SetAttribute("WaveCount", #waves)
	workspace:SetAttribute("Wave", 1)
	workspace:SetAttribute("MonstersLeft", 0)

	setPhase("Waiting")
	while not anyPlayerReady() do
		task.wait(0.5)
	end
	PlayerService.ResetMatch()

	local playerCount = math.clamp(#Players:GetPlayers(), 1, #Config.Waves.PlayerScale)
	local scale = Config.Waves.PlayerScale[playerCount]

	setPhase("Countdown", Config.Waves.StartDelay)
	waitSeconds(Config.Waves.StartDelay)

	for index, waveDef in waves do
		workspace:SetAttribute("Wave", index)
		setPhase("Wave")
		runWave(waveDef, scale)
		if lost() then
			break
		end
		if index < #waves then
			setPhase("Break", Config.Waves.BreakTime)
			waitSeconds(Config.Waves.BreakTime)
		end
	end

	setPhase(lost() and "Defeat" or "Victory", Config.Waves.ResultTime)
	MonsterService.ClearAll()
	task.wait(Config.Waves.ResultTime)
end

function WaveService.Start()
	task.spawn(function()
		while true do
			local ok, err = pcall(runMatch, 1)
			if not ok then
				warn("[WaveService] match error:", err)
				task.wait(3)
			end
		end
	end)
end

return WaveService
