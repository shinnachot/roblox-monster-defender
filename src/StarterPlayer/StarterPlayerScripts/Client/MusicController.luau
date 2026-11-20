-- MusicController: เพลงประกอบตามสถานะเกม (GDD เฟส 5) — ทำงานเอง แค่ require
-- เพลงอยู่ใน ReplicatedStorage.Assets.Music (Lobby, Battle, Boss = วนซ้ำ / Victory, Defeat = ท่อนสั้นเล่นครั้งเดียว)
-- เลือกเพลงจาก attribute ที่ server ตั้งไว้อยู่แล้ว: Player.InMatch, workspace.MatchPhase, workspace.BossHP
--   Lobby / รอเพื่อนในด่าน -> Lobby | นับถอยหลัง, คลื่น, พักคลื่น -> Battle (พัก = เบาลง) | มี Boss -> Boss
--   ชนะ / แพ้ -> หยุดเพลงแล้วเล่น Victory / Defeat ครั้งเดียว
-- เปลี่ยนเพลงแบบค่อย ๆ จางเข้า-ออก; ปุ่ม 🔊/🔇 บนแถบด้านบนของ Roblox (คอม: ปุ่ม M) ปิดเฉพาะเพลง (เสียงเอฟเฟกต์ยังอยู่)
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LOOP_VOLUME = { Lobby = 0.35, Battle = 0.3, Boss = 0.35 } -- ต่ำกว่าเสียงเอฟเฟกต์ (0.6-1.0)
local STING_VOLUME = 0.5
local CALM_FACTOR = 0.55 -- นับถอยหลัง/พักคลื่น: Battle เบาลง
local FADE_TIME = 1.5
local FONT = Font.fromEnum(Enum.Font.GothamBold)

local player = Players.LocalPlayer
local music = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Music")

local group = Instance.new("SoundGroup")
group.Name = "Music"
group.Volume = 1
group.Parent = SoundService

local loops = {} -- [name] = Sound (สร้างครั้งแรกที่ใช้)
local current = nil -- ชื่อเพลงวนที่กำลังเล่น (nil = เงียบ)
local currentVolume = 0
local lastPhase = nil
local muted = false

local function fade(sound, volume, onDone)
	local tween = TweenService:Create(sound, TweenInfo.new(FADE_TIME, Enum.EasingStyle.Sine), { Volume = volume })
	if onDone then
		tween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then
				onDone()
			end
		end)
	end
	tween:Play()
end

local function loopSound(name)
	if not loops[name] then
		local template = music:FindFirstChild(name)
		if not template then
			return nil
		end
		local sound = template:Clone()
		sound.Looped = true
		sound.Volume = 0
		sound.SoundGroup = group
		sound.Parent = SoundService
		loops[name] = sound
	end
	return loops[name]
end

-- เปลี่ยนเพลงวน (nil = เงียบ); เพลงเดิมแค่ปรับความดัง ไม่เริ่มใหม่
local function setLoop(name, volume)
	if name == current then
		local sound = name and loops[name]
		if sound and volume ~= currentVolume then
			currentVolume = volume
			fade(sound, volume)
		end
		return
	end
	local old = current and loops[current]
	if old then
		fade(old, 0, function()
			if current ~= old.Name then
				old:Stop()
			end
		end)
	end
	current, currentVolume = name, volume
	local sound = name and loopSound(name)
	if sound then
		if not sound.IsPlaying then
			sound.TimePosition = 0
			sound:Play()
		end
		fade(sound, volume)
	end
end

local function playSting(name)
	local template = music:FindFirstChild(name)
	if not template then
		return
	end
	local sound = template:Clone()
	sound.Volume = STING_VOLUME
	sound.SoundGroup = group
	sound.Parent = SoundService
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	sound:Play()
end

local function update()
	local phase = workspace:GetAttribute("MatchPhase")
	local inMatch = player:GetAttribute("InMatch") == true
	if not inMatch then
		lastPhase = nil
		setLoop("Lobby", LOOP_VOLUME.Lobby)
		return
	end
	if phase ~= lastPhase and (phase == "Victory" or phase == "Defeat") then
		setLoop(nil)
		playSting(phase)
	end
	lastPhase = phase
	if phase == "Victory" or phase == "Defeat" then
		setLoop(nil)
	elseif phase == "Wave" or phase == "Countdown" or phase == "Break" then
		if workspace:GetAttribute("BossHP") ~= nil then
			setLoop("Boss", LOOP_VOLUME.Boss)
		else
			setLoop("Battle", LOOP_VOLUME.Battle * (phase == "Wave" and 1 or CALM_FACTOR))
		end
	else
		setLoop("Lobby", LOOP_VOLUME.Lobby) -- รอเพื่อนมาถึง server แมตช์
	end
end

---------------------------------------------------------------- ปุ่มเปิด/ปิดเพลง (แถบด้านบน ข้างปุ่มของ Roblox)

local gui = Instance.new("ScreenGui")
gui.Name = "MusicToggle"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 4
gui.Parent = player:WaitForChild("PlayerGui")

local button = Instance.new("TextButton")
button.Name = "Toggle"
button.Size = UDim2.fromOffset(40, 40)
button.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
button.BackgroundTransparency = 0.3
button.BorderSizePixel = 0
button.FontFace = FONT
button.TextSize = 20
button.Text = "🔊"
button.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0.5, 0)
corner.Parent = button

local function place()
	-- TopbarInset = พื้นที่ว่างของแถบบนถัดจากปุ่มเมนู/แชทของ Roblox
	local inset = GuiService.TopbarInset
	local height = math.max(inset.Height, 44)
	button.Position = UDim2.fromOffset(inset.Min.X + 8, (height - 40) / 2)
end
GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(place)
place()

if UserInputService.KeyboardEnabled then
	-- คอม: เมาส์ถูกล็อกกลางจอ กดปุ่มไม่ได้ -> ใช้ปุ่ม M (ป้ายเล็กมุมปุ่ม)
	local key = Instance.new("TextLabel")
	key.Size = UDim2.fromOffset(16, 16)
	key.Position = UDim2.new(1, 2, 1, 2)
	key.AnchorPoint = Vector2.new(1, 1)
	key.BackgroundColor3 = Color3.fromRGB(55, 58, 66)
	key.BorderSizePixel = 0
	key.FontFace = FONT
	key.TextSize = 11
	key.TextColor3 = Color3.fromRGB(255, 196, 64)
	key.Text = "M"
	key.Parent = button
	local keyCorner = Instance.new("UICorner")
	keyCorner.CornerRadius = UDim.new(0, 4)
	keyCorner.Parent = key
end

local function toggle()
	muted = not muted
	group.Volume = muted and 0 or 1
	button.Text = muted and "🔇" or "🔊"
end
button.Activated:Connect(toggle)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.M then
		toggle()
	end
end)

---------------------------------------------------------------- เริ่ม

player:GetAttributeChangedSignal("InMatch"):Connect(update)
workspace:GetAttributeChangedSignal("MatchPhase"):Connect(update)
workspace:GetAttributeChangedSignal("BossHP"):Connect(update)
update()

return {}
