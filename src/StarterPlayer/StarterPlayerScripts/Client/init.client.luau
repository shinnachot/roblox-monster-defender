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

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local SwordCfg = Config.Weapons.Sword
local BowCfg = Config.Weapons.Bow
local RollCfg = Config.Roll
local TRACK_NAMES = { "SwordSlash1", "SwordSlash2", "SwordSlash3", BowCfg.Anim.Name, RollCfg.Anim.Name }

-- สถานะตัวละครปัจจุบัน
local char, hum, root, rootJoint
local tracks = {}
local segmentToken = {}

-- สถานะการต่อสู้
local equipped = Config.DefaultLoadout.Weapons[1]
local mouseDown = false
local comboIndex = 0
local nextSwingAt = 0
local lastSwingEnd = -math.huge
local drawStart = nil
local rolling = false
local nextRollAt = 0
local defaultWalkSpeed = 16

local function isAlive()
	return char ~= nil and char.Parent ~= nil and hum ~= nil and hum.Health > 0
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
	local drawTrack = tracks[BowCfg.Anim.Name]
	if drawTrack then
		stopSegment(drawTrack, 0.15)
	end
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
	-- ค้างท่าง้าง (ความเร็ว 0) แล้ว blend เข้าจากท่ายืน
	local seg = BowCfg.Anim
	local drawTrack = tracks[seg.Name]
	segmentToken[drawTrack] = nil
	drawTrack:Play(seg.FadeIn, 1, 0)
	drawTrack.TimePosition = seg.HoldTime
	hum.WalkSpeed = BowCfg.DrawWalkSpeed
	Sfx.Play("BowDraw")
	Remotes.BowDrawStart:FireServer()
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
	cancelDraw(false)

	local head = char:FindFirstChild("Head")
	if not head then
		Remotes.BowCancel:FireServer()
		return
	end
	local aimPoint = CameraController.GetAimPoint()
	local direction = aimPoint - head.Position
	if direction.Magnitude < 6 then
		direction = camera.CFrame.LookVector
	end
	direction = direction.Unit

	Sfx.Play("BowRelease") -- สายธนูตอนปล่อย: เล่นทันทีไม่รอ server
	Remotes.BowFire:FireServer(direction)
	local speed = BowCfg.MinSpeed + (BowCfg.MaxSpeed - BowCfg.MinSpeed) * charge
	ArrowVisuals.Spawn(head.Position + direction * 1.5, direction * speed, BowCfg.Gravity)
end

---------------------------------------------------------------- ดาบ

local function trySwing()
	local now = os.clock()
	if now < nextSwingAt or rolling or not isAlive() then
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

	playSegment(tracks[seg.Anim], seg.Start, seg.End, seg.Speed, false)
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

	task.delay(RollCfg.Duration, function()
		mover:Destroy()
		rolling = false
		CameraController.FaceCamera = true
	end)
end

-- คลิปกลิ้งมี root motion ในตัว (ตัวละครพุ่งไปข้างหน้าในคลิป) — ตัดการเคลื่อนที่แนวราบออก
-- เพราะระยะกลิ้งจริงคุมด้วย LinearVelocity ให้ได้ 14 studs ตาม GDD
RunService.Stepped:Connect(function()
	local rollTrack = tracks[RollCfg.Anim.Name]
	if rootJoint and rollTrack and rollTrack.IsPlaying then
		local transform = rootJoint.Transform
		rootJoint.Transform = transform.Rotation + Vector3.new(0, transform.Position.Y, 0)
	end
end)

---------------------------------------------------------------- สลับอาวุธ / input

local function equip(weaponName)
	if weaponName == equipped or rolling or not isAlive() then
		return
	end
	cancelDraw(true)
	equipped = weaponName
	Hud.SetEquipped(weaponName)
	Remotes.Equip:FireServer(weaponName)
end

local SLOT_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
}

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseDown = true
		if equipped == "Bow" then
			startDraw()
		end
	elseif input.KeyCode == Enum.KeyCode.Q then
		tryRoll()
	elseif SLOT_KEYS[input.KeyCode] then
		local weaponName = Config.DefaultLoadout.Weapons[SLOT_KEYS[input.KeyCode]]
		if weaponName then
			equip(weaponName)
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseDown = false
		releaseDraw()
	end
end)

RunService.RenderStepped:Connect(function()
	if mouseDown and equipped == "Sword" then
		trySwing() -- กดค้าง = ฟันต่อคอมโบ
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

Remotes.ArrowFired.OnClientEvent:Connect(function(userId, origin, velocity, gravity)
	if userId ~= player.UserId then
		ArrowVisuals.Spawn(origin, velocity, gravity)
	end
end)

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
		track.Looped = false
		tracks[name] = track
	end

	hum.Died:Connect(function()
		mouseDown = false
		cancelDraw(true)
	end)

	defaultWalkSpeed = hum.WalkSpeed
	mouseDown = false
	drawStart = nil
	rolling = false
	comboIndex = 0
	Hud.SetCharge(nil)
	Hud.SetEquipped(equipped)
	CameraController.SetCharacter(newChar)
end

StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)

task.spawn(function()
	ContentProvider:PreloadAsync(Assets.Animations:GetChildren())
	ContentProvider:PreloadAsync(Assets.Sounds:GetChildren())
end)

Hud.Init()
CameraController.Init()
player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end
