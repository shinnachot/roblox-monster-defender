-- MonsterService: spawn, AI (กติกาเปลี่ยนเป้าหมาย GDD ข้อ 7), ดาเมจ, กระสุน, ของดรอป และการตายของ monster
-- แบบของ monster กำหนดใน GameConfig.Monsters:
--   ประชิด (มี AttackRange), ยิงไกล (มี Ranged), Boss (Boss = true: ฟันกวาด + เรียกลูกน้อง)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets

local PlayerService = require(script.Parent.PlayerService)
local BaseService = require(script.Parent.BaseService)
local MonsterNav = require(script.Parent.MonsterNav)

local MonsterService = {}

local folder = workspace:WaitForChild("Monsters")
local pickupFolder = workspace:WaitForChild("Pickups")
local active = {} -- [Model] = monster data
local activeCount = 0
local pickups = {} -- [Model] = { Arrows, ExpiresAt }
local rng = Random.new()

-- ทางเข้าเดียวด้านหน้า (-Z): monster ที่ยังอยู่นอกลานป้อม (Z < GATE_Z) ยังตี/ยิงฐานไม่ได้
-- เส้นทางเดิน (อ้อมที่กำบัง, ผ่านประตู, ขึ้นบันไดกำแพง) คำนวณโดย MonsterNav
local GATE_Z = Config.Map.GateZ
local GROUND_ROOT_Y = 3 -- ความสูง root ของตัวที่ยืนบนพื้น
local BOSS_SIGHT_RANGE = 90

local DISABLED_STATES = {
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.PlatformStanding,
}

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function loadTrack(animator, name, priority, looped)
	local animation = name and Assets.Animations:FindFirstChild(name)
	if not animation then
		return nil
	end
	local track = animator:LoadAnimation(animation)
	track.Priority = priority
	track.Looped = looped
	return track
end

local function playerFromPart(part)
	local node = part
	while node and node ~= workspace do
		local player = Players:GetPlayerFromCharacter(node)
		if player then
			return player
		end
		node = node.Parent
	end
	return nil
end

function MonsterService.GetFromPart(part)
	local node = part
	while node and node.Parent ~= folder do
		node = node.Parent
	end
	return node and active[node] and node or nil
end

function MonsterService.GetActive()
	return active
end

function MonsterService.Count()
	return activeCount
end

---------------------------------------------------------------- spawn

local function attachWeapon(model, weapon)
	local hand = model:FindFirstChild(weapon.Hand .. "Hand")
	local template = Assets.Weapons:FindFirstChild(weapon.Model)
	if not hand or not template then
		return
	end
	local held = template:Clone()
	held.Name = "HeldWeapon"
	if weapon.Scale then
		held:ScaleTo(held:GetScale() * weapon.Scale)
	end
	local attachment = hand:FindFirstChild(weapon.Hand .. "GripAttachment")
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = held.PrimaryPart
	weld.C0 = attachment and attachment.CFrame or CFrame.new()
	weld.Parent = held.PrimaryPart
	held.Parent = model
end

