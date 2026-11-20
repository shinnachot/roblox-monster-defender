-- Progression: กติกา rank / ปลดล็อค / อัพเกรด / loadout (GDD ข้อ 3-5)
-- เป็นฟังก์ชันบริสุทธิ์ ใช้ได้ทั้ง server (ตัดสินจริง) และ client (แสดงผลใน UI)
local Config = require(script.Parent.GameConfig)

local Progression = {}

local rankIndexById = {}
for index, rank in Config.Ranks do
	rankIndexById[rank.Id] = index
end

function Progression.RankIndex(exp)
	local found = 1
	for index, rank in Config.Ranks do
		if exp >= rank.MinExp then
			found = index
		end
	end
	return found
end

function Progression.Rank(exp)
	return Config.Ranks[Progression.RankIndex(exp)]
end

-- rank ถัดไป (nil ถ้าสูงสุดแล้ว)
function Progression.NextRank(exp)
	return Config.Ranks[Progression.RankIndex(exp) + 1]
end

-- เพิ่ม/ลด EXP โดยไม่ให้ต่ำกว่าขั้นต่ำของ rank ปัจจุบัน (ตกแรงก์ไม่ได้)
function Progression.ApplyExp(exp, delta)
	return math.max(exp + delta, Progression.Rank(exp).MinExp)
end

function Progression.IsUnlocked(itemId, exp)
	local item = Config.Items[itemId]
	return item ~= nil and Progression.RankIndex(exp) >= rankIndexById[item.Rank]
end

-- id ไอเท็มที่ปลดล็อคแล้ว (onlyUpgradable = เฉพาะที่มีชิ้นส่วน) เรียงตาม Order
function Progression.UnlockedItems(exp, onlyUpgradable)
	local list = {}
	for id, item in Config.Items do
		if Progression.IsUnlocked(id, exp) and (not onlyUpgradable or item.Upgradable) then
			table.insert(list, id)
		end
	end
	table.sort(list, function(a, b)
		return Config.Items[a].Order < Config.Items[b].Order
	end)
	return list
end

-- ชิ้นส่วนที่ต้องใช้อัพจากเลเวลนี้ (nil = เลเวลเต็มหรืออัพไม่ได้)
function Progression.UpgradeCost(itemId, level)
	local item = Config.Items[itemId]
	if not item or not item.Upgradable then
		return nil
	end
	return Config.Upgrade.Costs[level + 1]
end

function Progression.MaxLevel()
	return #Config.Upgrade.Costs
end

-- ตัวคูณจากเลเวลอัพเกรด (อาวุธ = ดาเมจ, เกราะ = ค่าเกราะ)
function Progression.Bonus(level)
	return 1 + (level or 0) * Config.Upgrade.BonusPerLevel
end

function Progression.LoadoutCost(loadout)
	local total = 0
	for _, id in loadout do
		local item = Config.Items[id]
		total += item and item.Cost or 0
	end
	return total
end

-- ตรวจ loadout: ไอเท็มมีจริง + ปลดล็อคแล้ว, ไม่ซ้ำ (ยกเว้น Repeatable), เกราะไม่เกิน 1 ชุด,
-- อาวุธ 1..MaxWeapons ชิ้น, ลูกธนูต้องคู่กับธนู (มีธนู = อย่างน้อย 1 ชุด), แต้มไม่เกิน Points
-- คืน (true) หรือ (false, เหตุผล)
function Progression.ValidateLoadout(loadout, exp)
	if typeof(loadout) ~= "table" or #loadout > 20 then
		return false, "Invalid"
	end
	local seen, weapons, armors, ammo = {}, 0, 0, 0
	for _, id in loadout do
		local item = typeof(id) == "string" and Config.Items[id]
		if not item then
			return false, "UnknownItem"
		end
		if not Progression.IsUnlocked(id, exp) then
			return false, "Locked"
		end
		if item.Available == false then
			return false, "Unavailable"
		end
		if seen[id] and not item.Repeatable then
			return false, "Duplicate"
		end
		seen[id] = true
		if item.Kind == "Weapon" then
			weapons += 1
		elseif item.Kind == "Armor" then
			armors += 1
		elseif item.Kind == "Ammo" then
			ammo += 1
		end
	end
	if ammo > 0 and not seen.Bow then
		return false, "NeedsBow"
	end
	if seen.Bow and ammo == 0 then
		return false, "NoArrows"
	end
	if weapons < 1 or weapons > Config.Loadout.MaxWeapons then
		return false, "Weapons"
	end
	if armors > 1 then
		return false, "Armor"
	end
	if Progression.LoadoutCost(loadout) > Config.Loadout.Points then
		return false, "Points"
	end
	return true
