-- ============================================================================
-- MapData.lua - 超级红温！程序化大地图生成
-- 模式：大地图攀登（200+ 格高，3 分钟计时得分）
-- 坐标系：X 右，Y 上，每格 1m
-- ============================================================================

local Config = require("Config")

local MapData = {}

-- 方块类型常量（简写）
local E  = Config.BLOCK_EMPTY
local N  = Config.BLOCK_NORMAL
local S  = Config.BLOCK_SAFE
local EP = Config.BLOCK_ENERGY_PAD
local CP = Config.BLOCK_CHECKPOINT

-- 地图宽高
MapData.Width  = Config.DefaultMapWidth
MapData.Height = Config.DefaultMapHeight

-- 出生点位置表：SpawnPositions[playerIndex] = { x=世界X, y=世界Y }
MapData.SpawnPositions = {}

-- 检查点 Y 坐标列表（世界坐标，从低到高排序）
MapData.CheckpointYList = {}

-- 兼容旧版
MapData.SpawnX = 6
MapData.SpawnY = 4

-- 能量拾取点（由 RandomPickup 管理，此表保留为空）
MapData.EnergyPickups = {}

-- 终点方块列表（大地图模式不使用，保留兼容接口）
MapData.FinishBlocks = {}

-- 简单伪随机数生成器（可复现 seed）
local rngState_ = 12345

local function rngSeed(seed)
    rngState_ = seed
end

local function rngNext()
    -- xorshift32
    rngState_ = rngState_ ~ (rngState_ << 13)
    rngState_ = rngState_ & 0x7FFFFFFF
    rngState_ = rngState_ ~ (rngState_ >> 17)
    rngState_ = rngState_ & 0x7FFFFFFF
    rngState_ = rngState_ ~ (rngState_ << 5)
    rngState_ = rngState_ & 0x7FFFFFFF
    return rngState_
end

--- 返回 [min, max] 范围内的整数
local function rngRange(min, max)
    if min > max then return min end
    return min + (rngNext() % (max - min + 1))
end

--- 设置地图尺寸
function MapData.SetDimensions(w, h)
    MapData.Width = w or Config.DefaultMapWidth
    MapData.Height = h or Config.DefaultMapHeight
end

-- ============================================================================
-- 程序化地图生成
-- ============================================================================

