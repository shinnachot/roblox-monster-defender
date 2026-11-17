-- Client: ควบคุมการต่อสู้ของผู้เล่น (input, animation/เสียงของตัวเองแบบทันที, ส่งคำสั่งให้ server คิดดาเมจ)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContentProvider = game:GetService("ContentProvider")
local StarterGui = game:GetService("StarterGui")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Assets = ReplicatedStorage:WaitForChild("Assets")

local Sfx = require(script:WaitForChild("Sfx"))
local DamageNumbers = require(script:WaitForChild("DamageNumbers"))
local ArrowVisuals = require(script:WaitForChild("ArrowVisuals"))
local CameraController = require(script:WaitForChild("CameraController"))
local Hud = require(script:WaitForChild("Hud"))
local BowAim = require(script:WaitForChild("BowAim"))
local LegBlend = require(script:WaitForChild("LegBlend"))
local ShieldGuard = require(script:WaitForChild("ShieldGuard"))
local MeleeFx = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MeleeFx"))
local SlashPose = require(script:WaitForChild("SlashPose"))
local TouchControls = require(script:WaitForChild("TouchControls")) -- ปุ่มบนจอสัมผัส (มือถือ)
local LobbyUi = require(script:WaitForChild("LobbyUi"))
local LoadoutUi = require(script:WaitForChild("LoadoutUi"))
require(script:WaitForChild("MonsterPose")) -- ท่าเล็งของ monster ยิงไกล (ทำงานเอง)

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local SwordCfg = Config.Weapons.Sword
local ShieldCfg = SwordCfg.Shield
local BowCfg = Config.Weapons.Bow
local RollCfg = Config.Roll
local CRAWL = Config.Downed.CrawlAnim
local TRACK_NAMES = { "SwordSlash1", "SwordSlash2", "SwordSlash3", RollCfg.Anim.Name, CRAWL }
-- คลิปที่มี root motion ในตัว: ตัดการเคลื่อนที่แนวราบออก (ระยะจริงคุมด้วยการเคลื่อนที่ของตัวละคร)
local ROOT_MOTION_TRACKS = { RollCfg.Anim.Name, CRAWL }

-- สถานะตัวละครปัจจุบัน
local char, hum, root, rootJoint
local tracks = {}
local segmentToken = {}

-- สถานะการต่อสู้
local equipped = player:GetAttribute("Equipped") or "Sword" -- server ตั้งตาม loadout
local mouseDown = false
local hasShieldFor -- ประกาศล่วงหน้า (ใช้ก่อนนิยาม)
local rightMouseDown = false
local blocking = false -- ยกโล่อยู่ (ถือดาบ + กดค้างคลิกขวา)
local comboIndex = 0
local nextSwingAt = 0
local lastSwingEnd = -math.huge
local drawStart = nil
local rolling = false
local nextRollAt = 0
local defaultWalkSpeed = 16
local downed = false -- ล้มอยู่: คลานได้อย่างเดียว โจมตี/กลิ้ง/สลับอาวุธไม่ได้

local function isAlive()
	return char ~= nil and char.Parent ~= nil and hum ~= nil and hum.Health > 0 and not downed
end

-- เล่นเฉพาะช่วง [startTime, endTime] ของคลิปด้วยความเร็ว speed
local function playSegment(track, startTime, endTime, speed, holdAtEnd)
	local token = {}
	segmentToken[track] = token
	track:Play(0.08, 1, speed)
	track.TimePosition = startTime
	task.delay((endTime - startTime) / speed, function()
		if segmentToken[track] ~= token then
			return
		end
		if holdAtEnd then
			track:AdjustSpeed(0)
		else
			track:Stop(0.15)
		end
	end)
end

local function stopSegment(track, fade)
	segmentToken[track] = nil
	track:Stop(fade or 0.1)
end

---------------------------------------------------------------- ธนู

local function cancelDraw(notifyServer)
	if not drawStart then
		return
	end
	drawStart = nil
	Hud.SetCharge(nil)
	CameraController.SetAiming(false)
	BowAim.Stop()
	if hum then
		hum.WalkSpeed = defaultWalkSpeed
	end
	if notifyServer then
		Remotes.BowCancel:FireServer()
	end
end

