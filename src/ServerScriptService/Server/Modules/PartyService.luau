-- PartyService: ทีมใน Lobby (สูงสุด 3 คน), คำชวน, เลือก stage, กด Play (GDD ข้อ 2, เฟส 4)
-- ผู้เล่นทุกคนใน Lobby อยู่ในทีมเสมอ (คนเดียว = ทีมเดี่ยว)
-- หัวหน้าทีมเลือก stage ได้ถึงที่ตัวเองปลดล็อค; Play ตอนทีมครบ 3 -> ไปเลย, ไม่ครบ -> หาผู้เล่นข้าม server 30 วิ
-- Remotes:
--   PartyAction(RemoteFunction, action, arg) -> ok, reason
--     "Invite"(userId) "Respond"(accept) "Leave" "Kick"(userId) "SetStage"(n) "Play" "StartNow" "Cancel"
--   PartyState(RemoteEvent -> client, snapshot) / GetPartyState(RemoteFunction) -> snapshot
--     snapshot = { Id, LeaderId, Members = {{UserId, Name, Rank}}, Stage, Status, Deadline, Found, MaxSize,
--                  Invite = { FromUserId, FromName, ExpiresAt }? }
--     Status: Idle / Searching / Found (ถูกรวมกับทีมอื่นแล้ว รอเริ่ม) / Teleporting / Local (เล่นในป้อมของ server นี้ — Studio)
--   PartyNotice(RemoteEvent -> client, text)
-- attribute บน Player: PartyId, PartySize (ให้ client รู้ว่าใครชวนได้)
-- กลับจากแมตช์: TeleportData.Parties -> รวมทีมเดิมให้เอง; ผู้เล่นที่เข้าตามเพื่อน (FollowUserId) ได้คำชวนจากเพื่อนอัตโนมัติ
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Progression = require(ReplicatedStorage.Shared.Progression)
local DataService = require(script.Parent.DataService)
local PlayerService = require(script.Parent.PlayerService)
local MatchmakingService = require(script.Parent.MatchmakingService)
local WaveService = require(script.Parent.WaveService)

local PartyService = {}

local PartyCfg = Config.Party
local Remotes = ReplicatedStorage.Remotes
local ACTION_COOLDOWN = 0.2

local parties = {} -- [id] = party
local playerParty = {} -- [player] = party
local invites = {} -- [target player] = { From = player, PartyId, ExpiresAt }
local reunions = {} -- [token] = { Leader = userId, UserIds = {...}, ExpiresAt }
local lastAction = {}

---------------------------------------------------------------- สถานะ / ส่งให้ client

local function unlockedStageOf(player)
	if RunService:IsStudio() and workspace:GetAttribute("DebugUnlockAll") == true then
		return #Config.Waves.Stages
	end
	local data = DataService.Get(player)
	return data and data.UnlockedStage or 1
end

local function snapshot(party, viewer)
	local members = {}
	for _, member in party.Members do
		table.insert(members, {
			UserId = member.UserId,
			Name = member.DisplayName,
			Rank = Progression.Rank(member:GetAttribute("Exp") or 0).Id,
		})
	end
	local invite = invites[viewer]
	return {
		Id = party.Id,
		LeaderId = party.Leader.UserId,
		Members = members,
		Stage = party.Stage,
		Status = party.Status,
		Deadline = party.Deadline,
		Found = party.Found,
		MaxSize = PartyCfg.MaxSize,
		Invite = invite and {
			FromUserId = invite.From.UserId,
			FromName = invite.From.DisplayName,
			ExpiresAt = invite.ExpiresAt,
		} or nil,
	}
end

local function publishTo(player)
	local party = playerParty[player]
	if party and player.Parent then
		Remotes.PartyState:FireClient(player, snapshot(party, player))
	end
end

