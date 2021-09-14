
svac = class( nil )
svac.maxParentCount = 1
svac.maxChildCount = 2
svac.connectionInput = sm.interactable.connectionType.power + sm.interactable.connectionType.logic
svac.connectionOutput = sm.interactable.connectionType.bearing
svac.colorNormal = sm.color.new( 0x9900ffff )
svac.colorHighlight = sm.color.new( 0xcc33ffff )

svac.speedTbl =   {0, 1, 2, 3, 4, 6, 8, 10, 15, 20, 25, 35, 45, 55, 75, 95, 115}
svac.impulseBase = 1000
svac.targetTolarence2 = sm.vec3.new( 0.1, 0.1, 0.1 ):length2()
svac.sendSpeedWaitMaxSec = 5
svac.calWaitMaxSec = 1
svac.angleDiff = 0.01 * math.pi

--Server--
function svac.server_onCreate( self )
	self.interactable:setActive(false)
	self.lastActive = false
	
	local curBearingTbl = self.interactable:getBearings()
	
	local ldData = self.storage:load()
	print ("svac init load: ", ldData)
	if ldData == nil then
		-- all new init
		self.speedIndex = 8
		self.speed = self.speedTbl[self.speedIndex]
		self.bearingTbl = curBearingTbl
		self.calTbl = nil
		
		self.storage:save({speedIndex = self.speedIndex, bearingTbl = self.bearingTbl, calTbl = self.calTbl})
	else
		self.speedIndex = ldData.speedIndex
		self.speed = self.speedTbl[self.speedIndex]
		if not bearingTblEq(curBearingTbl, ldData.bearingTbl) then
			print ("WARN svac loaded bearing table not match current ")
			self.bearingTbl = curBearingTbl
			self.calTbl = nil
		else
			self.bearingTbl = ldData.bearingTbl
			self.calTbl = ldData.calTbl
		end
	end
	
	self.network:sendToClients("client_setUiIdx", self.speedIndex)
	
	self.lastTarget = nil
	self.lastTargetTime = 0
	
end

function bearingTblEq(ta, tb)
	-- print ("bearingTblEq 1-", ta," 2-", tb)
	if ta == nil then
		do return (tb == nil) end
	end
	if tb == nil then
		do return (ta == nil) end
	end
	if #ta ~= #tb then
		do return false end
	end
	for i, bearing in pairs(ta) do
		if bearing.id ~= tb[i].id then
			do return false end
		end
	end
	return true
end

function svac.server_onRefresh( self )
	self:server_onCreate()
end



function svac.server_request( self )
	self.network:sendToClients("client_setUiIdx", self.speedIndex)
end

function svac.sv_speedChange( self, speedIndex )
	self.speedIndex = speedIndex
	self.speed = self.speedTbl[self.speedIndex]
	self.storage:save({speedIndex = self.speedIndex, bearingTbl = self.bearingTbl, calTbl = self.calTbl})
	self.network:sendToClients("client_setUiIdx", self.speedIndex)
end