-- options: { Stage = เลข stage, PlayerCount = จำนวนผู้เล่น } (ใช้คำนวณความแข็งของ Boss)
function MonsterService.Spawn(kind, position, options)
	local cfg = Config.Monsters[kind]
	options = options or {}
	local stage = options.Stage or 1
	local playerCount = options.PlayerCount or 1

	local model = Assets.Monsters[cfg.Template]:Clone()
	model.Name = kind
	if cfg.Scale and cfg.Scale ~= 1 then
		model:ScaleTo(cfg.Scale)
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	hum.WalkSpeed = cfg.WalkSpeed
	for _, state in DISABLED_STATES do
		hum:SetStateEnabled(state, false)
	end
	if cfg.Weapon then
		attachWeapon(model, cfg.Weapon)
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Monsters"
		end
	end
	model:PivotTo(CFrame.lookAt(position, position + Vector3.new(0, 0, 1)))
	model.Parent = folder
	root:SetNetworkOwner(nil)

	local maxHP = cfg.HP
	local damageScale = 1
	if cfg.Boss then
		maxHP = cfg.HP * playerCount * (1 + cfg.StageHPScale * (stage - 1))
		damageScale = 1 + cfg.StageDamageScale * (stage - 1)
	end

	local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
	local m = {
		Model = model,
		Hum = hum,
		Root = root,
		Kind = kind,
		Cfg = cfg,
		HP = maxHP,
		MaxHP = maxHP,
		Radius = root.Size.X / 2, -- รัศมีลำตัวโดยประมาณ (ตัวใหญ่ตีโดนได้จากไกลกว่า)
		DamageScale = damageScale,
		Stage = stage,
		PlayerCount = playerCount,
		Target = nil, -- Player ที่กำลังไล่ตี (nil = เดินไปตีฐาน)
		DamageBy = {}, -- [Player] = ดาเมจสะสม (Boss ใช้เลือกเป้า)
		LaneX = math.clamp(position.X, -Config.Map.LaneHalfWidth, Config.Map.LaneHalfWidth), -- เลนที่เดินเข้าหาป้อม (ตามจุดเกิด)
		NextAttack = 0,
		BusyUntil = 0,
		Cover = nil, -- monster ยิงไกล: ที่กำบังที่กำลังใช้ { Box, Sign, RecheckAt, Deadline }
		NoCoverUntil = 0,
		BlindSince = nil, -- เริ่มมองไม่เห็นเป้าบนกำแพงตั้งแต่เมื่อไร
		IgnorePlayer = nil, -- ผู้เล่นที่เลิกสนใจชั่วคราว (มองไม่เห็น)
		IgnoreUntil = 0,
		AimUntil = nil, -- monster ยิงไกล: เวลาที่จะลั่น
		AimPlayer = nil,
		NextSummon = os.clock() + (cfg.Summon and cfg.Summon.Interval * 0.5 or 0),
		Dead = false,
		Walk = loadTrack(animator, "MonsterWalk", Enum.AnimationPriority.Movement, true),
		Attack = cfg.AttackAnim and loadTrack(animator, cfg.AttackAnim.Name, Enum.AnimationPriority.Action, false),
		Death = loadTrack(animator, cfg.DeathAnim.Name, Enum.AnimationPriority.Action4, false),
	}

	hum.Running:Connect(function(speed)
		if m.Dead or not m.Walk then
			return
		end
		if speed > 0.5 then
			if not m.Walk.IsPlaying then
				m.Walk:Play(0.2, 1, cfg.WalkSpeed / 12)
			end
		else
			m.Walk:Stop(0.2)
		end
	end)

	if cfg.Boss then
		workspace:SetAttribute("BossMaxHP", maxHP)
		workspace:SetAttribute("BossHP", maxHP)
		Remotes.WorldSound:FireAllClients(cfg.AttackSound, position)
	end

	active[model] = m
	activeCount += 1
	return model
end

---------------------------------------------------------------- ของดรอป

local function dropArrows(position, amount)
	local model = Assets.Weapons.Arrow:Clone()
	model.Name = "ArrowPickup"
	model.PrimaryPart.Anchored = true
	-- ปักเฉียงอยู่บนพื้น
	local ground = Vector3.new(position.X, 1.6, position.Z)
	model:PivotTo(CFrame.lookAt(ground, ground + Vector3.new(0.3, -1, 0.2)))
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(255, 220, 90)
	highlight.OutlineColor = Color3.fromRGB(255, 240, 160)
	highlight.FillTransparency = 0.4
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model
	model:SetAttribute("Arrows", amount)
	model.Parent = pickupFolder
	pickups[model] = { Arrows = amount, ExpiresAt = os.clock() + Config.Pickup.Lifetime }
end

