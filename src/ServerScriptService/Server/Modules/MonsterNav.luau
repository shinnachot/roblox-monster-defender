-- MonsterNav: การเดินของ monster ด้วย PathfindingService (อ้อมต้นไม้/ที่กำบัง, ผ่านประตู, ขึ้นบันไดกำแพง)
-- และการหาที่กำบังให้ monster ยิงไกล (ที่กำบัง = part ที่ติด tag "Cover" ใน Map.Field)
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
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
local NO_PROGRESS_TIME = 5 -- เดินอยู่แต่ไม่เข้าใกล้เป้าเลย (ส่ายไปมาหน้าสิ่งกีดขวาง) นานเท่านี้ = ติด
local ESCAPE_TIME = 1 -- เดินเลี่ยงซ้าย/ขวานานสุดเท่านี้ แล้วกลับไปตามเส้นทาง (คำนวณใหม่จากจุดใหม่)
local ARRIVED_DISTANCE = 3.5 -- ใกล้เป้าแล้ว (เช่น ยืนหลบหลังที่กำบัง) ไม่นับว่าติด
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

-- ทิศถอยออกจากสิ่งกีดขวางเมื่อหาเส้นทางจากจุดที่ยืนไม่ได้ (เทียบกับทิศไปเป้า: ข้าง ๆ ก่อน แล้วค่อยถอยหลัง)
local NUDGE_ANGLES = { 90, -90, 135, -135, 180, 45, -45 }
local NUDGE_EXTRA = { 2.5, 1, 4 } -- ระยะถอย = รัศมี agent + ค่านี้ (ลองใกล้ก่อน)

-- ทางเดินตรงจาก a ไป b โล่งพอให้ตัว monster ผ่าน (กวาดทรงกลมขนาดลำตัวที่ระดับเอว)
-- ไม่นับ monster และผู้เล่น (เดินชนกันเองได้ ไม่ใช่สิ่งกีดขวางถาวร)
local sweepParams = RaycastParams.new()
sweepParams.FilterType = Enum.RaycastFilterType.Exclude
local function ignoreList(m)
	local ignore = { m.Model, workspace:FindFirstChild("Monsters") }
	for _, player in Players:GetPlayers() do
		table.insert(ignore, player.Character)
	end
	return ignore
end
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude
local function canWalkStraight(m, a, b)
	local low = Vector3.new(0, 1.5, 0)
	local from, to = a - low, Vector3.new(b.X, a.Y, b.Z) - low
	local move = to - from
	if move.Magnitude < 0.05 then
		return true
	end
	local radius = math.max(0.8, m.Radius + 0.1)
	local ignore = ignoreList(m)
	-- Spherecast ไม่นับ part ที่ทรงกลมทับอยู่แล้วตอนเริ่ม (ตัวแนบกำแพงอยู่) -> ตรวจเองว่ากำลังเดินเข้าหา part นั้นไหม
	overlapParams.FilterDescendantsInstances = ignore
	for _, part in workspace:GetPartBoundsInRadius(from, radius, overlapParams) do
		if part.CanCollide then
			local half = part.Size / 2
			local localPos = part.CFrame:PointToObjectSpace(from)
			local closest = part.CFrame:PointToWorldSpace(Vector3.new(
				math.clamp(localPos.X, -half.X, half.X),
				math.clamp(localPos.Y, -half.Y, half.Y),
				math.clamp(localPos.Z, -half.Z, half.Z)
			))
			local away = flat(from - closest) -- พื้นใต้เท้า: away ราบ = 0 -> ไม่นับ
			if away.Magnitude > 0.01 and away.Magnitude < radius and flat(move):Dot(away) < 0 then
				return false
			end
		end
	end
	sweepParams.FilterDescendantsInstances = ignore
	local hit = workspace:Spherecast(from, radius, move, sweepParams)
	return hit == nil or not hit.Instance.CanCollide
end

