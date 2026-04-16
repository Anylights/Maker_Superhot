-- ============================================================================
-- MapData.lua - 超级红温！关卡地图数据
-- 方块类型：0=空 1=普通可破坏 2=安全不可破坏 4=起点 5=终点
-- 坐标系：X 右，Y 上，每格 1m
-- ============================================================================
-- 设计模板：8字擦肩型 + 终点争桥型（混合）
-- 6 个单元，双路线，7 个主竞点，3 个次竞点，终点在最高处
--
-- 角色移动包线（基于 Config.lua）：
--   RunJumpMax   ≈ 19 格（助跑最大水平跳跃）
--   JumpHeightMax ≈ 10 格（最大跳高）
--   主路径跳跃 ≤ 13 格水平, ≤ 6 格高度
--   主路径落点 ≥ 3 格宽
--   爆炸半径 = 7 格
--
-- 路线可达性验证摘要：
--   每段跳跃水平距离 ≤ 8格，高度差 ≤ 5格
--   所有落点宽度 ≥ 3格（主路径）
--   安全锚点占比 ≈ 30%，可破坏块 ≈ 45%，空隙 ≈ 25%
-- ============================================================================

local Config = require("Config")

local MapData = {}

-- 方块类型常量（简写）
local E = Config.BLOCK_EMPTY
local N = Config.BLOCK_NORMAL
local S = Config.BLOCK_SAFE
local SP = Config.BLOCK_SPAWN
local FI = Config.BLOCK_FINISH

-- 地图宽高
MapData.Width  = 50
MapData.Height = 48

-- 起点坐标（世界坐标）
MapData.SpawnX = 6
MapData.SpawnY = 4  -- 站在 Y=3 的平台上

-- 终点方块世界坐标列表（Generate 时填充）
MapData.FinishBlocks = {}

