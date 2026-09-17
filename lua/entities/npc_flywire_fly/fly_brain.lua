-- Native FlyWire-inspired leaky integrate-and-fire simulation.
-- The connectome JSON is shipped beside this file under lua/entities/npc_flywire_fly/.

local Brain = {}
Brain.__index = Brain

local DT = 1.0
local TAU = 20.0
local V_REST = -70.0
local V_TH = -50.0
local V_RESET = -65.0
local T_REF = 2.0
local WEIGHT_SCALE = 1.0
local STIM_MV_PER_NEURON = 15.0
local RATE_WINDOW_TICKS = 100

local function readConnectome()
    local paths = {
        "entities/npc_flywire_fly/fly_connectome.json",
        "npc_flywire_fly/fly_connectome.json",
    }

    for _, path in ipairs(paths) do
        local raw = file.Read(path, "LUA")
        if raw and raw ~= "" then
            local data = util.JSONToTable(raw)
            if istable(data) then return data end
        end
    end

    -- DATA is useful when testing a downloaded/generated connectome.
    local raw = file.Read("fly_connectome.json", "DATA")
    if raw and raw ~= "" then
        local data = util.JSONToTable(raw)
        if istable(data) then return data end
    end

    return nil
end

function Brain.new()
    local data = readConnectome()
    if not data then
        ErrorNoHalt("[FlyWire] Could not load fly_connectome.json\n")
        return nil
    end

    local self = setmetatable({}, Brain)
    self.dt = DT
    self.neuronCount = 0
    self.idToIndex = {}
    self.groups = {}
    self.adjacency = {}
    self.voltage = {}
    self.refractory = {}
    self.lastSpikes = {}
    self.currentInjection = {}
    self.history = {}
    self.historyIndex = 1

    local ids = {}
    local seen = {}

    local function addID(id)
        id = tonumber(id) or id
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    for _, edge in ipairs(data.edges or {}) do
        addID(edge[1])
        addID(edge[2])
    end
    for _, group in pairs(data.cell_types or {}) do
        for _, id in ipairs(group) do
            addID(id)
        end
    end

    self.neuronCount = #ids
    for i, id in ipairs(ids) do
        self.idToIndex[id] = i
        self.adjacency[i] = {}
        self.voltage[i] = V_REST
        self.refractory[i] = 0
        self.lastSpikes[i] = false
        self.currentInjection[i] = 0
    end

    for cellType, group in pairs(data.cell_types or {}) do
        self.groups[cellType] = {}
        for _, id in ipairs(group) do
            local index = self.idToIndex[tonumber(id) or id]
            if index then
                self.groups[cellType][#self.groups[cellType] + 1] = index
            end
        end
    end

    for _, edge in ipairs(data.edges or {}) do
        local pre = self.idToIndex[tonumber(edge[1]) or edge[1]]
        local post = self.idToIndex[tonumber(edge[2]) or edge[2]]
        if pre and post then
            self.adjacency[pre][#self.adjacency[pre] + 1] = {
                target = post,
                weight = (tonumber(edge[3]) or 0) * (tonumber(edge[4]) or 1) * WEIGHT_SCALE,
            }
        end
    end

    for tick = 1, RATE_WINDOW_TICKS do
        self.history[tick] = {}
        for i = 1, self.neuronCount do
            self.history[tick][i] = false
        end
    end

    print(string.format("[FlyWire] Loaded %d neurons and %d edges", self.neuronCount, #(data.edges or {})))
    return self
end

function Brain:InjectStimulus(cellType, value)
    local group = self.groups[cellType]
    if not group then return end
    local amount = math.max(0, tonumber(value) or 0) * STIM_MV_PER_NEURON
    for _, index in ipairs(group) do
        self.currentInjection[index] = self.currentInjection[index] + amount
    end
end

function Brain:Step()
    local synaptic = {}

    for pre = 1, self.neuronCount do
        if self.lastSpikes[pre] then
            for _, connection in ipairs(self.adjacency[pre]) do
                local target = connection.target
                synaptic[target] = (synaptic[target] or 0) + connection.weight
            end
        end
    end

    local spiked = {}
    for i = 1, self.neuronCount do
        local didSpike = false

        if self.refractory[i] <= 0 then
            local v = self.voltage[i]
            v = v + (V_REST - v) / TAU * DT
            v = v + (synaptic[i] or 0) + self.currentInjection[i]
            self.currentInjection[i] = 0

            if v >= V_TH then
                didSpike = true
                v = V_RESET
                self.refractory[i] = T_REF
            end
            self.voltage[i] = v
        else
            self.currentInjection[i] = 0
        end

        if self.refractory[i] > 0 then
            self.refractory[i] = math.max(0, self.refractory[i] - DT)
        end

        spiked[i] = didSpike
    end

    self.history[self.historyIndex] = spiked
    self.historyIndex = (self.historyIndex % RATE_WINDOW_TICKS) + 1
    self.lastSpikes = spiked
end

function Brain:GetFiringRate(cellType)
    local group = self.groups[cellType]
    if not group or #group == 0 then return 0 end

    local total = 0
    for _, index in ipairs(group) do
        local count = 0
        for tick = 1, RATE_WINDOW_TICKS do
            if self.history[tick][index] then
                count = count + 1
            end
        end
        total = total + (count / (RATE_WINDOW_TICKS * DT)) * 1000
    end
    return total / #group
end

return Brain
