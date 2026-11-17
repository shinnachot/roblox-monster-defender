-- CombatService: รับคำสั่งต่อสู้จาก client แล้วตรวจสอบ + คิดดาเมจฝั่ง server ทั้งหมด
-- client ทำแค่ animation/เสียง/เอฟเฟกต์ของตัวเอง (GDD ข้อ 0: server-authoritative)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage.Remotes
local CollectionService = game:GetService("CollectionService")

-- หุ่นฝึกใน Lobby (tag "TrainingDummy"): โดนได้ไม่จำกัด แสดงตัวเลข damage เหมือน monster
local function dummyFromPart(part)
	local node = part
	while node and node ~= workspace do
		if CollectionService:HasTag(node, "TrainingDummy") then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function hitDummy(player, dummy, amount, isHead, position, weapon)
	Remotes.DamageDealt:FireClient(player, position, amount, isHead, weapon)
	-- ส่ายเล็กน้อยให้รู้ว่าโดน
	dummy:SetAttribute("HitAt", workspace:GetServerTimeNow())
end

local PlayerService = require(script.Parent.PlayerService)
local MonsterService = require(script.Parent.MonsterService)

local CombatService = {}

local SWING_TOLERANCE = 0.15 -- เผื่อ latency
local ROLL_TOLERANCE = 0.2

-- ลูกธนู: client เห็น monster ช้ากว่า server ~0.2 วิ (ห่าง ~2 studs ตอนเดิน) — ยิงจากบนกำแพงลงมาจึงพลาดบ่อย
-- client จึงแจ้งตอนลูกธนูที่เห็นบนจอโดน monster (ArrowHit) แล้ว server ตรวจว่าสมเหตุสมผลก่อนคิดดาเมจ:
-- จุดที่โดนต้องอยู่บนวิถีลูกธนูจริง และใกล้ตำแหน่ง monster ฝั่ง server พอ (เผื่อระยะที่เดินได้ใน ~0.35 วิ)
-- ลูกธนูแต่ละดอกทำดาเมจได้ครั้งเดียว ไม่ว่าจะมาจากการจำลองฝั่ง server หรือจาก client
local HIT_PATH_TOLERANCE = 4 -- studs: จุดที่ client แจ้ง ห่างจากวิถีจริงได้ไม่เกินนี้
local HIT_LAG_SECONDS = 0.35 -- เผื่อระยะที่ monster เดินได้ระหว่างที่ภาพฝั่ง client ตามหลัง
local HIT_MARGIN = 2.5 -- studs
local SHOT_CLAIM_GRACE = 1.5 -- วินาทีหลังลูกธนูฝั่ง server จบ ที่ยังรับการแจ้งจาก client

local shots = {} -- [Player] = { [shotId] = shot }

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function isUnitVector(v)
	return typeof(v) == "Vector3" and v == v and math.abs(v.Magnitude - 1) < 0.01
end

---------------------------------------------------------------- ดาบ

local function swordHit(player, damage)
	local char, _, root = PlayerService.GetCharacterParts(player)
	local st = PlayerService.GetState(player)
	if not char or not st or st.Equipped ~= "Sword" then
		return
	end
	local cfg = Config.Weapons.Sword
	local origin = root.Position
	local look = flat(root.CFrame.LookVector).Unit
	local minDot = math.cos(math.rad(cfg.ArcDegrees / 2))

	local hits = {}
	for model, m in MonsterService.GetActive() do
		local offset = m.Root.Position - origin
		local to = flat(offset)
		local dist = to.Magnitude
		-- ระยะดาบวัดถึงผิวลำตัว (monster ตัวใหญ่มีรัศมีมากกว่า)
		local reach = cfg.Range - 1 + (m.Radius or 1)
		if dist <= reach and math.abs(offset.Y) <= 8 and (dist < 2.5 + (m.Radius or 1) or to.Unit:Dot(look) >= minDot) then
			table.insert(hits, model)
		end
	end
	for _, dummy in CollectionService:GetTagged("TrainingDummy") do
		local body = dummy.PrimaryPart
		if body then
			local offset = body.Position - origin
			local to = flat(offset)
			local radius = dummy:GetAttribute("Radius") or 1
			if to.Magnitude <= cfg.Range - 1 + radius and math.abs(offset.Y) <= 8
				and (to.Magnitude < 2.5 + radius or to.Unit:Dot(look) >= minDot) then
				hitDummy(player, dummy, damage, false, body.Position + Vector3.new(0, 3, 0), "Sword")
			end
		end
	end
	for _, model in hits do
		local head = model:FindFirstChild("Head")
		local numberPos = (head and head.Position or model:GetPivot().Position) + Vector3.new(0, 1.5, 0)
		local applied = MonsterService.Damage(model, damage, player)
		if applied then
			Remotes.DamageDealt:FireClient(player, numberPos, damage, false, "Sword")
		end
	end
