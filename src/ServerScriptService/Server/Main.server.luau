-- Main: จุดเริ่มต้นฝั่ง server ของ Monster Defender
local PhysicsService = game:GetService("PhysicsService")

-- monster ไม่ชนกันเอง (เดินเป็นกลุ่มไม่ติดกัน) แต่ยังชนกับผู้เล่นและฉาก
pcall(function()
	PhysicsService:RegisterCollisionGroup("Monsters")
end)
PhysicsService:CollisionGroupSetCollidable("Monsters", "Monsters", false)

local Modules = script.Parent.Modules
local PlayerService = require(Modules.PlayerService)
local MonsterService = require(Modules.MonsterService)
local CombatService = require(Modules.CombatService)
local WaveService = require(Modules.WaveService)

PlayerService.Init()
MonsterService.Init()
CombatService.Init()
WaveService.Start()
