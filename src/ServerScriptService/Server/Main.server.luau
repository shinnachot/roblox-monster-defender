-- Main: จุดเริ่มต้นฝั่ง server ของ Monster Defender
local PhysicsService = game:GetService("PhysicsService")

-- monster ไม่ชนกันเอง (เดินเป็นกลุ่มไม่ติดกัน) แต่ยังชนกับผู้เล่นและฉาก
pcall(function()
	PhysicsService:RegisterCollisionGroup("Monsters")
end)
PhysicsService:CollisionGroupSetCollidable("Monsters", "Monsters", false)

local Modules = script.Parent.Modules
local ServerMode = require(Modules.ServerMode)
ServerMode.Init() -- Lobby หรือ server แมตช์ (reserved) — ก่อนผู้เล่นเกิด
local DataService = require(Modules.DataService)
local ProgressionService = require(Modules.ProgressionService)
local PlayerService = require(Modules.PlayerService)
local MonsterService = require(Modules.MonsterService)
local CombatService = require(Modules.CombatService)
local WaveService = require(Modules.WaveService)
local PartyService = require(Modules.PartyService)

DataService.Init()
ProgressionService.Init()
PlayerService.Init()
MonsterService.Init()
CombatService.Init()
if ServerMode.IsMatchServer() then
	WaveService.StartMatchServer()
else
	PartyService.Init()
	WaveService.StartLobby()
end
