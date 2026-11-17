-- MonsterNav: การเดินของ monster ด้วย PathfindingService (อ้อมต้นไม้/ที่กำบัง, ผ่านประตู, ขึ้นบันไดกำแพง)
-- และการหาที่กำบังให้ monster ยิงไกล (ที่กำบัง = part ที่ติด tag "Cover" ใน Map.Field)
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)

local MonsterNav = {}

local DIRECT_RANGE = 10 -- ใกล้และอยู่ระดับเดียวกัน -> เดินตรง ไม่ต้องคำนวณเส้นทาง
local DIRECT_HEIGHT = 4
local REPATH_DISTANCE = 5 -- เป้าหมายขยับเกินนี้ -> คำนวณเส้นทางใหม่
local REPATH_INTERVAL = 0.5
local RETRY_AFTER_FAIL = 2
local WAYPOINT_REACH = 2.5
local STUCK_TIME = 1.5
local STUCK_DISTANCE = 1
local COVER_MARGIN = 2.5 -- ระยะยืนห่างจากขอบที่กำบัง

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- อยู่บนกำแพง/ป้อมมุม (สูงกว่าพื้นสนาม)
function MonsterNav.IsElevated(position)
	return position.Y > Config.Map.WallMinY
end

local function getState(m, now)
	local state = m.Nav
	if not state then
		state = {
			Path = PathfindingService:CreatePath({
				AgentRadius = math.max(1.5, m.Radius + 0.5),
				AgentHeight = 5,
				AgentCanJump = false,
				WaypointSpacing = 8,
			}),
			RequestedAt = 0,
			ForcePathUntil = 0,
			LastCall = now,
			StuckPos = m.Root.Position,
			StuckAt = now,
		}
		m.Nav = state
	end
	return state
end

local function compute(m, state, goal, now)
	state.Pending = true
	state.RequestedAt = now
	task.spawn(function()
		local path = state.Path
		local ok = pcall(function()
			path:ComputeAsync(m.Root.Position, goal)
		end)
		state.Pending = false
		if m.Dead then
			return
		end
		state.Goal = goal
		if ok and path.Status == Enum.PathStatus.Success then
			state.Waypoints = path:GetWaypoints()
			state.Index = 2
			state.Failed = false
		else
			state.Waypoints = nil
			state.Failed = true
		end
	end)
end

-- สั่งให้เดินไปยัง goal (เรียกซ้ำทุก tick ระหว่างที่ยังต้องการเดิน)
-- คืน false เมื่อหาเส้นทางไป goal นี้ไม่ได้
function MonsterNav.MoveTo(m, goal, now)
	local state = getState(m, now)
	local pos = m.Root.Position

	-- ตรวจว่าเดินติด: สั่งเดินต่อเนื่องแต่แทบไม่ขยับ -> บังคับคำนวณเส้นทางใหม่
	if now - state.LastCall > 0.4 then
		state.StuckPos, state.StuckAt = pos, now
	end
	state.LastCall = now
	if now - state.StuckAt >= STUCK_TIME then
		if (pos - state.StuckPos).Magnitude < STUCK_DISTANCE then
			state.ForcePathUntil = now + 4
			state.Waypoints = nil
			state.Goal = nil
			state.Failed = false
		end
		state.StuckPos, state.StuckAt = pos, now
	end

	local offset = goal - pos
	if now >= state.ForcePathUntil and flat(offset).Magnitude <= DIRECT_RANGE and math.abs(offset.Y) <= DIRECT_HEIGHT then
		m.Hum:MoveTo(goal)
		return true
	end

	local goalMoved = not state.Goal or (state.Goal - goal).Magnitude > REPATH_DISTANCE
	local retry = state.Failed and now - state.RequestedAt >= RETRY_AFTER_FAIL
	if (goalMoved or retry) and not state.Pending and now - state.RequestedAt >= REPATH_INTERVAL then
		compute(m, state, goal, now)
	end

	local waypoints = state.Waypoints
	if not waypoints then
		m.Hum:MoveTo(goal) -- ยังไม่มีเส้นทาง: เดินตรงไปก่อน
		return not (state.Failed and not goalMoved)
	end
	while state.Index < #waypoints and flat(waypoints[state.Index].Position - pos).Magnitude <= WAYPOINT_REACH do
		state.Index += 1
	end
	m.Hum:MoveTo(waypoints[math.min(state.Index, #waypoints)].Position)
	return true
end

-- จุดยืนหลบ (hide) และจุดโผล่ยิง (peek) ของที่กำบัง เมื่อภัยอยู่ที่ threatPos
-- sign = ด้านที่โผล่ออกมา (1 / -1), y = ความสูงของตัว monster
function MonsterNav.CoverSpots(box, threatPos, sign, y)
	local center = box.Position
	local away = flat(center - threatPos)
	local dir = away.Magnitude > 0.1 and away.Unit or Vector3.zAxis
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local half = box.Size / 2
	local right, look = box.CFrame.RightVector, box.CFrame.LookVector
	local depth = math.abs(dir:Dot(right)) * half.X + math.abs(dir:Dot(look)) * half.Z
	local width = math.abs(side:Dot(right)) * half.X + math.abs(side:Dot(look)) * half.Z
	local hide = Vector3.new(center.X, y, center.Z) + dir * (depth + COVER_MARGIN)
	local peek = hide + side * sign * (width + COVER_MARGIN)
	return hide, peek
end

-- ที่กำบังที่ใกล้ monster ที่สุดในรัศมีค้นหา ซึ่งโผล่ออกมาแล้วยิงถึง threatPos (ระยะ range)
-- คืน (box, sign) หรือ nil
function MonsterNav.FindCover(m, threatPos, range)
	local pos = m.Root.Position
	local best, bestSign, bestDist
	for _, box in CollectionService:GetTagged("Cover") do
		local center = box.Position
		local toMonster = flat(center - pos).Magnitude
		if toMonster <= Config.AI.CoverSearchRadius and (not bestDist or toMonster < bestDist) then
			if flat(center - threatPos).Magnitude >= Config.AI.CoverMinThreatDistance then
				-- โผล่ด้านที่ใกล้ตัวเองกว่า
				local hide, peek = MonsterNav.CoverSpots(box, threatPos, 1, pos.Y)
				local sign = 1
				if (pos - hide):Dot(peek - hide) < 0 then
					sign = -1
					hide, peek = MonsterNav.CoverSpots(box, threatPos, -1, pos.Y)
				end
				if flat(peek - threatPos).Magnitude <= range - 2 then
					best, bestSign, bestDist = box, sign, toMonster
				end
			end
		end
	end
	return best, bestSign
end

return MonsterNav
