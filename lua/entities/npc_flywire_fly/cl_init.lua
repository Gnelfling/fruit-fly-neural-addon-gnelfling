include("shared.lua")

function ENT:Initialize()
    self:SetRenderClipPlaneEnabled(false)
end

function ENT:Draw()
    self:DrawModel()
end
