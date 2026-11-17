-- PlayerService: สถานะผู้เล่นฝั่ง server (HP, เกราะ, อาวุธที่ถือ, โล่, ลูกธนู, i-frame, ล้ม/ชุบ, สถิติแมตช์)
-- เกราะเผยแพร่เป็น attribute บน Player: Armor (ความทนทานที่เหลือ), MaxArmor, ArmorName
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local MeleeFx = require(ReplicatedStorage.Shared.MeleeFx)
local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets

local PlayerService = {}

local states = {}
local STAT_NAMES = { "Kills", "Damage", "Downs" }
local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_HEIGHT = 7.2

local function newState()
	return {
		Equipped = nil,
		IFrameUntil = 0,
		LastRoll = -math.huge,
		NextSwing = 0,
		LastSwingEnd = -math.huge,
		ComboIndex = 0,
		DrawStart = nil,
		Blocking = false, -- กำลังยกโล่ (ถือดาบอยู่เท่านั้น)
		Downed = false,
		ReviveTarget = nil, -- Player ที่กำลังชุบอยู่
		ReviveStart = 0,
	}
end

function PlayerService.GetState(player)
	return states[player]
end

-- character, humanoid, root ของผู้เล่นที่ยังมี character (รวมคนที่ล้มอยู่)
function PlayerService.GetCharacterPartsAny(player)
	local char = player.Character
	if not char or not char.Parent then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then
		return nil
	end
	return char, hum, root
end

-- เฉพาะผู้เล่นที่ยังสู้ได้ (ไม่ล้ม): ใช้ตรวจก่อนโจมตี และใช้เป็นเป้าของ monster
-- (monster ไม่ตีผู้เล่นที่ล้มอยู่ — GDD ข้อ 7)
function PlayerService.GetCharacterParts(player)
	local st = states[player]
	if not st or st.Downed then
		return nil
	end
	return PlayerService.GetCharacterPartsAny(player)
end

-- ยกโล่/ลดโล่: ได้เฉพาะตอนถือดาบ (อาวุธที่มีโล่) และยังไม่ล้ม
-- attribute Blocking บน Player ให้ทุก client จัดท่ายกโล่ของผู้เล่นคนนั้น
function PlayerService.SetBlocking(player, blocking)
	local st = states[player]
	if not st then
		return
	end
	blocking = blocking == true
	if blocking then
		local cfg = st.Equipped and Config.Weapons[st.Equipped]
		if not cfg or not cfg.Shield or not PlayerService.GetCharacterParts(player) then
			blocking = false
		end
	end
	if st.Blocking ~= blocking then
		st.Blocking = blocking
		player:SetAttribute("Blocking", blocking or nil)
	end
end

local function attachShield(char, shieldCfg)
	local arm = char:FindFirstChild(shieldCfg.Hand .. "LowerArm")
	if not arm then
		return
	end
	local model = Assets.Weapons[shieldCfg.Model]:Clone()
	model.Name = "HeldShield"
	local weld = Instance.new("Weld")
	weld.Name = "GripWeld"
	weld.Part0 = arm
	weld.Part1 = model.PrimaryPart
	-- ด้านนอกของท่อนแขน (แกน -X ของแขนซ้าย) หน้าโล่หันออก
	weld.C0 = CFrame.new(-0.45, -0.15, 0) * CFrame.Angles(0, math.pi / 2, 0)
	weld.Parent = model.PrimaryPart
	model.Parent = char
end

