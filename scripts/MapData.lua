-- ============================================================================
-- MapData.lua - 垂直之字形攀登赛道地图数据
-- 方块类型：0=空 1=普通可破坏 2=安全不可破坏 4=起点 5=终点
-- 坐标系：X 右，Y 上，每格 1m
-- 设计：5 层水平跑道 + 交替方向台阶 → 顶部金色终点
-- ============================================================================

local Config = require("Config")

local MapData = {}

-- 方块类型常量（简写）
local E = Config.BLOCK_EMPTY
local N = Config.BLOCK_NORMAL
local S = Config.BLOCK_SAFE
local SP = Config.BLOCK_SPAWN
local FI = Config.BLOCK_FINISH

-- ============================================================================
-- 垂直之字形攀登赛道
-- 设计理念：
--   起点(左下) → 右跑(L1) → 右侧台阶上升 → 左跑(L2) → 左侧台阶上升 →
--   右跑(L3) → 右侧台阶上升 → 左跑(L4) → 左侧台阶上升 →
--   右跑(L5) → 中央台阶 → 顶部终点(金色方块)
--
-- 地图宽 40 格，高 28 格
-- 玩家从左下出发，逐层攀升到顶部金色终点
-- ============================================================================

-- 地图宽高
MapData.Width = 40
MapData.Height = 28

-- 起点坐标（世界坐标）
MapData.SpawnX = 4
MapData.SpawnY = 4  -- 站在 Y=3 的平台上

-- 终点方块世界坐标列表（Generate 时填充）
MapData.FinishBlocks = {}

-- 能量拾取点位置列表（世界坐标）
MapData.EnergyPickups = {
    -- 小能量块（沿路线分布）
    { x = 12.5, y = 3.8,  size = "small" },   -- L1 前段
    { x = 28.5, y = 3.8,  size = "small" },   -- L1 后段
    { x = 30.5, y = 7.8,  size = "small" },   -- L2 前段
    { x = 12.5, y = 7.8,  size = "small" },   -- L2 后段
    { x = 12.5, y = 11.8, size = "small" },   -- L3 前段
    { x = 28.5, y = 11.8, size = "small" },   -- L3 后段
    { x = 30.5, y = 15.8, size = "small" },   -- L4 前段
    { x = 12.5, y = 15.8, size = "small" },   -- L4 后段
    -- 大能量块（高风险位置：台阶附近）
    { x = 36.5, y = 5.8,  size = "large" },   -- 右台阶 L1→L2
    { x = 4.5,  y = 9.8,  size = "large" },   -- 左台阶 L2→L3
    { x = 36.5, y = 13.8, size = "large" },   -- 右台阶 L3→L4
    { x = 4.5,  y = 17.8, size = "large" },   -- 左台阶 L4→L5
    { x = 20.5, y = 21.8, size = "large" },   -- 中央台阶→终点
}