end

-- ปรับ loadout เก่าให้เข้ากติกาลูกธนู: ไม่มีธนู -> ตัดลูกธนูทิ้ง, มีธนูแต่ไม่มีลูกธนู -> เติม 1 ชุด
function Progression.NormalizeLoadout(loadout)
	local hasBow = table.find(loadout, "Bow") ~= nil
	local out, ammo = {}, 0
	for _, id in loadout do
		local item = Config.Items[id]
		if item and item.Kind == "Ammo" then
			if not hasBow then
				continue
			end
			ammo += 1
		end
		table.insert(out, id)
	end
	if hasBow and ammo == 0 then
		table.insert(out, "ExtraArrows")
	end
	return out
end

-- แปลง loadout (รายการ id) เป็นชุดอุปกรณ์ที่ใช้ในเกม
-- คืน { Weapons = {id...} ตามลำดับปุ่ม 1-5, Arrows, Armor = id|nil, Shield = bool, Potions,
--       DamageBonus = {[weaponId]=ตัวคูณ}, ArmorDurability }
function Progression.BuildKit(loadout, levels)
	levels = levels or {}
	local kit = { Weapons = {}, Arrows = 0, Armor = nil, Shield = false, Potions = 0, DamageBonus = {}, ArmorDurability = 0 }
	for _, id in loadout do
		local item = Config.Items[id]
		if not item then
			continue
		end
		if item.Kind == "Weapon" then
			table.insert(kit.Weapons, id)
			kit.DamageBonus[id] = Progression.Bonus(levels[id])
			-- อาวุธที่มาคู่กับโล่ (ดาบโล่) ได้โล่ด้วยเสมอ
			local weapon = Config.Weapons[id]
			kit.Shield = kit.Shield or (weapon ~= nil and weapon.Shield ~= nil)
		elseif item.Kind == "Armor" then
			kit.Armor = id
			local armor = Config.Armors[id]
			kit.ArmorDurability = armor and math.round(armor.Durability * Progression.Bonus(levels[id])) or 0
		elseif item.Kind == "Ammo" then
			kit.Arrows += item.Arrows
		elseif item.Kind == "Consumable" then
			kit.Potions += item.Charges
		end
	end
	return kit
end

-- สุ่มรางวัลหลังแมตช์: คืน { Exp = ค่าใหม่, ExpDelta, Parts = { [id] = จำนวน }, UnlockedStage }
-- ชิ้นส่วนสุ่มเฉพาะไอเท็มที่ปลดล็อคแล้วและอัพเกรดได้ (คิดจาก rank ก่อนได้ EXP รอบนี้)
function Progression.RollMatchReward(exp, unlockedStage, stage, won, rng)
	local rule = won and Config.Rewards.Win or Config.Rewards.Lose
	local pool = Progression.UnlockedItems(exp, true)
	local parts = {}
	for _ = 1, rng:NextInteger(rule.Parts[1], rule.Parts[2]) do
		local id = pool[rng:NextInteger(1, #pool)]
		parts[id] = (parts[id] or 0) + 1
	end
	local newExp = Progression.ApplyExp(exp, rule.ExpPerStage * stage)
	local newUnlocked = unlockedStage
	if won then
		newUnlocked = math.max(unlockedStage, math.min(stage + 1, #Config.Waves.Stages))
	end
	return {
		Exp = newExp,
		ExpDelta = newExp - exp,
		Parts = parts,
		UnlockedStage = newUnlocked,
	}
end

return Progression