--- 生成程序化大地图
--- 设计原则：
---   - 单跳高度约 3.5 格，二段跳约 6 格
---   - 平台层间距 3-5 格（保证可达）
---   - 每层 2-4 个平台段，长度 3-10 格
---   - 每 CheckpointInterval 格放检查点
---   - 底部全宽安全平台 + 6 个出生点
---@param seed? number 随机种子（可选，默认用 os.time）
---@return table grid  grid[y][x] = blockType
function MapData.Generate(seed)
    seed = seed or os.time()
    rngSeed(seed)
    print("[MapData] Generating procedural map " .. MapData.Width .. "x" .. MapData.Height .. " seed=" .. seed)

    -- 重置
    MapData.SpawnPositions = {}
    MapData.CheckpointYList = {}
    MapData.FinishBlocks = {}

    local W = MapData.Width
    local H = MapData.Height

    -- 初始化空网格
    local grid = {}
    for y = 1, H do
        grid[y] = {}
        for x = 1, W do
            grid[y][x] = E
        end
    end

    -- ====================================================================
    -- 底部出生区（Y=3: 全宽安全平台）
    -- ====================================================================
    local spawnY = 3
    for x = 1, W do
        grid[spawnY][x] = S
    end

    -- 放置 6 个出生点，均匀分布
    local spawnXList = { 4, 9, 14, 17, 22, 27 }
    for pi = 1, Config.NumPlayers do
        local sx = spawnXList[pi] or (3 + pi * 4)
        if sx >= 1 and sx <= W then
            grid[spawnY][sx] = Config.SpawnBlockTypes[pi]
        end
        local wx = (sx - 1) * Config.BlockSize + Config.BlockSize * 0.5
        local wy = spawnY * Config.BlockSize  -- 站在方块上方
        MapData.SpawnPositions[pi] = { x = wx, y = wy }
    end

    -- 兼容旧版字段
    MapData.SpawnX = MapData.SpawnPositions[1].x
    MapData.SpawnY = MapData.SpawnPositions[1].y

    -- ====================================================================
    -- 生成平台层
    -- ====================================================================
    local currentY = spawnY  -- 上一个平台层的 Y
    local layerIndex = 0

    while true do
        -- 决定下一层间距（3~5 格）
        local gap = rngRange(3, 5)
        local nextY = currentY + gap

        if nextY > H - 2 then break end  -- 留顶部余量

        layerIndex = layerIndex + 1

        -- 判断是否为检查点层
        local isCheckpointLayer = (nextY - spawnY) >= Config.CheckpointInterval
            and ((nextY - spawnY) % Config.CheckpointInterval) < gap

        -- 更精确：找最接近 CheckpointInterval 倍数的层
        local heightAboveSpawn = nextY - spawnY
        local nearestCheckpoint = math.floor(heightAboveSpawn / Config.CheckpointInterval + 0.5) * Config.CheckpointInterval
        if math.abs(heightAboveSpawn - nearestCheckpoint) < gap and nearestCheckpoint > 0 then
            -- 检查这个检查点是否还没生成过
            local alreadyExists = false
            for _, cy in ipairs(MapData.CheckpointYList) do
                if math.abs(cy - (spawnY + nearestCheckpoint)) < Config.CheckpointInterval * 0.5 then
                    alreadyExists = true
                    break
                end
            end
            if not alreadyExists then
                isCheckpointLayer = true
            end
        end

        -- 决定这一层的平台数量和布局
        local numPlatforms = rngRange(2, 4)
        local minLen = 3
        local maxLen = 10

        if isCheckpointLayer then
            -- 检查点层：一个宽平台横跨大部分地图
            local cpLen = rngRange(W - 8, W - 4)  -- 22~26 格宽
            local cpStart = rngRange(2, W - cpLen)
            for x = cpStart, math.min(cpStart + cpLen - 1, W) do
                grid[nextY][x] = CP
            end
            -- 两端用安全方块封边
            if cpStart > 1 then
                grid[nextY][cpStart] = S
            end
            if cpStart + cpLen - 1 < W then
                grid[nextY][math.min(cpStart + cpLen - 1, W)] = S
            end

            -- 记录检查点世界 Y
            local cpWorldY = (nextY - 1) * Config.BlockSize + Config.BlockSize * 0.5
            table.insert(MapData.CheckpointYList, cpWorldY)
        else
            -- 普通层：生成多个平台段
            -- 将地图宽度分成若干区域，每个区域放一个平台
            local segments = {}
            local segWidth = math.floor(W / numPlatforms)

            for i = 1, numPlatforms do
                local segStart = (i - 1) * segWidth + 1
                local segEnd = i * segWidth
                if i == numPlatforms then segEnd = W end

                -- 平台长度和起始位置（在区域内随机）
                local platLen = rngRange(minLen, math.min(maxLen, segEnd - segStart + 1))
                local platStart = rngRange(segStart, math.max(segStart, segEnd - platLen + 1))

                table.insert(segments, { start = platStart, len = platLen })
            end

            -- 放置平台
            for _, seg in ipairs(segments) do
                local blockType = N  -- 默认普通方块

                -- 20% 概率出现安全方块平台
                if rngRange(1, 100) <= 20 then
                    blockType = S
                end

                -- 10% 概率出现能量托台
                local hasEnergyPad = rngRange(1, 100) <= 10

                for x = seg.start, math.min(seg.start + seg.len - 1, W) do
                    grid[nextY][x] = blockType
                end

                -- 在平台中间放一个能量托台
                if hasEnergyPad and seg.len >= 3 then
                    local midX = seg.start + math.floor(seg.len / 2)
                    grid[nextY][midX] = EP
                end
            end
        end

        currentY = nextY
    end

    -- ====================================================================
    -- 确保可达性：检查相邻层的水平距离
    -- ====================================================================
    -- (程序化生成已通过区域划分保证水平覆盖，
    --  层间距 3-5 格在二段跳范围内，因此基本可达)

    -- 对 CheckpointYList 排序
    table.sort(MapData.CheckpointYList)

    print("[MapData] Generated " .. layerIndex .. " layers, "
        .. #MapData.CheckpointYList .. " checkpoints")

    return grid
end

--- 获取指定玩家的出生位置（世界坐标）
---@param playerIndex number 1~6
---@return number, number  -- x, y
function MapData.GetSpawnPosition(playerIndex)
    local sp = MapData.SpawnPositions[playerIndex]
    if sp then
        return sp.x, sp.y
    end
    -- 回退
    local x = MapData.SpawnX + (playerIndex - 1) * 1.2
    local y = MapData.SpawnY
    return x, y
end

--- 获取指定世界 Y 坐标以下最近的检查点 Y（用于重生）
--- 如果没有激活过的检查点，返回出生点 Y
---@param activatedCheckpoints table<number, boolean>  已激活的检查点索引集合
---@return number worldY  重生高度
---@return number worldX  重生 X 坐标（检查点中心）
function MapData.GetCheckpointRespawnPos(activatedCheckpoints, grid)
    -- 从高到低遍历检查点，找最高的已激活检查点
    local bestY = nil
    local bestGridY = nil
    for i = #MapData.CheckpointYList, 1, -1 do
        if activatedCheckpoints[i] then
            bestY = MapData.CheckpointYList[i]
            -- 从世界坐标反算 grid Y
            bestGridY = math.floor(bestY / Config.BlockSize) + 1
            break
        end
    end

    if bestY and bestGridY and grid then
        -- 找检查点层的中心 X
        local sumX, countX = 0, 0
        for x = 1, MapData.Width do
            if grid[bestGridY] and grid[bestGridY][x] ~= E then
                sumX = sumX + x
                countX = countX + 1
            end
        end
        local centerX = MapData.Width / 2
        if countX > 0 then
            centerX = sumX / countX
        end
        local wx = (centerX - 1) * Config.BlockSize + Config.BlockSize * 0.5
        return { x = wx, y = bestY + Config.BlockSize }  -- 站在检查点上方
    end

    -- 没有激活的检查点
    return nil
end

--- 检查某个世界 Y 是否在某个检查点附近
--- 返回检查点索引（1-based）或 nil
---@param wy number 世界 Y 坐标
---@return number|nil checkpointIndex
function MapData.GetCheckpointAt(wy)
    for i, cpY in ipairs(MapData.CheckpointYList) do
        if math.abs(wy - cpY) < 1.2 then
            return i
        end
    end
    return nil
end

--- 检查某个世界坐标是否在终点区域（大地图模式不使用，保留兼容）
---@param wx number
---@param wy number
---@return boolean
function MapData.IsAtFinish(wx, wy)
    return false  -- 大地图模式没有终点
end

-- ============================================================================
-- 自定义地图支持（编辑器用，大地图模式保留接口兼容）
-- ============================================================================

--- 是否有自定义地图
---@return boolean
function MapData.HasCustomGrid()
    return false  -- 大地图模式不支持自定义地图
end

--- 设置自定义地图网格（保留接口兼容）
function MapData.SetCustomGrid(grid)
    print("[MapData] SetCustomGrid ignored in big-map mode")
end

--- 清除自定义地图
function MapData.ClearCustomGrid()
    print("[MapData] ClearCustomGrid ignored in big-map mode")
end

return MapData
