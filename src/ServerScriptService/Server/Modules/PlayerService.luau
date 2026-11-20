-- PlayerService: สถานะผู้เล่นฝั่ง server (HP, เกราะ, อาวุธที่ถือ, โล่, ลูกธนู, i-frame, ล้ม/ชุบ, สถิติแมตช์)
-- เกราะเผยแพร่เป็น attribute บน Player: Armor (ความทนทานที่เหลือ), MaxArmor, ArmorName
--   เกราะที่มีโมเดล (Config.Armors[x].Model) สวมบนตัวเป็น WornArmor และหลุดร่วงเมื่อ Armor = 0
-- จุดเกิดในป้อม: ผู้เล่นแต่ละคนได้ SpawnSlot ของตัวเอง (ไม่เกิดทับกัน)
-- ชุดอุปกรณ์จาก loadout (Kit, ดู Progression.BuildKit): attribute Weapons ("Sword,Bow" ตามลำดับปุ่ม 1-5),
--   HasShield, Potions (ขวดที่เหลือ), Arrows — ใช้ชุดเริ่มต้นจนกว่าโปรไฟล์จะโหลด
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local MeleeFx = require(ReplicatedStorage.Shared.MeleeFx)
local Progression = require(ReplicatedStorage.Shared.Progression)
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
		Kit = Progression.BuildKit(Config.Loadout.Starter, {}),
		NextPotion = 0,
	}
end

function PlayerService.GetState(player)
	return states[player]
end

-- เริ่ม/เลิกง้างธนู (start = os.clock() หรือ nil) — attribute BowDraw ให้ทุก client จัดท่าง้างของคนนี้ตาม
function PlayerService.SetDrawStart(player, start)
	local st = states[player]
	if st then
		st.DrawStart = start
	end
	player:SetAttribute("BowDraw", start and workspace:GetServerTimeNow() or nil)
	if not start then
		player:SetAttribute("BowPitch", nil)
	end
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

-- อยู่ในแมตช์ (ที่ป้อม) หรืออยู่ Lobby
function PlayerService.InMatch(player)
	return states[player] ~= nil and player:GetAttribute("InMatch") == true
end

-- เป้าที่ monster เล็งได้: อยู่ในแมตช์และยังไม่ล้ม
function PlayerService.GetTargetParts(player)
	if not PlayerService.InMatch(player) then
		return nil
	end
	return PlayerService.GetCharacterParts(player)
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
		if not cfg or not cfg.Shield or not st.Kit.Shield or not PlayerService.GetCharacterParts(player) then
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
	if not table.find(st.Kit.Weapons, weaponName) then
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
	PlayerService.SetDrawStart(player, nil)
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
	if cfg.Shield and st.Kit.Shield then
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
	PlayerService.SetDrawStart(player, nil)
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
		PlayerService.Equip(player, st.Equipped or st.Kit.Weapons[1])
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
		if not PlayerService.InMatch(player) then
			continue
		end
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

---------------------------------------------------------------- เกราะบนตัวละคร

-- ชิ้นส่วนใน Assets.Armors.<Model> มี attribute Bone (ชื่อ body part), Offset (CFrame จาก body part),
-- BoneSize (ขนาด body part ของหุ่นอ้างอิง) — ย่อ/ขยายตามขนาดตัวจริงของผู้เล่นแต่ละคน
local function wearArmor(char, armorId, modelName)
	local template = Assets:FindFirstChild("Armors") and Assets.Armors:FindFirstChild(modelName)
	if not template then
		return
	end
	local worn = Instance.new("Model")
	worn.Name = "WornArmor"
	worn:SetAttribute("ArmorId", armorId)
	for _, source in template:GetChildren() do
		local bone = source:IsA("BasePart") and char:FindFirstChild(source:GetAttribute("Bone") or "")
		local offset = source:GetAttribute("Offset")
		local refSize = source:GetAttribute("BoneSize")
		if not bone or not bone:IsA("BasePart") or typeof(offset) ~= "CFrame" or typeof(refSize) ~= "Vector3" then
			continue
		end
		local scale = bone.Size / refSize
		local part = source:Clone()
		local partScale = scale
		if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
			local s = (scale.X + scale.Y + scale.Z) / 3
			partScale = Vector3.new(s, s, s)
		end
		part.Size *= partScale
		part.Anchored = false
		part.Massless = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		local c0 = CFrame.new(offset.Position * scale) * offset.Rotation
		part.CFrame = bone.CFrame * c0
		local weld = Instance.new("Weld")
		weld.Name = "ArmorWeld"
		weld.Part0 = bone
		weld.Part1 = part
		weld.C0 = c0
		weld.Parent = part
		part.Parent = worn
	end
	worn.Parent = char
