-- TouchControls: ปุ่มควบคุมบนจอสัมผัส (มือถือ/แท็บเล็ต) — กระโดด, โจมตี, กลิ้งหลบ, โล่, ชุบเพื่อน
-- ปุ่มเป็น Frame ที่ไม่กิน input (Active = false) และรับนิ้วผ่าน InputBegan ของ Frame เอง:
-- นิ้วที่กดปุ่มค้างอยู่จึงลากเพื่อหมุนกล้องได้ด้วย (ง้างธนูไปเล็งไปด้วยนิ้วเดียว)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local TouchControls = {}

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local IDLE_TRANSPARENCY = 0.5
local PRESSED_TRANSPARENCY = 0.2

-- ตำแหน่ง = ระยะจุดกึ่งกลางปุ่มจากมุมล่างขวาของจอ (ก่อนคูณ UIScale)
local LAYOUT = {
	Jump = { Size = 72, X = -62, Y = -62, Text = "กระโดด", TextSize = 15 },
	Attack = { Size = 84, X = -70, Y = -160, Text = "ฟัน", TextSize = 22 },
	Roll = { Size = 58, X = -150, Y = -52, Text = "กลิ้ง", TextSize = 15 },
	Block = { Size = 58, X = -158, Y = -130, Text = "โล่", TextSize = 15 },
	Revive = { Size = 54, X = -226, Y = -46, Text = "ชุบ", TextSize = 14 },
}
local ATTACK_TEXT = { Sword = "ฟัน", Bow = "ยิง" }

local player = Players.LocalPlayer
local callbacks = {}
local buttons = {} -- [name] = { Frame, Label, Overlay, Touch, OnDown, OnUp }
local rollReadyAt, rollDuration = 0, 1
local enabled = false

-- อุปกรณ์จอสัมผัสที่ไม่มีคีย์บอร์ด (โน้ตบุ๊กจอสัมผัสยังใช้เมาส์/คีย์บอร์ดตามเดิม)
function TouchControls.IsTouchDevice()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function make(className, props, parent)
	local instance = Instance.new(className)
	for key, value in props do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end

local function buildButton(parent, name)
	local spec = LAYOUT[name]
	local frame = make("Frame", {
		Name = name,
		Size = UDim2.fromOffset(spec.Size, spec.Size),
		Position = UDim2.fromOffset(spec.X, spec.Y),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(12, 14, 18),
		BackgroundTransparency = IDLE_TRANSPARENCY,
		BorderSizePixel = 0,
		Active = false,
		ClipsDescendants = false,
	}, parent)
	make("UICorner", { CornerRadius = UDim.new(0.5, 0) }, frame)
	make("UIStroke", { Thickness = 1.5, Color = Color3.new(1, 1, 1), Transparency = 0.55 }, frame)
	local label = make("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		FontFace = FONT,
		Text = spec.Text,
		TextSize = spec.TextSize,
		TextColor3 = Color3.new(1, 1, 1),
		ZIndex = 3,
	}, frame)
	make("UIStroke", { Thickness = 1.5, Color = Color3.new(0, 0, 0), Transparency = 0.4 }, label)
	local button = { Frame = frame, Label = label }
	buttons[name] = button
	-- นิ้วแตะลงบนปุ่ม (การปล่อยนิ้วตามจาก UserInputService.TouchEnded เพราะนิ้วอาจลากออกนอกปุ่มไปแล้ว)
	frame.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch or input.UserInputState ~= Enum.UserInputState.Begin or button.Touch then
			return
		end
		button.Touch = input
		frame.BackgroundTransparency = PRESSED_TRANSPARENCY
		if button.OnDown then
			button.OnDown()
		end
	end)
	return button
end

local function release(button)
	if not button.Touch then
		return
	end
	button.Touch = nil
	button.Frame.BackgroundTransparency = IDLE_TRANSPARENCY
	if button.OnUp then
		button.OnUp()
	end
end

-- ซ่อนปุ่มกระโดดมาตรฐานของ Roblox (ใช้ปุ่มของเราแทน) — Roblox เปิดกลับเองตอนเกิดใหม่ จึงต้องคอยซ่อนซ้ำ
local function hideDefaultJump()
	local playerGui = player:WaitForChild("PlayerGui")
	local function apply()
		local touchGui = playerGui:FindFirstChild("TouchGui")
		local controlFrame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
		local jump = controlFrame and controlFrame:FindFirstChild("JumpButton")
		if jump and jump.Visible then
			jump.Visible = false
		end
	end
	task.spawn(function()
		while true do
			apply()
			task.wait(0.5)
		end
	end)
end