local function updatePickups(now)
	for model, pickup in pickups do
		if now >= pickup.ExpiresAt or not model.Parent then
			pickups[model] = nil
			model:Destroy()
		else
			local position = model:GetPivot().Position
			for _, player in Players:GetPlayers() do
				local char, _, root = PlayerService.GetCharacterParts(player)
				if char and flat(root.Position - position).Magnitude <= Config.Pickup.Range then
					player:SetAttribute("Arrows", (player:GetAttribute("Arrows") or 0) + pickup.Arrows)
					Remotes.WorldSound:FireAllClients("Pickup", position)
					pickups[model] = nil
					model:Destroy()
					break
				end
			end
		end
	end
end

---------------------------------------------------------------- ดาเมจ / ตาย

local function kill(m, killer)
	m.Dead = true
	active[m.Model] = nil
	activeCount -= 1

	m.Hum.WalkSpeed = 0
	m.Root.Anchored = true
	m.Model:SetAttribute("AimAt", nil)
	for _, part in m.Model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanQuery = false
			part.CanCollide = false
		end
	end
	if m.Walk then
		m.Walk:Stop(0.1)
	end
	if m.Attack then
		m.Attack:Stop(0.1)
	end
	local seg = m.Cfg.DeathAnim
	if m.Death then
		m.Death:Play(0.1, 1, seg.Speed)
		m.Death.TimePosition = seg.Start
		task.delay((seg.Hold - seg.Start) / seg.Speed, function()
			m.Death:AdjustSpeed(0)
		end)
	end
	Remotes.WorldSound:FireAllClients(m.Cfg.DeathSound, m.Root.Position)
	Debris:AddItem(m.Model, m.Cfg.Boss and 5 or 3)

	if killer then
		PlayerService.AddStat(killer, "Kills", 1)
	end
	if m.Cfg.Boss then
		workspace:SetAttribute("BossHP", nil)
		workspace:SetAttribute("BossMaxHP", nil)
	end
	local drop = m.Cfg.Drop
	if drop and rng:NextNumber() < drop.Chance then
		dropArrows(m.Root.Position, drop.Arrows)
	end
end

-- คืน (โดนจริงไหม, ตายไหม)
function MonsterService.Damage(model, amount, attacker)
	local m = active[model]
	if not m or m.Dead then
		return false, false
	end
	local dealt = math.min(amount, m.HP)
	m.HP -= amount
	if attacker then
		m.DamageBy[attacker] = (m.DamageBy[attacker] or 0) + dealt
		PlayerService.AddStat(attacker, "Damage", math.round(dealt))
		if not m.Cfg.Boss then
			m.Target = attacker -- โดนผู้เล่นตี -> หันไปตีผู้เล่นคนนั้น
		end
	end
	if m.Cfg.Boss then
		workspace:SetAttribute("BossHP", math.max(0, math.ceil(m.HP)))
	end
	if m.HP <= 0 then
		kill(m, attacker)
		return true, true
	end
	return true, false
end

function MonsterService.ClearAll()
	for model, m in active do
		m.Dead = true
		model:Destroy()
	end
	table.clear(active)
	activeCount = 0
	folder:ClearAllChildren()
	table.clear(pickups)
	pickupFolder:ClearAllChildren()
	workspace:SetAttribute("BossHP", nil)
	workspace:SetAttribute("BossMaxHP", nil)
end

---------------------------------------------------------------- AI: ส่วนกลาง

local function face(m, targetPos, yawDegrees)
	local pos = m.Root.Position
	local to = flat(targetPos - pos)
	if to.Magnitude > 0.1 then
		m.Root.CFrame = CFrame.lookAt(pos, pos + to) * CFrame.Angles(0, -math.rad(yawDegrees or 0), 0)
	end
end

local function stop(m)
	m.Hum:MoveTo(m.Root.Position)
end

-- เดินไปหาฐาน (ผ่านประตูหน้าก่อน); คืนระยะราบถึงศูนย์กลางฐาน หรือ nil ถ้ายังอยู่นอกกำแพง
local function distanceToBase(m)
	local pos = m.Root.Position
	if pos.Z < GATE_Z then
		return nil
	end
	return flat(BaseService.GetPosition() - pos).Magnitude
end