function PlayerService.Equip(player, weaponName)
	local st = states[player]
	if not st or typeof(weaponName) ~= "string" then
		return
	end
	if not table.find(Config.DefaultLoadout.Weapons, weaponName) then
		return -- ไม่ได้อยู่ใน loadout
	end
	local char = PlayerService.GetCharacterParts(player)
	if not char then
		return
	end
	local cfg = Config.Weapons[weaponName]
	local hand = char:FindFirstChild(cfg.Hand .. "Hand")
	if not hand then
		return
	end

	for _, name in { "HeldWeapon", "HeldShield" } do
		local old = char:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	st.DrawStart = nil
	PlayerService.SetBlocking(player, false)

	local model = Assets.Weapons[weaponName]:Clone()
	model.Name = "HeldWeapon"
	local grip = model.PrimaryPart
	local attachment = hand:FindFirstChild(cfg.Hand .. "GripAttachment")
	local weld = Instance.new("Weld")
	weld.Name = "GripWeld"
	weld.Part0 = hand
	weld.Part1 = grip
	weld.C0 = attachment and attachment.CFrame or CFrame.new()
	if cfg.GripOrientation then
		local o = cfg.GripOrientation
		weld.C0 *= CFrame.fromOrientation(math.rad(o.X), math.rad(o.Y), math.rad(o.Z))
	end
	weld.Parent = grip
	if cfg.Kind == "Melee" then
		MeleeFx.AddTrails(model, cfg) -- แสงตามอาวุธ (client เปิดช่วงฟาด)
	end
	model.Parent = char
	if cfg.Shield then
		attachShield(char, cfg.Shield)
	end

	st.Equipped = weaponName
	player:SetAttribute("Equipped", weaponName)
end

---------------------------------------------------------------- สถิติ

function PlayerService.AddStat(player, name, amount)
	if states[player] then
		player:SetAttribute("Stat" .. name, (player:GetAttribute("Stat" .. name) or 0) + amount)
	end
end

---------------------------------------------------------------- ล้ม & ชุบ

local function stopReviving(player)
	local st = states[player]
	if st and st.ReviveTarget then
		local target = st.ReviveTarget
		st.ReviveTarget = nil
		player:SetAttribute("Reviving", nil)
		if target.Parent then
			target:SetAttribute("ReviveEndsAt", nil)
		end
	end
end

local function setDowned(player, downed)
	local st = states[player]
	local char, hum = PlayerService.GetCharacterPartsAny(player)
	if not st or st.Downed == downed then
		return
	end
	st.Downed = downed
	st.DrawStart = nil
	player:SetAttribute("Downed", downed)
	player:SetAttribute("ReviveEndsAt", nil)
	if char then
		hum.WalkSpeed = downed and Config.Downed.WalkSpeed or DEFAULT_WALK_SPEED
		hum.UseJumpPower = false
		hum.JumpHeight = downed and 0 or DEFAULT_JUMP_HEIGHT
	end
	if downed then
		stopReviving(player)
		PlayerService.SetBlocking(player, false)
		PlayerService.AddStat(player, "Downs", 1)
		for _, name in { "HeldWeapon", "HeldShield" } do
			local held = char and char:FindFirstChild(name)
			if held then
				held:Destroy() -- ล้มแล้วโจมตี/กันไม่ได้
			end
		end
	else
		PlayerService.Equip(player, st.Equipped or Config.DefaultLoadout.Weapons[1])
	end
end

function PlayerService.IsDowned(player)
	local st = states[player]
	return st ~= nil and st.Downed
end

-- ทั้งทีมล้มพร้อมกัน -> แพ้ทันที (GDD ข้อ 6)
function PlayerService.AllDowned()
	local anyDowned = false
	for player, st in states do
		if st.Downed then
			anyDowned = true
		elseif PlayerService.GetCharacterPartsAny(player) then
			return false -- ยังมีคนยืนอยู่
		end
	end
	return anyDowned
end

function PlayerService.Revive(player, healthFraction)
	local st = states[player]
	local char, hum = PlayerService.GetCharacterPartsAny(player)
	if not st or not st.Downed then
		return
	end
	if char then
		hum.Health = math.max(1, hum.MaxHealth * healthFraction)
	end
	setDowned(player, false)
end

