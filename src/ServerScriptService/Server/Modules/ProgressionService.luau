-- ProgressionService: รางวัลหลังแมตช์ (หีบชิ้นส่วน + EXP + ปลดล็อค stage), อัพเกรดไอเท็ม, จัด loadout
-- คิดฝั่ง server ทั้งหมด (GDD ข้อ 0) — กติกาอยู่ใน Shared/Progression
-- Remotes:
--   SetLoadout(RemoteFunction, {itemId...}) -> ok, reason   (จัดได้เฉพาะตอนไม่อยู่ในแมตช์)
--   UpgradeItem(RemoteFunction, itemId) -> ok, reason
--   MatchRewards(RemoteEvent → client): { Won, Stage, ExpBefore, Exp, ExpDelta, RankBefore, Rank, Parts, UnlockedStage }
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Progression = require(ReplicatedStorage.Shared.Progression)
local DataService = require(script.Parent.DataService)

local ProgressionService = {}

local rng = Random.new()
local IN_MATCH_PHASES = { Countdown = true, Wave = true, Break = true }
local REQUEST_COOLDOWN = 0.25
local lastRequest = {}

local function throttled(player)
	local now = os.clock()
	if lastRequest[player] and now - lastRequest[player] < REQUEST_COOLDOWN then
		return true
	end
	lastRequest[player] = now
	return false
end

function ProgressionService.InMatch()
	return IN_MATCH_PHASES[workspace:GetAttribute("MatchPhase")] == true
end

-- แจกรางวัลให้ผู้เล่นหนึ่งคน (หีบสุ่มแยกกันทุกคน) — เซฟทันที
function ProgressionService.AwardMatch(player, stage, won)
	local data = DataService.Get(player)
	if not data then
		return nil
	end
	local expBefore = data.Exp
	local reward = Progression.RollMatchReward(data.Exp, data.UnlockedStage, stage, won, rng)
	DataService.Update(player, function(d)
		d.Exp = reward.Exp
		d.UnlockedStage = reward.UnlockedStage
		for id, count in reward.Parts do
			d.Parts[id] = (d.Parts[id] or 0) + count
		end
	end, true)
	local summary = {
		Won = won,
		Stage = stage,
		ExpBefore = expBefore,
		Exp = reward.Exp,
		ExpDelta = reward.ExpDelta,
		RankBefore = Progression.Rank(expBefore).Id,
		Rank = Progression.Rank(reward.Exp).Id,
		Parts = reward.Parts,
		UnlockedStage = reward.UnlockedStage,
	}
	ReplicatedStorage.Remotes.MatchRewards:FireClient(player, summary)
	return summary
end

function ProgressionService.AwardAll(stage, won)
	for _, player in Players:GetPlayers() do
		task.spawn(ProgressionService.AwardMatch, player, stage, won)
	end
end

local function setLoadout(player, loadout)
	if throttled(player) then
		return false, "Busy"
	end
	if ProgressionService.InMatch() then
		return false, "InMatch"
	end
	local data = DataService.Get(player)
	if not data then
		return false, "NotLoaded"
	end
	local ok, reason = Progression.ValidateLoadout(loadout, data.Exp)
	if not ok then
		return false, reason
	end
	local copy = {}
	for index, id in loadout do
		copy[index] = id
	end
	DataService.Update(player, function(d)
		d.Loadout = copy
	end)
	return true
end

local function upgradeItem(player, itemId)
	if throttled(player) then
		return false, "Busy"
	end
	local data = DataService.Get(player)
	if not data then
		return false, "NotLoaded"
	end
	if typeof(itemId) ~= "string" or not Progression.IsUnlocked(itemId, data.Exp) then
		return false, "Locked"
	end
	local level = data.Levels[itemId] or 0
	local cost = Progression.UpgradeCost(itemId, level)
	if not cost then
		return false, "MaxLevel"
	end
	if (data.Parts[itemId] or 0) < cost then
		return false, "NotEnoughParts"
	end
	DataService.Update(player, function(d)
		d.Parts[itemId] -= cost
		if d.Parts[itemId] <= 0 then
			d.Parts[itemId] = nil
		end
		d.Levels[itemId] = level + 1
	end, true)
	return true
end

function ProgressionService.Init()
	local remotes = ReplicatedStorage.Remotes
	for name, class in { SetLoadout = "RemoteFunction", UpgradeItem = "RemoteFunction", MatchRewards = "RemoteEvent" } do
		if not remotes:FindFirstChild(name) then
			local remote = Instance.new(class)
			remote.Name = name
			remote.Parent = remotes
		end
	end
	remotes.SetLoadout.OnServerInvoke = setLoadout
	remotes.UpgradeItem.OnServerInvoke = upgradeItem
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
end

return ProgressionService
