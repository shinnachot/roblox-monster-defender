# src — สำรองสคริปต์จาก Roblox Studio

Studio คือต้นฉบับของโค้ด (GDD ข้อ 0) โฟลเดอร์นี้เป็นสำเนาที่ export หลังจบแต่ละรอบงาน
โครงตาม service; สคริปต์ที่มีลูกจะเป็นโฟลเดอร์ + `init.*.luau`

## Asset ที่ใช้

โมเดลจาก Creator Store (ลบสคริปต์/GUI ที่ติดมาออกทั้งหมดก่อนใช้ — หลายตัวมีสคริปต์ซ่อนทั้งที่หน้า store เขียนว่า "No scripts"):

| ใช้เป็น | assetId |
|---|---|
| ดาบ | 86734189755806 |
| โล่ (คู่กับดาบ, ติดท่อนแขนซ้าย) | 97615965139101 |
| ธนู | 82137658715480 |
| ลูกธนู | 77628724111197 |
| Goblin (R15) | 16317433513 |
| คริสตัลฐาน | 99829008230184 |
| ป้อม — เหลือใช้แค่หลังคาป้อมมุม 4 หลัง (กำแพงสร้างใหม่จาก Part ใน `Map.Fort`) | 91733327096845 |
| ชั้นวางอาวุธ (คลังอาวุธใน Lobby) | 117098692227056 |
| ต้นไม้ (Low Poly Tree Pack) — ต้นแบบเก็บใน `ServerStorage.TreeTemplates` | 15217079919 |
| Skeleton (R15) — Skeleton Archer | 94271026740769 |
| Orc (R15) — Orc Brute และ Boss Orc Warlord | 71129266059717 |
| ปืนคาบศิลา — Goblin Musketeer | 8845834570 |

Animation (สร้างด้วย `generate_animation`, อยู่ในบัญชีเจ้าของเกม):

| ชื่อ | assetId | หมายเหตุ |
|---|---|---|
| SwordSlash1 | 85172413897286 | |
| SwordSlash2 | 117425635427522 | |
| SwordSlash3 | 119096744923720 | ใช้เป็นท่าตีของ Goblin ด้วย |
| Roll | 114548083139152 | ตัด root motion แนวราบออกใน client |
| GoblinDeath | 89394267292810 | ใช้เป็นท่าตายของ monster ทุกแบบ |
| Crawl | 80395659785739 | ท่าคลานตอนผู้เล่นล้ม |

ท่าง้างธนู ท่ายกโล่ของผู้เล่น และท่าเล็งของ monster ยิงไกลไม่ใช้คลิป animation — ตั้งมุมข้อต่อแขนโดยตรงใน `Client/BowAim.luau`, `Client/ShieldGuard.luau` และ `Client/MonsterPose.luau`

เสียง: ดู `ReplicatedStorage.Assets.Sounds` ใน Studio (id อยู่ใน SoundId ของแต่ละตัว) — ShieldBlock = 9125740352

## ทดสอบ

ผู้เล่นเกิดที่ Lobby (`Workspace.Lobby`, หลังป้อม Z≈330) กด **เล่น** เพื่อเข้าแมตช์ที่ป้อม จบแมตช์แล้วกลับ Lobby เอง
server นี้มีป้อมเดียว จึงเล่นได้ทีละแมตช์ (เฟส 4 ย้ายแมตช์ไป reserved server) ตั้ง attribute บน `Workspace` ก่อนกด Play ได้:

- `DebugUnlockAll` (bool) — เลือกด่านที่ยังไม่ปลดล็อคได้ (ใช้ได้เฉพาะใน Studio)
- `DebugWave` (number 1–5) — แมตช์ถัดไปเริ่มที่คลื่นนี้ (5 = Boss)

## ข้อมูลผู้เล่น (เฟส 3)

- DataStore `PlayerData_v1` คีย์ `Player_<UserId>` — Exp, Parts, Levels, Loadout, UnlockedStage (+ session lock)
- ทดสอบใน Studio ต้องเปิด **Game Settings → Security → Enable Studio Access to API Services** ไม่งั้นจะใช้โปรไฟล์ชั่วคราวและไม่เซฟ (มี warning ใน Output)