-- ระยะที่ monster ประชิดตีถึงฐาน (ตัวใหญ่ตีถึงจากไกลกว่า)
local function baseReach(m)
	return Config.Base.AttackRadius + math.max(0, (m.Cfg.AttackRange or 5) - 5)
end

-- เดินไปหาฐาน: เป้าคือจุดบนวงรอบคริสตัลด้านที่ตัวเองเดินมา (ศูนย์กลางคริสตัลเดินไปถึงไม่ได้)
local function moveTowardBase(m, now)
	-- ยังอยู่กลางสนาม: เดินตามเลนของตัวเอง (กระจายซ้าย/กลาง/ขวา) แล้วค่อยบีบเข้าประตูตอนใกล้ป้อม
	if m.Root.Position.Z < Config.Map.LaneEndZ - 6 then
		MonsterNav.MoveTo(m, Vector3.new(m.LaneX, GROUND_ROOT_Y, Config.Map.LaneEndZ), now)
		return
	end
	local base = BaseService.GetPosition()
	local away = flat(m.Root.Position - base)
	local dir = away.Magnitude > 0.1 and away.Unit or -Vector3.zAxis
	MonsterNav.MoveTo(m, Vector3.new(base.X, GROUND_ROOT_Y, base.Z) + dir * (baseReach(m) - 1), now)
end

-- ผู้เล่นที่ขวางทางอยู่ข้างหน้าในระยะ AggroFrontRange (ไม่นับคนที่อยู่ต่างระดับ เช่น บนกำแพง)
local function findBlockingPlayer(m)
	local pos = m.Root.Position
	local look = flat(m.Root.CFrame.LookVector)
	local best, bestDist
	for _, player in Players:GetPlayers() do
		local char, _, root = PlayerService.GetCharacterParts(player)
		if char then
			local to = flat(root.Position - pos)
			local dist = to.Magnitude
			local sameLevel = math.abs(root.Position.Y - pos.Y) <= Config.AI.MeleeHeightReach
			if sameLevel and dist <= Config.AI.AggroFrontRange and (dist < 2 or to.Unit:Dot(look) > 0.2) then
				if not bestDist or dist < bestDist then
					best, bestDist = player, dist
				end
			end
		end
	end
	return best
end

-- ตรวจเป้าหมายปัจจุบัน: ผู้เล่นตาย/ล้ม/หนีไกลเกิน -> กลับไปหาฐาน; คืน root ของเป้าหมายถ้ายังใช้ได้
-- เป้าที่อยู่บนกำแพงไม่มีระยะเลิกไล่: ไล่จนกว่าจะล้ม หรือลงมาแล้วหนีไกลเกิน leash
local function validateTarget(m, leash)
	if not m.Target then
		return nil
	end
	local char, _, root = PlayerService.GetCharacterParts(m.Target)
	if char and (MonsterNav.IsElevated(root.Position) or flat(root.Position - m.Root.Position).Magnitude <= leash) then
		return root
	end
	m.Target = nil
	return nil
end

---------------------------------------------------------------- AI: ประชิด

