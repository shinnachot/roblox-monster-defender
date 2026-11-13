-- PlayerService: สถานะผู้เล่นฝั่ง server (HP, อาวุธที่ถือ, ลูกธนู, i-frame)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage.Remotes
local Assets = ReplicatedStorage.Assets

local PlayerService = {}

local states = {}

local function newState()
	return {
		Equipped = nil,
		IFrameUntil = 0,
		LastRoll = -math.huge,
		NextSwing = 0,
		LastSwingEnd = -math.huge,
		ComboIndex = 0,
		DrawStart = nil,
	}
end

function PlayerService.GetState(player)
	return states[player]
end

-- คืน character, humanoid, root เฉพาะเมื่อผู้เล่นยังมีชีวิต
function PlayerService.GetCharacterParts(player)
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

	local old = char:FindFirstChild("HeldWeapon")
	if old then
		old:Destroy()
	end
	st.DrawStart = nil

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
	model.Parent = char

	st.Equipped = weaponName
	player:SetAttribute("Equipped", weaponName)
end

-- ทำดาเมจใส่ผู้เล่น; คืน false ถ้าหลบได้ (i-frame) หรือผู้เล่นตายอยู่
function PlayerService.Damage(player, amount)
	local st = states[player]
	if not st then
		return false
	end
	local char, hum = PlayerService.GetCharacterParts(player)
	if not char then
		return false
	end
	if os.clock() < st.IFrameUntil then
		return false
	end
	hum:TakeDamage(amount)
	Remotes.PlayerHurt:FireClient(player, amount)
	return true
end

-- เริ่มแมตช์ใหม่: เติมลูกธนูตาม loadout และ HP เต็ม
function PlayerService.ResetPlayer(player)
	player:SetAttribute("Arrows", Config.Weapons.Bow.Ammo + Config.DefaultLoadout.ExtraArrows)
	local char, hum = PlayerService.GetCharacterParts(player)
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
	st.DrawStart = nil
	st.ComboIndex = 0
	char:WaitForChild("RightHand", 10)
	char:WaitForChild("LeftHand", 10)
	PlayerService.Equip(player, st.Equipped or Config.DefaultLoadout.Weapons[1])
end

local function onPlayerAdded(player)
	states[player] = newState()
	player:SetAttribute("Arrows", Config.Weapons.Bow.Ammo + Config.DefaultLoadout.ExtraArrows)
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
		states[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return PlayerService