-- ใส่เกราะตาม loadout ใหม่ (ความทนทานเต็ม)
local function refillArmor(player)
	local cfg = Config.Armors[Config.DefaultLoadout.Armor]
	player:SetAttribute("ArmorName", cfg and cfg.Name or nil)
	player:SetAttribute("MaxArmor", cfg and cfg.Durability or 0)
	player:SetAttribute("Armor", cfg and cfg.Durability or 0)
end

-- จบ wave: คนที่ไม่มีใครชุบ respawn ที่ฐาน (ได้เกราะใหม่)
function PlayerService.RespawnDowned()
	local spawn = workspace.Map:FindFirstChildWhichIsA("SpawnLocation")
	for player, st in states do
		if st.Downed then
			PlayerService.Revive(player, 1)
			refillArmor(player)
			local char = player.Character
			if char and spawn then
				char:PivotTo(spawn.CFrame + Vector3.new(0, 3, 0))
			end
		end
	end
end

-- ยกโล่อยู่และการโจมตีมาจากด้านหน้า (sourcePosition = ตำแหน่งผู้โจมตี/จุดยิง)
local function shieldCovers(st, root, sourcePosition)
	if not st.Blocking or typeof(sourcePosition) ~= "Vector3" then
		return nil
	end
	local shield = Config.Weapons[st.Equipped] and Config.Weapons[st.Equipped].Shield
	if not shield then
		return nil
	end
	local to = sourcePosition - root.Position
	to = Vector3.new(to.X, 0, to.Z)
	local look = root.CFrame.LookVector
	look = Vector3.new(look.X, 0, look.Z)
	if to.Magnitude < 0.5 or look.Magnitude < 0.01 then
		return shield -- ประชิดตัวมาก: นับว่ากันได้
	end
	if to.Unit:Dot(look.Unit) >= math.cos(math.rad(shield.ArcDegrees / 2)) then
		return shield
	end
	return nil
end

-- ทำดาเมจใส่ผู้เล่น; คืน false ถ้าหลบได้ (i-frame), ล้มอยู่, หรือมี ForceField
-- sourcePosition (ไม่บังคับ): ใช้ตรวจว่าโล่กันได้ไหม — กันได้ลดดาเมจตาม BlockReduction
-- HP ถึง 0 = ล้ม (ไม่ตายจริง): เก็บ Health ไว้ที่ 1 เพื่อไม่ให้ Humanoid ตายแล้ว respawn เอง
function PlayerService.Damage(player, amount, sourcePosition)
	local st = states[player]
	if not st then
		return false
	end
	local char, hum, root = PlayerService.GetCharacterParts(player)
	if not char then
		return false
	end
	if os.clock() < st.IFrameUntil or char:FindFirstChildOfClass("ForceField") then
		return false
	end
	local shield = shieldCovers(st, root, sourcePosition)
	if shield then
		amount = math.max(1, math.round(amount * (1 - shield.BlockReduction)))
		Remotes.WorldSound:FireAllClients("ShieldBlock", root.Position + Vector3.new(0, 1.5, 0))
	end
	-- เกราะรับดาเมจก่อนทั้งหมด เหลือเท่าไรค่อยหัก HP
	local armor = player:GetAttribute("Armor") or 0
	if armor > 0 then
		local absorbed = math.min(armor, amount)
		amount -= absorbed
		player:SetAttribute("Armor", armor - absorbed)
	end
	stopReviving(player) -- คนชุบโดนตี -> ต้องเริ่มกดใหม่
	Remotes.PlayerHurt:FireClient(player, amount, shield ~= nil)
	if amount <= 0 then
		return true -- เกราะรับไว้หมด
	end
	if hum.Health - amount <= 0 then
		hum.Health = 1
		setDowned(player, true)
	else
		hum.Health -= amount
	end
	return true
end

