-- WaveService: วงจรแมตช์ — 1 แมตช์ = 1 stage = 5 wave (wave 5 มี Boss)
-- สถานะแมตช์เผยแพร่เป็น attribute บน workspace:
--   MatchPhase (Waiting/Countdown/Wave/Break/Victory/Defeat), Stage, StageCount, Wave, WaveCount,
--   PhaseEndsAt, MonstersLeft, DefeatReason (Base/Team), MatchTime, NextStage
-- แพ้เมื่อ HP ฐาน = 0 หรือผู้เล่นทั้งทีมล้มพร้อมกัน (GDD ข้อ 6)
-- เฟส 2 ยังไม่มี lobby: ชนะ -> ไป stage ถัดไป, แพ้ -> เล่น stage เดิมซ้ำ
-- ทดสอบ: ตั้ง attribute workspace.DebugStage = เลข stage เพื่อเริ่มแมตช์ถัดไปที่ stage นั้น,
--          workspace.DebugWave = เลข wave เพื่อข้ามไปเริ่มที่ wave นั้น
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)

local PlayerService = require(script.Parent.PlayerService)
local MonsterService = require(script.Parent.MonsterService)
local BaseService = require(script.Parent.BaseService)
local ProgressionService = require(script.Parent.ProgressionService)

local WaveService = {}

local spawnPart = workspace:WaitForChild("Map"):WaitForChild("MonsterSpawn")
local rng = Random.new()

local function setPhase(phase, duration)
	workspace:SetAttribute("PhaseEndsAt", duration and (workspace:GetServerTimeNow() + duration) or 0)
	workspace:SetAttribute("MatchPhase", phase)
end

-- คืนเหตุผลที่แพ้ ("Base" / "Team") หรือ nil ถ้ายังไม่แพ้
local function defeatReason()
	if BaseService.GetHP() <= 0 then
		return "Base"
	end
	if PlayerService.AllDowned() then
		return "Team"
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
local function runMatch(stage)
	local waves = Config.Waves.Stages[stage]
	BaseService.Reset()
	MonsterService.ClearAll()
	PlayerService.ResetMatch()
	workspace:SetAttribute("Stage", stage)
	workspace:SetAttribute("StageCount", #Config.Waves.Stages)
	workspace:SetAttribute("WaveCount", #waves)
	workspace:SetAttribute("Wave", 1)
	workspace:SetAttribute("MonstersLeft", 0)
	workspace:SetAttribute("DefeatReason", nil)

	setPhase("Waiting")
	while not anyPlayerReady() do
		task.wait(0.5)
	end
	PlayerService.ResetMatch()

	local playerCount = math.clamp(#Players:GetPlayers(), 1, #Config.Waves.PlayerScale)
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
	local nextStage = won and (stage % #Config.Waves.Stages + 1) or stage
	workspace:SetAttribute("DefeatReason", reason)
	workspace:SetAttribute("MatchTime", math.floor(os.clock() - startedAt))
	workspace:SetAttribute("NextStage", nextStage)
	setPhase(won and "Victory" or "Defeat", Config.Waves.ResultTime)
	ProgressionService.AwardAll(stage, won)
	MonsterService.ClearAll()
	task.wait(Config.Waves.ResultTime)
	return nextStage
end

function WaveService.Start()
	task.spawn(function()
		local stage = 1
		while true do
			local debugStage = workspace:GetAttribute("DebugStage")
			if typeof(debugStage) == "number" and Config.Waves.Stages[debugStage] then
				stage = debugStage
				workspace:SetAttribute("DebugStage", nil)
			end
			local ok, result = pcall(runMatch, stage)
			if ok then
				stage = result
			else
				warn("[WaveService] match error:", result)
				task.wait(3)
			end
		end
	end)
end

return WaveService
