-- GameConfig: ค่าสมดุลเริ่มต้นทั้งหมด (GDD ข้อ 0)
-- เฟส 5 จะ override ค่าเหล่านี้ผ่าน ConfigService ได้ — ตอนนี้เป็นค่า default ในโค้ด
-- เวลาใน Anim (Start/Hit/Hold/End) คือวินาทีในคลิป animation ที่สร้างจาก generate_animation
-- (คลิปยาว 3-6 วิ จึงเล่นเฉพาะช่วงที่เป็นท่าจริง แล้วเร่งด้วย Speed)

local Config = {}

Config.Player = {
	MaxHP = 100,
	RespawnTime = 5,
}

Config.Roll = {
	Distance = 14, -- studs
	Duration = 0.45,
	IFrame = 0.3,
	Cooldown = 3,
	Anim = { Name = "Roll", Start = 0.8, End = 2.6 },
}

Config.HeadshotMultiplier = 1.5

Config.Base = {
	MaxHP = 1000,
	AttackRadius = 9, -- monster หยุดตีฐานเมื่อเข้าใกล้ศูนย์กลางคริสตัลในระยะนี้
}

Config.Weapons = {
	Sword = {
		Slot = 1,
		Kind = "Melee",
		Hand = "Right",
		Range = 8,
		ArcDegrees = 120,
		ComboReset = 0.9, -- เว้นนานกว่านี้หลังจบจังหวะ = เริ่มคอมโบใหม่
		Combo = {
			-- Hit = จังหวะที่ปลายดาบเร็วสุดในคลิป (วัดจาก playtest)
			{ Anim = "SwordSlash1", Start = 0.8, Hit = 1.2, End = 1.7, Speed = 2.0, Damage = 18 },
			{ Anim = "SwordSlash2", Start = 0.4, Hit = 0.8, End = 1.2, Speed = 2.0, Damage = 18 },
			{ Anim = "SwordSlash3", Start = 0.5, Hit = 1.25, End = 1.8, Speed = 1.8, Damage = 30 },
		},
	},
	Bow = {
		Slot = 2,
		Kind = "Bow",
		Hand = "Left",
		Ammo = 6,
		ChargeTime = 1.0, -- วินาทีจนง้างสุด
		MinCharge = 0.15, -- ง้างน้อยกว่านี้ = ยกเลิก ไม่เสียลูกธนู
		MinDamage = 12,
		MaxDamage = 45,
		-- ระยะยิงไกลสุดบนพื้นราบ = Speed^2 / Gravity (ง้างสุด ~1,000 studs, ง้างน้อยสุด ~230)
		-- client ยกมุมยิงชดเชยให้ลูกธนูไปตกที่จุดเล็ง (ดู BowAim)
		MinSpeed = 90, -- studs/s
		MaxSpeed = 190,
		Gravity = 35,
		MaxFlightTime = 6,
		DrawWalkSpeed = 8,
		-- ท่าง้างจัดด้วย IK ฝั่ง client (ดู BowAim) — ไม่ใช้คลิป animation
		DrawPose = {
			BodyYaw = 70, -- องศาที่ลำตัวหันข้าง (ไหล่ซ้ายนำเข้าหาเป้า)
			ArmReach = 2.0, -- ระยะจากไหล่ซ้ายถึงคันธนู
			Raise = 0.25, -- ยกเส้นลูกธนูขึ้นจากไหล่ให้ถึงระดับคาง
			StringRest = 0.5, -- มือขวาห่างคันธนูตอนยังไม่ดึง
			DrawLength = 1.9, -- ดึงสายถอยเพิ่มเมื่อง้างสุด
		},
	},
}

-- เฟส 1 ยังไม่มีหน้า Loadout: ใช้ชุดเริ่มต้น (ดาบ + ธนู + ลูกธนูเพิ่ม)
Config.DefaultLoadout = {
	Weapons = { "Sword", "Bow" },
	ExtraArrows = 6,
}

Config.Monsters = {
	Goblin = {
		Template = "Goblin",
		HP = 60,
		Damage = 10,
		BaseDamage = 10,
		WalkSpeed = 11,
		AttackRange = 5,
		AttackCooldown = 1.6,
		-- ใช้คลิปฟาดจากเหนือหัว (คลิป GoblinAttack ที่ generate ได้ขยับน้อยเกินไป) — เงื้อ 0.5 วิ ให้ผู้เล่นกลิ้งหลบทัน
		AttackAnim = { Name = "SwordSlash3", Start = 0.5, Hit = 1.25, End = 1.8, Speed = 1.5 },
		DeathAnim = { Name = "GoblinDeath", Start = 0.7, Hold = 2.3, Speed = 1.6 },
		AttackSound = "GoblinAttack",
		DeathSound = "GoblinDeath",
	},
}

Config.AI = {
	AggroFrontRange = 12, -- ผู้เล่นขวางทางข้างหน้าในระยะนี้ -> หันมาตีผู้เล่น
	LeashRange = 30, -- ผู้เล่นหนีไกลกว่านี้ -> กลับไปหาฐาน
	TickRate = 0.1,
}

Config.Waves = {
	PlayerScale = { 0.5, 0.75, 1.0 }, -- ตัวคูณจำนวน monster สำหรับ 1/2/3 คน
	StartDelay = 8,
	BreakTime = 15,
	SpawnInterval = 1.2,
	ResultTime = 10,
	Stages = {
		[1] = {
			{ Goblin = 8 },
			{ Goblin = 12 },
			{ Goblin = 16 },
			{ Goblin = 20 },
			{ Goblin = 24 },
		},
	},
}

-- แปลงช่วงคลิปเป็นเวลาจริง: คืน (เวลาที่ดาเมจเกิด, ความยาวท่า) เป็นวินาที
function Config.SegmentTiming(seg)
	local speed = seg.Speed or 1
	local hit = seg.Hit and (seg.Hit - seg.Start) / speed or 0
	local stop = seg.End or seg.Hold
	return hit, (stop - seg.Start) / speed
end

return Config
