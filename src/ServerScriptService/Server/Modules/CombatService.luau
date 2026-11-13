-- CombatService: รับคำสั่งต่อสู้จาก client แล้วตรวจสอบ + คิดดาเมจฝั่ง server ทั้งหมด
-- client ทำแค่ animation/เสียง/เอฟเฟกต์ของตัวเอง (GDD ข้อ 0: server-authoritative)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage.Remotes

local PlayerService = require(script.Parent.PlayerService)
local MonsterService = require(script.Parent.MonsterService)

local CombatService = {}

local SWING_TOLERANCE = 0.15 -- เผื่อ latency
local ROLL_TOLERANCE = 0.2

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
		if dist <= cfg.Range and math.abs(offset.Y) <= 6 and (dist < 2.5 or to.Unit:Dot(look) >= minDot) then
			table.insert(hits, model)
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
	if not st or st.Equipped ~= "Sword" or not PlayerService.GetCharacterParts(player) then
		return
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

local function simulateArrow(player, origin, velocity, damage)
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
				local part = result.Instance
				local isHead = part.Name == "Head" or part:FindFirstAncestorWhichIsA("Accessory") ~= nil
				local amount = math.round(damage * (isHead and Config.HeadshotMultiplier or 1))
				local applied = MonsterService.Damage(model, amount, player)
				if applied then
					Remotes.DamageDealt:FireClient(player, result.Position + Vector3.new(0, 1, 0), amount, isHead, "Bow")
				end
			end
			return
		end
		pos += step
		vel += gravity * dt
	end
end

local function onBowFire(player, direction)
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
	player:SetAttribute("Arrows", arrows - 1)

	-- ยิ่งง้างนานยิ่งแรงและบินไกล
	local speed = cfg.MinSpeed + (cfg.MaxSpeed - cfg.MinSpeed) * charge
	local damage = cfg.MinDamage + (cfg.MaxDamage - cfg.MinDamage) * charge
	local origin = head.Position + direction * 1.5
	local velocity = direction * speed

	Remotes.ArrowFired:FireAllClients(player.UserId, origin, velocity, cfg.Gravity)
	task.spawn(simulateArrow, player, origin, velocity, damage)
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
end

function CombatService.Init()
	Remotes.Equip.OnServerEvent:Connect(PlayerService.Equip)
	Remotes.SwordSwing.OnServerEvent:Connect(onSwordSwing)
	Remotes.BowDrawStart.OnServerEvent:Connect(onBowDrawStart)
	Remotes.BowCancel.OnServerEvent:Connect(onBowCancel)
	Remotes.BowFire.OnServerEvent:Connect(onBowFire)
	Remotes.Roll.OnServerEvent:Connect(onRoll)
end

return CombatService