local function startDraw()
	if drawStart or rolling or not isAlive() then
		return
	end
	if (player:GetAttribute("Arrows") or 0) <= 0 then
		Hud.FlashAmmo()
		return
	end
	drawStart = os.clock()
	CameraController.SetAiming(true)
	BowAim.Start(drawStart) -- ท่าง้างแบบ IK: มือขวาดึงสายตามแรงง้าง
	hum.WalkSpeed = BowCfg.DrawWalkSpeed
	Sfx.Play("BowDraw")
	Remotes.BowDrawStart:FireServer()
end

local nextShotId = 0
local monsterFolder = workspace:WaitForChild("Monsters")

-- ลูกธนูของเราโดน monster บนจอ: แจ้ง server (server ตรวจวิถี/ตำแหน่งก่อนคิดดาเมจ)
-- เพราะบนจอ monster อยู่ช้ากว่า server ~0.2 วิ การจำลองฝั่ง server อย่างเดียวจะพลาดทั้งที่เห็นว่าโดน
local function reportArrowHit(shotId, result)
	local node = result.Instance
	while node and node.Parent ~= monsterFolder do
		node = node.Parent
		if node == workspace or node == game then
			return
		end
	end
	if not node then
		return
	end
	local part = result.Instance
	local isHead = part.Name == "Head" or part:FindFirstAncestorWhichIsA("Accessory") ~= nil
	Remotes.ArrowHit:FireServer(shotId, node, isHead, result.Position)
end

local function releaseDraw()
	if not drawStart then
		return
	end
	local charge = math.clamp((os.clock() - drawStart) / BowCfg.ChargeTime, 0, 1)
	if charge < BowCfg.MinCharge or not isAlive() then
		cancelDraw(true)
		return
	end
	-- ทิศปล่อย (ชดเชยวิถีโค้งให้ไปตกที่จุดเล็ง) — คำนวณก่อนกล้องถอยกลับมุมปกติ
	local direction = BowAim.GetLaunchDirection(charge)
	cancelDraw(false)

	local head = char:FindFirstChild("Head")
	if not head then
		Remotes.BowCancel:FireServer()
		return
	end

	Sfx.Play("BowRelease") -- สายธนูตอนปล่อย: เล่นทันทีไม่รอ server
	nextShotId += 1
	local shotId = nextShotId
	Remotes.BowFire:FireServer(direction, shotId)
	local speed = BowCfg.MinSpeed + (BowCfg.MaxSpeed - BowCfg.MinSpeed) * charge
	ArrowVisuals.Spawn(head.Position + direction * 1.5, direction * speed, BowCfg.Gravity, nil, false, function(result)
		reportArrowHit(shotId, result)
	end)
end

---------------------------------------------------------------- โล่

local function stopBlock()
	if not blocking then
		return
	end
	blocking = false
	ShieldGuard.SetLocalBlocking(false)
	Hud.SetBlocking(false)
	if hum and not downed then
		hum.WalkSpeed = defaultWalkSpeed
	end
	Remotes.ShieldBlock:FireServer(false)
end

local function startBlock()
	if blocking or rolling or not isAlive() or equipped ~= "Sword" or not ShieldCfg or not player:GetAttribute("HasShield") then
		return
	end
	blocking = true
	ShieldGuard.SetLocalBlocking(true)
	Hud.SetBlocking(true)
	hum.WalkSpeed = ShieldCfg.WalkSpeed
	Remotes.ShieldBlock:FireServer(true)
end

---------------------------------------------------------------- ดาบ

local function trySwing()
	local now = os.clock()
	if now < nextSwingAt or rolling or blocking or not isAlive() then
		return
	end
	local combo = SwordCfg.Combo
	local index = 1
	if comboIndex < #combo and now - lastSwingEnd <= SwordCfg.ComboReset then
		index = comboIndex + 1
	end
	local seg = combo[index]
	local hitDelay, duration = Config.SegmentTiming(seg)
	comboIndex = index
	nextSwingAt = now + duration * 0.8
	lastSwingEnd = now + duration

	local weaponModel = char:FindFirstChild("HeldWeapon")
	if seg.Pose then
		SlashPose.Play(char, seg) -- ท่าฟันจัดด้วยโค้ด
		local _, _, strikeAt, strikeEndAt = Config.SegmentTiming(seg)
		MeleeFx.ShowTrail(weaponModel, strikeAt, strikeEndAt) -- แสงตามดาบช่วงฟาด
	else
		MeleeFx.PlaySlash(tracks[seg.Anim], seg, weaponModel) -- ท่าจากคลิป: ฟาดเร็ว + แสงตามดาบ
	end
	-- เสียงวืดตรงจังหวะดาบเหวี่ยง (ก่อนดาเมจเกิดเล็กน้อย)
	task.delay(math.max(0, hitDelay - 0.1), Sfx.Play, "SwordSwing")
	Remotes.SwordSwing:FireServer(index)