--- 生成地图网格数据
--- grid[y][x] = 方块类型（注意 Lua 索引从 1 开始）
---@return table
function MapData.Generate()
    local grid = {}

    -- 初始化空网格
    for y = 1, MapData.Height do
        grid[y] = {}
        for x = 1, MapData.Width do
            grid[y][x] = E
        end
    end

    -- 清空终点方块列表
    MapData.FinishBlocks = {}

    -- 辅助：放置一行平台
    local function placePlatform(startX, y, length, blockType)
        for x = startX, startX + length - 1 do
            if x >= 1 and x <= MapData.Width and y >= 1 and y <= MapData.Height then
                grid[y][x] = blockType
            end
        end
    end

    -- 辅助：放置安全锚点
    local function placeAnchor(startX, y, length)
        placePlatform(startX, y, length, S)
    end

    -- 辅助：放置终点方块并记录世界坐标
    local function placeFinish(startX, y, length)
        for x = startX, startX + length - 1 do
            if x >= 1 and x <= MapData.Width and y >= 1 and y <= MapData.Height then
                grid[y][x] = FI
                -- 记录世界坐标（格子中心）
                local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                local wy = (y - 1) * Config.BlockSize + Config.BlockSize * 0.5
                table.insert(MapData.FinishBlocks, { x = wx, y = wy })
            end
        end
    end

    -- ================================================================
    -- L1: 第一层 (Y=3, 左→右)
    -- ================================================================
    placeAnchor(2, 3, 5)          -- 起点安全区 x=2~6
    grid[3][3] = SP               -- 标记起点
    grid[3][4] = SP
    grid[3][5] = SP

    placePlatform(7, 3, 5, N)     -- x=7~11
    placeAnchor(12, 3, 2)         -- x=12~13 安全锚点
    placePlatform(14, 3, 8, N)    -- x=14~21
    -- 间隙 x=18
    grid[3][18] = E
    placeAnchor(22, 3, 2)         -- x=22~23 安全锚点
    placePlatform(24, 3, 8, N)    -- x=24~31
    -- 间隙 x=28
    grid[3][28] = E
    placeAnchor(32, 3, 2)         -- x=32~33 安全锚点
    placePlatform(34, 3, 4, N)    -- x=34~37

    -- ================================================================
    -- 右台阶 L1→L2 (x=35~37)
    -- ================================================================
    placePlatform(35, 5, 3, N)    -- Y=5 中间台阶

    -- ================================================================
    -- L2: 第二层 (Y=7, 右→左)
    -- ================================================================
    placeAnchor(35, 7, 3)         -- 右侧安全入口 x=35~37
    placePlatform(27, 7, 8, N)    -- x=27~34
    -- 间隙 x=31
    grid[7][31] = E
    placeAnchor(25, 7, 2)         -- x=25~26 安全锚点
    placePlatform(15, 7, 10, N)   -- x=15~24
    -- 间隙 x=20
    grid[7][20] = E
    placeAnchor(13, 7, 2)         -- x=13~14 安全锚点
    placePlatform(4, 7, 9, N)     -- x=4~12
    -- 间隙 x=8
    grid[7][8] = E

    -- ================================================================
    -- 左台阶 L2→L3 (x=3~5)
    -- ================================================================
    placePlatform(3, 9, 3, N)     -- Y=9 中间台阶

    -- ================================================================
    -- L3: 第三层 (Y=11, 左→右)
    -- ================================================================
    placeAnchor(3, 11, 3)         -- 左侧安全入口 x=3~5
    placePlatform(6, 11, 8, N)    -- x=6~13
    -- 间隙 x=10
    grid[11][10] = E
    placeAnchor(14, 11, 2)        -- x=14~15 安全锚点
    placePlatform(16, 11, 8, N)   -- x=16~23
    -- 间隙 x=20
    grid[11][20] = E
    placeAnchor(24, 11, 2)        -- x=24~25 安全锚点
    placePlatform(26, 11, 9, N)   -- x=26~34
    -- 间隙 x=30
    grid[11][30] = E
    placePlatform(35, 11, 3, N)   -- x=35~37

    -- ================================================================
    -- 右台阶 L3→L4 (x=35~37)
    -- ================================================================
    placePlatform(35, 13, 3, N)   -- Y=13 中间台阶

    -- ================================================================
    -- L4: 第四层 (Y=15, 右→左)
    -- ================================================================
    placeAnchor(35, 15, 3)        -- 右侧安全入口 x=35~37
    placePlatform(27, 15, 8, N)   -- x=27~34
    -- 间隙 x=31
    grid[15][31] = E
    placeAnchor(25, 15, 2)        -- x=25~26 安全锚点
    placePlatform(15, 15, 10, N)  -- x=15~24
    -- 间隙 x=20
    grid[15][20] = E
    placeAnchor(13, 15, 2)        -- x=13~14 安全锚点
    placePlatform(4, 15, 9, N)    -- x=4~12
    -- 间隙 x=8
    grid[15][8] = E

    -- ================================================================
    -- 左台阶 L4→L5 (x=3~5)
    -- ================================================================
    placePlatform(3, 17, 3, N)    -- Y=17 中间台阶

    -- ================================================================
    -- L5: 第五层 (Y=19, 左→右，向中央收束)
    -- ================================================================
    placeAnchor(3, 19, 3)         -- 左侧安全入口 x=3~5
    placePlatform(6, 19, 10, N)   -- x=6~15
    -- 间隙 x=11
    grid[19][11] = E
    placeAnchor(16, 19, 2)        -- x=16~17 安全锚点
    placePlatform(18, 19, 6, N)   -- x=18~23
    placeAnchor(24, 19, 2)        -- x=24~25 安全锚点
    placePlatform(26, 19, 10, N)  -- x=26~35
    -- 间隙 x=31
    grid[19][31] = E

    -- ================================================================
    -- 中央台阶 L5→终点 (x=18~23)
    -- ================================================================
    placePlatform(17, 21, 8, N)   -- Y=21 中间台阶 x=17~24

    -- ================================================================
    -- 终点平台 (Y=24, 金色方块)
    -- 终点在最高处！玩家触碰这些金色方块才算到达终点
    -- ================================================================
    placeAnchor(14, 24, 2)        -- 左护栏 x=14~15
    placeFinish(16, 24, 10)       -- 金色终点 x=16~25
    placeAnchor(26, 24, 2)        -- 右护栏 x=26~27

    return grid
end

--- 获取起点位置（世界坐标）
---@param playerIndex number 1~4
---@return number, number  -- x, y
function MapData.GetSpawnPosition(playerIndex)
    -- 4 名玩家在起点平台并排出生
    local x = MapData.SpawnX + (playerIndex - 1) * 1.2
    local y = MapData.SpawnY
    return x, y
end

--- 检查某个世界坐标是否在终点区域
--- 通过检测与实际终点方块的距离判定（而非坐标范围）
---@param wx number
---@param wy number
---@return boolean
function MapData.IsAtFinish(wx, wy)
    -- 检查是否站在任何终点方块上方（距离方块中心 1.2m 以内）
    for _, fb in ipairs(MapData.FinishBlocks) do
        local dx = math.abs(wx - fb.x)
        local dy = wy - fb.y  -- 玩家应该在方块上方
        -- 水平距离在 0.8 格以内，垂直在方块上方 0~1.5m
        if dx < 0.8 and dy > -0.2 and dy < 1.5 then
            return true
        end
    end
    return false
end

return MapData
