-- WaveService: วงจรแมตช์ — 1 แมตช์ = 1 stage = 5 wave (wave 5 มี Boss)
-- สถานะแมตช์เผยแพร่เป็น attribute บน workspace:
--   MatchPhase (Lobby/Countdown/Wave/Break/Victory/Defeat), Stage, StageCount, Wave, WaveCount,
--   PhaseEndsAt, MonstersLeft, DefeatReason (Base/Team), MatchTime
-- แพ้เมื่อ HP ฐาน = 0 หรือผู้เล่นทั้งทีมล้มพร้อมกัน (GDD ข้อ 6)
-- เฟส 4: แมตช์เล่นใน reserved server (ServerMode = Match) — StartMatchServer:
--   อ่านข้อมูลแมตช์จาก MemoryStore -> รอทีมมาครบ (ArrivalTimeout) -> เล่น -> แจกรางวัล -> teleport ทุกคนกลับ Lobby
--   (TeleportData: MatchId, Rewards[userId] = สรุปรางวัลให้หน้าเปิดหีบ, Parties = ทีมเดิมไว้รวมใหม่ใน Lobby)
-- Lobby ใน Studio (teleport ไม่ได้): PartyService เรียก RequestLocalMatch -> เล่นในป้อมของ server นี้แล้วกลับ Lobby
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
local ServerMode = require(script.Parent.ServerMode)
local MatchmakingService = require(script.Parent.MatchmakingService)
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

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

-- คืนรางวัลของแต่ละคน { [tostring(userId)] = summary }
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
	-- รางวัล: ทุกคนที่ยังอยู่ในแมตช์ตอนจบ (รวมคนที่มาถึงทีหลัง)
	local remaining = {}
	for _, player in Players:GetPlayers() do
		if PlayerService.InMatch(player) then
			table.insert(remaining, player)
		end
	end
	local rewards = ProgressionService.AwardAll(stage, won, remaining)
	MonsterService.ClearAll()
	task.wait(Config.Waves.ResultTime)
	return rewards
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

---------------------------------------------------------------- Lobby ใน Studio: แมตช์ในป้อมของ server นี้

local localRequest = nil -- { Stage, Players, OnDone }
local localRunning = false

function WaveService.LocalMatchBusy()
	return localRunning or localRequest ~= nil
end

-- คืน false ถ้าป้อมไม่ว่าง; onDone() เรียกหลังทุกคนกลับ Lobby
function WaveService.RequestLocalMatch(stage, players, onDone)
	if WaveService.LocalMatchBusy() then
		return false
	end
	localRequest = { Stage = stage, Players = players, OnDone = onDone }
	return true
end

function WaveService.StartLobby()
	workspace:SetAttribute("StageCount", #Config.Waves.Stages)
	setPhase("Lobby")
	task.spawn(function()
		while true do
			while not localRequest do
				task.wait(0.2)
			end
			local request = localRequest
			localRunning = true
			localRequest = nil
			local present = {}
			for _, player in request.Players do
				if player.Parent then
					table.insert(present, player)
				end
			end
			if #present > 0 then
				local ok, err = pcall(runMatch, request.Stage, present)
				if not ok then
					warn("[WaveService] match error:", err)
				end
			end
			pcall(returnToLobby)
			localRunning = false
			if request.OnDone then
				task.spawn(request.OnDone)
			end
		end
	end)
end

---------------------------------------------------------------- server แมตช์ (reserved server)

local returnData = nil -- TeleportData ตอนส่งกลับ Lobby (ตั้งเมื่อจบแมตช์)
local returnAttempts = {}

local function sendToLobby(players)
	if ServerMode.IsDebugMatch() then
		-- Studio: ไม่มี Lobby ให้กลับ — ทำแบบแมตช์ในป้อม
		pcall(returnToLobby)
		return
	end
	if #players == 0 then
		return
	end
	local ok = MatchmakingService.Teleport(players, nil, returnData)
	if not ok then
		for _, player in players do
			player:Kick("กลับ Lobby ไม่สำเร็จ — กรุณาเข้าเกมใหม่ (ความคืบหน้าบันทึกแล้ว)")
		end
	end
end

function WaveService.StartMatchServer()
	workspace:SetAttribute("StageCount", #Config.Waves.Stages)
	setPhase("Waiting")

	-- teleport กลับ Lobby ล้ม: ลองใหม่ 3 ครั้งแล้วค่อย kick
	TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		warn("[WaveService] return teleport failed:", player.Name, result, message)
		returnAttempts[player] = (returnAttempts[player] or 0) + 1
		if returnAttempts[player] > 3 then
			player:Kick("กลับ Lobby ไม่สำเร็จ — กรุณาเข้าเกมใหม่ (ความคืบหน้าบันทึกแล้ว)")
		else
			task.delay(2, sendToLobby, { player })
		end
	end)

	task.spawn(function()
		local info = ServerMode.LoadMatchInfo()
		local finished = false
		local started = false
		local expected = nil
		if info and info.UserIds then
			expected = {}
			for _, userId in info.UserIds do
				expected[userId] = true
			end
		end
		local ready = {}

		local function admit(player)
			if not info or finished or (expected and not expected[player.UserId]) then
				sendToLobby({ player })
				return
			end
			DataService.WaitForProfile(player)
			if not player.Parent or finished then
				return
			end
			ProgressionService.ApplyKit(player) -- ชุดตาม loadout ก่อนล็อค (InMatch)
			PlayerService.EnterMatch(player)
			ready[player] = true
			if started then
				print("[WaveService] late arrival:", player.Name)
			end
		end
		Players.PlayerAdded:Connect(admit)
		Players.PlayerRemoving:Connect(function(player)
			ready[player] = nil
			returnAttempts[player] = nil
		end)
		for _, player in Players:GetPlayers() do
			task.spawn(admit, player)
		end
		if not info then
			warn("[WaveService] no match info for this server — sending players back")
			finished = true
			return
		end
		workspace:SetAttribute("Stage", info.Stage)

		-- รอคนแรก (ไม่มีใครมาใน 60 วิ = ปล่อยให้ server ปิดเอง)
		local giveUp = os.clock() + 60
		while not next(ready) and os.clock() < giveUp do
			task.wait(0.2)
		end
		if not next(ready) then
			finished = true
			return
		end
		-- รอทีมมาครบ
		setPhase("Waiting", Config.Party.ArrivalTimeout)
		local deadline = os.clock() + Config.Party.ArrivalTimeout
		while os.clock() < deadline do
			local missing = false
			if expected then
				for userId in expected do
					local player = Players:GetPlayerByUserId(userId)
					if not player or not ready[player] then
						missing = true
						break
					end
				end
			else
				missing = os.clock() < deadline - Config.Party.ArrivalTimeout + 3 -- debug: รอ 3 วิ
			end
			if not missing then
				break
			end
			task.wait(0.2)
		end

		local participants = {}
		for player in ready do
			if player.Parent then
				table.insert(participants, player)
			end
		end
		started = true
		local rewards = {}
		if #participants > 0 then
			local ok, result = pcall(runMatch, info.Stage, participants)
			if ok then
				rewards = result or {}
			else
				warn("[WaveService] match error:", result)
			end
		end
		finished = true
		returnData = { MatchId = game.JobId, Rewards = rewards, Parties = info.Parties }
		sendToLobby(Players:GetPlayers())
	end)
end

return WaveService
