-- MatchmakingService: หาผู้เล่นข้าม lobby server + จอง reserved server + teleport (GDD ข้อ 2, เฟส 4)
--
-- คิวต่อ stage = MemoryStore SortedMap "MMQueue_v1_S<stage>" — 1 entry ต่อ 1 ทีม
--   key = "<เวลาเข้าคิว ms 13 หลัก>_<jobId>_<ticketId>" -> เรียงตามเวลาเข้าคิว (เก่าก่อน)
--   value = { JobId, UserIds, Leader, Size, Total, Seen, Host?, ClaimedAt?, AccessCode?, Closed? }
--   entry หมดอายุเอง 30 วิ ถ้า server เจ้าของไม่ต่ออายุ (server ล่ม)
-- กติกาจับคู่ (ทุก server ทำแบบเดียวกัน ไม่มีตัวกลาง):
--   ทีมที่ยังไม่ถูกจับ (host) "จอง" ทีมที่เข้าคิวทีหลังได้ ถ้าจำนวนรวมไม่เกิน 3 — จองด้วย UpdateAsync (atomic)
--   จองได้แค่ทีมที่ยังไม่ได้จองใคร -> ไม่มีวงวน; ถ้า host โดนทีมที่เก่ากว่าจองไปเอง จะปล่อยทีมที่จองไว้
--   host เริ่มเมื่อครบ 3 / ครบ 30 วิ / หัวหน้ากด "เริ่มเลย" -> จอง server, ส่ง AccessCode ให้ทีมที่จองผ่าน entry
--   ทีมที่ถูกจองรอ AccessCode; ถ้า host เงียบเกิน ClaimTimeout -> กลับไปหาใหม่
-- ใน Studio teleport ไม่ได้: Reserve คืน STUDIO_CODE แล้ว PartyService เล่นแมตช์ในป้อมของ server นี้แทน
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local ServerMode = require(script.Parent.ServerMode)

local MatchmakingService = {}

MatchmakingService.STUDIO_CODE = "__studio__"

local PartyCfg = Config.Party
local QUEUE_TTL = 30
local STALE_AFTER = 10 -- entry ที่ไม่ถูกต่ออายุนานกว่านี้ไม่นับ
local jobKey = game.JobId ~= "" and game.JobId or ("studio" .. math.random(1, 1e9))
local nextTicketId = 0

local function now()
	return workspace:GetServerTimeNow()
end

local function queueMap(stage)
	return MemoryStoreService:GetSortedMap("MMQueue_v1_S" .. stage)
end

local function update(map, key, transform)
	return pcall(function()
		return map:UpdateAsync(key, transform, QUEUE_TTL)
	end)
end

---------------------------------------------------------------- จอง server

-- parties = { { Leader = userId, UserIds = {...} }, ... } -> accessCode หรือ nil, err
function MatchmakingService.Reserve(stage, parties)
	if RunService:IsStudio() then
		return MatchmakingService.STUDIO_CODE
	end
	local ok, code, privateServerId = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not ok then
		warn("[Matchmaking] ReserveServer failed:", code)
		return nil, code
	end
	local userIds = {}
	for _, party in parties do
		for _, userId in party.UserIds do
			table.insert(userIds, userId)
		end
	end
	if not ServerMode.PublishMatchInfo(privateServerId, { Stage = stage, UserIds = userIds, Parties = parties }) then
		return nil, "MatchInfo"
	end
	return code
end

-- teleport กลุ่มผู้เล่นไปด้วยกัน (accessCode = nil -> public server ของ place นี้ เช่น กลับ Lobby)
function MatchmakingService.Teleport(players, accessCode, teleportData)
	if #players == 0 then
		return true
	end
	local options = Instance.new("TeleportOptions")
	if accessCode then
		options.ReservedServerAccessCode = accessCode
	end
	if teleportData then
		options:SetTeleportData(teleportData)
	end
	local lastErr
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, players, options)
		end)
		if ok then
			return true
		end
		lastErr = err
		warn("[Matchmaking] TeleportAsync failed:", err)
		task.wait(attempt * 2)
	end
	return false, lastErr
end

---------------------------------------------------------------- คิว