end

---------------------------------------------------------------- กลิ้งหลบ

local function tryRoll()
	local now = os.clock()
	if now < nextRollAt or rolling or not isAlive() then
		return
	end
	if hum.FloorMaterial == Enum.Material.Air then
		return
	end
	cancelDraw(true)
	stopBlock()
	SlashPose.Stop(char)

	local direction = hum.MoveDirection
	if direction.Magnitude < 0.1 then
		direction = root.CFrame.LookVector
	end
	direction = Vector3.new(direction.X, 0, direction.Z).Unit

	rolling = true
	nextRollAt = now + RollCfg.Cooldown
	CameraController.FaceCamera = false
	root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)

	local attachment = root:FindFirstChild("RootAttachment") or Instance.new("Attachment", root)
	local mover = Instance.new("LinearVelocity")
	mover.Attachment0 = attachment
	mover.RelativeTo = Enum.ActuatorRelativeTo.World
	mover.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	mover.PrimaryTangentAxis = Vector3.xAxis
	mover.SecondaryTangentAxis = Vector3.zAxis
	mover.PlaneVelocity = Vector2.new(direction.X, direction.Z) * (RollCfg.Distance / RollCfg.Duration)
	mover.MaxForce = 1e6
	mover.Parent = root

	local seg = RollCfg.Anim
	playSegment(tracks[seg.Name], seg.Start, seg.End, (seg.End - seg.Start) / RollCfg.Duration, false)
	Sfx.Play("Roll")
	Remotes.Roll:FireServer()
	Hud.SetRollCooldown(RollCfg.Cooldown)
	TouchControls.SetRollCooldown(RollCfg.Cooldown)

	task.delay(RollCfg.Duration, function()
		mover:Destroy()
		rolling = false
		CameraController.FaceCamera = true
		if rightMouseDown then
			startBlock() -- ยังกดคลิกขวาค้างอยู่ -> ยกโล่ต่อหลังกลิ้ง
		end
	end)
end

-- คลิปกลิ้งมี root motion ในตัว (ตัวละครพุ่งไปข้างหน้าในคลิป) — ตัดการเคลื่อนที่แนวราบออก
-- เพราะระยะกลิ้งจริงคุมด้วย LinearVelocity ให้ได้ 14 studs ตาม GDD
RunService.Stepped:Connect(function()
	if not rootJoint then
		return
	end
	for _, name in ROOT_MOTION_TRACKS do
		local track = tracks[name]
		if track and track.IsPlaying then
			local transform = rootJoint.Transform
			rootJoint.Transform = transform.Rotation + Vector3.new(0, transform.Position.Y, 0)
			break
		end
	end
end)

---------------------------------------------------------------- ล้ม & ชุบ

-- server ตั้ง attribute Downed บน Player: ล้ม = เล่นท่าคลาน (ค้างท่าตอนหยุดนิ่ง)
local function applyDowned()
	downed = player:GetAttribute("Downed") == true
	local crawl = tracks[CRAWL]
	if downed then
		mouseDown = false
		cancelDraw(true)
		stopBlock()
		SlashPose.Stop(char)
		if crawl and not crawl.IsPlaying then
			crawl:Play(0.3, 1, 0)
		end
	elseif crawl then
		crawl:Stop(0.3)
	end
	if hum then
		hum.WalkSpeed = downed and Config.Downed.WalkSpeed or defaultWalkSpeed
	end
end
player:GetAttributeChangedSignal("Downed"):Connect(applyDowned)

---------------------------------------------------------------- สลับอาวุธ / input

-- ปุ่มโล่บนจอสัมผัส: อาวุธนี้ถือโล่ได้ และใส่โล่ใน loadout
hasShieldFor = function(weaponName)
	local cfg = Config.Weapons[weaponName]
	return cfg ~= nil and cfg.Shield ~= nil and player:GetAttribute("HasShield") == true