end

-- เกราะหมด: ชิ้นส่วนหลุดกระเด็นลงพื้น (tween ไม่ใช้ฟิสิกส์ — ไม่ตกทะลุพื้น ไม่ชนผู้เล่น) แล้วจางหาย
local function breakArmor(worn, floorY)
	worn.Name = "BrokenArmor"
	local center = worn:GetPivot().Position
	for _, part in worn:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end
		local weld = part:FindFirstChild("ArmorWeld")
		if weld then
			weld:Destroy()
		end
		part.Anchored = true
		local away = part.Position - center
		away = Vector3.new(away.X, 0, away.Z)
		away = away.Magnitude > 0.01 and away.Unit or Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
		local landing = part.Position + away * (1 + math.random() * 2)
		local target = CFrame.new(landing.X, floorY + math.min(part.Size.X, part.Size.Y, part.Size.Z) / 2, landing.Z)
			* CFrame.Angles(math.rad(math.random(-90, 90)), math.rad(math.random(0, 360)), math.rad(math.random(-90, 90)))
		local fall = TweenService:Create(part, TweenInfo.new(0.35 + math.random() * 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = target })
		fall:Play()
		fall.Completed:Connect(function()
			TweenService:Create(part, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 }):Play()
		end)
	end
	worn.Parent = workspace
	Debris:AddItem(worn, 1.6)
	Remotes.WorldSound:FireAllClients("ShieldBlock", center)
end

-- ใส่/ถอดเกราะบนตัวให้ตรงกับสถานะ: ใส่เมื่อ kit มีเกราะที่มีโมเดลและค่าเกราะยังเหลือ
local function updateArmorVisual(player)
	local st = states[player]
	local char = player.Character
	if not st or not char or not char:FindFirstChild("UpperTorso") then
		return
	end
	local armorId = st.Kit.Armor
	local cfg = armorId and Config.Armors[armorId]
	local want = cfg and cfg.Model and (player:GetAttribute("Armor") or 0) > 0
	local worn = char:FindFirstChild("WornArmor")
	if worn and (not want or worn:GetAttribute("ArmorId") ~= armorId) then
		if not want and cfg and worn:GetAttribute("ArmorId") == armorId then
			local root = char:FindFirstChild("HumanoidRootPart")
			local hum = char:FindFirstChildOfClass("Humanoid")
			local floorY = root and (root.Position.Y - root.Size.Y / 2 - (hum and hum.HipHeight or 2)) or worn:GetPivot().Position.Y - 3
			breakArmor(worn, floorY) -- ค่าเกราะหมด
		else
			worn:Destroy() -- เปลี่ยน/ถอดชุดใน Lobby
		end
		worn = nil
	end
	if want and not worn then
		wearArmor(char, armorId, cfg.Model)
	end
end

-- ใส่เกราะตาม loadout ใหม่ (ความทนทานเต็ม)
local function refillArmor(player)
	local st = states[player]
	local kit = st and st.Kit
	local cfg = kit and kit.Armor and Config.Armors[kit.Armor]
	player:SetAttribute("ArmorName", cfg and cfg.Name or nil)
	player:SetAttribute("MaxArmor", cfg and kit.ArmorDurability or 0)
	player:SetAttribute("Armor", cfg and kit.ArmorDurability or 0)
end

-- เติมของกินได้ตาม kit: ลูกธนู, ยา, เกราะ
local function refillSupplies(player)
	local st = states[player]
	if not st then
		return
	end
	player:SetAttribute("Arrows", st.Kit.Arrows)
	player:SetAttribute("Potions", st.Kit.Potions)
	refillArmor(player)
end

-- ตั้งชุดอุปกรณ์จาก loadout (เรียกตอนโปรไฟล์โหลด / จัด loadout / อัพเกรด ใน Lobby)
function PlayerService.SetKit(player, kit)
	local st = states[player]
	if not st or #kit.Weapons == 0 then
		return
	end
	st.Kit = kit
	player:SetAttribute("Weapons", table.concat(kit.Weapons, ","))
	player:SetAttribute("HasShield", kit.Shield)
	if not PlayerService.InMatch(player) then
		refillSupplies(player)
	end
	updateArmorVisual(player)
	-- ถืออาวุธเดิมต่อถ้ายังอยู่ใน loadout (ถอด/ใส่โล่ใหม่ตาม kit) ไม่งั้นถือชิ้นแรก
	local weapon = table.find(kit.Weapons, st.Equipped) and st.Equipped or kit.Weapons[1]
	st.Equipped = nil
	PlayerService.Equip(player, weapon)
	if st.Equipped == nil then
		st.Equipped = weapon -- ยังไม่มีตัวละคร: ถือชิ้นนี้ตอนเกิด
		player:SetAttribute("Equipped", weapon)
	end
