-- MonsterPose: ท่าเล็งของ monster ยิงไกล (Skeleton Archer ง้างธนู, Goblin Musketeer ประทับปืน)
-- server ตั้ง attribute AimAt (Vector3) + AimKind ("Bow"/"Rifle") บนโมเดลระหว่างเล็ง
-- client แต่ละเครื่องตั้งมุมข้อต่อแขน/คอเองทุกเฟรม (หลัง animation) — ผู้เล่นจึงเห็นว่ากำลังถูกเล็งและหลบทัน
local RunService = game:GetService("RunService")

local MonsterPose = {}

local folder = workspace:WaitForChild("Monsters")
local rigs = setmetatable({}, { __mode = "k" }) -- [Model] = { joints..., Weight }

local JOINTS = {
	LeftShoulder = "LeftUpperArm",
	LeftElbow = "LeftLowerArm",
	LeftWrist = "LeftHand",
	RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm",
	RightWrist = "RightHand",
	Neck = "Head",
}

local function getRig(model)
	local rig = rigs[model]
	if rig then
		return rig
	end
	local upperTorso = model:FindFirstChild("UpperTorso")
	local head = model:FindFirstChild("Head")
	local rightHand = model:FindFirstChild("RightHand")
	if not upperTorso or not head or not rightHand then
		return nil
	end
	rig = { UpperTorso = upperTorso, Head = head, RightHand = rightHand, Joints = {}, Weight = 0 }
	for jointName, partName in JOINTS do
		local part = model:FindFirstChild(partName)
		rig.Joints[jointName] = part and part:FindFirstChild(jointName)
	end
	rigs[model] = rig
	return rig
end

-- การหมุนของชิ้นส่วนแขน: ปลายแขน (-Y) ชี้ไปทาง direction, ด้านหน้า (-Z) ชี้ใกล้ front ที่สุด
local function limbRotation(direction, front)
	local yAxis = -direction
	local zAxis = -front
	zAxis -= zAxis:Dot(yAxis) * yAxis
	if zAxis.Magnitude < 1e-3 then
		zAxis = Vector3.xAxis - Vector3.xAxis:Dot(yAxis) * yAxis
	end
	zAxis = zAxis.Unit
	return CFrame.fromMatrix(Vector3.zero, yAxis:Cross(zAxis), yAxis, zAxis)
end

local function pose(rig, jointName, parentRotation, desiredRotation)
	local joint = rig.Joints[jointName]
	if joint then
		local target = joint.C0.Rotation:Inverse() * parentRotation:Inverse() * desiredRotation * joint.C1.Rotation
		joint.Transform = joint.Transform:Lerp(target, rig.Weight)
	end
end

local function aimPose(rig, aimAt, kind)
	local offset = aimAt - rig.Head.Position
	if offset.Magnitude < 0.5 then
		return
	end
	local aim = offset.Unit
	local right = aim:Cross(Vector3.yAxis)
	if right.Magnitude < 0.01 then
		return
	end
	right = right.Unit
	local up = right:Cross(aim)
	local torso = rig.UpperTorso.CFrame.Rotation

	if kind == "Rifle" then
		-- มือขวาจับปืนหน้าอกขวา ลำกล้องชี้เป้า (ปืนเชื่อมกับมือขวา: ลำกล้อง = ด้านหน้าของมือ)
		local upperArm = limbRotation((right * 0.25 - up * 0.8 - aim * 0.3).Unit, aim)
		local foreArm = limbRotation((aim * 0.6 + up * 0.7 - right * 0.25).Unit, aim)
		local hand = CFrame.fromMatrix(Vector3.zero, up:Cross(-aim), up, -aim)
		pose(rig, "RightShoulder", torso, upperArm)
		pose(rig, "RightElbow", upperArm, foreArm)
		pose(rig, "RightWrist", foreArm, hand)

		-- มือซ้ายประคองใต้ลำกล้อง
		local leftShoulder = rig.Joints.LeftShoulder
		if leftShoulder then
			local shoulder = rig.UpperTorso.CFrame:PointToWorldSpace(leftShoulder.C0.Position)
			local support = rig.RightHand.Position + aim * 1.6 - up * 0.2
			local supportArm = limbRotation((support - shoulder).Unit, up)
			pose(rig, "LeftShoulder", torso, supportArm)
			pose(rig, "LeftElbow", supportArm, supportArm)
			pose(rig, "LeftWrist", supportArm, supportArm)
		end
	else
		-- ธนู: แขนซ้ายเหยียดถือคันธนูชี้เป้า แขนขวางอศอกดึงสาย
		local bowArm = limbRotation(aim, up)
		pose(rig, "LeftShoulder", torso, bowArm)
		pose(rig, "LeftElbow", bowArm, bowArm)
		pose(rig, "LeftWrist", bowArm, bowArm)
		local upperArm = limbRotation((-aim * 0.25 + right * 0.7 + up * 0.35).Unit, up)
		local foreArm = limbRotation((aim * 0.95 - right * 0.55 + up * 0.2).Unit, up)
		pose(rig, "RightShoulder", torso, upperArm)
		pose(rig, "RightElbow", upperArm, foreArm)
		pose(rig, "RightWrist", foreArm, foreArm)
	end
	pose(rig, "Neck", torso, CFrame.lookAt(Vector3.zero, aim))
end

RunService.Stepped:Connect(function(_, dt)
	for _, model in folder:GetChildren() do
		local aimAt = model:GetAttribute("AimAt")
		local rig = (aimAt or rigs[model]) and getRig(model)
		if rig then
			rig.Weight += ((aimAt and 1 or 0) - rig.Weight) * math.min(1, dt * 12)
			if aimAt then
				rig.LastAim = aimAt
			end
			if rig.Weight > 0.02 and rig.LastAim then
				aimPose(rig, rig.LastAim, model:GetAttribute("AimKind"))
			end
		end
	end
end)

return MonsterPose
