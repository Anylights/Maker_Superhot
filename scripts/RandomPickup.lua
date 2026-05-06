-- ============================================================================
-- RandomPickup.lua - 随机道具生成系统（大世界持久模式）
-- 仅在活跃玩家附近区域生成拾取物，适配 500m 大地图
-- ============================================================================

local Config = require("Config")

local RandomPickup = {}

-- ============================================================================
-- 配置
-- ============================================================================
RandomPickup.MaxPickups     = 30    -- 场景中同时存在的最大拾取物数量
RandomPickup.SpawnInterval  = 3.0   -- 每次尝试生成的冷却时间（秒）
RandomPickup.SmallRatio     = 0.70  -- 小能量块占比（70% 小 / 30% 大）
RandomPickup.MinDistance    = 3.0   -- 新拾取物与已有拾取物的最小距离（米）
RandomPickup.ScanRadius     = 25    -- 扫描玩家上下各 25 层（米）
RandomPickup.SpawnPerCycle  = 2     -- 每个玩家区域每次最多生成数

-- ============================================================================
-- 内部状态
-- ============================================================================
local spawnTimer_ = 0
local mapModule_ = nil
local pickupModule_ = nil
local playerModule_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化随机道具系统
---@param mapRef table Map 模块引用
---@param pickupRef table Pickup 模块引用
---@param playerRef table|nil Player 模块引用（用于获取玩家位置）
function RandomPickup.Init(mapRef, pickupRef, playerRef)
    mapModule_ = mapRef
    pickupModule_ = pickupRef
    playerModule_ = playerRef
    spawnTimer_ = 0
    print("[RandomPickup] Initialized (large map mode, max=" .. RandomPickup.MaxPickups
        .. " scanRadius=" .. RandomPickup.ScanRadius .. ")")
end

-- ============================================================================
-- 区域扫描：只在指定 Y 范围内寻找有效生成位置
-- ============================================================================

--- 扫描指定世界 Y 范围内的有效生成位置
--- 有效位置 = 空格子且下方有实心方块（玩家可到达的平台上方）
---@param worldMinY number 世界坐标最小 Y
---@param worldMaxY number 世界坐标最大 Y
---@return table 位置列表 { {x, y}, ... }
local function ScanValidPositionsInRange(worldMinY, worldMaxY)
    local positions = {}
    if mapModule_ == nil then return positions end

    local grid = mapModule_.GetGrid()
    if grid == nil then return positions end

    local w, h = mapModule_.GetDimensions()

    -- 世界坐标转网格 Y（grid Y 从 1 开始，world Y = (gridY-1) * BlockSize）
    local gridMinY = math.max(2, math.floor(worldMinY / Config.BlockSize) + 1)
    local gridMaxY = math.min(h, math.ceil(worldMaxY / Config.BlockSize) + 1)

    for y = gridMinY, gridMaxY do
        for x = 1, w do
            local cell = grid[y] and grid[y][x] or 0
            local below = grid[y - 1] and grid[y - 1][x] or 0

            -- 空格子且下方是实心可站立方块
            if cell == Config.BLOCK_EMPTY and
               (below == Config.BLOCK_NORMAL or below == Config.BLOCK_SAFE or
                below == Config.BLOCK_CHECKPOINT or below == Config.BLOCK_ENERGY_PAD or
                Config.IsSpawnBlock(below)) then
                local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                local wy = (y - 1) * Config.BlockSize + Config.BlockSize * 0.5
                table.insert(positions, { x = wx, y = wy })
            end
        end
    end

    return positions
end

-- ============================================================================
-- 随机选点
-- ============================================================================

--- 从候选位置中随机选取不重叠的生成位置
---@param candidates table 候选位置列表
---@param count number 需要的数量
---@return table 位置列表 { {x, y, size}, ... }
local function PickRandomPositions(candidates, count)
    if #candidates == 0 then return {} end

    -- Fisher-Yates 洗牌
    for i = #candidates, 2, -1 do
        local j = math.random(1, i)
        candidates[i], candidates[j] = candidates[j], candidates[i]
    end

    local result = {}
    for _, pos in ipairs(candidates) do
        if #result >= count then break end

        -- 检查与已选位置的最小距离
        local tooClose = false
        for _, chosen in ipairs(result) do
            local dx = pos.x - chosen.x
            local dy = pos.y - chosen.y
            if math.sqrt(dx * dx + dy * dy) < RandomPickup.MinDistance then
                tooClose = true
                break
            end
        end

        if not tooClose then
            table.insert(result, {
                x = pos.x,
                y = pos.y,
                size = (math.random() < RandomPickup.SmallRatio) and "small" or "large",
            })
        end
    end

    return result
end

-- ============================================================================
-- 更新（每帧调用，服务端/单机）
-- ============================================================================

--- 每帧更新：周期性在玩家附近生成新拾取物
---@param dt number
function RandomPickup.Update(dt)
    if pickupModule_ == nil then return end

    spawnTimer_ = spawnTimer_ - dt
    if spawnTimer_ > 0 then return end
    spawnTimer_ = RandomPickup.SpawnInterval

    local activeCount = pickupModule_.GetActiveCount()
    if activeCount >= RandomPickup.MaxPickups then return end

    -- 收集活跃玩家 Y 位置
    local playerYs = {}
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.session and p.session.active and p.alive and p.node then
                table.insert(playerYs, p.node.position.y)
            end
        end
    end

    -- 无活跃玩家时不生成
    if #playerYs == 0 then return end

    local spawned = 0
    local maxToSpawn = RandomPickup.MaxPickups - activeCount

    for _, py in ipairs(playerYs) do
        if spawned >= maxToSpawn then break end

        local minY = py - RandomPickup.ScanRadius
        local maxY = py + RandomPickup.ScanRadius

        local candidates = ScanValidPositionsInRange(minY, maxY)
        if #candidates > 0 then
            local toSpawn = math.min(RandomPickup.SpawnPerCycle, maxToSpawn - spawned)
            local positions = PickRandomPositions(candidates, toSpawn)

            for _, pos in ipairs(positions) do
                if not pickupModule_.HasPickupNear(pos.x, pos.y, RandomPickup.MinDistance) then
                    pickupModule_.Spawn(pos.x, pos.y, pos.size)
                    spawned = spawned + 1
                end
            end
        end
    end
end

-- ============================================================================
-- 重置（世界初始化时调用）
-- ============================================================================

--- 重置：清除所有拾取物，重置计时器
function RandomPickup.Reset()
    spawnTimer_ = 0
    if pickupModule_ then
        pickupModule_.ClearAll()
    end
    print("[RandomPickup] Reset for persistent world")
end

return RandomPickup