end

local function onSwordSwing(player, comboIndex)
	local st = PlayerService.GetState(player)
	if not st or st.Equipped ~= "Sword" or st.Blocking or not PlayerService.GetCharacterParts(player) then
		return -- ยกโล่อยู่ฟันไม่ได้
	end
	local now = os.clock()
	if now < st.NextSwing - SWING_TOLERANCE then
		return -- กดเร็วกว่าคูลดาวน์
	end
	local cfg = Config.Weapons.Sword
	local index = 1
	if typeof(comboIndex) == "number" and comboIndex == st.ComboIndex + 1 and cfg.Combo[comboIndex]
		and now - st.LastSwingEnd <= cfg.ComboReset + 0.3 then
		index = comboIndex
	end
	local seg = cfg.Combo[index]
	local hitDelay, duration = Config.SegmentTiming(seg)
	st.ComboIndex = index
	st.NextSwing = now + duration * 0.8
	st.LastSwingEnd = now + duration
	st.SwingCount = (st.SwingCount or 0) + 1
	-- ให้ client อื่นเปิดแสงตามดาบของผู้เล่นคนนี้ ("ท่า:ลำดับ" — ลำดับทำให้ค่าเปลี่ยนทุกครั้งที่ฟัน)
	player:SetAttribute("MeleeSwing", index .. ":" .. st.SwingCount)
	task.delay(hitDelay, swordHit, player, seg.Damage)
end

---------------------------------------------------------------- ธนู

local function onBowDrawStart(player)
	local st = PlayerService.GetState(player)
	if not st or st.Equipped ~= "Bow" or not PlayerService.GetCharacterParts(player) then
		return
	end
	if (player:GetAttribute("Arrows") or 0) <= 0 then
		return
	end
	st.DrawStart = os.clock()
end

local function onBowCancel(player)
	local st = PlayerService.GetState(player)
	if st then
		st.DrawStart = nil
	end
end

-- ทำดาเมจจากลูกธนู 1 ดอก (ครั้งเดียวต่อดอก)
local function applyArrowHit(player, shot, model, isHead, position)
	if shot.Done then
		return
	end
	shot.Done = true
	local amount = math.round(shot.Damage * (isHead and Config.HeadshotMultiplier or 1))
	local applied = MonsterService.Damage(model, amount, player)
	if applied then
		Remotes.DamageDealt:FireClient(player, position + Vector3.new(0, 1, 0), amount, isHead, "Bow")
	end
end

local function isHeadPart(part)
	return part.Name == "Head" or part:FindFirstAncestorWhichIsA("Accessory") ~= nil
end

local function simulateArrow(player, shot)
	local origin, velocity = shot.Origin, shot.Velocity
	local cfg = Config.Weapons.Bow
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character) -- ไม่มี friendly fire
		end
	end
	params.FilterDescendantsInstances = ignore

	local gravity = Vector3.new(0, -cfg.Gravity, 0)
	local pos, vel, elapsed = origin, velocity, 0
	while elapsed < cfg.MaxFlightTime do
		local dt = RunService.Heartbeat:Wait()
		elapsed += dt
		local step = vel * dt + 0.5 * gravity * dt * dt
		local result = workspace:Raycast(pos, step, params)
		if result then
			local model = MonsterService.GetFromPart(result.Instance)
			if model then
				applyArrowHit(player, shot, model, isHeadPart(result.Instance), result.Position)
			else
				local dummy = dummyFromPart(result.Instance)
				if dummy and not shot.Done then
					shot.Done = true
					local isHead = result.Instance.Name == "Head"
					local amount = math.round(shot.Damage * (isHead and Config.HeadshotMultiplier or 1))
					hitDummy(player, dummy, amount, isHead, result.Position + Vector3.new(0, 1, 0), "Bow")
				end
			end
			break
		end
		pos += step
		vel += gravity * dt
	end
	-- เก็บไว้อีกครู่เผื่อ client แจ้งว่าโดน (ฝั่ง client เห็น monster ช้ากว่า)
	task.delay(SHOT_CLAIM_GRACE, function()
		local list = shots[player]
		if list and list[shot.Id] == shot then
			list[shot.Id] = nil
		end
	end)
end