local function meleeAttack(m, now, targetPlayer, targetPos)
	local cfg = m.Cfg
	local seg = cfg.AttackAnim
	local hitDelay, duration = Config.SegmentTiming(seg)
	m.NextAttack = now + cfg.AttackCooldown
	m.BusyUntil = now + duration
	stop(m)
	face(m, targetPos)
	if m.Attack then
		m.Attack:Play(0.1, 1, seg.Speed)
		m.Attack.TimePosition = seg.Start
		task.delay(duration, function()
			if not m.Dead then
				m.Attack:Stop(0.2)
			end
		end)
	end
	Remotes.WorldSound:FireAllClients(cfg.AttackSound, m.Root.Position)

	task.delay(hitDelay, function()
		if m.Dead then
			return
		end
		local origin = m.Root.Position
		if cfg.HitSound then
			Remotes.WorldSound:FireAllClients(cfg.HitSound, origin)
		end
		local damage = math.round(cfg.Damage * m.DamageScale)
		if cfg.Sweep then
			-- ฟันกวาดเป็นวง: โดนทุกคนในรัศมีและอยู่ในมุมกวาด
			local look = flat(m.Root.CFrame.LookVector).Unit
			local minDot = math.cos(math.rad(cfg.Sweep.ArcDegrees / 2))
			for _, player in Players:GetPlayers() do
				local char, _, root = PlayerService.GetCharacterParts(player)
				if char then
					local to = flat(root.Position - origin)
					local sameLevel = math.abs(root.Position.Y - origin.Y) <= Config.AI.MeleeHeightReach + 3
					if sameLevel and to.Magnitude <= cfg.Sweep.Radius and (to.Magnitude < 3 or to.Unit:Dot(look) >= minDot) then
						PlayerService.Damage(player, damage, origin)
					end
				end
			end
			if not targetPlayer then
				BaseService.Damage(math.round(cfg.BaseDamage * m.DamageScale))
			end
		elseif targetPlayer then
			local char, _, root = PlayerService.GetCharacterParts(targetPlayer)
			if char
				and flat(root.Position - origin).Magnitude <= cfg.AttackRange + 2
				and math.abs(root.Position.Y - origin.Y) <= Config.AI.MeleeHeightReach
			then
				PlayerService.Damage(targetPlayer, damage, origin)
			end
		else
			BaseService.Damage(cfg.BaseDamage)
		end
	end)
end

local function meleeChase(m, now, targetRoot)
	local offset = targetRoot.Position - m.Root.Position
	local reach = Config.AI.MeleeHeightReach + (m.Cfg.Boss and 3 or 0)
	if flat(offset).Magnitude <= m.Cfg.AttackRange and math.abs(offset.Y) <= reach then
		if now >= m.NextAttack then
			meleeAttack(m, now, m.Target, targetRoot.Position)
		else
			stop(m)
			face(m, targetRoot.Position)
		end
	elseif not MonsterNav.MoveTo(m, targetRoot.Position, now) then
		m.Target = nil -- เดินไปไม่ถึง (เช่น ยืนบนเชิงเทิน) -> กลับไปหาฐาน
	end
end

local function meleeBase(m, now)
	local dist = distanceToBase(m)
	local reach = baseReach(m)
	if dist and dist <= reach then
		if now >= m.NextAttack then
			meleeAttack(m, now, nil, BaseService.GetPosition())
		else
			stop(m)
		end
	else
		moveTowardBase(m, now)
	end
end

local function updateMelee(m, now)
	local targetRoot = validateTarget(m, Config.AI.LeashRange)
	if not targetRoot then
		local blocker = findBlockingPlayer(m)
		if blocker then
			m.Target = blocker
			targetRoot = blocker.Character.HumanoidRootPart
		end
	end
	if targetRoot then
		meleeChase(m, now, targetRoot)
	else
		meleeBase(m, now)
	end
end

---------------------------------------------------------------- AI: Boss