local function publish(party)
	for _, member in party.Members do
		member:SetAttribute("PartyId", party.Id)
		member:SetAttribute("PartySize", #party.Members)
		publishTo(member)
	end
end

local function notice(player, text)
	if player.Parent then
		Remotes.PartyNotice:FireClient(player, text)
	end
end

local function noticeAll(party, text)
	for _, member in party.Members do
		notice(member, text)
	end
end

---------------------------------------------------------------- ทีม

local function newParty(leader)
	local party = {
		Id = HttpService:GenerateGUID(false),
		Leader = leader,
		Members = { leader },
		Stage = unlockedStageOf(leader),
		Status = "Idle",
		Deadline = nil,
		Found = nil,
		Ticket = nil,
		ReunionToken = nil,
	}
	parties[party.Id] = party
	playerParty[leader] = party
	publish(party)
	return party
end

local function clampStage(party)
	party.Stage = math.clamp(party.Stage or 1, 1, unlockedStageOf(party.Leader))
end

local function setIdle(party)
	party.Status = "Idle"
	party.Deadline = nil
	party.Found = nil
	party.Ticket = nil
	publish(party)
end

local function cancelSearch(party, text)
	if party.Ticket then
		party.Ticket.Cancelled = true
	end
	if party.Status == "Searching" or party.Status == "Found" then
		setIdle(party)
		if text then
			noticeAll(party, text)
		end
	end
end

-- เอาผู้เล่นออกจากทีม (ไม่สร้างทีมใหม่ให้)
local function detach(player)
	local party = playerParty[player]
	if not party then
		return
	end
	playerParty[player] = nil
	local index = table.find(party.Members, player)
	if index then
		table.remove(party.Members, index)
	end
	if #party.Members == 0 then
		if party.Ticket then
			party.Ticket.Cancelled = true
		end
		parties[party.Id] = nil
		return
	end
	cancelSearch(party, string.format("%s ออกจากทีม — ยกเลิกการหาผู้เล่น", player.DisplayName))
	if party.Leader == player then
		party.Leader = party.Members[1]
		clampStage(party)
		noticeAll(party, string.format("%s เป็นหัวหน้าทีมคนใหม่", party.Leader.DisplayName))
	end
	publish(party)
end

local function isSoloIdle(player)
	local party = playerParty[player]
	return party ~= nil and #party.Members == 1 and party.Status == "Idle"
end

local function join(player, party)
	local old = playerParty[player]
	if old == party then
		return
	end
	detach(player)
	table.insert(party.Members, player)
	playerParty[player] = party
	publish(party)
end

local function closeInvite(target)
	if invites[target] then
		invites[target] = nil
		publishTo(target)
	end
end

---------------------------------------------------------------- เริ่มแมตช์

local function launch(party, accessCode)
	if accessCode == MatchmakingService.STUDIO_CODE then
		-- Studio: เล่นในป้อมของ server นี้
		local members = table.clone(party.Members)
		local ok = WaveService.RequestLocalMatch(party.Stage, members, function()
			if parties[party.Id] and party.Status == "Local" then
				setIdle(party)
			end
		end)
		if ok then
			party.Status = "Local"
			party.Deadline = nil
			publish(party)
		else
			setIdle(party)
			noticeAll(party, "มีแมตช์กำลังเล่นอยู่ที่ป้อม — รอสักครู่")
		end
		return
	end
	party.Status = "Teleporting"
	party.Deadline = nil
	publish(party)
	local members = {}
	for _, member in party.Members do
		if member.Parent then
			table.insert(members, member)
		end
	end
	local ok = MatchmakingService.Teleport(members, accessCode, { Mode = "Match" })
	if not ok and parties[party.Id] then
		setIdle(party)
		noticeAll(party, "ย้ายไปด่านไม่สำเร็จ — ลองกดเล่นอีกครั้ง")
	end
end

local function startSearch(party)
	local ticket
	ticket = {
		Stage = party.Stage,
		GetUserIds = function()
			local ids = {}
			for _, member in party.Members do
				table.insert(ids, member.UserId)
			end
			return ids
		end,
		GetLeader = function()
			return party.Leader.UserId
		end,
		OnStatus = function(status, count)
			if party.Ticket ~= ticket or ticket.Cancelled then
				return
			end
			if party.Status ~= status or party.Found ~= count then
				party.Status = status
				party.Found = count
				publish(party)
			end
		end,
		OnLaunch = function(accessCode)
			if party.Ticket == ticket and not ticket.Cancelled and parties[party.Id] then
				party.Ticket = nil
				launch(party, accessCode)
			end
		end,
		OnFailed = function()
			if party.Ticket == ticket and parties[party.Id] then
				setIdle(party)
				noticeAll(party, "หาด่านไม่สำเร็จ — ลองกดเล่นอีกครั้ง")
			end
		end,
	}
	party.Ticket = ticket
	party.Status = "Searching"
	party.Found = #party.Members
	MatchmakingService.Search(ticket)
	party.Deadline = ticket.Deadline
	publish(party)
end

local function launchDirect(party)
	party.Status = "Teleporting"
	publish(party)
	local ids = {}
	for _, member in party.Members do
		table.insert(ids, member.UserId)
	end
	local code = MatchmakingService.Reserve(party.Stage, { { Leader = party.Leader.UserId, UserIds = ids } })
	if not parties[party.Id] or party.Status ~= "Teleporting" then
		return
	end
	if not code then
		setIdle(party)
		noticeAll(party, "หาด่านไม่สำเร็จ — ลองกดเล่นอีกครั้ง")
		return
	end
	launch(party, code)
end

---------------------------------------------------------------- คำสั่งจาก client

local actions = {}

function actions.Invite(player, party, userId)
	if party.Leader ~= player then
		return false, "NotLeader"
	end
	if party.Status ~= "Idle" then
		return false, "Busy"
	end
	if #party.Members >= PartyCfg.MaxSize then
		return false, "Full"
	end
	local target = typeof(userId) == "number" and Players:GetPlayerByUserId(userId)
	if not target or target == player then
		return false, "NoTarget"
	end
	if not isSoloIdle(target) or target:GetAttribute("InMatch") == true then
		return false, "TargetBusy"
	end
	local existing = invites[target]
	if existing and existing.ExpiresAt > os.time() and existing.From ~= player then
		return false, "TargetBusy"
	end
	invites[target] = { From = player, PartyId = party.Id, ExpiresAt = os.time() + PartyCfg.InviteTimeout }
	publishTo(target)
	return true
end

function actions.Respond(player, party, accept)
	local invite = invites[player]
	if not invite then
		return false, "NoInvite"
	end
	closeInvite(player)
	local from = invite.From
	local target = parties[invite.PartyId]
	if accept ~= true then
		notice(from, string.format("%s ปฏิเสธคำชวน", player.DisplayName))
		return true
	end
	if invite.ExpiresAt < os.time() then
		return false, "Expired"
	end
	if not target or target.Leader ~= from or target.Status ~= "Idle" or not from.Parent then
		return false, "Gone"
	end
	if #target.Members >= PartyCfg.MaxSize then
		return false, "Full"
	end
	if not isSoloIdle(player) then
		return false, "Busy"
	end
	join(player, target)
	noticeAll(target, string.format("%s เข้าทีมแล้ว", player.DisplayName))
	return true
end

function actions.Leave(player, party)
	if #party.Members <= 1 then
		return false, "Solo"
	end
	if party.Status == "Teleporting" or party.Status == "Local" then
		return false, "Busy"
	end
	detach(player)
	newParty(player)
	return true
end

function actions.Kick(player, party, userId)
	if party.Leader ~= player then
		return false, "NotLeader"
	end
	if party.Status == "Teleporting" or party.Status == "Local" then
		return false, "Busy"
	end
	local target = typeof(userId) == "number" and Players:GetPlayerByUserId(userId)
	if not target or target == player or playerParty[target] ~= party then
		return false, "NoTarget"
	end
	detach(target)
	newParty(target)
	notice(target, "คุณถูกเชิญออกจากทีม")
	return true
end

function actions.SetStage(player, party, stage)
	if party.Leader ~= player then
		return false, "NotLeader"
	end
	if party.Status ~= "Idle" then
		return false, "Busy"
	end
	if typeof(stage) ~= "number" or stage ~= math.floor(stage) or not Config.Waves.Stages[stage] then
		return false, "Invalid"
	end
	if stage > unlockedStageOf(player) then
		return false, "Locked"
	end
	party.Stage = stage
	publish(party)
	return true
end

function actions.Play(player, party)
	if party.Leader ~= player then
		return false, "NotLeader"
	end
	if party.Status ~= "Idle" then
		return false, "Busy"
	end
	clampStage(party)
	for _, member in party.Members do
		if not DataService.Get(member) then
			return false, "NotLoaded"
		end
		if not PlayerService.GetCharacterParts(member) then
			return false, "NoCharacter"
		end
		if member:GetAttribute("InMatch") == true then
			return false, "Busy"
		end
	end
	if RunService:IsStudio() and WaveService.LocalMatchBusy() then
		return false, "FortBusy"
	end
	if #party.Members >= PartyCfg.MaxSize then
		task.spawn(launchDirect, party)
	else
		startSearch(party)
	end
	return true
end

function actions.StartNow(player, party)
	if party.Leader ~= player then
		return false, "NotLeader"
	end
	if party.Status ~= "Searching" or not party.Ticket then
		return false, "Busy"
	end
	party.Ticket.StartNow = true
	return true
end

function actions.Cancel(player, party)
	if party.Leader ~= player then
		return false, "NotLeader"
	end
	if party.Status ~= "Searching" and party.Status ~= "Found" then
		return false, "Busy"
	end
	cancelSearch(party)
	return true
end

local function onAction(player, action, arg)
	local now = os.clock()
	if lastAction[player] and now - lastAction[player] < ACTION_COOLDOWN then
		return false, "Busy"
	end
	lastAction[player] = now
	local handler = typeof(action) == "string" and actions[action]
	local party = playerParty[player]
	if not handler or not party then
		return false, "Invalid"
	end
	return handler(player, party, arg)
end

---------------------------------------------------------------- กลับจากแมตช์ / เข้าตามเพื่อน

-- รวมสมาชิกทีมเดิมที่กลับมาถึงแล้ว (ทยอยมาก็รวมเพิ่มได้)
local function tryReunite(token)
	local reunion = reunions[token]
	if not reunion then
		return
	end
	if reunion.ExpiresAt < os.time() then
		reunions[token] = nil
		return
	end
	local target = nil
	for _, party in parties do
		if party.ReunionToken == token then
			target = party
			break
		end
	end
	local waiting = {}
	for _, userId in reunion.UserIds do
		local member = Players:GetPlayerByUserId(userId)
		if member and isSoloIdle(member) and (not target or playerParty[member] ~= target) then
			table.insert(waiting, member)
		end
	end
	if not target then
		if #waiting < 2 then
			return
		end
		local leader = waiting[1]
		for _, member in waiting do
			if member.UserId == reunion.Leader then
				leader = member
			end
		end
		target = playerParty[leader]
		target.ReunionToken = token
		table.remove(waiting, table.find(waiting, leader))
	end
	if target.Status ~= "Idle" then
		return
	end
	for _, member in waiting do
		if #target.Members >= PartyCfg.MaxSize then
			break
		end
		join(member, target)
	end
end

local function readReturnData(player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or typeof(joinData) ~= "table" or joinData.SourcePlaceId ~= game.PlaceId then
		return
	end
	local data = joinData.TeleportData
	if typeof(data) ~= "table" or typeof(data.Parties) ~= "table" then
		return
	end
	for index, party in data.Parties do
		if typeof(party) == "table" and typeof(party.UserIds) == "table" and table.find(party.UserIds, player.UserId) then
			if #party.UserIds >= 2 then
				local token = tostring(data.MatchId) .. ":" .. index
				reunions[token] = reunions[token] or {
					Leader = party.Leader,
					UserIds = party.UserIds,
					ExpiresAt = os.time() + PartyCfg.ReunionTime,
				}
				tryReunite(token)
			end
			return
		end
	end
end

local function onPlayerAdded(player)
	newParty(player)
	task.spawn(function()
		DataService.WaitForProfile(player)
		if not player.Parent then
			return
		end
		local party = playerParty[player]
		if party and party.Leader == player and party.Status == "Idle" then
			party.Stage = unlockedStageOf(player) -- เริ่มที่ด่านสูงสุดที่ปลดล็อค
			publish(party)
		end
		readReturnData(player)
		-- เข้าเกมตามเพื่อน (เช่น รับ invite ของ Roblox): ได้คำชวนเข้าทีมของเพื่อนให้เอง
		local friend = player.FollowUserId ~= 0 and Players:GetPlayerByUserId(player.FollowUserId)
		local friendParty = friend and playerParty[friend]
		if friendParty and friendParty.Leader == friend and isSoloIdle(player) then
			actions.Invite(friend, friendParty, player.UserId)
		end
	end)
end

local function onPlayerRemoving(player)
	detach(player)
	invites[player] = nil
	lastAction[player] = nil
	for target, invite in invites do
		if invite.From == player then
			closeInvite(target)
		end
	end
end

function PartyService.Init()
	for name, class in { PartyAction = "RemoteFunction", GetPartyState = "RemoteFunction", PartyState = "RemoteEvent", PartyNotice = "RemoteEvent" } do
		if not Remotes:FindFirstChild(name) then
			local remote = Instance.new(class)
			remote.Name = name
			remote.Parent = Remotes
		end
	end
	Remotes.PartyAction.OnServerInvoke = onAction
	Remotes.GetPartyState.OnServerInvoke = function(player)
		local party = playerParty[player]
		return party and snapshot(party, player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		if not playerParty[player] then
			task.spawn(onPlayerAdded, player)
		end
	end

	-- rank ของหัวหน้าเปลี่ยน / ปลดล็อคด่าน -> ส่งสถานะใหม่
	DataService.ProfileLoaded:Connect(function(player)
		local party = playerParty[player]
		if party then
			publish(party)
		end
	end)

	-- teleport ล้มหลังเริ่มไปแล้ว: กลับเป็น Idle
	TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		warn("[PartyService] teleport failed:", player.Name, result, message)
		local party = playerParty[player]
		if party and party.Status == "Teleporting" then
			setIdle(party)
			noticeAll(party, "ย้ายไปด่านไม่สำเร็จ — ลองกดเล่นอีกครั้ง")
		end
	end)

	-- คำชวนหมดอายุ + ทีมที่รอรวมตัวกลับจากแมตช์
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.time()
			for target, invite in invites do
				if invite.ExpiresAt < now then
					closeInvite(target)
				end
			end
			for token in reunions do
				tryReunite(token)
			end
		end
	end)
end

return PartyService