-- client แจ้งว่าลูกธนูที่เห็นบนจอโดน monster: ตรวจวิถีและตำแหน่ง monster ฝั่ง server ก่อนคิดดาเมจ
local function onArrowHit(player, shotId, model, isHead, hitPosition)
	if type(shotId) ~= "number" or typeof(model) ~= "Instance" or typeof(hitPosition) ~= "Vector3" or hitPosition ~= hitPosition then
		return
	end
	local shot = shots[player] and shots[player][shotId]
	if not shot or shot.Done then
		return
	end
	local m = MonsterService.GetActive()[model]
	if not m or m.Dead then
		return
	end

	-- จุดที่โดนต้องอยู่บนวิถีจริงของลูกธนูดอกนี้
	local cfg = Config.Weapons.Bow
	local flatVelocity = flat(shot.Velocity)
	if flatVelocity.Magnitude < 1 then
		return
	end
	local t = flat(hitPosition - shot.Origin):Dot(flatVelocity.Unit) / flatVelocity.Magnitude
	if t < 0 or t > cfg.MaxFlightTime then
		return
	end
	local expected = shot.Origin + shot.Velocity * t + Vector3.new(0, -0.5 * cfg.Gravity * t * t, 0)
	if (expected - hitPosition).Magnitude > HIT_PATH_TOLERANCE then
		return
	end

	-- และใกล้ตัว monster ฝั่ง server พอ (เผื่อระยะที่เดินได้ระหว่างที่ภาพฝั่ง client ตามหลัง)
	local _, size = model:GetBoundingBox()
	local root = m.Root.Position
	local reach = math.max(size.X, size.Z) / 2 + m.Cfg.WalkSpeed * HIT_LAG_SECONDS + HIT_MARGIN
	if flat(hitPosition - root).Magnitude > reach or math.abs(hitPosition.Y - root.Y) > size.Y / 2 + HIT_MARGIN then
		return
	end

	-- โดนหัว: จุดที่โดนต้องสูงระดับหัวด้วย (monster เดินบนพื้น ความสูงจึงไม่คลาดตาม lag)
	if isHead == true then
		local head = model:FindFirstChild("Head")
		isHead = head ~= nil and hitPosition.Y >= head.Position.Y - head.Size.Y / 2 - 0.75
	else
		isHead = false
	end
	applyArrowHit(player, shot, model, isHead, hitPosition)
end

local function onBowFire(player, direction, shotId)
	local st = PlayerService.GetState(player)
	local char = PlayerService.GetCharacterParts(player)
	if not st or not char or st.Equipped ~= "Bow" or not st.DrawStart then
		return
	end
	local drawStart = st.DrawStart
	st.DrawStart = nil
	if not isUnitVector(direction) then
		return
	end
	local arrows = player:GetAttribute("Arrows") or 0
	if arrows <= 0 then
		return
	end
	local cfg = Config.Weapons.Bow
	local charge = math.clamp((os.clock() - drawStart) / cfg.ChargeTime, 0, 1)
	if charge < cfg.MinCharge then
		return
	end
	local head = char:FindFirstChild("Head")
	if not head then
		return
	end
	if PlayerService.InMatch(player) then
		player:SetAttribute("Arrows", arrows - 1) -- ใน Lobby ยิงได้ไม่จำกัด
	end

	-- ยิ่งง้างนานยิ่งแรงและบินไกล
	local speed = cfg.MinSpeed + (cfg.MaxSpeed - cfg.MinSpeed) * charge
	local damage = cfg.MinDamage + (cfg.MaxDamage - cfg.MinDamage) * charge
	local origin = head.Position + direction * 1.5
	local velocity = direction * speed

	local shot = { Id = type(shotId) == "number" and shotId or -1, Origin = origin, Velocity = velocity, Damage = damage, Done = false }
	shots[player] = shots[player] or {}
	shots[player][shot.Id] = shot

	Remotes.ArrowFired:FireAllClients(player.UserId, origin, velocity, cfg.Gravity)
	task.spawn(simulateArrow, player, shot)
end

---------------------------------------------------------------- กลิ้งหลบ

local function onRoll(player)
	local st = PlayerService.GetState(player)
	if not st or not PlayerService.GetCharacterParts(player) then
		return
	end
	local now = os.clock()
	if now - st.LastRoll < Config.Roll.Cooldown - ROLL_TOLERANCE then
		return
	end
	st.LastRoll = now
	st.IFrameUntil = now + Config.Roll.IFrame
	st.DrawStart = nil
	PlayerService.SetBlocking(player, false)
end

function CombatService.Init()
	Remotes.Equip.OnServerEvent:Connect(PlayerService.Equip)
	Remotes.SwordSwing.OnServerEvent:Connect(onSwordSwing)
	Remotes.BowDrawStart.OnServerEvent:Connect(onBowDrawStart)
	Remotes.BowCancel.OnServerEvent:Connect(onBowCancel)
	Remotes.BowFire.OnServerEvent:Connect(onBowFire)
	Remotes.ArrowHit.OnServerEvent:Connect(onArrowHit)
	Players.PlayerRemoving:Connect(function(player)
		shots[player] = nil
	end)
	Remotes.Roll.OnServerEvent:Connect(onRoll)
end

return CombatService