function svac.server_onFixedUpdate( self, dt )
	local curBearingTbl = self.interactable:getBearings()
	if not bearingTblEq(curBearingTbl, self.bearingTbl) then
		-- new bearing set, should calibrate again
		self.bearingTbl = curBearingTbl
		self.calTbl = nil
	end

	local nowActive = false
	Parent = self.interactable:getSingleParent()
	if Parent then
		if  Parent:isActive() == true then
			nowActive	= true
			self.interactable:setActive(true)
		else
			nowActive = false
			self.interactable:setActive(false)
		end
		-- TODO should be the player who activates the parent
		Player = server_getNearestPlayer(Parent:getShape():getWorldPosition())
	else
		self.interactable:setActive(false)
		Player = server_getNearestPlayer(self.shape:getWorldPosition())
	end
	
	if Player == nil then
		print ("Error svac player not found")
		do return end
	end
	PlayerID = Player:getId()
	self.network:sendToClients("cl_OnOff", PlayerID )
	
	if self.bearingTbl == nil or #self.bearingTbl <= 0 then
		-- print ("svac have no bearing to control")
		do return end
	end
	
	-- lock up
	if nowActive == false or self.speed <= 0 then
		for _, bearing in pairs(self.bearingTbl) do
			bearing:setMotorVelocity(0, svac.impulseBase + self.speed * 10)
		end
		do return end
	end
	
	-- below is code for active and have bearing
	
	local playerVec = Player.character:getDirection()
	
	
	local PlayerDir = directionCalculation(playerVec)
	local ObjectDir = directionCalculation(self.shape.up)
	
	
	------ show player debug
	--local printStr = "debug player view: "..fmtStr(PlayerDir.ADDeg)..", "..fmtStr(PlayerDir.WSDeg)..
	--	"player vec: "..fmtStr(playerVec.x)..", "..fmtStr(playerVec.y)..", "..fmtStr(playerVec.z)
	-- print("debug player view: ", PlayerDir, "player vec: ", playerVec)
	--self.network:sendToClients("cli_debug", printStr)
	
	if self.calTbl == nil then
		-- do calibration
		
		if #self.bearingTbl <= 0 or #self.bearingTbl > 2 then
			print ("[Error]svac calibration unexpected bearing number: ", #self.bearingTbl)
			do return end
		elseif #self.bearingTbl == 1 then
			--------one bearing --------
			print ("svac calibration start for single bearing")
			if self.calStep == nil then
				self.calStep = 1
				self.calStartAngle = self.bearingTbl[1]:getAngle()
				self.calStartObjDir = ObjectDir
				self.calTargetAngleDif = svac.angleDiff * 1.3
				local tryAngle = angleRangeRound(self.calStartAngle + self.calTargetAngleDif)
				cal_setAngle(self.bearingTbl, tryAngle, self.speed / 10, 1)
				self.calWaitTime = 0
				print ("svac calibration first init, try angle: ", tryAngle)
				do return end
			end
			local curAngle = self.bearingTbl[1]:getAngle()
			local angleDiff = math.abs(angleRangeRound(curAngle - self.calStartAngle))
			local calWaitAbort = false
			if angleDiff < svac.angleDiff then
				-- not enough, continue wait
				self.calWaitTime = self.calWaitTime + dt
				print ("svac calibration wait for moving, cur angle and time: ", curAngle, self.calWaitTime)
				if self.calWaitTime <= svac.calWaitMaxSec then
					do return end
				else
					-- wait too long
					if self.calTargetAngleDif > 0 then
						self.calStartAngle = self.bearingTbl[1]:getAngle()
						self.calStartObjDir = ObjectDir
						self.calTargetAngleDif = -self.calTargetAngleDif
						local tryAngle = angleRangeRound(self.calStartAngle + self.calTargetAngleDif)
						cal_setAngle(self.bearingTbl, tryAngle, self.speed / 10, 1)
						self.calWaitTime = 0
						print ("svac calibrate trying the other direction. [curAngle, targetAngle]:", self.calStartAngle, tryAngle)
						do return end
					else
						print ("svac calibrate failed in both direction. [calStartAngle, calTargetAngleDif]", self.calStartAngle, self.calTargetAngleDif)
						calWaitAbort = true
					end
				end
			end
		
			-- enough diff, do calibrate
			self.calTmpTbl = {}
			if calWaitAbort then
				self.calTmpTbl[1] = {wsRate = 0, adRate = 0}
			else
				self.calTmpTbl[1] = calibrateAngle(ObjectDir, self.calStartObjDir, curAngle, self.calStartAngle)
			end
			print ("svac calibration fin cal step, calTmpTbl: ", self.calTmpTbl)
			-- only one bearing, this is end of calibration
		elseif #self.bearingTbl == 2 then
			-- print ("svac calibration for two bearing")
			-----------two bearing 
			-- calRecord = {allbearing:getAngle(),  ObjectDir} = {b1,b2, Ox,Oy}
			-- init: bn = bearingNumber,  start_record = cur_record
			--       [b1, b2] start direction [random] (distance 0.03*math.pi)
			-- get diff1:	moved_vector = cur[b1, b2] - st_re[b1,b2]
			--  			if distance(moved_vector) > 0.03*math.pi then new direction vertical to moved_vector, diff1=moved_vector
			--  			else wait diff1 time ++ if time > tolarence, new direction= [random] (distance 0.03*math.pi)
			-- get diff2:	moved_vector = cur[b1,b2] - st_re[b1,b2], div = abs(mv[b1]*diff1[b2] - mv[b2]*diff1[b1])
			--  			if div > ... then cal result
			--  			else wait diff2 time ++ if time > tolarence and direction tried once, new direction= -old_direction
			--  									else if both dircetion tried, direction= [random]... , fall back to get diff1
			--  				
			
			
			
			local curAngle = {self.bearingTbl[1]:getAngle(), self.bearingTbl[2]:getAngle()}
			
			if self.calStep == nil then
				-- start to get diff1
				self.calStep = 1
				self.calStartAngle = {self.bearingTbl[1]:getAngle(), self.bearingTbl[2]:getAngle()}
				self.calStartObjDir = ObjectDir
				local randTarget = randomAngleDirection(self.calStartAngle, svac.angleDiff * 1.3)
				self.calCurTarget = randTarget
				setTwoBearingTarget(self.bearingTbl, self.calCurTarget, self.speed / 10, curAngle)
				self.calWaitTime = 0
				print ("svac calibration 2D first init. start, target:", self.calStartAngle, randTarget)
				do return end
			elseif self.calStep == 1 then
				-- diff1 wait
				
				
				-- repeat
				setTwoBearingTarget(self.bearingTbl, self.calCurTarget, self.speed / 10, curAngle)
				
				local angleDiffVector = twoAngleVector(curAngle, self.calStartAngle)
				local angleDiff2 = angleVectorLength2(angleDiffVector)
				if angleDiff2 < svac.angleDiff * svac.angleDiff then
					-- not enough, continue wait
					self.calWaitTime = self.calWaitTime + dt
					print ("svac calibration diff1 wait for moving, cur angle and time: ", curAngle, self.calWaitTime)
					if self.calWaitTime <= svac.calWaitMaxSec then
						do return end
					else
						-- wait too long
						print ("svac calibration wait diff1 too long, restart diff1 finding ", curAngle, self.calWaitTime)
						self.calStep = nil
						do return end
					end
				end
				-- enough angle diff
				
				self.calThetaAB1 = angleDiffVector
				self.calDeltaXY1 = ObjDirVector(ObjectDir, self.calStartObjDir)
				print ("svac calibration diff1 enough, recording tAB1, dXY1:", self.calThetaAB1, self.calDeltaXY1)
				
				
				self.calStep = 2
				self.calStartAngle = curAngle
				self.calStartObjDir = ObjectDir
				self.calWaitTime = 0
				self.calDiff2Direction = verticalDirectionVector(angleDiffVector, 1.5)
				self.calDiff2TryingDir = 1
				local diff2Target = vectorAdd(curAngle, self.calDiff2Direction)
				self.calCurTarget = diff2Target
				setTwoBearingTarget(self.bearingTbl, self.calCurTarget, self.speed / 10, curAngle)
				print ("svac calibration start diff2 try 1st direction. direction, target:", self.calDiff2Direction, diff2Target)
				do return end
			elseif self.calStep == 2 then
				-- diff2 wait
				
				-- repeat
				setTwoBearingTarget(self.bearingTbl, self.calCurTarget, self.speed / 10, curAngle)
				
				-- div = ta1 * tb2 - ta2 * tb1. (eq to tab2's sine projection to tab1)
				local calThetaAB2 = twoAngleVector(curAngle, self.calStartAngle)
				local calThetaAB1 = self.calThetaAB1
				local calDiv = calThetaAB1[1] * calThetaAB2[2] - calThetaAB2[1] * calThetaAB1[2]
				if math.abs(calDiv) < svac.angleDiff * svac.angleDiff then
					-- not enough, continue wait
					self.calWaitTime = self.calWaitTime + dt
					print ("svac calibration diff2 wait for moving, cur angle, div, target, time: ", curAngle, calDiv, self.calCurTarget, self.calWaitTime)
					if self.calWaitTime <= svac.calWaitMaxSec then
						do return end
					elseif self.calDiff2TryingDir == 1 then
						-- wait too long and only tried one direction
						print ("svac calibration wait diff2 too long, try the other direction ", curAngle, self.calWaitTime)
						
						self.calStartAngle = curAngle
						self.calStartObjDir = ObjectDir
						self.calWaitTime = 0
						self.calDiff2Direction = otherVecotrDirection(self.calDiff2Direction)
						self.calDiff2TryingDir = 2
						local diff2Target = vectorAdd(curAngle, self.calDiff2Direction)
						self.calCurTarget = diff2Target
						setTwoBearingTarget(self.bearingTbl, self.calCurTarget, self.speed / 10, curAngle)
						print ("svac calibration start diff2 try 2nd direction. direction, target:", self.calDiff2Direction, diff2Target)
						
						do return end
					else
						
						-- wait too long and tried both direction
						print ("svac calibration wait diff2 too long and tried both direction, restart diff1 finding ", curAngle, self.calWaitTime)
						self.calStep = nil
						do return end
					end
				end
				
				-- calDiv big enough, do cal
				self.calTmpTbl = {}
				self.calTmpTbl[1] = {}
				self.calTmpTbl[2] = {}
				-- div = ta1 * tb2 - ta2 * tb1. (eq to tab2's sine projection to tab1)
				-- Ax = (tb2 * dx1 - tb1 * dx2) / div
				-- Ay = (tb2 * dy1 - tb1 * dy2) / div
				-- Bx = (ta1 * dx2 - ta2 * dx1) / div
				-- By = (ta1 * dy2 - ta2 * dy1) / div
				-- calThetaAB1 calThetaAB2
				-- self.calDeltaXY1 = ObjDirVector(ObjectDir, self.calStartObjDir)
				local calDeltaXY1 = self.calDeltaXY1
				local calDeltaXY2 = ObjDirVector(ObjectDir, self.calStartObjDir)
				
				local calThetaA1 = calThetaAB1[1]
				local calThetaB1 = calThetaAB1[2]
				local calThetaA2 = calThetaAB2[1]
				local calThetaB2 = calThetaAB2[2]
				
				local calDeltaX1 = calDeltaXY1[1]
				local calDeltaY1 = calDeltaXY1[2]
				local calDeltaX2 = calDeltaXY2[1]
				local calDeltaY2 = calDeltaXY2[2]
				self.calTmpTbl[1].wsRate = (calThetaB2 * calDeltaX1 - calThetaB1 * calDeltaX2) / calDiv -- Ax
				self.calTmpTbl[1].adRate = (calThetaB2 * calDeltaY1 - calThetaB1 * calDeltaY2) / calDiv -- Ay
				self.calTmpTbl[2].wsRate = (calThetaA1 * calDeltaX2 - calThetaA2 * calDeltaX1) / calDiv -- Bx
				self.calTmpTbl[2].adRate = (calThetaA1 * calDeltaY2 - calThetaA2 * calDeltaY1) / calDiv -- By
				
				print ("svac calibration fin 2d cal, calTmpTbl: ", self.calTmpTbl)
				-- this is end of 2d calibration step 2
			else
				print ("[Error] unexpected 2d cal step: ", self.calStep)
				do return end
			end
			-- this is end of 2d calibration
		end
		
		
		-- this is end of calibration, use self.calTmpTbl[] to do choices
		local reCalTbl = {}
		local adChoice = bestAdIdx(self.calTmpTbl)
		if adChoice == nil then
			reCalTbl.adChoice = nil
		else
			reCalTbl.adChoice = adChoice
			reCalTbl.adRate = self.calTmpTbl[adChoice].adRate
			self.calTmpTbl[adChoice].wsRate = 0 -- dont choose the same bearing for ws and ad
		end
		local wsChoice = bestWsIdx(self.calTmpTbl)
		if wsChoice == nil then
			reCalTbl.wsChoice = nil
		else
			reCalTbl.wsChoice = wsChoice
			reCalTbl.wsRate = self.calTmpTbl[wsChoice].wsRate
		end
		
		self.calTbl = reCalTbl
		self.calTmpTbl = nil
		self.calStep = nil
		self.storage:save({speedIndex = self.speedIndex, bearingTbl = self.bearingTbl, calTbl = self.calTbl})
		print ("svac calibration fin calibration, choices of ws,ad: ", wsChoice, adChoice)
		print ("svac calibration fin calibration, calTbl: ", self.calTbl)
		do return end
	
	else
	
		-- have cal table, make speed decision
		local targetSpeed = {}
		for i, _ in pairs(self.bearingTbl) do
			-- bearing:setMotorVelocity(0, svac.impulseBase + self.speed * 10)
			targetSpeed[i] = {useSpeed = true, value = 0}
		end
		
		
		local wsDiff = ObjectDir.WSDeg - PlayerDir.WSDeg
		local adDiff = ObjectDir.ADDeg - PlayerDir.ADDeg
		if math.abs(adDiff) > 1.5 * math.pi then
			adDiff = angleRangeRound(adDiff)
		end
		--print(WSDeg)
		
		local sendingSpeed = false
		if math.abs(wsDiff) > 0.01 and self.calTbl.wsChoice ~= nil then
			sendingSpeed = true
			local wsChoice = self.calTbl.wsChoice
			--if math.abs(wsDiff) < 0.5 * math.pi then
				local dSpeed = speedByAngleDiff(wsDiff) * self.speed
				if self.calTbl.wsRate * wsDiff < 0 then
					dSpeed = -dSpeed
				end
				targetSpeed[wsChoice].value = dSpeed
			--else
			--	targetSpeed[wsChoice].useSpeed = false
			--	targetSpeed[wsChoice].value = (self.calTbl.wsRate * wsDiff + self.bearingTbl[wsChoice]:getAngle())
			--end
		end
		if math.abs(adDiff) > 0.01 and self.calTbl.adChoice ~= nil then
			sendingSpeed = true
			local adChoice = self.calTbl.adChoice
			--if math.abs(adDiff) < 0.5 * math.pi then
				local dSpeed = speedByAngleDiff(adDiff) * self.speed
				if self.calTbl.adRate * adDiff < 0 then
					dSpeed = -dSpeed
				end
				targetSpeed[adChoice].value = dSpeed
			--else
			--	targetSpeed[adChoice].useSpeed = false
			--	targetSpeed[adChoice].value = (self.calTbl.adRate * adDiff + self.bearingTbl[adChoice]:getAngle())
			--end
		end
		
		if sendingSpeed then
			print ("svac calibration speed decision.[wsDiff, adDiff, wsChoice, adChoice, speed]:", 
					wsDiff, adDiff, self.calTbl.wsChoice, self.calTbl.adChoice, targetSpeed)
		end
		
		for i, bearing in pairs(self.bearingTbl) do
			if targetSpeed[i].useSpeed then
				local vDir = 1
				if bearing:isReversed() == true then
					vDir = -1
				end
				bearing:setMotorVelocity(targetSpeed[i].value * vDir, svac.impulseBase + self.speed * 10)
			else
				bearing:setTargetAngle(targetSpeed[i].value, self.speed, svac.impulseBase + self.speed * 10)
			end
		end
		
		
		-- check last target
		if self.lastTarget == nil then
			self.lastTarget = playerVec
			self.lastTargetTime = 0
		elseif sendingSpeed == true and (self.lastTarget - playerVec):length2() <= svac.targetTolarence2 then
			self.lastTargetTime = self.lastTargetTime + dt
			print ("svac target delay add.. current: ", self.lastTargetTime)
			if self.lastTargetTime >= svac.sendSpeedWaitMaxSec then
				print ("[WARN] svac wait too long for reach target, restart calibration")
				self.lastTarget = playerVec
				self.lastTargetTime = 0
				self.calTbl = nil
			end
		else
			self.lastTarget = playerVec
			self.lastTargetTime = 0
		end
	
	end
	
	
	
	
	self.lastActive = self.interactable:isActive()
end



function fmtStr(num)
	return string.format("%.2f", num)
end

function randomAngleDirection(start_pos, dlength)
	local randAngle = sm.noise.randomRange( -math.pi, math.pi )
	return {start_pos[1] + math.cos(randAngle) * dlength, start_pos[2] + math.sin(randAngle) * dlength}
end
function setTwoBearingTarget(bearingTbl, targets, speed, curAngle)
	--bearingTbl[1]:setTargetAngle(targets[1], speed, svac.impulseBase + speed * 10)
	--bearingTbl[2]:setTargetAngle(targets[2], speed, svac.impulseBase + speed * 10)
	for i, bearing in pairs(bearingTbl) do
		local direction = 1
		if bearing:isReversed() == true then
			direction = -1
		end
		if (targets[i] - curAngle[i]) * direction > 0 then
			bearing:setMotorVelocity(speed, svac.impulseBase + speed * 10)
		else
			bearing:setMotorVelocity(-speed, svac.impulseBase + speed * 10)
		end
	end
end

function twoAngleVector(angles1, angles2)
	return {angleRangeRound(angles1[1] - angles2[1]), angleRangeRound(angles1[2] - angles2[2])}
end

function ObjDirVector(ObjDir1, ObjDir2)
	return {angleRangeRound(ObjDir1.WSDeg - ObjDir2.WSDeg), angleRangeRound(ObjDir1.ADDeg - ObjDir2.ADDeg)}
end
			
			
function angleVectorLength2(angleVector)
	return math.pow(angleVector[1], 2) + math.pow(angleVector[2], 2)
end


function verticalDirectionVector(inVector, times)
	return {-inVector[2] * times, inVector[1] * times}
end
function vectorAdd(vec1, vec2)
	return {vec1[1] + vec2[1], vec1[2] + vec2[2]}
end

function otherVecotrDirection(dir)
			return {-dir[1], -dir[2]}
end


function server_getNearestPlayer( position )
	local nearestPlayer = nil
	local nearestDistance = nil
	for id,Player in pairs(sm.player.getAllPlayers()) do
		if Player.character then
			local length2 = sm.vec3.length2(position - Player.character:getWorldPosition())
			if nearestDistance == nil or length2 < nearestDistance then
				nearestDistance = length2
				nearestPlayer = Player
			end
			--print(nearestPlayer)
		end
	end
	
	if nearestPlayer then
		return nearestPlayer
	else
		return nil
	end
end

function angleRangeRound(angle)
	if math.abs(angle) > math.pi then
		local angleAddOne = angle / math.pi + 1
		while angleAddOne < 0 do
			angleAddOne = angleAddOne + 2
		end
		angleAddOne = angleAddOne % 2
		angle = (angleAddOne - 1) * math.pi
	end
	return angle
end

function cal_setAngle(bearingTbl, tryAngle, speed, curStep)
	for i, bearing in pairs(bearingTbl) do
		if i ~= curStep then
			bearing:setMotorVelocity(0, svac.impulseBase + speed * 10)
		else
			bearing:setTargetAngle(tryAngle, speed, svac.impulseBase + speed * 10)
		end
	end
end 


function directionCalculation( direction )
	local Degree = {}
	--Degree.WSDeg = math.acos(direction.z) * 2 - math.pi
	Degree.WSDeg = math.acos(direction.z)
	Degree.ADDeg = math.atan2(direction.y,direction.x)
	
	return Degree
end

function calibrateAngle(objDir1, objDir2, angle1, angle2)
	local wsDiff = angleRangeRound(objDir1.WSDeg - objDir2.WSDeg)
	local adDiff = angleRangeRound(objDir1.ADDeg - objDir2.ADDeg)
	local angelDiff = angleRangeRound(angle1 - angle2)
	return {wsRate = wsDiff / angelDiff, adRate = adDiff / angelDiff}
end

function bestAdIdx(cal_tmp_tbl)
	local bestIdx = nil
	local curBestRate = 0
	for idx, item in pairs(cal_tmp_tbl) do
		local thisAbsRate = math.abs(item.adRate)
		if thisAbsRate > 0.001 and thisAbsRate > curBestRate then
			bestIdx = idx
			curBestRate = thisAbsRate
		end
	end
	return bestIdx
end

function bestWsIdx(cal_tmp_tbl)
	local bestIdx = nil
	local curBestRate = 0
	for idx, item in pairs(cal_tmp_tbl) do
		local thisAbsRate = math.abs(item.wsRate)
		if thisAbsRate > 0.001 and thisAbsRate > curBestRate then
			bestIdx = idx
			curBestRate = thisAbsRate
		end
	end
	return bestIdx
end

function speedByAngleDiff(angleDiff)
	local angleRate = math.abs(angleDiff) / math.pi
	local speedRate = 0
	local angleRateThd = 0.7
	local angleRateTar = 0.5
	if angleRate > angleRateThd then
		-- too close to edge, slow down in case of frequent reverting
		speedRate = angleRateThd - (angleRateThd - angleRateTar) / (1 - angleRateThd) * (angleRate - angleRateThd)
		-- speedRate = angleRateThd
	else
		speedRate = angleRate
	end
	return speedRate
end


--Client--
function svac.client_onCreate( self )
	--self.interactable:setPoseWeight( 1, 0 )
	self.boltValue = 0.0
	self.lastActive = false
	self.UIPosIndex = 1
	self.network:sendToServer("server_request")
end

function svac.client_onUpdate( self, dt )	
	if self.interactable:isActive() then
		self.boltValue = 1.0
	else
		self.boltValue = 0.0	
	end	
	--self.interactable:setPoseWeight( 1, self.boltValue )
end

function svac.cl_OnOff( self, PlayerID )
	if self.lastActive == false and self.interactable:isActive() then
		print (sm.audio.soundList )
		if PlayerID then
			sm.audio.play("Retrowildblip", self.shape:getWorldPosition())
		end
	elseif self.lastActive == true and self.interactable:isActive() == false then
		if PlayerID then
			sm.audio.play("Sensor off", self.shape:getWorldPosition())
		end
	end
	self.lastActive = self.interactable:isActive()
end

function svac.cli_debug( self, printStr )
	sm.gui.displayAlertText(printStr, 1)
end



function svac.client_setUiIdx(self, UIPosIndex )
	self.UIPosIndex = UIPosIndex
end

function svac.client_onInteract(self, character, state)
    if not state then return end
	if self.gui == nil then
		self.gui = sm.gui.createEngineGui()
		self.gui:setSliderCallback( "Setting", "cli_onSliderChange")
		self.gui:setText("Name", "#{CONTROLLER_UPGRADE_Settings}")
		self.gui:setText("Interaction", "#{CONTROLLER_UPGRADE_Settings}#{CONTROLLER_UPGRADE_Speed}")		
		self.gui:setIconImage("Icon", sm.uuid.new("da2e564f-f1de-4b38-b2e3-cb43f30d7a4c"))
		self.gui:setVisible("FuelContainer", false )
	end
	self.gui:setSliderData("Setting", #self.speedTbl, self.UIPosIndex-1)
	self.gui:setText("SubTitle", "#{CONTROLLER_UPGRADE_Settings}#{CONTROLLER_UPGRADE_Speed}: "..self.speedTbl[self.UIPosIndex])
	self.gui:open()
end

function svac.cli_onSliderChange( self, sliderName, sliderPos )
	local newIndex = sliderPos + 1
	self.UIPosIndex = newIndex
	if self.gui ~= nil then
		self.gui:setText("SubTitle", "#{CONTROLLER_UPGRADE_Settings}#{CONTROLLER_UPGRADE_Speed}: "..self.speedTbl[self.UIPosIndex])
	end
	self.network:sendToServer("sv_speedChange", newIndex)
end

function svac.client_canInteract(self)
	sm.gui.setInteractionText( "", sm.gui.getKeyBinding( "Use" ), "#{CONTROLLER_UPGRADE_Settings}#{CONTROLLER_UPGRADE_Speed}" )
	do return true end
end

