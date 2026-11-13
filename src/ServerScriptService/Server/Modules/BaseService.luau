-- BaseService: คริสตัลเวทกลางป้อม (ฐาน) — HP เก็บเป็น attribute บนโมเดลเพื่อให้ client อ่านได้
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.GameConfig)
local Remotes = ReplicatedStorage.Remotes

local BaseService = {}

local model = workspace:WaitForChild("Map"):WaitForChild("Base")
local destroyed = Instance.new("BindableEvent")

BaseService.Model = model
BaseService.Destroyed = destroyed.Event

function BaseService.GetPosition()
	return model.PrimaryPart.Position
end

function BaseService.GetHP()
	return model:GetAttribute("HP") or 0
end

function BaseService.Reset()
	model:SetAttribute("MaxHP", Config.Base.MaxHP)
	model:SetAttribute("HP", Config.Base.MaxHP)
end

function BaseService.Damage(amount)
	local hp = BaseService.GetHP()
	if hp <= 0 then
		return
	end
	hp = math.max(0, hp - amount)
	model:SetAttribute("HP", hp)
	Remotes.WorldSound:FireAllClients("BaseHit", BaseService.GetPosition() + Vector3.new(0, 6, 0))
	if hp == 0 then
		destroyed:Fire()
	end
end

return BaseService
