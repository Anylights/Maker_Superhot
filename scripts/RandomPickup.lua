-- ============================================================================
-- RandomPickup.lua - 随机道具生成系统
-- 替代硬编码的 MapData.EnergyPickups
-- 在地图上的有效位置随机生成能量拾取物，有冷却和数量限制
-- ============================================================================

local Config = require("Config")

local RandomPickup = {}

-- ============================================================================
-- 配置
-- ============================================================================
RandomPickup.MaxPickups     = 12    -- 场景中同时存在的最大拾取物数量
RandomPickup.SpawnInterval  = 3.0   -- 每次尝试生成的冷却时间（秒）
RandomPickup.InitialCount   = 8     -- 回合开始时初始生成数量
RandomPickup.SmallRatio     = 0.70  -- 小能量块占比（70% 小 / 30% 大）
RandomPickup.MinDistance    = 3.0   -- 新拾取物与已有拾取物的最小距离（米）

-- ============================================================================
-- 内部状态
-- ============================================================================
local spawnTimer_ = 0
local mapModule_ = nil
local pickupModule_ = nil
local playerModule_ = nil  -- Player 模块引用（用于获取人类玩家高度）
local validPositions_ = {}  -- 缓存的有效生成位置

-- 高度相关配置
RandomPickup.SpawnBelowPlayer  = 10   -- 在玩家下方多少格内生成
RandomPickup.SpawnAbovePlayer  = 30   -- 在玩家上方多少格内生成
RandomPickup.CleanupDistance   = 50   -- 距离玩家超过此距离的拾取物会被清理

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化随机道具系统
---@param mapRef table Map 模块引用
---@param pickupRef table Pickup 模块引用
---@param playerRef table|nil Player 模块引用（可选，用于高度相关生成）
function RandomPickup.Init(mapRef, pickupRef, playerRef)
    mapModule_ = mapRef
    pickupModule_ = pickupRef
    playerModule_ = playerRef
    spawnTimer_ = 0
    validPositions_ = {}
    print("[RandomPickup] Initialized (max=" .. RandomPickup.MaxPickups ..
          " interval=" .. RandomPickup.SpawnInterval .. "s)")
end

-- ============================================================================
-- 有效位置扫描
-- ============================================================================