local function updateBoss(m, now)
	local cfg = m.Cfg

	-- เลือกตีคนที่ทำดาเมจใส่ตัวเองมากที่สุด (ที่ยังยืนอยู่); ถ้ายังไม่มีใครตี เลือกคนที่ใกล้สุดในระยะมองเห็น
	-- Boss ไม่โจมตีคนบนกำแพง: ข้ามไปเลือกคนบนพื้น ถ้าไม่มีใครอยู่บนพื้นเลยก็ไปตีฐาน
	local best, bestScore
	for _, player in Players:GetPlayers() do
		local char, _, root = PlayerService.GetCharacterParts(player)
		if char and not MonsterNav.IsElevated(root.Position) then
			local dealt = m.DamageBy[player] or 0
			local dist = flat(root.Position - m.Root.Position).Magnitude
			local score = dealt > 0 and (1e6 + dealt) or (dist <= BOSS_SIGHT_RANGE and -dist or nil)
			if score and (not bestScore or score > bestScore) then
				best, bestScore = player, score
			end
		end
	end
	m.Target = best

	-- เรียกลูกน้องเป็นระยะ
	local summon = cfg.Summon
	if summon and now >= m.NextSummon then
		m.NextSummon = now + summon.Interval
		local scale = Config.Waves.PlayerScale[math.clamp(m.PlayerCount, 1, #Config.Waves.PlayerScale)]
		local count = math.max(1, math.ceil(summon.Count * scale))
		Remotes.WorldSound:FireAllClients(cfg.AttackSound, m.Root.Position)
		for index = 1, count do
			local angle = (index / count) * math.pi * 2
			local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 7
			local pos = m.Root.Position + offset
			MonsterService.Spawn(summon.Kind, Vector3.new(pos.X, 3.5, pos.Z), { Stage = m.Stage, PlayerCount = m.PlayerCount })
		end
	end

	if best then
		meleeChase(m, now, best.Character.HumanoidRootPart)
	else
		meleeBase(m, now)
	end
end

---------------------------------------------------------------- AI: ยิงไกล

local function hasLineOfSight(from, to)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { folder, pickupFolder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(from, to - from, params) == nil
end

local function eyePosition(m)
	local head = m.Model:FindFirstChild("Head")
	return head and head.Position or m.Root.Position + Vector3.new(0, 1.5, 0)
end

-- ทิศยิงที่ชดเชยแรงโน้มถ่วงให้ไปตกที่ target (ไม่นำหน้าเป้า — ผู้เล่นที่ขยับหลบได้)
local function launchDirection(origin, target, speed, gravity)
	local offset = target - origin
	local flatOffset = flat(offset)
	local distance = flatOffset.Magnitude
	if gravity <= 0 or distance < 1 then
		return offset.Unit
	end
	local v2 = speed * speed
	local discriminant = v2 * v2 - gravity * (gravity * distance * distance + 2 * offset.Y * v2)
	if discriminant < 0 then
		return (flatOffset.Unit + Vector3.yAxis).Unit
	end
	return (flatOffset.Unit + Vector3.yAxis * ((v2 - math.sqrt(discriminant)) / (gravity * distance))).Unit
end

local function simulateProjectile(m, origin, velocity, ranged)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { folder, pickupFolder }
	for _, player in Players:GetPlayers() do
		-- กระสุนทะลุผู้เล่นที่ล้มอยู่ (monster ไม่ตีคนล้ม)
		if player.Character and PlayerService.IsDowned(player) then
			table.insert(ignore, player.Character)
		end
	end
	params.FilterDescendantsInstances = ignore

	local gravity = Vector3.new(0, -ranged.Gravity, 0)
	local pos, vel, elapsed = origin, velocity, 0
	local damage = math.round(ranged.Damage * m.DamageScale)
	while elapsed < 4 do
		local dt = RunService.Heartbeat:Wait()
		elapsed += dt
		local step = vel * dt + 0.5 * gravity * dt * dt
		local result = workspace:Raycast(pos, step, params)
		if result then
			local player = playerFromPart(result.Instance)
			if player then
				PlayerService.Damage(player, damage, origin)
			elseif result.Instance:IsDescendantOf(BaseService.Model) then
				BaseService.Damage(m.Cfg.BaseDamage)
			end
			return
		end
		pos += step
		vel += gravity * dt
	end
end

local function fire(m, targetPos)
	local ranged = m.Cfg.Ranged
	local origin = eyePosition(m)
	local direction = launchDirection(origin, targetPos, ranged.Speed, ranged.Gravity)
	origin += direction * 2
	local velocity = direction * ranged.Speed
	Remotes.WorldSound:FireAllClients(m.Cfg.AttackSound, origin)
	Remotes.ArrowFired:FireAllClients(0, origin, velocity, ranged.Gravity, ranged.Kind == "Rifle" and "Bullet" or "Arrow")
	task.spawn(simulateProjectile, m, origin, velocity, ranged)
end

local function stopAiming(m)
	m.AimUntil = nil
	m.AimPlayer = nil
	m.Model:SetAttribute("AimAt", nil)
end

local function startAiming(m, now, player, targetPos)
	local ranged = m.Cfg.Ranged
	m.AimUntil = now + ranged.AimTime
	m.AimPlayer = player
	stop(m)
	face(m, targetPos, ranged.BodyYaw)
	-- client จัดท่าเล็งจาก attribute นี้ (ดู MonsterPose)
	m.Model:SetAttribute("AimKind", ranged.Kind)
	m.Model:SetAttribute("AimAt", targetPos)
end

-- ที่กำบังที่กำลังใช้อยู่ (ทบทวนใหม่เป็นระยะ); nil = ไม่มีที่กำบังที่ใช้ได้ในตอนนี้
local function currentCover(m, now, threatPos)
	if MonsterNav.IsElevated(m.Root.Position) or now < m.NoCoverUntil then
		m.Cover = nil
		return nil
	end
	local cover = m.Cover
	if cover and now < cover.RecheckAt and cover.Box.Parent then
		return cover
	end
	local box, sign = MonsterNav.FindCover(m, threatPos, m.Cfg.Ranged.Range)
	if not box then
		m.Cover = nil
		m.NoCoverUntil = now + 1
		return nil
	end
	if cover and cover.Box == box then
		cover.RecheckAt = now + 1.5
		return cover
	end
	cover = { Box = box, Sign = sign, RecheckAt = now + 1.5, Deadline = now + Config.AI.CoverGiveUpTime }
	m.Cover = cover
	return cover
end

local function abandonCover(m, now)
	m.Cover = nil
	m.NoCoverUntil = now + 8
end

-- เป้าคือผู้เล่น: ถ้ามีที่กำบังใกล้ตัว หลบหลังที่กำบังระหว่างบรรจุ -> โผล่ออกมาเล็งยิง -> กลับไปหลบ
-- ไม่มีที่กำบัง: ยืนยิงกลางแจ้ง; เป้าอยู่บนกำแพง: เข้ามาในระยะยิงแต่ไม่ปีนขึ้นไปหา
local function updateRangedVsPlayer(m, now, targetRoot)
	local ranged = m.Cfg.Ranged
	local pos = m.Root.Position
	local targetPos = targetRoot.Position
	local inRange = (targetPos - pos).Magnitude <= ranged.Range
	local canShoot = inRange and hasLineOfSight(eyePosition(m), targetPos)
	local ready = now >= m.NextAttack

	local cover = currentCover(m, now, targetPos)
	if cover then
		m.BlindSince = nil
		local hide, peek = MonsterNav.CoverSpots(cover.Box, targetPos, cover.Sign, pos.Y)
		if now >= cover.Deadline then
			abandonCover(m, now)
		elseif ready then
			if flat(peek - pos).Magnitude > 2 then
				MonsterNav.MoveTo(m, peek, now)
				return
			elseif canShoot then
				cover.Deadline = now + Config.AI.CoverGiveUpTime + ranged.AimTime + ranged.Cooldown
				startAiming(m, now, m.Target, targetPos)
				return
			end
			abandonCover(m, now) -- โผล่แล้วยังยิงไม่ได้
		else
			if flat(hide - pos).Magnitude > 1.5 then
				MonsterNav.MoveTo(m, hide, now)
			else
				cover.Deadline = now + Config.AI.CoverGiveUpTime + ranged.Cooldown
				stop(m)
				face(m, targetPos, ranged.BodyYaw)
			end
			return
		end
	end

	if canShoot then
		m.BlindSince = nil
		if ready then
			startAiming(m, now, m.Target, targetPos)
		else
			stop(m) -- กำลังบรรจุ
			face(m, targetPos, ranged.BodyYaw)
		end
		return
	end

	if MonsterNav.IsElevated(targetPos) and not MonsterNav.IsElevated(pos) then
		local toMonster = flat(pos - targetPos)
		local arrived = toMonster.Magnitude <= Config.AI.ElevatedStandOff + 2
		local moving = true
		if arrived then
			stop(m)
			face(m, targetPos, ranged.BodyYaw)
		else
			local standOff = Vector3.new(targetPos.X, pos.Y, targetPos.Z) + toMonster.Unit * Config.AI.ElevatedStandOff
			moving = MonsterNav.MoveTo(m, standOff, now)
		end
		-- เข้ามาถึงระยะแล้วแต่ยังยิงคนบนกำแพงไม่ได้นานเกินไป (หลบหลังเชิงเทิน/เดินไปไม่ถึง) -> เลิกสนใจชั่วคราว กลับไปหาฐาน
		if inRange or arrived or not moving then
			m.BlindSince = m.BlindSince or now
			if now - m.BlindSince >= Config.AI.BlindGiveUpTime then
				m.IgnorePlayer, m.IgnoreUntil = m.Target, now + 6
				m.Target, m.BlindSince = nil, nil
			end
		else
			m.BlindSince = nil
		end
	else
		m.BlindSince = nil
		MonsterNav.MoveTo(m, targetPos, now) -- เข้าไปให้ถึงระยะ/มองเห็น
	end
end

local function updateRanged(m, now)
	local ranged = m.Cfg.Ranged
	local pos = m.Root.Position
	local eye = eyePosition(m)

	-- กำลังเล็งอยู่: หันตามเป้า แล้วลั่นเมื่อครบเวลา
	if m.AimUntil then
		local targetPos
		if m.AimPlayer then
			local char, _, root = PlayerService.GetCharacterParts(m.AimPlayer)
			if not char then
				stopAiming(m) -- เป้าล้ม/หายไป
				return
			end
			targetPos = root.Position + Vector3.new(0, 0.5, 0)
		else
			targetPos = BaseService.GetPosition() + Vector3.new(0, 7, 0)
		end
		face(m, targetPos, ranged.BodyYaw)
		m.Model:SetAttribute("AimAt", targetPos)
		if now >= m.AimUntil then
			stopAiming(m)
			m.NextAttack = now + ranged.Cooldown
			fire(m, targetPos)
		end
		return
	end

	-- เป้าหมายผู้เล่น: คนที่ตีตัวเอง หรือคนที่มองเห็นในรัศมีค้นหา (DetectRange)
	local detectRange = ranged.DetectRange or ranged.Range
	local targetRoot = validateTarget(m, math.max(Config.AI.LeashRange, detectRange))
	if not targetRoot then
		local bestDist
		for _, player in Players:GetPlayers() do
			local char, _, root = PlayerService.GetCharacterParts(player)
			if char and not (m.IgnorePlayer == player and now < m.IgnoreUntil) then
				local dist = (root.Position - pos).Magnitude
				if dist <= detectRange and (not bestDist or dist < bestDist) and hasLineOfSight(eye, root.Position) then
					m.Target, targetRoot, bestDist = player, root, dist
				end
			end
		end
	end

	if targetRoot then
		updateRangedVsPlayer(m, now, targetRoot)
		return
	end
	m.Cover = nil

	-- เป้าหลัก = ฐาน: เข้ามาในระยะแล้วยืนยิง
	local dist = distanceToBase(m)
	if dist and dist <= ranged.BaseRange then
		if now >= m.NextAttack then
			startAiming(m, now, nil, BaseService.GetPosition() + Vector3.new(0, 7, 0))
		else
			stop(m)
		end
	else
		moveTowardBase(m, now)
	end
end

----------------------------------------------------------------

local function update(m, now)
	if m.Dead or now < m.BusyUntil then
		return
	end
	if m.Cfg.Boss then
		updateBoss(m, now)
	elseif m.Cfg.Ranged then
		updateRanged(m, now)
	else
		updateMelee(m, now)
	end
end

function MonsterService.Init()
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < Config.AI.TickRate then
			return
		end
		accumulator = 0
		local now = os.clock()
		-- snapshot: Boss อาจ spawn ลูกน้องระหว่างวน
		local list = {}
		for _, m in active do
			table.insert(list, m)
		end
		for _, m in list do
			local ok, err = pcall(update, m, now)
			if not ok then
				warn("[MonsterService] AI error (" .. m.Kind .. "):", err)
			end
		end
		updatePickups(now)
	end)
end

return MonsterService
