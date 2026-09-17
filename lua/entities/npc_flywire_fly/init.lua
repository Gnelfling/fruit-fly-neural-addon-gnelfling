AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
AddCSLuaFile("fly_brain.lua")
include("shared.lua")

local Brain = include("fly_brain.lua")
local SIM_DT = 0.01
local MAX_ESCAPE_SPEED = 700

function ENT:Initialize()
    if not IsValid(self) then return end

    self:SetModel(self.Model or "models/props_junk/PopCan01a.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_FLY)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_NONE)
    self:SetGravity(0)
    self:SetHealth(100)
    self:SetMaxHealth(100)
    self:SetUseType(SIMPLE_USE)
    self:SetAngles(Angle(0, math.random(0, 359), 0))
    self:SetRenderMode(RENDERMODE_NORMAL)

    self.lastDNp01 = 0
    self.lastDNa01 = 0
    self.lastDNa02 = 0
    self.lastThreat = 0
    self.lastThreatDistance = nil
    self.lastThreatTime = 0
    self.flightYaw = math.random(0, 360)
    self.escapeBurstUntil = 0
    self.escapeCooldownUntil = 0
    self.nextDebugPrint = 0

    self.brain = Brain.new()
    self.simAccumulator = 0
    self:NextThink(CurTime() + SIM_DT)
end

function ENT:GetNearestThreatPlayer()
    local bestEnt = nil
    local bestDist = math.huge
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:Alive() then
            local dist = self:GetPos():Distance(ply:GetPos())
            if dist < bestDist then
                bestEnt = ply
                bestDist = dist
            end
        end
    end
    return bestEnt, bestDist
end

function ENT:ComputeThreatValue()
    local target, dist = self:GetNearestThreatPlayer()
    if not IsValid(target) then
        self.lastThreat = 0
        self.lastThreatDistance = nil
        self.lastThreatTime = CurTime()
        return 0
    end

    local now = CurTime()
    local previousDistance = self.lastThreatDistance
    local closingSpeed = 0

    if previousDistance ~= nil and self.lastThreatTime > 0 then
        local dt = math.max(0.05, now - self.lastThreatTime)
        closingSpeed = math.max(0, (previousDistance - dist) / dt)
    end

    self.lastThreatDistance = dist
    self.lastThreatTime = now

    local nearFactor = 1 - math.Clamp((dist - 500) / (1500 - 500), 0, 1)
    local motionFactor = math.Clamp(closingSpeed / 400, 0, 1)

    local threat = math.Clamp(nearFactor * 0.7 + motionFactor * 0.3, 0, 1)
    self.lastThreat = threat
    return threat
end

function ENT:RunBrain()
    if not self.brain then return end

    local threat = self:ComputeThreatValue()
    self.brain:InjectStimulus("LC4", threat)
    self.brain:InjectStimulus("LPLC2", threat)
    self.brain:Step()

    self.lastDNp01 = self.brain:GetFiringRate("DNp01")
    self.lastDNa01 = self.brain:GetFiringRate("DNa01")
    self.lastDNa02 = self.brain:GetFiringRate("DNa02")

    if CurTime() >= self.nextDebugPrint then
        print(string.format(
            "threat=%.2f DNp01=%.1f DNa01=%.1f DNa02=%.1f",
            threat,
            self.lastDNp01,
            self.lastDNa01,
            self.lastDNa02
        ))
        self.nextDebugPrint = CurTime() + 1.0
    end
end

function ENT:ApplyEscapeBurst()
    local nearestPlayer, _ = self:GetNearestThreatPlayer()
    if not IsValid(nearestPlayer) then return end

    local now = CurTime()
    if self.escapeCooldownUntil > now then return end

    local away = self:GetPos() - nearestPlayer:GetPos()
    if away:LengthSqr() < 1 then
        away = Vector(math.random() - 0.5, math.random() - 0.5, 0.2)
    end
    away:Normalize()

    local burstSpeed = 180 + math.Clamp(self.lastDNp01 or 0, 0, 230) * 1.3
    local impulse = away * burstSpeed
    impulse.z = math.max(45, impulse.z + 15)

    local currentVelocity = self:GetVelocity()
    local resultingVelocity = currentVelocity + impulse

    if resultingVelocity:Length() > MAX_ESCAPE_SPEED then
        resultingVelocity = resultingVelocity:GetNormalized() * MAX_ESCAPE_SPEED
    end

    -- Apply only once at burst start, not repeatedly on later ticks.
    self:SetVelocity(resultingVelocity - currentVelocity)

    self.escapeBurstUntil = now + 0.45
    self.escapeCooldownUntil = now + 2.0
end

function ENT:ApplyIdleWander()
    local now = CurTime()
    local dNa01 = math.Clamp(self.lastDNa01 or 0, 0, 500)
    local dNa02 = math.Clamp(self.lastDNa02 or 0, -500, 500)

    local wanderIntensity = math.Clamp(dNa01 / 370, 0, 1)
    local turnBias = math.Clamp(dNa02 / 370, -1, 1)

    self.flightYaw = self.flightYaw + (
        math.sin(now * (0.9 + wanderIntensity * 0.9)) * 0.5 +
        turnBias * 0.8
    ) * (0.2 + wanderIntensity * 0.8)

    local forward = Angle(0, self.flightYaw, 0):Forward()
    local right = Angle(0, self.flightYaw + 90, 0):Forward()

    local desiredVel = forward * (25 + wanderIntensity * 120)
    desiredVel = desiredVel + right * turnBias * (30 + wanderIntensity * 100)
    desiredVel.z = math.sin(now * 1.4 + self:EntIndex()) * (12 + wanderIntensity * 18)

    self:SetVelocity(LerpVector(0.18, self:GetVelocity(), desiredVel))
end

function ENT:ApplyMovement()
    local now = CurTime()

    if (self.lastDNp01 or 0) > 0 then
        self:ApplyEscapeBurst()

        -- Do not keep adding velocity during the burst window.
        if self.escapeBurstUntil > now then
            local velocity = self:GetVelocity()
            if velocity:Length() > MAX_ESCAPE_SPEED then
                self:SetVelocity(velocity:GetNormalized() * MAX_ESCAPE_SPEED - velocity)
            end
        end
        return
    end

    self:ApplyIdleWander()
end

function ENT:Think()
    if not IsValid(self) then return false end

    self.simAccumulator = self.simAccumulator + 0.05
    while self.simAccumulator >= SIM_DT do
        self:RunBrain()
        self.simAccumulator = self.simAccumulator - SIM_DT
    end

    self:ApplyMovement()

    self:NextThink(CurTime() + 0.05)
    return true
end

function ENT:OnRemove()
end