end

local function equip(weaponName)
	if weaponName == "Potion" then
		Remotes.UsePotion:FireServer() -- ช่องยา: แตะ/คลิกเพื่อดื่ม
		return
	end
	if weaponName == equipped or rolling or not isAlive() or not table.find(Hud.GetWeapons(), weaponName) then
		return
	end
	cancelDraw(true)
	stopBlock()
	equipped = weaponName
	Hud.SetEquipped(weaponName)
	TouchControls.SetEquipped(weaponName, hasShieldFor(weaponName))
	Remotes.Equip:FireServer(weaponName)
end

-- คำสั่งต่อสู้: ใช้ร่วมกันทั้งเมาส์/คีย์บอร์ด และปุ่มบนจอสัมผัส (TouchControls)
local function attackDown()
	mouseDown = true
	if equipped == "Bow" then
		startDraw()
	end
end

local function attackUp()
	mouseDown = false
	releaseDraw()
end

local function blockDown()
	rightMouseDown = true
	startBlock()
end

local function blockUp()
	rightMouseDown = false
	stopBlock()
end

-- กดค้างใกล้เพื่อนที่ล้มเพื่อชุบ (server นับเวลาและตรวจระยะ)
local function reviveDown()
	local target = Hud.GetReviveCandidate()
	if target and isAlive() then
		cancelDraw(true)
		Remotes.ReviveStart:FireServer(target)
	end
end

local function reviveUp()
	Remotes.ReviveCancel:FireServer()
end

local SLOT_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
}

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		attackDown()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		blockDown()
	elseif input.KeyCode == Enum.KeyCode.Q then
		tryRoll()
	elseif input.KeyCode == Enum.KeyCode.E then
		reviveDown()
	elseif input.KeyCode == Enum.KeyCode.F then
		Remotes.UsePotion:FireServer()
	elseif SLOT_KEYS[input.KeyCode] then
		local weaponName = Hud.GetWeapons()[SLOT_KEYS[input.KeyCode]]
		if weaponName then
			equip(weaponName)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		attackUp()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		blockUp()
	elseif input.KeyCode == Enum.KeyCode.E then
		reviveUp()
	end
end)

RunService.RenderStepped:Connect(function()
	if mouseDown and equipped == "Sword" then
		trySwing() -- กดค้าง = ฟันต่อคอมโบ
	end
	if downed and hum then
		local crawl = tracks[CRAWL]
		if crawl then
			crawl:AdjustSpeed(hum.MoveDirection.Magnitude > 0.1 and 1 or 0)
		end
	end
	if drawStart then
		Hud.SetCharge(math.clamp((os.clock() - drawStart) / BowCfg.ChargeTime, 0, 1))
	end
end)

---------------------------------------------------------------- ผลจาก server

Remotes.DamageDealt.OnClientEvent:Connect(function(position, amount, isHead, kind)
	DamageNumbers.Show(position, amount, isHead)
	-- เสียงโดนเล่นตอนดาเมจเกิดจริง; โดนหัวดังและเด่นเป็นพิเศษ
	if isHead then
		Sfx.Play("Headshot")
	elseif kind == "Bow" then
		Sfx.Play("ArrowHit")
	else
		Sfx.Play("SwordHit")
	end
end)

-- userId 0 = กระสุนของ monster
Remotes.ArrowFired.OnClientEvent:Connect(function(userId, origin, velocity, gravity, kind)
	if userId ~= player.UserId then
		ArrowVisuals.Spawn(origin, velocity, gravity, kind, userId == 0)
	end
end)

-- แสงตามอาวุธประชิดของผู้เล่นคนอื่น (ท่าของเขา replicate มาเองผ่าน Animator)
local function watchMeleeSwing(other)
	if other == player then
		return
	end
	other:GetAttributeChangedSignal("MeleeSwing"):Connect(function()
		local value = other:GetAttribute("MeleeSwing")
		local index = value and tonumber(string.match(value, "^(%d+):"))
		local weaponName = other:GetAttribute("Equipped")
		local cfg = weaponName and Config.Weapons[weaponName]
		local seg = index and cfg and cfg.Combo and cfg.Combo[index]
		local model = other.Character and other.Character:FindFirstChild("HeldWeapon")
		if seg and model then
			local _, _, strikeAt, strikeEndAt = Config.SegmentTiming(seg)
			MeleeFx.ShowTrail(model, strikeAt, strikeEndAt)
			if seg.Pose then
				SlashPose.Play(other.Character, seg)
			end
		end
	end)
