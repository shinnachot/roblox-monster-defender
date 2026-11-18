-- ServerMode: server นี้เป็น Lobby (public) หรือ server แมตช์ (reserved, เฟส 4)
-- place เดียวกันทั้งสองโหมด: reserved server (PrivateServerId ~= "" และ PrivateServerOwnerId == 0) = แมตช์
-- ข้อมูลแมตช์ (stage, ผู้เล่นที่จะมา) เก็บใน MemoryStore HashMap คีย์ = PrivateServerId
--   ฝั่ง Lobby เขียนตอนจอง server (ไม่ใช้ TeleportData เพราะ client ปลอมได้)
-- เผยแพร่ workspace attribute ServerMode = "Lobby" / "Match" ให้ client
-- ทดสอบใน Studio: ตั้ง workspace.DebugMatchServer = เลข stage ก่อนกด Play -> ทำตัวเป็น server แมตช์
local MemoryStoreService = game:GetService("MemoryStoreService")
local RunService = game:GetService("RunService")

local ServerMode = {}

local MATCH_INFO_MAP = "MatchInfo_v1"
local MATCH_INFO_TTL = 15 * 60

local isMatch = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
local debugStage = RunService:IsStudio() and workspace:GetAttribute("DebugMatchServer") or nil
if typeof(debugStage) == "number" then
	isMatch = true
end

local infoMap = nil
local function getInfoMap()
	if not infoMap then
		infoMap = MemoryStoreService:GetHashMap(MATCH_INFO_MAP)
	end
	return infoMap
end

function ServerMode.IsMatchServer()
	return isMatch
end

-- ทดสอบใน Studio: server แมตช์ปลอม (ไม่มี lobby ให้ teleport กลับ)
function ServerMode.IsDebugMatch()
	return typeof(debugStage) == "number"
end

-- ฝั่ง Lobby: บันทึกข้อมูลแมตช์ของ reserved server — info = { Stage, UserIds = {...}, Parties = {{Leader, UserIds}} }
function ServerMode.PublishMatchInfo(privateServerId, info)
	local ok, err = pcall(function()
		getInfoMap():SetAsync(privateServerId, info, MATCH_INFO_TTL)
	end)
	if not ok then
		warn("[ServerMode] publish match info failed:", err)
	end
	return ok
end

-- ฝั่งแมตช์: อ่านข้อมูลแมตช์ (ลองซ้ำ — Lobby อาจยังเขียนไม่ทัน) คืน info หรือ nil
function ServerMode.LoadMatchInfo()
	if ServerMode.IsDebugMatch() then
		return { Stage = debugStage, UserIds = nil, Parties = {} }
	end
	for attempt = 1, 8 do
		local ok, result = pcall(function()
			return getInfoMap():GetAsync(game.PrivateServerId)
		end)
		if ok and typeof(result) == "table" and typeof(result.Stage) == "number" then
			return result
		end
		if not ok then
			warn("[ServerMode] load match info failed:", result)
		end
		task.wait(math.min(attempt, 3))
	end
	return nil
end

function ServerMode.Init()
	workspace:SetAttribute("ServerMode", isMatch and "Match" or "Lobby")
	-- เกิดที่ป้อมในแมตช์ / ที่ลานกลางใน Lobby
	local fortSpawn = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("FortSpawn")
	local lobbySpawn = workspace:FindFirstChild("Lobby") and workspace.Lobby:FindFirstChild("LobbySpawn")
	if fortSpawn and fortSpawn:IsA("SpawnLocation") then
		fortSpawn.Enabled = isMatch
	end
	if lobbySpawn and lobbySpawn:IsA("SpawnLocation") then
		lobbySpawn.Enabled = not isMatch
	end
end

return ServerMode