-- ticket (สร้างโดย PartyService):
--   Stage, GetUserIds() -> {userId}, GetLeader() -> userId
--   OnStatus(status "Searching"/"Found", count)   -- count = จำนวนผู้เล่นที่รวมได้
--   OnLaunch(accessCode)                            -- ได้ server แล้ว: teleport ทีม
--   OnFailed(reason)                                -- MemoryStore/จอง server ล้มเหลว
--   ตั้งจากภายนอก: ticket.StartNow = true (หัวหน้ากดเริ่มเลย), ticket.Cancelled = true
-- ticket.Deadline (เวลา server) ถูกตั้งให้ UI นับถอยหลัง
function MatchmakingService.Search(ticket)
	local map = queueMap(ticket.Stage)
	local since = now()
	nextTicketId += 1
	local key = string.format("%013d_%s_%d", math.floor(since * 1000), jobKey, nextTicketId)
	ticket.Deadline = since + PartyCfg.QueueTime
	local claimed = {} -- [key] = { Size, UserIds, Leader }

	local function fill(value)
		local userIds = ticket.GetUserIds()
		value = value or { JobId = jobKey }
		value.UserIds = userIds
		value.Leader = ticket.GetLeader()
		value.Size = #userIds
		local total = value.Size
		for _, c in claimed do
			total += c.Size
		end
		value.Total = total
		value.Seen = now()
		return value
	end

	local function releaseClaims()
		for claimedKey in claimed do
			update(map, claimedKey, function(old)
				if old and old.Host == key and not old.AccessCode then
					old.Host = nil
					old.ClaimedAt = nil
					return old
				end
				return nil
			end)
		end
		table.clear(claimed)
	end

	local function remove()
		pcall(function()
			map:RemoveAsync(key)
		end)
	end

	-- พยายามจองทีมที่เข้าคิวทีหลัง คืนจำนวนรวม
	local function claimYounger(total)
		local ok, items = pcall(function()
			return map:GetRangeAsync(Enum.SortDirection.Ascending, 100)
		end)
		if not ok then
			warn("[Matchmaking] GetRangeAsync failed:", items)
			return total
		end
		for _, item in items do
			if total >= PartyCfg.MaxSize then
				break
			end
			local v = item.value
			if item.key <= key or claimed[item.key] or typeof(v) ~= "table" then
				continue
			end
			local free = PartyCfg.MaxSize - total
			if v.Host or v.Closed or v.AccessCode or (v.Total or v.Size) ~= v.Size or v.Size > free or now() - (v.Seen or 0) > STALE_AFTER then
				continue
			end
			local okClaim, result = update(map, item.key, function(old)
				if typeof(old) ~= "table" or old.Host or old.Closed or old.AccessCode then
					return nil
				end
				if (old.Total or old.Size) ~= old.Size or old.Size > free then
					return nil
				end
				old.Host = key
				old.ClaimedAt = now()
				return old
			end)
			if okClaim and typeof(result) == "table" and result.Host == key then
				claimed[item.key] = { Size = result.Size, UserIds = result.UserIds, Leader = result.Leader }
				total += result.Size
			end
		end
		return total
	end

	local function launchAsHost()
		local parties = { { Leader = ticket.GetLeader(), UserIds = ticket.GetUserIds() } }
		for _, c in claimed do
			table.insert(parties, { Leader = c.Leader, UserIds = c.UserIds })
		end
		local code, err = MatchmakingService.Reserve(ticket.Stage, parties)
		if not code then
			releaseClaims()
			remove()
			ticket.OnFailed(err)
			return
		end
		for claimedKey in claimed do
			update(map, claimedKey, function(old)
				if typeof(old) == "table" and old.Host == key then
					old.AccessCode = code
					return old
				end
				return nil
			end)
		end
		remove()
		ticket.OnLaunch(code)
	end

	task.spawn(function()
		while not ticket.Cancelled do
			local ok, entry = update(map, key, function(old)
				if typeof(old) == "table" and old.Closed then
					return nil
				end
				local value = fill(typeof(old) == "table" and old or nil)
				-- host เงียบไปนาน (server ล่ม?) -> กลับไปหาใหม่
				if value.Host and not value.AccessCode and now() - (value.ClaimedAt or 0) > PartyCfg.ClaimTimeout then
					value.Host = nil
					value.ClaimedAt = nil
				end
				return value
			end)
			if ticket.Cancelled then
				break
			end
			if not ok or typeof(entry) ~= "table" then
				-- MemoryStore ใช้ไม่ได้: ไม่มีใครมาจองเราได้ — ครบเวลา/กดเริ่มเลย ก็เล่นกับทีมที่มี
				warn("[Matchmaking] queue update failed:", entry)
				local total = #ticket.GetUserIds()
				for _, c in claimed do
					total += c.Size
				end
				ticket.OnStatus("Searching", total)
				if ticket.StartNow or now() >= ticket.Deadline then
					launchAsHost()
					return
				end
			elseif entry.AccessCode then
				-- host ส่ง server มาให้แล้ว
				remove()
				ticket.OnLaunch(entry.AccessCode)
				return
			elseif entry.Host then
				-- ถูกทีมที่เก่ากว่าจองไป: ปล่อยทีมที่เราจองไว้ (ถ้ามี) แล้วรอ
				if next(claimed) then
					releaseClaims()
				end
				ticket.OnStatus("Found", entry.Size)
			else
				local total = entry.Total
				if total < PartyCfg.MaxSize and not ticket.StartNow and now() < ticket.Deadline then
					local before = total
					total = claimYounger(total)
					if total ~= before then
						local _, mine = update(map, key, function(old)
							if typeof(old) ~= "table" then
								return nil
							end
							return fill(old)
						end)
						if typeof(mine) == "table" and mine.Host then
							releaseClaims() -- โดนจองระหว่างที่เรากำลังจองคนอื่น
							total = mine.Size
						end
					end
				end
				ticket.OnStatus("Searching", total)
				if total >= PartyCfg.MaxSize or ticket.StartNow or now() >= ticket.Deadline then
					-- ปิด entry กันไม่ให้ใครมาจองระหว่างจอง server
					local okClose, closed = update(map, key, function(old)
						if typeof(old) == "table" and (old.Host or old.AccessCode) then
							return nil
						end
						local value = fill(typeof(old) == "table" and old or nil)
						value.Closed = true
						return value
					end)
					if okClose and typeof(closed) == "table" and closed.Closed then
						launchAsHost()
						return
					end
					-- ถูกจองพอดี: วนรอบถัดไปจะเห็น Host
				end
			end
			task.wait(PartyCfg.PollInterval)
		end
		-- ยกเลิก
		releaseClaims()
		remove()
	end)
end

return MatchmakingService
