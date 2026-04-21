-- ============================================================================
-- MapData.lua - 超级红温！关卡地图数据 v4
-- 方块类型：0=空 1=普通 2=安全 4=旧起点 5=终点 10-13=P1~P4出生点
-- 坐标系：X 右，Y 上，每格 1m
-- 地图尺寸：默认 30x24（固定相机可视全局）
-- ============================================================================

local Config = require("Config")

local MapData = {}

-- 方块类型常量（简写）
local E = Config.BLOCK_EMPTY
local N = Config.BLOCK_NORMAL
local S = Config.BLOCK_SAFE
local SP = Config.BLOCK_SPAWN
local FI = Config.BLOCK_FINISH

-- 地图宽高（可被 SetDimensions 修改）
MapData.Width  = Config.DefaultMapWidth
MapData.Height = Config.DefaultMapHeight

-- 出生点位置表：SpawnPositions[playerIndex] = { x=世界X, y=世界Y }
-- 由 Generate() 扫描网格填充
MapData.SpawnPositions = {}

-- 兼容旧版：单一起点坐标（用于旧版 BLOCK_SPAWN 回退）
MapData.SpawnX = 6
MapData.SpawnY = 4

-- 终点方块世界坐标列表（Generate 时填充）
MapData.FinishBlocks = {}

-- 自定义地图网格（编辑器使用）
local customGrid_ = nil

-- 能量拾取点位置列表（现由 RandomPickup 随机生成，此表保留为空）
MapData.EnergyPickups = {}

--- 设置地图尺寸（加载关卡时调用）
---@param w number
---@param h number
function MapData.SetDimensions(w, h)
    MapData.Width = w or Config.DefaultMapWidth
    MapData.Height = h or Config.DefaultMapHeight
end

--- 生成地图网格数据
--- grid[y][x] = 方块类型（Lua 索引从 1 开始）
---@return table
function MapData.Generate()
    -- 重置出生点
    MapData.SpawnPositions = {}
    MapData.FinishBlocks = {}

    -- 如果有自定义地图，使用自定义地图
    if customGrid_ then
        local grid = {}
        local oldSpawnX, oldSpawnY = nil, nil

        for y = 1, MapData.Height do
            grid[y] = {}
            for x = 1, MapData.Width do
                local cell = customGrid_[y] and customGrid_[y][x] or E
                grid[y][x] = cell

                -- 收集终点方块
                if cell == FI then
                    local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                    local wy = (y - 1) * Config.BlockSize + Config.BlockSize * 0.5
                    table.insert(MapData.FinishBlocks, { x = wx, y = wy })
                end

                -- 收集 P1-P4 出生点
                for pi = 1, 4 do
                    if cell == Config.SpawnBlockTypes[pi] then
                        local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                        local wy = y * Config.BlockSize  -- 站在方块上方
                        MapData.SpawnPositions[pi] = { x = wx, y = wy }
                    end
                end

                -- 兼容旧版 BLOCK_SPAWN（取第一个作为通用起点）
                if cell == SP and oldSpawnX == nil then
                    oldSpawnX = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                    oldSpawnY = y * Config.BlockSize
                end
            end
        end

        -- 旧版兼容：如果没有 P1-P4 出生点，使用旧版 SPAWN
        if oldSpawnX then
            MapData.SpawnX = oldSpawnX
            MapData.SpawnY = oldSpawnY
        end

        -- 如果没有任何 P1-P4 出生点，用旧版 SPAWN 位置为所有玩家分配
        if #MapData.SpawnPositions == 0 and oldSpawnX then
            for pi = 1, 4 do
                MapData.SpawnPositions[pi] = {
                    x = oldSpawnX + (pi - 1) * 1.2,
                    y = oldSpawnY,
                }
            end
        end

        return grid
    end

    -- ========================================================================
    -- 默认地图（30x24 简单测试用）
    -- ========================================================================
    local grid = {}
    for y = 1, MapData.Height do
        grid[y] = {}
        for x = 1, MapData.Width do
            grid[y][x] = E
        end
    end

    local function placePlatform(startX, y, length, blockType)
        for x = startX, startX + length - 1 do
            if x >= 1 and x <= MapData.Width and y >= 1 and y <= MapData.Height then
                grid[y][x] = blockType
            end
        end
    end

    -- Y=3: 起点层（底部安全平台）
    placePlatform(1, 3, MapData.Width, S)

    -- P1 出生点：左下 x=5
    grid[3][5] = Config.BLOCK_SPAWN_P1
    -- P2 出生点：右下 x=26
    grid[3][26] = Config.BLOCK_SPAWN_P2
    -- P3 出生点：左偏中 x=10
    grid[3][10] = Config.BLOCK_SPAWN_P3
    -- P4 出生点：右偏中 x=21
    grid[3][21] = Config.BLOCK_SPAWN_P4

    -- Y=5: 第一层跳台
    placePlatform(4, 5, 6, N)
    placePlatform(20, 5, 6, N)

    -- Y=7: 中间层
    placePlatform(10, 7, 10, N)
    placePlatform(12, 7, 3, S)

    -- Y=9: 高层
    placePlatform(3, 9, 5, N)
    placePlatform(22, 9, 5, N)

    -- Y=11: 汇合层
    placePlatform(9, 11, 12, N)
    placePlatform(14, 11, 3, S)

    -- Y=13: 终点层
    placePlatform(12, 13, 6, S)
    for x = 13, 16 do
        grid[13][x] = FI
    end

    -- 扫描出生点
    for y = 1, MapData.Height do
        for x = 1, MapData.Width do
            local cell = grid[y][x]
            for pi = 1, 4 do
                if cell == Config.SpawnBlockTypes[pi] then
                    local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                    local wy = y * Config.BlockSize
                    MapData.SpawnPositions[pi] = { x = wx, y = wy }
                end
            end
            if cell == FI then
                local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                local wy = (y - 1) * Config.BlockSize + Config.BlockSize * 0.5
                table.insert(MapData.FinishBlocks, { x = wx, y = wy })
            end
        end
    end

    -- 兼容旧版字段
    if MapData.SpawnPositions[1] then
        MapData.SpawnX = MapData.SpawnPositions[1].x
        MapData.SpawnY = MapData.SpawnPositions[1].y
    end

    return grid
