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
| หีบรางวัล (`ReplicatedStorage.Assets.Props.RewardChest` — Base + Lid, หมุนฝารอบ attachment `Base.Hinge`) | 17269605532 |
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

ผู้เล่นเกิดที่ Lobby (`Workspace.Lobby`, หลังป้อม Z≈330) กด **เล่น** (K) — ทีมไม่ครบ 3 คนจะหาผู้เล่นเพิ่ม 30 วิ (กด K อีกครั้ง = เริ่มเลย, X = ยกเลิก)
ใน Studio teleport ไม่ได้ จึงเล่นแมตช์ในป้อมของ server เดียวกันแทน (ทีละแมตช์) แล้วกลับ Lobby เอง ตั้ง attribute บน `Workspace` ก่อนกด Play ได้:

- `DebugMatchServer` (number = stage) — ทำตัวเป็น server แมตช์ (reserved): เกิดที่ป้อม, รอทีม 3 วิ แล้วเริ่ม; จบแล้วกลับ Lobby ในที่เดิม (ไม่มี teleport) — **ลบออกหลังทดสอบ**
- `DebugUnlockAll` (bool) — เลือกด่านที่ยังไม่ปลดล็อคได้ (ใช้ได้เฉพาะใน Studio)
- `DebugWave` (number 1–5) — แมตช์ถัดไปเริ่มที่คลื่นนี้ (5 = Boss)
- `DebugGrantParts` / `DebugGrantExp` (number) — ตั้งระหว่าง Play เพื่อแจกชิ้นส่วน (ทุกไอเท็มที่ปลดล็อค) / EXP ให้ทุกคน (เฉพาะใน Studio)
- จบแมตช์เร็ว ๆ: ระหว่างแมตช์ตั้ง attribute `HP` = 0 บน `Workspace.Map.Base` (แพ้ทันที)
- หน้าเปิดหีบ (`Client/RewardUi`) เด้งเองหลังกลับ Lobby — ลองหน้าตาโดยไม่ต้องเล่นจบ: จาก server ยิง `Remotes.MatchRewards:FireClient(player, summary)` ด้วย summary ปลอม (ExpBefore/Exp ข้าม 500 เพื่อดู rank up)

## ข้อมูลผู้เล่น (เฟส 3)

- DataStore `PlayerData_v1` คีย์ `Player_<UserId>` — Exp, Parts, Levels, Loadout, UnlockedStage (+ session lock)
- ทดสอบใน Studio ต้องเปิด **Game Settings → Security → Enable Studio Access to API Services** ไม่งั้นจะใช้โปรไฟล์ชั่วคราวและไม่เซฟ (มี warning ใน Output)

## Multiplayer (เฟส 4)

- place เดียวกันทั้ง Lobby และแมตช์: reserved server (`PrivateServerId ~= ""`, `PrivateServerOwnerId == 0`) = server แมตช์ — `Server/Modules/ServerMode`
- ข้อมูลแมตช์ (stage, ผู้เล่นที่จะมา, ทีมเดิม) เก็บใน MemoryStore HashMap `MatchInfo_v1` คีย์ = PrivateServerId (ไม่ใช้ TeleportData ขาเข้าเพราะ client ปลอมได้)
- ทีม/คำชวน: `PartyService` + `Client/PartyUi` (P = หน้าทีม, Y/N = ตอบคำชวน); คนที่เข้าเกมตามเพื่อน (FollowUserId) ได้คำชวนจากเพื่อนเอง
- หาผู้เล่นข้าม server: `MatchmakingService` — SortedMap `MMQueue_v1_S<stage>`; ทีมที่เข้าคิวก่อน "จอง" ทีมที่มาทีหลัง (UpdateAsync) แล้วจอง server ให้ทุกทีม
- จบแมตช์: teleport ทุกคนกลับ public server พร้อม TeleportData (`Rewards` ให้หน้าเปิดหีบ, `Parties` รวมทีมเดิมให้เอง) — รางวัลจริงเซฟที่ server แมตช์แล้ว
- ทดสอบ teleport/matchmaking ของจริงต้อง **Publish** แล้วเล่นจากเว็บ/แอป (Studio teleport ไม่ได้) — ลองด้วย 2–3 บัญชี