end
Players.PlayerAdded:Connect(watchMeleeSwing)
for _, other in Players:GetPlayers() do
	watchMeleeSwing(other)
end

Remotes.WorldSound.OnClientEvent:Connect(function(name, position)
	Sfx.Play(name, position)
end)

Remotes.PlayerHurt.OnClientEvent:Connect(function()
	Hud.FlashHurt()
	Sfx.Play("PlayerHurt")
end)

---------------------------------------------------------------- ตัวละคร

local function onCharacterAdded(newChar)
	char = newChar
	hum = newChar:WaitForChild("Humanoid")
	root = newChar:WaitForChild("HumanoidRootPart")
	local animator = hum:WaitForChild("Animator")
	local lowerTorso = newChar:WaitForChild("LowerTorso", 10)
	rootJoint = lowerTorso and lowerTorso:WaitForChild("Root", 10)

	table.clear(tracks)
	table.clear(segmentToken)
	for _, name in TRACK_NAMES do
		local track = animator:LoadAnimation(Assets.Animations:WaitForChild(name))
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = name == CRAWL
		tracks[name] = track
	end

	hum.Died:Connect(function()
		mouseDown = false
		cancelDraw(true)
		stopBlock()
	end)

	defaultWalkSpeed = hum.WalkSpeed
	mouseDown = false
	drawStart = nil
	rolling = false
	blocking = false
	ShieldGuard.SetLocalBlocking(false)
	Hud.SetBlocking(false)
	comboIndex = 0
	Hud.SetCharge(nil)
	Hud.SetEquipped(equipped)
	TouchControls.SetEquipped(equipped, hasShieldFor(equipped))
	applyDowned()
	CameraController.SetCharacter(newChar)
	BowAim.SetCharacter(newChar)
	-- ให้ขาเดินต่อระหว่างฟันดาบขณะเคลื่อนที่
	local slashTracks = {}
	for _, seg in SwordCfg.Combo do
		if seg.Anim then
			table.insert(slashTracks, tracks[seg.Anim])
		end
	end
	task.spawn(LegBlend.SetCharacter, newChar, slashTracks)
end

StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)

task.spawn(function()
	ContentProvider:PreloadAsync(Assets.Animations:GetChildren())
	ContentProvider:PreloadAsync(Assets.Sounds:GetChildren())
end)

Hud.OnSlotActivated = equip -- แตะช่องอาวุธเพื่อสลับ
-- server เปลี่ยนอาวุธที่ถือตาม loadout ใหม่ (เช่น เอาดาบออก) -> ตามให้ตรง
player:GetAttributeChangedSignal("Equipped"):Connect(function()
	local serverWeapon = player:GetAttribute("Equipped")
	if serverWeapon and serverWeapon ~= equipped and not table.find(Hud.GetWeapons(), equipped) then
		cancelDraw(true)
		stopBlock()
		equipped = serverWeapon
		Hud.SetEquipped(equipped)
		TouchControls.SetEquipped(equipped, hasShieldFor(equipped))
	end
end)
player:GetAttributeChangedSignal("HasShield"):Connect(function()
	if not player:GetAttribute("HasShield") then
		stopBlock()
	end
	TouchControls.SetEquipped(equipped, hasShieldFor(equipped))
end)
LobbyUi.OnOpenLoadout = LoadoutUi.Open
Hud.Init({ Touch = TouchControls.IsTouchDevice() })
task.spawn(LobbyUi.Init, { Touch = TouchControls.IsTouchDevice() })
TouchControls.Init({
	AttackDown = attackDown,
	AttackUp = attackUp,
	BlockDown = blockDown,
	BlockUp = blockUp,
	Roll = tryRoll,
	ReviveDown = reviveDown,
	ReviveUp = reviveUp,
	CanRevive = function()
		return Hud.GetReviveCandidate() ~= nil and isAlive()
	end,
})
CameraController.Init()
player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end