local function tryCompute(path, start, goal)
	local ok = pcall(function()
		path:ComputeAsync(start, goal)
	end)
	return ok and path.Status == Enum.PathStatus.Success
end

local function compute(m, state, goal, now)
	state.Pending = true
	state.RequestedAt = now
	task.spawn(function()
		local path = state.Path
		local start = m.Root.Position
		local waypoints, direct
		if tryCompute(path, start, goal) then
			direct = path:GetWaypoints()
			-- ช่วงแรกต้องเดินตรงไปถึงได้: ตัวแนบมุมสิ่งกีดขวาง (เช่น กำแพงหินเตี้ยบนถนน) เส้นทางจะตัดมุมผ่านตัวสิ่งกีดขวาง
			-- -> ดันมุมค้างอยู่ คำนวณใหม่ก็ได้เส้นเดิม -> ใช้วิธีถอยออกมาก่อนแบบเดียวกับตอนหาเส้นทางไม่ได้
			local first = direct[math.min(2, #direct)]
			if canWalkStraight(m, start, first.Position) then
				waypoints = direct
			end
		end
		if not waypoints then
			-- ยืนชิดสิ่งกีดขวางจน PathfindingService ถือว่าจุดเริ่มอยู่ในสิ่งกีดขวาง (NoPath)
			-- -> ลองหาเส้นทางจากจุดที่ถอยออกมาเล็กน้อย แล้วเดินไปจุดนั้นก่อน
			-- จุดถอยต้องเดินตรงไปถึงได้จริง: กองหินมีหลายก้อน จุดถอยข้าง ๆ อาจอยู่หลังหินอีกก้อน
			-- (เดิมไม่ตรวจ -> เดินชนหินก้อนนั้น ติดแล้วคำนวณได้จุดเดิมซ้ำ ค้างอยู่ที่หินตลอด)
			local toGoal = flat(goal - start)
			local forward = toGoal.Magnitude > 0.1 and toGoal.Unit or Vector3.zAxis
			local agent = math.max(1.5, m.Radius + 0.5)
			for _, extra in NUDGE_EXTRA do
				for _, angle in NUDGE_ANGLES do
					local nudged = start + CFrame.Angles(0, math.rad(angle), 0):VectorToWorldSpace(forward) * (agent + extra)
					if canWalkStraight(m, start, nudged) and tryCompute(path, nudged, goal) then
						waypoints = path:GetWaypoints()
						table.insert(waypoints, 1, PathWaypoint.new(nudged, Enum.PathWaypointAction.Walk))
						table.insert(waypoints, 1, PathWaypoint.new(start, Enum.PathWaypointAction.Walk))
						break
					end
				end
				if waypoints then
					break
				end
			end
			waypoints = waypoints or direct -- ถอยไม่ได้เลย: ใช้เส้นทางเดิม (ดีกว่าเดินตรงเข้าหาเป้า)
		end
		state.Pending = false
		if m.Dead then
			return
		end
		state.Goal = goal
		if waypoints then
			state.Waypoints = waypoints
			state.Index = 2
			state.Failed = false
		else
			state.Waypoints = nil
			state.Failed = true
		end
	end)
end

-- ทางตรงไป goal โล่ง (ระดับเอว) — ถ้ามีสิ่งกีดขวางเตี้ย ๆ ขวาง (เช่น กำแพงหิน Low) ต้องใช้เส้นทางอ้อม
-- ไม่นับ monster และผู้เล่น (เดินชนกันเองได้ ไม่ใช่สิ่งกีดขวางถาวร)
local lineParams = RaycastParams.new()
lineParams.FilterType = Enum.RaycastFilterType.Exclude
local function clearLine(m, from, goal)
	lineParams.FilterDescendantsInstances = ignoreList(m)
	local low = Vector3.new(0, 1.5, 0)
	local start = Vector3.new(from.X, from.Y, from.Z) - low
	local finish = Vector3.new(goal.X, from.Y, goal.Z) - low
	local result = workspace:Raycast(start, finish - start, lineParams)
	return result == nil or not result.Instance.CanCollide
end

-- ติดแล้ว: ก้าวเลี่ยงไปทางซ้ายหรือขวาของทิศที่พยายามเดิน (สลับข้างทุกครั้ง และก้าวไกลขึ้นถ้ายังติดซ้ำ)
-- ไม่พึ่ง PathfindingService — กันกรณีเส้นทางที่คำนวณได้พาดันสิ่งกีดขวางเดิมวนไม่จบ
local function startEscape(m, state, pos, now)
	local heading = flat(m.Hum.WalkToPoint - pos)
	if heading.Magnitude < 0.1 then
		heading = flat(m.Root.CFrame.LookVector)
	end
	heading = heading.Magnitude > 0.1 and heading.Unit or Vector3.zAxis
	state.StuckCount = (state.StuckCount or 0) + 1
	state.EscapeSide = -(state.EscapeSide or 1)
	local side = state.EscapeSide
	local step = 3 + math.min(state.StuckCount - 1, 3) * 1.5
	for _, distance in { step, step * 0.6 } do
		for _, angle in { 90 * side, -90 * side, 135 * side, -135 * side, 180 } do
			local dir = CFrame.Angles(0, math.rad(angle), 0):VectorToWorldSpace(heading)
			local point = pos + dir * distance
			if canWalkStraight(m, pos, point) then
				state.Escape = { Point = point, Until = now + ESCAPE_TIME }
				return
			end
		end
	end
end

-- สั่งให้เดินไปยัง goal (เรียกซ้ำทุก tick ระหว่างที่ยังต้องการเดิน)
-- คืน false เมื่อหาเส้นทางไป goal นี้ไม่ได้
function MonsterNav.MoveTo(m, goal, now)
	local state = getState(m, now)
	local pos = m.Root.Position
	local distance = flat(goal - pos).Magnitude

	-- ตรวจว่าเดินติด: (ก) สั่งเดินต่อเนื่องแต่แทบไม่ขยับ หรือ (ข) ขยับอยู่แต่ไม่เข้าใกล้เป้าเลย
	if now - state.LastCall > 0.4 then
		state.StuckPos, state.StuckAt = pos, now
		state.ProgressGoal = nil
	end
	state.LastCall = now
	local stuck = false
	if now - state.StuckAt >= STUCK_TIME then
		stuck = (pos - state.StuckPos).Magnitude < STUCK_DISTANCE
		state.StuckPos, state.StuckAt = pos, now
	end
	if not state.ProgressGoal or (state.ProgressGoal - goal).Magnitude > REPATH_DISTANCE then
		state.ProgressGoal, state.BestDistance, state.BestAt = goal, distance, now
	elseif distance < state.BestDistance - 1 then
		state.BestDistance, state.BestAt, state.StuckCount = distance, now, 0
	elseif now - state.BestAt >= NO_PROGRESS_TIME then
		stuck = true
		state.BestDistance, state.BestAt = distance, now
	end
	if stuck and distance > ARRIVED_DISTANCE and not state.Escape then
		state.ForcePathUntil = now + 4
		state.Waypoints = nil
		state.Goal = nil
		state.Failed = false
		startEscape(m, state, pos, now)
	end

	-- กำลังก้าวเลี่ยง: เดินไปจุดเลี่ยงให้ถึง (หรือหมดเวลา) ก่อน แล้วค่อยกลับไปตามเส้นทาง
	local escape = state.Escape
	if escape then
		if now < escape.Until and flat(escape.Point - pos).Magnitude > 0.8 then
			m.Hum:MoveTo(escape.Point)
			return true
		end
		state.Escape = nil
	end

	local offset = goal - pos
	if now >= state.ForcePathUntil and flat(offset).Magnitude <= DIRECT_RANGE and math.abs(offset.Y) <= DIRECT_HEIGHT
		and clearLine(m, pos, goal)
	then
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