end

-- ตัวคูณดาเมจจากเลเวลอัพเกรดของอาวุธที่ถือ
function PlayerService.DamageBonus(player, weaponId)
	local st = states[player]
	return st and st.Kit.DamageBonus[weaponId] or 1
end

-- เอฟเฟกต์ฮีลสีเขียว (สร้างฝั่ง server ให้ทุกคนเห็น): ตัวเรืองเขียว + ประกายลอยขึ้น + วงแหวนที่เท้า + แสง
-- client ของคนดื่มดู attribute HealedAt แล้วกระพริบขอบจอสีเขียว (Hud.FlashHeal)
local HEAL_COLOR = Color3.fromRGB(90, 255, 120)

local function playHealEffect(player, char, root)
	player:SetAttribute("HealedAt", workspace:GetServerTimeNow())

	local glow = Instance.new("Highlight")
	glow.Name = "HealGlow"
	glow.FillColor = HEAL_COLOR
	glow.OutlineColor = Color3.fromRGB(200, 255, 210)
	glow.FillTransparency = 0.45
	glow.OutlineTransparency = 0.1
	glow.DepthMode = Enum.HighlightDepthMode.Occluded
	glow.Parent = char
	TweenService:Create(glow, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	Debris:AddItem(glow, 1.2)

	local light = Instance.new("PointLight")
	light.Color = HEAL_COLOR
	light.Brightness = 3
	light.Range = 12
	light.Parent = root
	TweenService:Create(light, TweenInfo.new(1.1), { Brightness = 0 }):Play()
	Debris:AddItem(light, 1.2)

	local sparkles = Instance.new("ParticleEmitter")
	sparkles.Name = "HealSparkles"
	sparkles.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkles.Color = ColorSequence.new(Color3.fromRGB(180, 255, 190), HEAL_COLOR)
	sparkles.LightEmission = 1
	sparkles.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	sparkles.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	sparkles.Lifetime = NumberRange.new(0.7, 1.2)
	sparkles.Speed = NumberRange.new(3, 6)
	sparkles.Acceleration = Vector3.new(0, 4, 0)
	sparkles.SpreadAngle = Vector2.new(25, 25)
	sparkles.EmissionDirection = Enum.NormalId.Top
	sparkles.Rate = 0
	sparkles.Parent = root
	sparkles:Emit(35)
	Debris:AddItem(sparkles, 1.5)

	-- วงแหวนขยายออกที่เท้า
	local ring = Instance.new("Part")
	ring.Name = "HealRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = HEAL_COLOR
	ring.Transparency = 0.35
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	local hum = char:FindFirstChildOfClass("Humanoid")
	local feetY = root.Position.Y - root.Size.Y / 2 - (hum and hum.HipHeight or 2) + 0.1
	ring.Size = Vector3.new(0.1, 2, 2)
	ring.CFrame = CFrame.new(root.Position.X, feetY, root.Position.Z) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = workspace
	TweenService:Create(ring, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.1, 9, 9), Transparency = 1 }):Play()
	Debris:AddItem(ring, 0.8)
end

-- ดื่มยา: +Heal HP (ไม่เกิน MaxHP) — ในแมตช์ใช้ขวดจริง, ใน Lobby ไม่จำกัด
local function onUsePotion(player)
	local st = states[player]
	local char, hum, root = PlayerService.GetCharacterParts(player)
	if not st or not char or os.clock() < st.NextPotion then
		return
	end
	local potions = player:GetAttribute("Potions") or 0
	if potions <= 0 or hum.Health >= hum.MaxHealth then
		return
	end
	st.NextPotion = os.clock() + 1
	hum.Health = math.min(hum.MaxHealth, hum.Health + Config.Items.Potion.Heal)
	if PlayerService.InMatch(player) then
		player:SetAttribute("Potions", potions - 1)
	end
	Remotes.WorldSound:FireAllClients("Pickup", char:GetPivot().Position)
	playHealEffect(player, char, root)
end

-- จบ wave: คนที่ไม่มีใครชุบ respawn ที่ฐาน (ได้เกราะใหม่)
local function fortSpawn()
	return workspace.Map:FindFirstChild("FortSpawn")
end