local function onReviveStart(player, target)
	local st = states[player]
	if not st or typeof(target) ~= "Instance" or not target:IsA("Player") or target == player then
		return
	end
	local targetState = states[target]
	if not targetState or not targetState.Downed or not PlayerService.GetCharacterParts(player) then
		return
	end
	stopReviving(player)
	st.ReviveTarget = target
	st.ReviveStart = os.clock()
	player:SetAttribute("Reviving", target.UserId)
	target:SetAttribute("ReviveEndsAt", workspace:GetServerTimeNow() + Config.Downed.ReviveTime)
end

local function updateRevives()
	local now = os.clock()
	for player, st in states do
		local target = st.ReviveTarget
		if target then
			local _, _, root = PlayerService.GetCharacterParts(player)
			local _, _, targetRoot = PlayerService.GetCharacterPartsAny(target)
			local targetState = states[target]
			if not root or not targetRoot or not targetState or not targetState.Downed
				or (root.Position - targetRoot.Position).Magnitude > Config.Downed.ReviveRange + 2 then
				stopReviving(player)
			elseif now - st.ReviveStart >= Config.Downed.ReviveTime then
				stopReviving(player)
				PlayerService.Revive(target, Config.Downed.ReviveHPFraction)
				Remotes.WorldSound:FireAllClients("Pickup", targetRoot.Position)
			end
		end
	end
end

---------------------------------------------------------------- แมตช์ / ตัวละคร

-- เริ่มแมตช์ใหม่: เติมลูกธนูตาม loadout, HP เต็ม, ลุกขึ้น, ล้างสถิติ
function PlayerService.ResetPlayer(player)
	local st = states[player]
	if not st then
		return
	end
	player:SetAttribute("Arrows", Config.Weapons.Bow.Ammo + Config.DefaultLoadout.ExtraArrows)
	refillArmor(player)
	for _, name in STAT_NAMES do
		player:SetAttribute("Stat" .. name, 0)
	end
	if st.Downed then
		PlayerService.Revive(player, 1)
	end
	local char, hum = PlayerService.GetCharacterPartsAny(player)
	if char then
		hum.Health = hum.MaxHealth
	end
end

function PlayerService.ResetMatch()
	for _, player in Players:GetPlayers() do
		PlayerService.ResetPlayer(player)
	end
end

local function onCharacterAdded(player, char)
	local st = states[player]
	if not st then
		return
	end
	local hum = char:WaitForChild("Humanoid")
	hum.MaxHealth = Config.Player.MaxHP
	hum.Health = Config.Player.MaxHP
	refillArmor(player)
	st.DrawStart = nil
	st.ComboIndex = 0
	st.Blocking = false
	player:SetAttribute("Blocking", nil)
	st.Downed = false
	player:SetAttribute("Downed", false)
	player:SetAttribute("ReviveEndsAt", nil)
	char:WaitForChild("RightHand", 10)
	char:WaitForChild("LeftHand", 10)
	PlayerService.Equip(player, st.Equipped or Config.DefaultLoadout.Weapons[1])
end

local function onPlayerAdded(player)
	states[player] = newState()
	player:SetAttribute("Arrows", Config.Weapons.Bow.Ammo + Config.DefaultLoadout.ExtraArrows)
	player:SetAttribute("Downed", false)
	for _, name in STAT_NAMES do
		player:SetAttribute("Stat" .. name, 0)
	end
	player.CharacterAdded:Connect(function(char)
		onCharacterAdded(player, char)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

function PlayerService.Init()
	Players.RespawnTime = Config.Player.RespawnTime
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		stopReviving(player)
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	Remotes.ReviveStart.OnServerEvent:Connect(onReviveStart)
	Remotes.ReviveCancel.OnServerEvent:Connect(stopReviving)
	Remotes.ShieldBlock.OnServerEvent:Connect(PlayerService.SetBlocking)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator >= 0.1 then
			accumulator = 0
			updateRevives()
		end
	end)
end

return PlayerService
