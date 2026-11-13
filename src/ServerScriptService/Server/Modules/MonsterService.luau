-- MonsterService: spawn, AI (กติกาเปลี่ยนเป้าหมาย GDD ข้อ 7), ดาเมจ และการตายของ monster
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets

local PlayerService = require(script.Parent.PlayerService)
local BaseService = require(script.Parent.BaseService)

local MonsterService = {}

local folder = workspace:WaitForChild("Monsters")
local active = {} -- [Model] = monster data
local activeCount = 0

-- ทางเข้าเดียวด้านหน้า (-Z): monster ที่ยังอยู่นอกกำแพงต้องเดินผ่านประตูก่อน
local GATE_Z = -34
local GATE_HALF_WIDTH = 4

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
	local animation = Assets.Animations:FindFirstChild(name)
	if not animation then
		return nil
	end
	local track = animator:LoadAnimation(animation)
	track.Priority = priority
	track.Looped = looped
	return track
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

function MonsterService.Spawn(kind, position)
	local cfg = Config.Monsters[kind]
	local model = Assets.Monsters[cfg.Template]:Clone()
	model.Name = kind
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	hum.WalkSpeed = cfg.WalkSpeed
	for _, state in DISABLED_STATES do
		hum:SetStateEnabled(state, false)
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Monsters"
		end
	end
	model:PivotTo(CFrame.lookAt(position, position + Vector3.new(0, 0, 1)))
	model.Parent = folder
	root:SetNetworkOwner(nil)

	local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
	local m = {
		Model = model,
		Hum = hum,
		Root = root,
		Kind = kind,
		Cfg = cfg,
		HP = cfg.HP,
		Target = nil, -- Player ที่กำลังไล่ตี (nil = เดินไปตีฐาน)
		NextAttack = 0,
		BusyUntil = 0,
		Dead = false,
		Walk = loadTrack(animator, "MonsterWalk", Enum.AnimationPriority.Movement, true),
		Attack = loadTrack(animator, cfg.AttackAnim.Name, Enum.AnimationPriority.Action, false),
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

	active[model] = m
	activeCount += 1
	return model
end

local function kill(m)
	m.Dead = true
	active[m.Model] = nil
	activeCount -= 1

	m.Hum.WalkSpeed = 0
	m.Root.Anchored = true
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
	Debris:AddItem(m.Model, 3)
end

-- คืน (โดนจริงไหม, ตายไหม)
function MonsterService.Damage(model, amount, attacker)
	local m = active[model]
	if not m or m.Dead then
		return false, false
	end
	m.HP -= amount
	if attacker then
		m.Target = attacker -- โดนผู้เล่นตี -> หันไปตีผู้เล่นคนนั้น
	end
	if m.HP <= 0 then
		kill(m)
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
end

-- ผู้เล่นที่ขวางทางอยู่ข้างหน้าในระยะ AggroFrontRange
local function findBlockingPlayer(m)
	local pos = m.Root.Position
	local look = flat(m.Root.CFrame.LookVector)
	local best, bestDist
	for _, player in Players:GetPlayers() do
		local char, _, root = PlayerService.GetCharacterParts(player)
		if char then
			local to = flat(root.Position - pos)
			local dist = to.Magnitude
			if dist <= Config.AI.AggroFrontRange and (dist < 2 or to.Unit:Dot(look) > 0.2) then
				if not bestDist or dist < bestDist then
					best, bestDist = player, dist
				end
			end
		end
	end
	return best
end

local function face(m, targetPos)
	local pos = m.Root.Position
	local to = flat(targetPos - pos)
	if to.Magnitude > 0.1 then
		m.Root.CFrame = CFrame.lookAt(pos, pos + to)
	end
end

local function attack(m, now, targetPlayer, targetPos)
	local cfg = m.Cfg
	local seg = cfg.AttackAnim
	local hitDelay, duration = Config.SegmentTiming(seg)
	m.NextAttack = now + cfg.AttackCooldown
	m.BusyUntil = now + duration
	m.Hum:MoveTo(m.Root.Position)
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
		if targetPlayer then
			local char, _, root = PlayerService.GetCharacterParts(targetPlayer)
			if char and flat(root.Position - m.Root.Position).Magnitude <= cfg.AttackRange + 2 then
				PlayerService.Damage(targetPlayer, cfg.Damage)
			end
		else
			BaseService.Damage(cfg.BaseDamage)
		end
	end)
end

local function update(m, now)
	if m.Dead or now < m.BusyUntil then
		return
	end
	local cfg = m.Cfg
	local pos = m.Root.Position

	-- ตรวจเป้าหมายที่เป็นผู้เล่น: ตาย/หนีไกลเกิน -> กลับไปหาฐาน
	local targetRoot
	if m.Target then
		local char, _, root = PlayerService.GetCharacterParts(m.Target)
		if char and flat(root.Position - pos).Magnitude <= Config.AI.LeashRange then
			targetRoot = root
		else
			m.Target = nil
		end
	end
	if not m.Target then
		local blocker = findBlockingPlayer(m)
		if blocker then
			m.Target = blocker
			targetRoot = blocker.Character.HumanoidRootPart
		end
	end

	if targetRoot then
		local dist = flat(targetRoot.Position - pos).Magnitude
		if dist <= cfg.AttackRange then
			if now >= m.NextAttack then
				attack(m, now, m.Target, targetRoot.Position)
			else
				m.Hum:MoveTo(pos)
				face(m, targetRoot.Position)
			end
		else
			m.Hum:MoveTo(targetRoot.Position)
		end
		return
	end

	-- เป้าหลัก = ฐาน
	local basePos = BaseService.GetPosition()
	if pos.Z < GATE_Z then
		m.Hum:MoveTo(Vector3.new(math.clamp(pos.X, -GATE_HALF_WIDTH, GATE_HALF_WIDTH), pos.Y, GATE_Z + 4))
		return
	end
	local dist = flat(basePos - pos).Magnitude
	if dist <= Config.Base.AttackRadius then
		if now >= m.NextAttack then
			attack(m, now, nil, basePos)
		else
			m.Hum:MoveTo(pos)
		end
	else
		m.Hum:MoveTo(basePos)
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
		for _, m in active do
			local ok, err = pcall(update, m, now)
			if not ok then
				warn("[MonsterService] AI error:", err)
			end
		end
	end)
end

return MonsterService