--- 扫描地图网格，找到玩家附近的有效拾取物生成位置
--- 有效位置 = 空格子且下方有实心方块（玩家可到达的平台上方）
--- 大地图模式下只扫描人类玩家附近区域（-SpawnBelowPlayer 到 +SpawnAbovePlayer）
function RandomPickup.RefreshValidPositions()
    validPositions_ = {}
    if mapModule_ == nil then return end

    local grid = mapModule_.GetGrid()
    if grid == nil then return end

    local w, h = mapModule_.GetDimensions()

    -- 确定扫描范围（基于人类玩家高度）
    local minGridY = 2
    local maxGridY = h
    if playerModule_ then
        local humanPos = playerModule_.GetHumanPosition()
        if humanPos then
            local playerGridY = math.floor(humanPos.y / Config.BlockSize) + 1
            minGridY = math.max(2, playerGridY - RandomPickup.SpawnBelowPlayer)
            maxGridY = math.min(h, playerGridY + RandomPickup.SpawnAbovePlayer)
        end
    end

    for y = minGridY, maxGridY do
        for x = 1, w do
            local cell = grid[y] and grid[y][x] or 0
            local below = grid[y - 1] and grid[y - 1][x] or 0

            -- 空格子且下方是实心方块（普通/安全/出生点/检查点等）
            if cell == Config.BLOCK_EMPTY and
               (below == Config.BLOCK_NORMAL or below == Config.BLOCK_SAFE or
                below == Config.BLOCK_SPAWN or below == Config.BLOCK_FINISH or
                below == Config.BLOCK_CHECKPOINT or
                Config.IsSpawnBlock(below)) then
                local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                local wy = (y - 1) * Config.BlockSize + Config.BlockSize * 0.5
                table.insert(validPositions_, { x = wx, y = wy, gx = x, gy = y })
            end
        end
    end

    print("[RandomPickup] Found " .. #validPositions_ .. " valid spawn positions (Y range: " .. minGridY .. "-" .. maxGridY .. ")")
end

-- ============================================================================
-- 随机选点
-- ============================================================================

--- 从有效位置中按权重随机选取 count 个不重叠的生成位置
--- 权重规则：越低的平台权重越高（道具更多），越高的平台权重越低（道具更少）
---@param count number 需要的数量
---@return table 位置列表 { { x, y, size }, ... }
function RandomPickup.GetRandomPositions(count)
    if #validPositions_ == 0 then return {} end

    -- 找出位置的 Y 范围（用于计算权重）
    local minY, maxY = math.huge, -math.huge
    for _, v in ipairs(validPositions_) do
        if v.y < minY then minY = v.y end
        if v.y > maxY then maxY = v.y end
    end
    local yRange = maxY - minY
    if yRange < 0.01 then yRange = 1 end  -- 防止除零

    -- 按高度权重选择：低位置权重大，高位置权重小
    -- 权重公式：weight = 1 + 2 * (1 - normalizedY)  即底部权重3，顶部权重1
    local candidates = {}
    local totalWeight = 0
    for i, v in ipairs(validPositions_) do
        local normalizedY = (v.y - minY) / yRange  -- 0=最低, 1=最高
        local weight = 1.0 + 2.0 * (1.0 - normalizedY)  -- 底部=3.0, 顶部=1.0
        totalWeight = totalWeight + weight
        candidates[i] = { pos = v, weight = weight, cumWeight = totalWeight }
    end

    -- 按加权随机选取（无放回抽样）
    local result = {}
    local used = {}  -- 已选索引标记

    local maxAttempts = #candidates * 3  -- 防止死循环
    local attempts = 0

    while #result < count and attempts < maxAttempts do
        attempts = attempts + 1

        -- 加权随机选一个
        local roll = math.random() * totalWeight
        local picked = nil
        local pickedIdx = nil
        for i, c in ipairs(candidates) do
            if not used[i] and roll <= c.cumWeight then
                picked = c.pos
                pickedIdx = i
                break
            end
            if not used[i] then
                roll = roll - c.weight
                if roll <= 0 then
                    picked = c.pos
                    pickedIdx = i
                    break
                end
            end
        end

        -- 后备：随机选一个未使用的
        if picked == nil then
            for i, c in ipairs(candidates) do
                if not used[i] then
                    picked = c.pos
                    pickedIdx = i
                    break
                end
            end
        end

        if picked == nil then break end  -- 没有可选位置了

        -- 检查与已选位置的最小距离
        local tooClose = false
        for _, chosen in ipairs(result) do
            local dx = picked.x - chosen.x
            local dy = picked.y - chosen.y
            if math.sqrt(dx * dx + dy * dy) < RandomPickup.MinDistance then
                tooClose = true
                break
            end
        end

        if not tooClose then
            used[pickedIdx] = true
            table.insert(result, {
                x = picked.x,
                y = picked.y,
                size = (math.random() < RandomPickup.SmallRatio) and "small" or "large"
            })
        else
            used[pickedIdx] = true  -- 太近的也标记为已用，避免反复选到
        end
    end

    return result
end

-- ============================================================================
-- 更新（每帧调用）
-- ============================================================================

--- 每帧更新：周期性尝试生成新拾取物 + 清理远距离拾取物
---@param dt number
function RandomPickup.Update(dt)
    if pickupModule_ == nil then return end

    spawnTimer_ = spawnTimer_ - dt
    if spawnTimer_ > 0 then return end
    spawnTimer_ = RandomPickup.SpawnInterval

    -- 每次刷新有效位置（大地图下基于玩家高度动态调整）
    RandomPickup.RefreshValidPositions()

    -- 清理距离玩家太远的拾取物
    if playerModule_ then
        local humanPos = playerModule_.GetHumanPosition()
        if humanPos then
            pickupModule_.CleanupFarPickups(humanPos.y, RandomPickup.CleanupDistance)
        end
    end

    local activeCount = pickupModule_.GetActiveCount()
    if activeCount >= RandomPickup.MaxPickups then return end

    -- 每次尝试生成 1-2 个
    local toSpawn = math.min(2, RandomPickup.MaxPickups - activeCount)
    local positions = RandomPickup.GetRandomPositions(toSpawn)
    if #positions == 0 then return end

    local spawned = 0
    for _, pos in ipairs(positions) do
        -- 检查附近是否已有拾取物
        if not pickupModule_.HasPickupNear(pos.x, pos.y, RandomPickup.MinDistance) then
            pickupModule_.Spawn(pos.x, pos.y, pos.size)
            spawned = spawned + 1
        end
    end
    if spawned > 0 then
        print("[RandomPickup] Spawned " .. spawned .. " pickups, active=" .. (activeCount + spawned))
    end
end

-- ============================================================================
-- 重置（新回合开始时调用）
-- ============================================================================

--- 重置：清除所有拾取物，刷新有效位置，生成初始批次
function RandomPickup.Reset()
    spawnTimer_ = RandomPickup.SpawnInterval
    RandomPickup.RefreshValidPositions()

    if pickupModule_ then
        pickupModule_.ClearAll()

        -- 生成初始批次
        local initialCount = math.min(RandomPickup.InitialCount, RandomPickup.MaxPickups)
        local positions = RandomPickup.GetRandomPositions(initialCount)

        for _, pos in ipairs(positions) do
            pickupModule_.Spawn(pos.x, pos.y, pos.size)
        end

        print("[RandomPickup] Reset with " .. #positions .. " initial pickups")
    end
end

return RandomPickup
