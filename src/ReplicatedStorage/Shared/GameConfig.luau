-- GameConfig: ค่าสมดุลเริ่มต้นทั้งหมด (GDD ข้อ 0)
-- เฟส 5 จะ override ค่าเหล่านี้ผ่าน ConfigService ได้ — ตอนนี้เป็นค่า default ในโค้ด
-- เวลาใน Anim (Start/Hit/Hold/End) คือวินาทีในคลิป animation ที่สร้างจาก generate_animation
-- (คลิปยาว 3-6 วิ จึงเล่นเฉพาะช่วงที่เป็นท่าจริง แล้วเร่งด้วย Speed)
-- ท่าฟันของอาวุธระยะประชิดแบ่ง 3 ช่วง (ดู SegmentTiming): เงื้อ (Speed) -> ฟาดเร็ว Strike..StrikeEnd (StrikeSpeed)
-- -> ดึงกลับ (RecoverSpeed); แสงตามดาบเปิดเฉพาะช่วงฟาด
-- กฎของเกม: อาวุธระยะประชิดทุกชิ้นต้องฟาดเร็วและมีแสงตามอาวุธ (ใส่ Strike* ในท่า + Trail ในอาวุธ)

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
		Range = 9.5, -- ดาบยาวขึ้น 1.3 เท่า (โมเดลใน Assets ถูก scale แล้ว)
		ArcDegrees = 140, -- ท่าฟันกวาดกว้างขึ้น
		ComboReset = 0.9, -- เว้นนานกว่านี้หลังจบจังหวะ = เริ่มคอมโบใหม่
		Combo = {
			-- ท่าฟันจัดด้วยโค้ด (Client/SlashPose + Config.SlashPoses) — เวลาเป็นวินาทีจริง:
			-- เงื้อ (Windup) -> ฟาด (Strike, แสงเปิด) -> ค้าง/คืนท่า (Recover); ดาเมจเกิดที่ HitAt ของช่วงฟาด
			-- คอมโบครบ 3 ท่า ~1.0 วิ; ดาเมจ 12/12/20 ให้ DPS ใกล้เคียงตอนท่ายังช้า
			{ Pose = "ForehandDown", Windup = 0.1, Strike = 0.1, Recover = 0.13, HitAt = 0.6, Damage = 12 },
			{ Pose = "BackhandRise", Windup = 0.09, Strike = 0.1, Recover = 0.12, HitAt = 0.6, Damage = 12 },
			{ Pose = "WideSweep", Windup = 0.17, Strike = 0.12, Recover = 0.2, HitAt = 0.6, Damage = 20 },
		},
		-- แสงตามดาบ: จุดโคน/ปลายใบดาบตามแกน Y ของ Grip (studs) — สี/ความยาวใช้ Config.MeleeTrail
		Trail = { Base = 1.15, Tip = 5.8 },
		-- โล่มือซ้าย: กดค้างคลิกขวาเพื่อยกโล่ — เดินช้า ฟันไม่ได้ ลดดาเมจที่โดนจากด้านหน้า
		Shield = {
			Model = "Shield",
			Hand = "Left", -- ติดที่ท่อนแขนล่างซ้าย (LeftLowerArm)
			BlockReduction = 0.3, -- กันได้ 30% ของดาเมจ (โดน 70%)
			ArcDegrees = 180, -- กันได้เฉพาะการโจมตีจากด้านหน้าในมุมนี้
			WalkSpeed = 8,
		},
	},
	Bow = {
		Slot = 2,
		Kind = "Bow",
		Hand = "Left",
		-- ลูกธนูไม่ได้มากับธนู: ซื้อเป็นชุดใน loadout (Items.ExtraArrows)
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

-- ท่าฟันของอาวุธระยะประชิด (จัดด้วยโค้ดใน Client/SlashPose) — keyframe: ท่าเตรียม, กลางวง, จบวง
-- Arm/Blade = { ขวา, ขึ้น, หน้า } ในพื้นที่ตัวละคร, Yaw = บิดเอว (องศา, บวก = ซ้าย)
-- อาวุธประชิดชิ้นใหม่ใช้ท่าเหล่านี้ซ้ำได้ หรือเพิ่มท่าใหม่ที่นี่
Config.SlashPoses = {
	-- ฟันเฉียงลง: ดาบชูขึ้นทางขวา -> ฟาดเฉียงผ่านหน้า -> จบต่ำทางซ้าย
	ForehandDown = {
		{ Arm = { 0.55, 0.8, 0.1 }, Blade = { 0.15, 1, -0.35 }, Yaw = -25 },
		{ Arm = { 0.2, 0.25, 1 }, Blade = { -0.55, 0.35, 0.75 }, Yaw = 0 },
		{ Arm = { -0.55, -0.35, 0.75 }, Blade = { -0.9, -0.35, -0.25 }, Yaw = 35 },
	},
	-- ฟันย้อนขึ้น: จากต่ำทางซ้าย -> กวาดผ่านหน้า -> จบสูงทางขวา
	BackhandRise = {
		{ Arm = { -0.6, -0.3, 0.7 }, Blade = { -0.85, -0.3, -0.4 }, Yaw = 35 },
		{ Arm = { 0.15, 0.1, 1 }, Blade = { 0.5, 0.35, 0.8 }, Yaw = 0 },
		{ Arm = { 0.7, 0.45, 0.45 }, Blade = { 0.55, 0.8, -0.25 }, Yaw = -30 },
	},
	-- ท่าปิด: ง้างไปด้านหลังขวา -> กวาดแนวราบกว้างระดับอก -> จบทางซ้าย
	WideSweep = {
		{ Arm = { 0.85, 0.25, -0.2 }, Blade = { 0.4, 0.15, -0.9 }, Yaw = -45 },
		{ Arm = { 0.1, 0.15, 1 }, Blade = { -0.6, 0.05, 0.8 }, Yaw = 0 },
		{ Arm = { -0.75, 0.1, 0.55 }, Blade = { -0.95, 0, -0.2 }, Yaw = 45 },
	},
}

-- แสงตามอาวุธระยะประชิด (ใช้ร่วมกันทุกชิ้น; อาวุธแต่ละชิ้น override สีได้ด้วย Trail.Color)
Config.MeleeTrail = {
	Color = { Color3.fromRGB(255, 214, 110), Color3.fromRGB(255, 160, 40) }, -- ทองเข้ม: ต้นแสง -> หาง
	EdgeColor = Color3.fromRGB(255, 244, 205), -- เส้นสว่างที่ขอบปลายดาบ
	Transparency = 0.25, -- ตอนเริ่ม (จางจนหายตามอายุ)
	Lifetime = 0.16,
	EdgeWidth = 0.35, -- ความกว้างเส้นขอบ (studs จากปลายดาบ)
	LightEmission = 0.6,
}

-- เกราะ: ค่าเกราะ (Durability) รับดาเมจก่อนทั้งหมด เกราะหมดแล้วจึงเริ่มลด HP
-- ไม่ฟื้นระหว่างด่าน; ได้เกราะใหม่ตอนเริ่มแมตช์ และตอน respawn ที่ฐาน (จบ wave โดยไม่มีใครชุบ)
-- Model = โมเดลใน Assets.Armors ที่สวมบนตัวละครตอนเกราะยังเหลือ (หลุดร่วงเมื่อเกราะหมด)
Config.Armors = {
	Leather = { Name = "เกราะหนัง", Durability = 25, Model = "LeatherArmor" },
	Chain = { Name = "เกราะโซ่", Durability = 50 },
	Iron = { Name = "เกราะเหล็ก", Durability = 75 },
	LegendArmor = { Name = "เกราะในตำนาน", Durability = 100 },
}

---------------------------------------------------------------- Progression (เฟส 3, GDD ข้อ 3-5)

-- Rank ตาม EXP (เรียงจากต่ำไปสูง) — ตกแรงก์ไม่ได้
Config.Ranks = {
	{ Id = "Bronze", Name = "Bronze", MinExp = 0, Color = Color3.fromRGB(205, 127, 50) },
	{ Id = "Silver", Name = "Silver", MinExp = 500, Color = Color3.fromRGB(200, 205, 215) },
	{ Id = "Gold", Name = "Gold", MinExp = 1500, Color = Color3.fromRGB(255, 205, 60) },
	{ Id = "Platinum", Name = "Platinum", MinExp = 4000, Color = Color3.fromRGB(120, 225, 230) },
	{ Id = "Legend", Name = "Legend", MinExp = 10000, Color = Color3.fromRGB(200, 110, 255) },
}

-- ไอเท็มใน loadout: key = id ที่เก็บใน DataStore (ห้ามเปลี่ยนชื่อ key), Name = ข้อความที่แสดง
-- Kind: Weapon / Armor / Ammo / Consumable; Upgradable = สุ่มได้ชิ้นส่วนและอัพเกรดได้
-- Repeatable = ใส่ใน loadout ซ้ำได้หลายชิ้น; Order = ลำดับการ์ดในหน้า Loadout
-- Model = โมเดลใน Assets.Weapons (เกราะ: Assets.Armors) ที่แสดงบนการ์ด (ไม่มี = ใช้ Icon แทน), Desc = คำอธิบายสั้นบนการ์ด
-- Available = false: ยังไม่มีระบบต่อสู้จริง — แสดงเป็น "เร็ว ๆ นี้" ใส่ loadout ไม่ได้
Config.Items = {
	-- ดาบมาคู่กับโล่เสมอ (ไม่มีโล่แยกใน loadout) — ดู Config.Weapons.Sword.Shield
	Sword = { Name = "ดาบโล่", Rank = "Bronze", Cost = 3, Kind = "Weapon", Upgradable = true, Order = 1, Model = "Sword", Desc = "คอมโบ 3 จังหวะ, คลิกขวาค้างยกโล่" },
	Bow = { Name = "ธนู", Rank = "Bronze", Cost = 3, Kind = "Weapon", Upgradable = true, Order = 2, Model = "Bow", Desc = "กดค้างง้าง ยิงไกล — ใส่แล้วได้ลูกธนู 1 ชุดให้เอง" },
	-- ลูกธนู: ใส่ได้เฉพาะเมื่อมีธนู และมีธนูต้องมีอย่างน้อย 1 ชุด (Progression.ValidateLoadout)
	ExtraArrows = { Name = "ลูกธนู", Rank = "Bronze", Cost = 1, Kind = "Ammo", Repeatable = true, Arrows = 12, Order = 3, Model = "Arrow", Desc = "12 ดอกต่อชุด" },
	Potion = { Name = "ยาฟื้น HP", Rank = "Bronze", Cost = 2, Kind = "Consumable", Charges = 2, Heal = 50, Order = 5, Icon = "🧪", Desc = "2 ขวด ขวดละ +50 HP (ปุ่ม F)" },
	Leather = { Name = "เกราะหนัง", Rank = "Bronze", Cost = 2, Kind = "Armor", Upgradable = true, Order = 6, Model = "LeatherArmor", Icon = "🦺", Desc = "เกราะ 25" },
	Spear = { Name = "หอก", Rank = "Silver", Cost = 4, Kind = "Weapon", Upgradable = true, Order = 7, Icon = "🔱", Desc = "ระยะตีไกล", Available = false },
	Chain = { Name = "เกราะโซ่", Rank = "Silver", Cost = 4, Kind = "Armor", Upgradable = true, Order = 8, Icon = "⛓️", Desc = "เกราะ 50" },
	Crossbow = { Name = "หน้าไม้", Rank = "Gold", Cost = 4, Kind = "Weapon", Upgradable = true, Order = 9, Icon = "🏹", Desc = "แรงแต่ยิงช้า", Available = false },
	Hammer = { Name = "ค้อนสองมือ", Rank = "Gold", Cost = 5, Kind = "Weapon", Upgradable = true, Order = 10, Icon = "🔨", Desc = "ทุบแรง", Available = false },
	Musket = { Name = "ปืนคาบศิลา", Rank = "Platinum", Cost = 4, Kind = "Weapon", Upgradable = true, Order = 11, Model = "Musket", Desc = "สไนเปอร์ บรรจุ 3 วิ", Available = false },
	Iron = { Name = "เกราะเหล็ก", Rank = "Platinum", Cost = 6, Kind = "Armor", Upgradable = true, Order = 12, Icon = "🛡️", Desc = "เกราะ 75" },
	LegendSword = { Name = "ดาบในตำนาน", Rank = "Legend", Cost = 5, Kind = "Weapon", Upgradable = true, Order = 13, Icon = "⚔️", Desc = "", Available = false },
	LegendArmor = { Name = "เกราะในตำนาน", Rank = "Legend", Cost = 7, Kind = "Armor", Upgradable = true, Order = 14, Icon = "👑", Desc = "เกราะ 100" },
}

Config.Loadout = {
	Points = 12,
	MaxWeapons = 5, -- สลับอาวุธปุ่ม 1-5
	-- ชุดเริ่มต้นเมื่อยังไม่เคยจัด (12 แต้ม)
	Starter = { "Sword", "Bow", "ExtraArrows", "ExtraArrows", "Leather", "Potion" },
}

Config.Rewards = {
	Win = { Parts = { 3, 5 }, ExpPerStage = 100 },
	Lose = { Parts = { 1, 2 }, ExpPerStage = -40 },
}

Config.Upgrade = {
	Costs = { 5, 8, 12, 16, 20 }, -- ชิ้นส่วนที่ใช้อัพเป็นเลเวล 1..5
	BonusPerLevel = 0.03, -- อาวุธ = ดาเมจ, เกราะ = ค่าเกราะ
}

Config.Monsters = {
	Goblin = {
		Template = "Goblin",
		Scale = 0.85,
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

	-- มองหาผู้เล่นในรัศมี 90 studs แล้วเดินเข้าไปยิงจากระยะ 65 studs, มีโอกาสดรอปลูกธนู (เริ่มเจอ stage 1 คลื่น 2)
	SkeletonArcher = {
		Template = "Skeleton",
		Scale = 1,
		HP = 50,
		BaseDamage = 8,
		WalkSpeed = 10,
		Weapon = { Model = "Bow", Hand = "Left" },
		Ranged = {
			Kind = "Bow", -- ท่าเล็ง + ชนิดกระสุนที่ client แสดง
			Damage = 8,
			Range = 65, -- ระยะยิงผู้เล่น
			DetectRange = 90, -- รัศมีมองหาผู้เล่น (เห็นแล้วเดินเข้าหาจนถึงระยะยิง; ไม่ใส่ = เท่ากับ Range)
			BaseRange = 28, -- ระยะที่หยุดยิงฐาน
			AimTime = 0.9, -- เล็งค้างก่อนยิง (ให้ผู้เล่นเห็นและหลบทัน)
			Cooldown = 2.6,
			Speed = 110,
			Gravity = 20,
			BodyYaw = 70,
		},
		Drop = { Chance = 0.35, Arrows = 3 },
		DeathAnim = { Name = "GoblinDeath", Start = 0.7, Hold = 2.3, Speed = 1.6 },
		AttackSound = "BowRelease",
		DeathSound = "GoblinDeath",
	},

	-- ช้า ถึก ทุบแรง ตีฐานแรง (เริ่มเจอ stage 3)
	OrcBrute = {
		Template = "Orc",
		Scale = 1.35,
		HP = 250,
		Damage = 25,
		BaseDamage = 40,
		WalkSpeed = 7,
		AttackRange = 7,
		AttackCooldown = 2.4,
		AttackAnim = { Name = "SwordSlash3", Start = 0.5, Hit = 1.25, End = 1.8, Speed = 1.0 },
		DeathAnim = { Name = "GoblinDeath", Start = 0.7, Hold = 2.3, Speed = 1.2 },
		AttackSound = "GoblinAttack",
		HitSound = "Slam",
		DeathSound = "GoblinDeath",
	},

	-- ยิงทีละนัด ระยะ 60 studs บรรจุ 3 วิ (เริ่มเจอ stage 4)
	GoblinMusketeer = {
		Template = "Goblin",
		Scale = 0.85,
		HP = 70,
		BaseDamage = 20,
		WalkSpeed = 10,
		Weapon = { Model = "Musket", Hand = "Right" },
		Ranged = {
			Kind = "Rifle",
			Damage = 20,
			Range = 60,
			BaseRange = 34,
			AimTime = 1.2,
			Cooldown = 3,
			Speed = 320,
			Gravity = 0,
			BodyYaw = 15,
		},
		DeathAnim = { Name = "GoblinDeath", Start = 0.7, Hold = 2.3, Speed = 1.6 },
		AttackSound = "MusketShot",
		DeathSound = "GoblinDeath",
	},

	-- Boss: wave 5 ทุก stage — HP x จำนวนผู้เล่น, แข็งขึ้นตาม stage
	-- ฟันกวาดเป็นวง + เรียกลูกน้อง, เลือกตีคนที่ทำดาเมจใส่ตัวเองมากที่สุด
	OrcWarlord = {
		Template = "Orc",
		Scale = 2.1,
		Boss = true,
		HP = 1500,
		StageHPScale = 0.25, -- +25% ต่อ stage
		StageDamageScale = 0.15,
		Damage = 30,
		BaseDamage = 60,
		WalkSpeed = 9,
		AttackRange = 9,
		AttackCooldown = 3,
		Sweep = { Radius = 14, ArcDegrees = 220 },
		Summon = { Interval = 18, Kind = "Goblin", Count = 4 },
		Weapon = { Model = "Sword", Hand = "Right", Scale = 1.7 }, -- โมเดลดาบยาวขึ้น 1.3 เท่าแล้ว (1.7 x 1.3 ~ ขนาดเดิม 2.2)
		AttackAnim = { Name = "SwordSlash2", Start = 0.4, Hit = 0.8, End = 1.2, Speed = 0.6 },
		DeathAnim = { Name = "GoblinDeath", Start = 0.7, Hold = 2.3, Speed = 0.9 },
		AttackSound = "BossRoar",
		HitSound = "Slam",
		DeathSound = "BossRoar",
	},
}

-- ล้ม & ชุบ (GDD ข้อ 8)
Config.Downed = {
	WalkSpeed = 3, -- คลานช้า ๆ
	ReviveTime = 3, -- กดค้าง E
	ReviveRange = 7,
	ReviveHPFraction = 0.3,
	CrawlAnim = "Crawl",
}

Config.Pickup = {
	Range = 5,
	Lifetime = 25,
}

Config.AI = {
	AggroFrontRange = 12, -- ผู้เล่นขวางทางข้างหน้าในระยะนี้ -> หันมาตีผู้เล่น
	LeashRange = 30, -- ผู้เล่นหนีไกลกว่านี้ -> กลับไปหาฐาน (ไม่ใช้กับเป้าที่อยู่บนกำแพง)
	MeleeHeightReach = 7, -- ต่างระดับเกินนี้ตีไม่ถึง (เช่น ผู้เล่นบนกำแพง) ต้องเดินขึ้นไปหา
	-- monster ยิงไกล: หลบหลังที่กำบัง (tag "Cover") ระหว่างบรรจุ แล้วโผล่ออกมายิง
	CoverSearchRadius = 35, -- ใช้ที่กำบังที่อยู่ใกล้ตัวไม่เกินนี้
	CoverMinThreatDistance = 12, -- ไม่ใช้ที่กำบังที่ผู้เล่นยืนติดอยู่
	CoverGiveUpTime = 6, -- เดินไปจุดหลบ/จุดโผล่ไม่ถึงในเวลานี้ -> เลิกใช้ที่กำบังชั่วคราว
	ElevatedStandOff = 20, -- เป้าอยู่บนกำแพง: monster ยิงไกลเข้าใกล้ไม่เกินระยะราบนี้ (ไม่ปีนขึ้นไป)
	BlindGiveUpTime = 5, -- อยู่ในระยะแต่มองไม่เห็นเป้านานเท่านี้ -> เลิกสนใจเป้านั้นชั่วคราว
	TickRate = 0.1,
}

-- แผนที่: ป้อมอยู่กลาง (0,0), ประตูเดียวด้านหน้า (-Z), จุดเกิด monster ห่างประตู ~300 studs
Config.Map = {
	GateZ = -55, -- ผิวด้านในของกำแพงหน้า: Z น้อยกว่านี้ = ยังอยู่นอกลานป้อม
	LaneEndZ = -110, -- monster เดินตามเลนของตัวเอง (X ตามจุดเกิด) จนถึง Z นี้ แล้วจึงบีบเข้าประตู
	LaneHalfWidth = 80, -- เลนอยู่ในช่วง X = -80..80
	WallMinY = 11, -- ตำแหน่งที่สูงกว่านี้ = อยู่บนกำแพง/ป้อมมุม (ทางเดินบนกำแพงสูง 16)
}

-- ทีม + หาผู้เล่นข้าม server (GDD ข้อ 2 Party & Matchmaking, เฟส 4)
Config.Party = {
	MaxSize = 3,
	InviteTimeout = 20, -- คำชวนหมดอายุ (วินาที)
	QueueTime = 30, -- หาผู้เล่นจากทุก lobby server นานเท่านี้ แล้วเริ่มด้วยจำนวนที่มี
	PollInterval = 2, -- รอบตรวจคิวใน MemoryStore
	ClaimTimeout = 15, -- ทีมที่ถูกจับคู่แล้วรอ host ส่งรหัส server นานสุดเท่านี้ ก่อนกลับไปหาใหม่
	ArrivalTimeout = 25, -- server แมตช์รอทุกคนมาถึงนานสุด (นับจากคนแรกมาถึง)
	ReunionTime = 60, -- กลับ Lobby แล้วรวมทีมเดิมให้เองภายในเวลานี้
}

Config.Waves = {
	PlayerScale = { 0.5, 0.75, 1.0 }, -- ตัวคูณจำนวน monster สำหรับ 1/2/3 คน
	StartDelay = 8,
	BreakTime = 15,
	SpawnInterval = 1.2,
	ResultTime = 20, -- รวมเวลาเปิดหีบในด่าน (RewardUi) ก่อนกลับ Lobby
	-- จำนวนต่อ wave สำหรับทีม 3 คน (คูณ PlayerScale ตามจำนวนผู้เล่น; Boss มี 1 ตัวเสมอ)
	-- wave 5 ของทุก stage มี Boss
	Stages = {
		[1] = {
			{ Goblin = 8 },
			{ Goblin = 12, SkeletonArcher = 2 }, -- เริ่มมีตัวยิงไกลตั้งแต่คลื่น 2 ไม่ให้ง่ายเกินไป
			{ Goblin = 14, SkeletonArcher = 3 },
			{ Goblin = 18, SkeletonArcher = 4 },
			{ OrcWarlord = 1, Goblin = 8, SkeletonArcher = 2 },
		},
		[2] = {
			{ Goblin = 10, SkeletonArcher = 2 },
			{ Goblin = 12, SkeletonArcher = 4 },
			{ Goblin = 14, SkeletonArcher = 6 },
			{ Goblin = 16, SkeletonArcher = 8 },
			{ OrcWarlord = 1, Goblin = 8, SkeletonArcher = 4 },
		},
		[3] = {
			{ Goblin = 10, SkeletonArcher = 4, OrcBrute = 2 },
			{ Goblin = 12, SkeletonArcher = 4, OrcBrute = 2 },
			{ Goblin = 12, SkeletonArcher = 6, OrcBrute = 4 },
			{ Goblin = 14, SkeletonArcher = 6, OrcBrute = 4 },
			{ OrcWarlord = 1, Goblin = 8, SkeletonArcher = 4, OrcBrute = 2 },
		},
		[4] = {
			{ Goblin = 10, SkeletonArcher = 4, OrcBrute = 2, GoblinMusketeer = 2 },
			{ Goblin = 12, SkeletonArcher = 4, OrcBrute = 2, GoblinMusketeer = 4 },
			{ Goblin = 12, SkeletonArcher = 6, OrcBrute = 4, GoblinMusketeer = 4 },
			{ Goblin = 14, SkeletonArcher = 6, OrcBrute = 4, GoblinMusketeer = 6 },
			{ OrcWarlord = 1, Goblin = 8, SkeletonArcher = 4, OrcBrute = 2, GoblinMusketeer = 4 },
		},
		[5] = {
			{ Goblin = 14, SkeletonArcher = 6, OrcBrute = 2, GoblinMusketeer = 4 },
			{ Goblin = 16, SkeletonArcher = 6, OrcBrute = 4, GoblinMusketeer = 4 },
			{ Goblin = 16, SkeletonArcher = 8, OrcBrute = 4, GoblinMusketeer = 6 },
			{ Goblin = 18, SkeletonArcher = 8, OrcBrute = 6, GoblinMusketeer = 6 },
			{ OrcWarlord = 1, Goblin = 10, SkeletonArcher = 6, OrcBrute = 4, GoblinMusketeer = 6 },
		},
	},
}

-- แปลงช่วงคลิปเป็นเวลาจริง: คืน (เวลาที่ดาเมจเกิด, ความยาวท่า, เวลาเริ่มฟาด, เวลาจบฟาด) เป็นวินาที
-- ท่าที่มี Strike: เงื้อด้วย Speed, ฟาดด้วย StrikeSpeed, ดึงกลับด้วย RecoverSpeed
function Config.SegmentTiming(seg)
	if seg.Pose then
		-- ท่าจัดด้วยโค้ด: เวลาเป็นวินาทีจริงอยู่แล้ว
		local strikeAt = seg.Windup
		local strikeEnd = seg.Windup + seg.Strike
		return strikeAt + seg.Strike * (seg.HitAt or 0.5), strikeEnd + seg.Recover, strikeAt, strikeEnd
	end
	local speed = seg.Speed or 1
	local stop = seg.End or seg.Hold
	if not seg.Strike then
		local hit = seg.Hit and (seg.Hit - seg.Start) / speed or 0
		return hit, (stop - seg.Start) / speed, nil, nil
	end
	local windup = (seg.Strike - seg.Start) / speed
	local strike = (seg.StrikeEnd - seg.Strike) / seg.StrikeSpeed
	local recover = (stop - seg.StrikeEnd) / (seg.RecoverSpeed or speed)
	local hit = windup + (seg.Hit - seg.Strike) / seg.StrikeSpeed
	return hit, windup + strike + recover, windup, windup + strike
end

return Config