end

--- 获取指定玩家的出生位置（世界坐标）
---@param playerIndex number 1~4
---@return number, number  -- x, y
function MapData.GetSpawnPosition(playerIndex)
    local sp = MapData.SpawnPositions[playerIndex]
    if sp then
        return sp.x, sp.y
    end

    -- 回退：用旧版单一起点 + 水平偏移
    local x = MapData.SpawnX + (playerIndex - 1) * 1.2
    local y = MapData.SpawnY
    return x, y
end

--- 检查某个世界坐标是否在终点区域
---@param wx number
---@param wy number
---@return boolean
function MapData.IsAtFinish(wx, wy)
    for _, fb in ipairs(MapData.FinishBlocks) do
        local dx = math.abs(wx - fb.x)
        local dy = wy - fb.y
        if dx < 0.8 and dy > -0.2 and dy < 1.5 then
            return true
        end
    end
    return false
end

-- ============================================================================
-- 自定义地图支持（编辑器用）
-- ============================================================================

--- 设置自定义地图网格（深拷贝输入）
---@param grid table grid[y][x] 格式
function MapData.SetCustomGrid(grid)
    customGrid_ = {}
    for y = 1, MapData.Height do
        customGrid_[y] = {}
        for x = 1, MapData.Width do
            customGrid_[y][x] = (grid[y] and grid[y][x]) or E
        end
    end
    print("[MapData] Custom grid set (" .. MapData.Width .. "x" .. MapData.Height .. ")")
end

--- 是否有自定义地图
---@return boolean
function MapData.HasCustomGrid()
    return customGrid_ ~= nil
end

--- 清除自定义地图（恢复使用默认生成）
function MapData.ClearCustomGrid()
    customGrid_ = nil
    -- 恢复默认尺寸和起点
    MapData.Width = Config.DefaultMapWidth
    MapData.Height = Config.DefaultMapHeight
    MapData.SpawnX = 6
    MapData.SpawnY = 4
    MapData.SpawnPositions = {}
    print("[MapData] Custom grid cleared, using default map")
end

return MapData