-- actions: { AttackDown, AttackUp, BlockDown, BlockUp, Roll, ReviveDown, ReviveUp, CanRevive, IsBlocked }
function TouchControls.Init(actions)
	callbacks = actions
	if not TouchControls.IsTouchDevice() then
		return
	end
	enabled = true

	local gui = make("ScreenGui", { Name = "TouchControls", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 6 }, player:WaitForChild("PlayerGui"))
	-- holder เป็นจุดขนาด 0 ที่มุมล่างขวาของจอ: UIScale ขยายรอบจุดนี้ ปุ่มจึงไม่หลุดจอ
	-- (เดิม holder เต็มจอ — UIScale 1.5 บน iPad ขยายจากมุมซ้ายบน ดันปุ่มทั้งหมดออกนอกจอ)
	local holder = make("Frame", {
		Size = UDim2.fromScale(0, 0),
		Position = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = false,
	}, gui)
	local scale = make("UIScale", {}, holder)
	local camera = workspace.CurrentCamera
	local function rescale()
		-- ออกแบบที่จอสูง ~400 px (มือถือแนวนอน); แท็บเล็ตขยายขึ้นได้ไม่เกิน 1.5 เท่า
		scale.Scale = math.clamp(camera.ViewportSize.Y / 400, 0.8, 1.5)
	end
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	rescale()

	-- กระโดด: ControlModule ของ Roblox เขียน Humanoid.Jump ทับทุกเฟรม (ตามปุ่มกระโดดมาตรฐานที่เราซ่อนไว้)
	-- จึงต้องตั้ง Jump = true ทุกเฟรมหลังมัน ตลอดที่นิ้วยังกดปุ่มอยู่ (กดค้าง = กระโดดต่อเนื่องเหมือนปุ่มเดิม)
	local jump = buildButton(holder, "Jump")
	RunService:BindToRenderStep("TouchJumpHold", Enum.RenderPriority.Input.Value + 1, function()
		if not jump.Touch then
			return
		end
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Jump = true
		end
	end)

	local attack = buildButton(holder, "Attack")
	attack.OnDown, attack.OnUp = actions.AttackDown, actions.AttackUp

	local roll = buildButton(holder, "Roll")
	roll.OnDown = actions.Roll
	roll.Frame.ClipsDescendants = true
	-- คูลดาวน์: ม่านมืดไล่ลง + ตัวเลขวินาที
	roll.Overlay = make("Frame", {
		Size = UDim2.fromScale(1, 0), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.35, BorderSizePixel = 0, ZIndex = 2,
	}, roll.Frame)

	local block = buildButton(holder, "Block")
	block.OnDown, block.OnUp = actions.BlockDown, actions.BlockUp

	local revive = buildButton(holder, "Revive")
	revive.OnDown, revive.OnUp = actions.ReviveDown, actions.ReviveUp
	revive.Frame.BackgroundColor3 = Color3.fromRGB(20, 70, 35)
	revive.Frame.Visible = false

	UserInputService.TouchEnded:Connect(function(touch)
		for _, button in buttons do
			if button.Touch == touch then
				release(button)
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		-- เปิดหน้าต่าง (คลัง/ทีม/หีบรางวัล) อยู่: ซ่อนปุ่มทั้งหมด ไม่ให้วาดทับหรือรับนิ้วแทนปุ่มของหน้าต่าง
		local blocked = actions.IsBlocked ~= nil and actions.IsBlocked()
		if gui.Enabled == blocked then
			gui.Enabled = not blocked
			if blocked then
				for _, button in buttons do
					release(button)
				end
			end
		end
		local remaining = rollReadyAt - os.clock()
		if remaining > 0 then
			roll.Overlay.Size = UDim2.fromScale(1, math.clamp(remaining / rollDuration, 0, 1))
			roll.Label.Text = string.format("%.1f", remaining)
		else
			roll.Overlay.Size = UDim2.fromScale(1, 0)
			roll.Label.Text = LAYOUT.Roll.Text
		end
		-- ปุ่มชุบโผล่เมื่อมีเพื่อนล้มอยู่ในระยะ; หายไประหว่างกดค้าง = ปล่อยปุ่ม
		local canRevive = actions.CanRevive ~= nil and actions.CanRevive()
		if revive.Frame.Visible ~= canRevive then
			revive.Frame.Visible = canRevive
			if not canRevive then
				release(revive)
			end
		end
	end)

	hideDefaultJump()
end

-- อาวุธที่ถืออยู่: เปลี่ยนข้อความปุ่มโจมตี และแสดงปุ่มโล่เฉพาะอาวุธที่มีโล่
function TouchControls.SetEquipped(weaponName, hasShield)
	if not enabled then
		return
	end
	buttons.Attack.Label.Text = ATTACK_TEXT[weaponName] or "โจมตี"
	local block = buttons.Block
	if block.Frame.Visible ~= hasShield then
		block.Frame.Visible = hasShield
		if not hasShield then
			release(block)
		end
	end
end

function TouchControls.SetRollCooldown(duration)
	rollDuration = duration
	rollReadyAt = os.clock() + duration
end

return TouchControls