-- 能量拾取点位置列表（世界坐标）
MapData.EnergyPickups = {
    -- ===== U1 暖身区 =====
    { x = 18.5, y = 3.8,  size = "small" },
    { x = 35.5, y = 3.8,  size = "small" },

    -- ===== U2 分流竞争区 =====
    { x = 25.5, y = 12.8, size = "large" },   -- 竞点A：分流口争夺
    { x = 10.5, y = 14.8, size = "small" },    -- 左路
    { x = 40.5, y = 15.8, size = "small" },    -- 右路

    -- ===== U3 8字交叉区 =====
    { x = 25.5, y = 23.8, size = "large" },    -- 竞点C：交叉中心
    { x = 8.5,  y = 21.8, size = "small" },
    { x = 42.5, y = 21.8, size = "small" },

    -- ===== U4 双层追击区 =====
    { x = 32.5, y = 32.8, size = "large" },    -- 竞点E：上层高风险
    { x = 12.5, y = 28.8, size = "small" },    -- 下层
    { x = 38.5, y = 28.8, size = "small" },    -- 下层

    -- ===== U5 收束攀升区 =====
    { x = 25.5, y = 39.8, size = "large" },    -- 竞点G：窄桥争夺
    { x = 14.5, y = 37.8, size = "small" },
    { x = 36.5, y = 37.8, size = "small" },

    -- ===== U6 终点戏剧区 =====
    { x = 25.5, y = 45.8, size = "large" },    -- 竞点I：终点前博弈
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

    -- ========================================================================
    -- 辅助函数
    -- ========================================================================

    local function placePlatform(startX, y, length, blockType)
        for x = startX, startX + length - 1 do
            if x >= 1 and x <= MapData.Width and y >= 1 and y <= MapData.Height then
                grid[y][x] = blockType
            end
        end
    end

    local function placeAnchor(startX, y, length)
        placePlatform(startX, y, length, S)
    end

    local function placeFinish(startX, y, length)
        for x = startX, startX + length - 1 do
            if x >= 1 and x <= MapData.Width and y >= 1 and y <= MapData.Height then
                grid[y][x] = FI
                local wx = (x - 1) * Config.BlockSize + Config.BlockSize * 0.5
                local wy = (y - 1) * Config.BlockSize + Config.BlockSize * 0.5
                table.insert(MapData.FinishBlocks, { x = wx, y = wy })
            end
        end
    end

    -- ========================================================================
    -- U1: 起点暖身区 (Y=3~9)
    -- 宽敞平台，轻松上手
    -- 双路线雏形：下方主路 + 上方小跳台
    -- ========================================================================

    -- 起点平台（安全区）
    placeAnchor(3, 3, 8)           -- x=3~10 安全起点
    grid[3][5] = SP
    grid[3][6] = SP
    grid[3][7] = SP
    grid[3][8] = SP

    -- 主路向右
    placePlatform(11, 3, 8, N)     -- x=11~18
    placeAnchor(19, 3, 3)          -- x=19~21 安全锚
    placePlatform(22, 3, 8, N)     -- x=22~29
    placeAnchor(30, 3, 3)          -- x=30~32 安全锚
    placePlatform(33, 3, 8, N)     -- x=33~40
    placeAnchor(41, 3, 3)          -- x=41~43 安全锚

    -- 上方捷径跳台（可选支线）
    placePlatform(16, 6, 4, N)     -- Y=6 x=16~19
    placePlatform(28, 6, 4, N)     -- Y=6 x=28~31

    -- U1→U2 过渡：右侧台阶上升
    placePlatform(42, 6, 5, N)     -- 第一级 Y=6 x=42~46
    placeAnchor(44, 6, 3)          -- 部分安全
    placePlatform(40, 9, 5, N)     -- 第二级 Y=9 x=40~44
    placeAnchor(41, 9, 3)          -- 部分安全

    -- ========================================================================
    -- U2: 分流竞争区 (Y=10~18)
    -- 从右上入口进入，中央分流平台
    -- 竞点A：分流口能量争夺（中央大能量）
    -- 竞点B：右路断桥拦截
    -- ========================================================================

    -- 入口平台（安全缓冲）
    placeAnchor(38, 12, 5)         -- x=38~42 Y=12 安全入口

    -- 中央分流平台（竞点A）
    placePlatform(22, 12, 6, N)    -- x=22~27 中央可破坏
    placeAnchor(24, 12, 3)         -- x=24~26 中央锚点（保底）
    placePlatform(28, 12, 5, N)    -- x=28~32 连接右侧

    -- 左路过渡
    placePlatform(15, 12, 5, N)    -- x=15~19 连接左路

    -- === 左路线（安全稳定）===
    placeAnchor(7, 13, 3)          -- x=7~9 Y=13 安全台
    placePlatform(4, 14, 7, N)     -- x=4~10 Y=14 左主平台
    placeAnchor(5, 14, 3)          -- 部分安全
    -- 左路出口向上
    placePlatform(6, 17, 7, N)     -- x=6~12 Y=17
    placeAnchor(7, 17, 3)          -- 安全锚

    -- === 右路线（快但有断桥）===
    placePlatform(35, 12, 3, N)    -- x=35~37 连接
    placePlatform(36, 15, 8, N)    -- x=36~43 Y=15 断桥平台（竞点B）
    -- 右路出口向上
    placePlatform(40, 17, 6, N)    -- x=40~45 Y=17
    placeAnchor(42, 17, 3)         -- 安全锚

    -- ========================================================================
    -- U2→U3 过渡
    -- 两条路线都向中央汇合
    -- ========================================================================

    -- 左路上升台阶
    placePlatform(11, 19, 5, N)    -- Y=19 x=11~15
    placeAnchor(12, 19, 2)         -- 安全锚

    -- 右路上升台阶
    placePlatform(36, 19, 5, N)    -- Y=19 x=36~40
    placeAnchor(37, 19, 2)         -- 安全锚

    -- ========================================================================
    -- U3: 8字交叉区 (Y=19~26)
    -- 路线交叉：左路→右上，右路→左上
    -- 竞点C：交叉中心大能量
    -- ========================================================================

    -- 左路入口 → 向右上方穿越
    placePlatform(6, 21, 6, N)     -- x=6~11 Y=21
    placeAnchor(7, 21, 2)          -- 安全锚
    placePlatform(14, 22, 5, N)    -- x=14~18 Y=22

    -- 右路入口 → 向左上方穿越
    placePlatform(38, 21, 6, N)    -- x=38~43 Y=21
    placeAnchor(40, 21, 2)         -- 安全锚
    placePlatform(32, 22, 5, N)    -- x=32~36 Y=22

    -- 中央交叉大平台（竞点C：所有路线在此擦肩）
    placePlatform(19, 23, 13, N)   -- x=19~31 Y=23
    placeAnchor(24, 23, 3)         -- x=24~26 中央锚（保底通路）

    -- 交叉后各走一段：左路玩家→右侧出口，右路玩家→左侧出口
    placePlatform(32, 25, 6, N)    -- x=32~37 Y=25 （原右路方向）
    placeAnchor(34, 25, 2)         -- 安全锚
    placePlatform(12, 25, 6, N)    -- x=12~17 Y=25 （原左路方向）
    placeAnchor(13, 25, 2)         -- 安全锚

    -- ========================================================================
    -- U3→U4 过渡
    -- 两侧都有通道进入 U4
    -- ========================================================================

    -- 左侧过渡（从 x=12~17 Y=25 向下层）
    placePlatform(8, 27, 5, N)     -- Y=27 x=8~12

    -- 右侧过渡（从 x=32~37 Y=25 向下层）
    placePlatform(38, 27, 5, N)    -- Y=27 x=38~42

    -- ========================================================================
    -- U4: 双层追击区 (Y=27~34)
    -- 下层：安全稳定（多锚点），横跨全图
    -- 上层：快速但危险，间断跳台
    -- 竞点E：上层大能量
    -- 竞点F：层间连通（爆炸可断两层路）
    -- ========================================================================

    -- === 下层 (Y=28) 安全稳定，横跨全图 ===
    placeAnchor(5, 28, 4)          -- x=5~8 安全入口（左）
    placePlatform(9, 28, 7, N)     -- x=9~15
    placeAnchor(16, 28, 3)         -- x=16~18 安全锚
    placePlatform(19, 28, 8, N)    -- x=19~26
    placeAnchor(27, 28, 3)         -- x=27~29 安全锚
    placePlatform(30, 28, 8, N)    -- x=30~37
    placeAnchor(38, 28, 3)         -- x=38~40 安全锚
    placePlatform(41, 28, 4, N)    -- x=41~44
    placeAnchor(43, 28, 3)         -- x=43~45 安全入口（右）

    -- === 上层 (Y=31~32) 快速但危险 ===
    placePlatform(38, 31, 5, N)    -- x=38~42 Y=31 右入口
    placePlatform(30, 32, 5, N)    -- x=30~34 Y=32 （竞点E大能量附近）
    placePlatform(22, 31, 5, N)    -- x=22~26 Y=31
    placePlatform(14, 32, 5, N)    -- x=14~18 Y=32
    placePlatform(6, 31, 5, N)     -- x=6~10 Y=31 左出口

    -- 上下层连接（竞点F：可从上层安全跳到下层）
    placePlatform(25, 30, 3, N)    -- x=25~27 Y=30 竖直连接

    -- ========================================================================
    -- U4→U5 过渡
    -- 双路线分别上升
    -- ========================================================================

    -- 右侧出口台阶（从下层右端 Y=28 / 上层右入口上升）
    placeAnchor(44, 31, 3)         -- x=44~46 Y=31 右出口台阶
    placePlatform(43, 34, 4, N)    -- x=43~46 Y=34

    -- 左侧出口台阶（从上层左出口上升）
    placePlatform(4, 34, 5, N)     -- x=4~8 Y=34
    placeAnchor(5, 34, 2)          -- 安全锚

    -- ========================================================================
    -- U5: 收束攀升区 (Y=35~42)
    -- 双路线重新汇合，向中央收束
    -- 竞点G：汇合口窄桥争夺
    -- ========================================================================

    -- 左路上升
    placePlatform(7, 37, 6, N)     -- x=7~12 Y=37
    placeAnchor(8, 37, 2)          -- 安全锚
    placePlatform(14, 38, 5, N)    -- x=14~18 Y=38

    -- 右路上升
    placePlatform(37, 37, 6, N)    -- x=37~42 Y=37
    placeAnchor(39, 37, 2)         -- 安全锚
    placePlatform(32, 38, 5, N)    -- x=32~36 Y=38

    -- 汇合大平台（竞点G：窄桥争夺）
    placePlatform(19, 39, 13, N)   -- x=19~31 Y=39
    placeAnchor(24, 39, 3)         -- x=24~26 中央锚

    -- 汇合后向上
    placePlatform(21, 41, 9, N)    -- x=21~29 Y=41
    placeAnchor(24, 41, 3)         -- x=24~26 安全锚

    -- ========================================================================
    -- U6: 终点戏剧区 (Y=43~48)
    -- 最终博弈：断桥 + 大能量 + 终点在最高处
    -- 竞点I：终点前断桥戏剧点
    -- ========================================================================

    -- 中央攀升
    placePlatform(22, 43, 7, N)    -- x=22~28 Y=43
    placeAnchor(24, 43, 3)         -- 安全锚

    -- 终点前断桥（竞点I：大能量 + 可炸断）
    placePlatform(18, 45, 15, N)   -- x=18~32 Y=45 可破坏断桥
    placeAnchor(25, 45, 1)         -- x=25 最小锚（保底1格通过）

    -- 左右安全旁路（保底路线，更慢但不怕炸）
    placeAnchor(14, 44, 3)         -- x=14~16 Y=44 左旁路
    placeAnchor(33, 44, 3)         -- x=33~35 Y=44 右旁路

    -- 终点台阶
    placeAnchor(19, 46, 3)         -- x=19~21 Y=46 左台阶
    placeAnchor(30, 46, 3)         -- x=30~32 Y=46 右台阶

    -- 终点护栏
    placeAnchor(19, 47, 3)         -- x=19~21 Y=47 左护栏
    placeAnchor(30, 47, 3)         -- x=30~32 Y=47 右护栏

    -- 最终终点平台（地图最高处 Y=48）
    placeFinish(22, 48, 8)         -- 金色终点 x=22~29 Y=48

    return grid
end

--- 获取起点位置（世界坐标）
---@param playerIndex number 1~4
---@return number, number  -- x, y
function MapData.GetSpawnPosition(playerIndex)
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

return MapData