local function lobbySpawn()
	return workspace:FindFirstChild("Lobby") and workspace.Lobby:FindFirstChild("LobbySpawn")
end

local function moveTo(player, spawnPart)
	local char = player.Character
	if char and spawnPart then
		local offset = Vector3.new(math.random(-3, 3), 3, math.random(-3, 3))
		char:PivotTo(CFrame.new(spawnPart.Position + offset) * spawnPart.CFrame.Rotation)
	end
end

-- จุดเกิดในป้อม: ผู้เล่นแต่ละคนได้ช่อง (SpawnSlot 1..3) เรียงข้างกันตามแกนขวาของ FortSpawn ไม่ให้ตัวทับกัน
local SPAWN_SPACING = 5

local function claimSpawnSlot(player)
	local st = states[player]
	local used = {}
	for other, otherState in states do
		if other ~= player and otherState.SpawnSlot and PlayerService.InMatch(other) then
			used[otherState.SpawnSlot] = true
		end
	end
	local slot = 1
	while used[slot] do
		slot += 1
	end
	st.SpawnSlot = slot
end

local function moveToFort(player)
	local st = states[player]
	local spawn = fortSpawn()
	local char = player.Character
	if not st or not spawn or not char then
		return
	end
	local slot = st.SpawnSlot or 1
	-- ช่อง 1 = กลาง, 2 = ซ้าย, 3 = ขวา, 4 = ซ้ายถัดไป ...
	local side = (slot % 2 == 0) and -1 or 1
	local x = side * (slot // 2) * SPAWN_SPACING
	char:PivotTo(spawn.CFrame * CFrame.new(x, 3, 0))
end

function PlayerService.RespawnDowned()
	for player, st in states do
		if st.Downed and PlayerService.InMatch(player) then
			PlayerService.Revive(player, 1)
			refillArmor(player)
			moveToFort(player)
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
	refillSupplies(player)
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

-- เข้าแมตช์: ย้ายไปป้อม + รีเซ็ตสถานะ
function PlayerService.EnterMatch(player)
	if not states[player] then
		return
	end
	claimSpawnSlot(player)
	player:SetAttribute("InMatch", true)
	PlayerService.ResetPlayer(player)
	moveToFort(player)
end

-- กลับ Lobby: ลุกขึ้น HP/เกราะ/ลูกธนูเต็ม (สถิติแมตช์เก็บไว้ดูจนเริ่มแมตช์ใหม่)
function PlayerService.LeaveMatch(player)
	local st = states[player]
	if not st then
		return
	end
	player:SetAttribute("InMatch", false)
	st.SpawnSlot = nil
	stopReviving(player)
	if st.Downed then
		PlayerService.Revive(player, 1)
	end
	local char, hum = PlayerService.GetCharacterPartsAny(player)
	if char then
		hum.Health = hum.MaxHealth
	end
	refillSupplies(player)
	moveTo(player, lobbySpawn())
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
	PlayerService.SetDrawStart(player, nil)
	st.ComboIndex = 0
	st.Blocking = false
	player:SetAttribute("Blocking", nil)
	st.Downed = false
	player:SetAttribute("Downed", false)
	player:SetAttribute("ReviveEndsAt", nil)
	if PlayerService.InMatch(player) then
		-- เกิดใหม่ระหว่างแมตช์ (เช่น reset ตัวละคร): กลับมาที่ป้อม ไม่ใช่ Lobby
		local root = char:WaitForChild("HumanoidRootPart", 10)
		if root then
			task.defer(moveToFort, player)
		end
	end
	char:WaitForChild("RightHand", 10)
	char:WaitForChild("LeftHand", 10)
	PlayerService.Equip(player, st.Equipped or st.Kit.Weapons[1])
	char:WaitForChild("UpperTorso", 10)
	updateArmorVisual(player)
end

local function onPlayerAdded(player)
	states[player] = newState()
	player:SetAttribute("InMatch", false)
	player:SetAttribute("Downed", false)
	player:SetAttribute("Weapons", table.concat(states[player].Kit.Weapons, ","))
	player:SetAttribute("HasShield", states[player].Kit.Shield)
	refillSupplies(player)
	for _, name in STAT_NAMES do
		player:SetAttribute("Stat" .. name, 0)
	end
	player:GetAttributeChangedSignal("Armor"):Connect(function()
		updateArmorVisual(player)
	end)
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
	local usePotion = Remotes:FindFirstChild("UsePotion") or Instance.new("RemoteEvent")
	usePotion.Name = "UsePotion"
	usePotion.Parent = Remotes
	usePotion.OnServerEvent:Connect(onUsePotion)

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
