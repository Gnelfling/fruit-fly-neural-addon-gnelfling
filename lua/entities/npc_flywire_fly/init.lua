-- GMod note:
-- http.Post/http.Fetch can usually reach 127.0.0.1 from a listen server / dedicated server
-- as long as the server environment permits loopback and the HTTP module is enabled.
-- Some sandbox/server policies, anti-cheat layers, or OS firewall settings can still block
-- localhost traffic. If that happens, use a tiny local relay process or a custom binary
-- socket module (C++/native module) instead of GMod's built-in HTTP API.
-- The common workaround is to run a small proxy on a non-loopback port and point the add-on
-- at that proxy instead of directly hitting 127.0.0.1.

AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local PYTHON_URL = "http://127.0.0.1:8787"
local HTTP_POLL_INTERVAL = 0.1
local HTTP_RETRY_DELAY = 2.5

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

    -- Last successful values returned by the HTTP server.
    self.lastDNp01 = 0
    self.lastDNa01 = 0
    self.lastDNa02 = 0

    -- Threat estimation state.
    self.lastThreat = 0
    self.lastThreatDistance = nil
    self.lastThreatTime = 0

    -- Movement state.
    self.flightYaw = math.random(0, 360)
    self.escapeBurstUntil = 0
    self.escapeCooldownUntil = 0

    -- HTTP state.
    self.httpHealthy = true
    self.nextHttpPoll = 0

    self:NextThink(CurTime() + 0.05)
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

    -- More threatening when the player is close and approaching quickly.
    -- Normalized to roughly 0..1 using tuned distance and speed thresholds.
    local nearFactor = 1 - math.Clamp((dist - 500) / (1500 - 500), 0, 1)
    local motionFactor = math.Clamp(closingSpeed / 400, 0, 1)

    local threat = math.Clamp(nearFactor * 0.7 + motionFactor * 0.3, 0, 1)
    self.lastThreat = threat
    return threat
end

function ENT:DoStimulusRequest(threat)
    local params = {
        ["LC4"] = tostring(threat),
        ["LPLC2"] = tostring(threat),
    }

    http.Post(
        PYTHON_URL .. "/stimulate",
        params,
        function(body, length, headers, code)
            if not IsValid(self) then return end

            if code ~= 200 then
                self.httpHealthy = false
                self.nextHttpPoll = CurTime() + HTTP_RETRY_DELAY
                return
            end

            self.httpHealthy = true
        end,
        function(err)
            if not IsValid(self) then return end
            self.httpHealthy = false
            self.nextHttpPoll = CurTime() + HTTP_RETRY_DELAY
        end
    )
end

function ENT:DoOutputRequest()
    http.Fetch(
        PYTHON_URL .. "/output",
        function(body, length, headers, code)
            if not IsValid(self) then return end

            if code ~= 200 then
                self.httpHealthy = false
                self.nextHttpPoll = CurTime() + HTTP_RETRY_DELAY
                return
            end

            local decoded = util.JSONToTable(body)
            if not istable(decoded) then
                self.httpHealthy = false
                self.nextHttpPoll = CurTime() + HTTP_RETRY_DELAY
                return
            end

            -- Only update cached values inside the HTTP callback.
            -- This keeps movement logic safe while requests are in flight.
            self.lastDNp01 = tonumber(decoded.DNp01) or 0
            self.lastDNa01 = tonumber(decoded.DNa01) or 0
            self.lastDNa02 = tonumber(decoded.DNa02) or 0

            self.httpHealthy = true
            self.nextHttpPoll = CurTime() + HTTP_POLL_INTERVAL
        end,
        function(err)
            if not IsValid(self) then return end
            self.httpHealthy = false
            self.nextHttpPoll = CurTime() + HTTP_RETRY_DELAY
        end
    )
end

function ENT:DoHttpPoll()
    local now = CurTime()
    if now < self.nextHttpPoll then return end

    local threat = self:ComputeThreatValue()
    self:DoStimulusRequest(threat)
    self:DoOutputRequest()

    if self.httpHealthy then
        self.nextHttpPoll = now + HTTP_POLL_INTERVAL
    else
        self.nextHttpPoll = now + HTTP_RETRY_DELAY
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

    local impulse = away * (500 + math.Clamp(self.lastDNp01 or 0, 0, 200) * 3)
    impulse.z = math.max(60, impulse.z + 30)

    self:SetVelocity(impulse)
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

        if self.escapeBurstUntil > now then
            local nearestPlayer, _ = self:GetNearestThreatPlayer()
            if IsValid(nearestPlayer) then
                local away = self:GetPos() - nearestPlayer:GetPos()
                away:Normalize()
                self:SetVelocity(self:GetVelocity() + away * 180)
            end
        end

        return
    end

    -- Fallback behavior if the server is unreachable or output is stale.
    self:ApplyIdleWander()
end

function ENT:Think()
    if not IsValid(self) then return false end

    -- HTTP poll runs at about 10Hz, not every tick.
    self:DoHttpPoll()

    -- Movement is applied every think tick and uses the last cached output.
    self:ApplyMovement()

    self:NextThink(CurTime() + 0.05)
    return true
end

function ENT:OnRemove()
end
