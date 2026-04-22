-- ============================================================================
-- LevelsData.lua - 内置关卡数据（持久化存储）
-- 此文件由关卡编辑器自动更新，保存在工程中，刷新不会丢失
-- 格式：每个关卡 = { name, width, height, blocks = {{x,y,t}, ...} }
-- 方块类型：0=空 1=普通可破坏 2=安全不可破坏
--           10=P1出生 11=P2出生 12=P3出生 13=P4出生 5=终点
-- 平台间距规范：每层 Y 差 = 3（1格平台 + 2格空气 + 上层平台）
-- ============================================================================

local LevelsData = {}

-- 关卡存储表：key = 文件名（如 "level_001"），value = 关卡数据
LevelsData.levels = {}

-- ============================================================================
-- 辅助函数：简化关卡构建
-- ============================================================================

local W, H = 30, 24

--- 在 blocks 表中添加一段水平平台
---@param blocks table
---@param startX number 起始X (1-based)
---@param y number Y坐标 (1-based)
---@param length number 平台长度
---@param blockType number 方块类型
local function addPlatform(blocks, startX, y, length, blockType)
    for x = startX, startX + length - 1 do
        if x >= 1 and x <= W and y >= 1 and y <= H then
            table.insert(blocks, { x = x, y = y, t = blockType })
        end
    end
end

--- 添加单个方块
---@param blocks table
---@param x number
---@param y number
---@param blockType number
local function addBlock(blocks, x, y, blockType)
    if x >= 1 and x <= W and y >= 1 and y <= H then
        table.insert(blocks, { x = x, y = y, t = blockType })
    end
end

-- 简写常量
local N  = 1   -- 普通可破坏
local S  = 2   -- 安全不可破坏
local FI = 5   -- 终点
local P1 = 10  -- P1出生点（番茄红）
local P2 = 11  -- P2出生点（宝蓝）
local P3 = 12  -- P3出生点（翠绿）
local P4 = 13  -- P4出生点（鲜黄）

-- ============================================================================
-- 关卡 1: "新手峡谷" - 阶梯入门关卡 (30×24)
-- Z字形交错上升，层间距+3（2格空气），宽平台，简单左右交替
-- 6层平台 Y=2→5→8→11→14→17，终点Y=20
-- ============================================================================
do
    local b = {}

    -- Y=2: 底部出生平台
    addPlatform(b, 3, 2, 3, N)      -- x=3-5
    addBlock(b, 6, 2, P1)           -- P1出生
    addPlatform(b, 7, 2, 2, N)      -- x=7-8
    addBlock(b, 9, 2, P2)           -- P2出生
    addPlatform(b, 10, 2, 11, N)    -- x=10-20 中段可破坏
    addBlock(b, 21, 2, P3)          -- P3出生
    addPlatform(b, 22, 2, 2, N)     -- x=22-23
    addBlock(b, 24, 2, P4)          -- P4出生
    addPlatform(b, 25, 2, 4, N)     -- x=25-28

    -- Y=5: 右侧台阶 (+3)
    addPlatform(b, 14, 5, 14, N)    -- x=14-27 长可破坏
    addBlock(b, 15, 5, S)           -- x=15 单个安全锚

    -- Y=8: 左侧台阶 (+3)
    addPlatform(b, 3, 8, 14, N)     -- x=3-16 长可破坏
    addBlock(b, 15, 8, S)           -- x=15 单个安全锚

    -- Y=11: 右侧台阶 (+3)
    addPlatform(b, 12, 11, 15, N)   -- x=12-26 可破坏
    addBlock(b, 16, 11, S)          -- x=16 安全锚

    -- Y=14: 左侧台阶 (+3) - 窄化
    addPlatform(b, 4, 14, 12, N)    -- x=4-15 可破坏
    addBlock(b, 14, 14, S)          -- x=14 安全锚

    -- Y=17: 终点前汇合 (+3)
    addPlatform(b, 7, 17, 5, N)     -- x=7-11 左可破坏桥
    addPlatform(b, 13, 17, 5, N)    -- x=13-17 中可破坏桥
    addPlatform(b, 19, 17, 5, N)    -- x=19-23 右可破坏桥

    -- Y=20: 终点层 (+3)
    addPlatform(b, 12, 20, 3, N)    -- x=12-14 左跳台
    addBlock(b, 15, 20, FI)         -- x=15 终点（单格）
    addPlatform(b, 16, 20, 4, N)    -- x=16-19 右跳台

    LevelsData.levels["level_001"] = {
        version = 1,
        name = "新手峡谷",
        width = 30,
        height = 24,
        blocks = b,
    }
end

-- ============================================================================
-- 关卡 2: "双线竞速" - 双路线分合型 (30×24)
-- 左右两条路线分流再汇合，中段交叉，终点前争桥
-- 层间距+3，Y=2→5→8→11→14→17→20
-- ============================================================================
do
    local b = {}

    -- Y=2: 两组出生点（左右对称）
    addPlatform(b, 3, 2, 2, N)      -- x=3-4
    addBlock(b, 5, 2, P1)           -- P1出生
    addPlatform(b, 6, 2, 2, N)      -- x=6-7
    addBlock(b, 8, 2, P2)           -- P2出生
    addPlatform(b, 9, 2, 3, N)      -- x=9-11
    addPlatform(b, 20, 2, 3, N)     -- x=20-22
    addBlock(b, 23, 2, P3)          -- P3出生
    addPlatform(b, 24, 2, 2, N)     -- x=24-25
    addBlock(b, 26, 2, P4)          -- P4出生
    addPlatform(b, 27, 2, 2, N)     -- x=27-28

    -- Y=5: 左右分流 (+3)
    addPlatform(b, 3, 5, 10, N)     -- x=3-12 左路可破坏
    addPlatform(b, 19, 5, 10, N)    -- x=19-28 右路可破坏

    -- Y=8: 路线交叉向中靠拢 (+3)
    addPlatform(b, 6, 8, 8, N)      -- x=6-13 左路内移
    addBlock(b, 10, 8, S)           -- x=10 安全锚
    addPlatform(b, 17, 8, 8, N)     -- x=17-24 右路内移
    addBlock(b, 21, 8, S)           -- x=21 安全锚

    -- Y=11: 中央汇合大平台 (+3)
    addPlatform(b, 5, 11, 21, N)    -- x=5-25 大面积可破坏
    addBlock(b, 15, 11, S)          -- x=15 中央锚点

    -- Y=14: 再次分流 (+3)
    addPlatform(b, 3, 14, 9, N)     -- x=3-11 左路
    addPlatform(b, 20, 14, 9, N)    -- x=20-28 右路

    -- Y=17: 终点前争桥 (+3) - 三座桥
    addPlatform(b, 5, 17, 4, N)     -- x=5-8 左桥
    addPlatform(b, 12, 17, 7, N)    -- x=12-18 中央桥（关键通道）
    addBlock(b, 15, 17, S)          -- x=15 中央唯一锚
    addPlatform(b, 22, 17, 4, N)    -- x=22-25 右桥

    -- Y=20: 终点层 (+3)
    addPlatform(b, 12, 20, 3, N)    -- x=12-14 左跳台
    addBlock(b, 15, 20, FI)         -- x=15 终点（单格）
    addPlatform(b, 16, 20, 4, N)    -- x=16-19 右跳台

    LevelsData.levels["level_002"] = {
        version = 1,
        name = "双线竞速",
        width = 30,
        height = 24,
        blocks = b,
    }
end

-- ============================================================================
-- 关卡 3: "螺旋峰" - 紧凑攀登型 (30×24)
-- 窄桥+断桥结合，操作精度要求更高，安全方块极少
-- 层间距+3，Y=2→5→8→11→14→17→20
-- ============================================================================
do
    local b = {}

    -- Y=2: 底部平台（4个出生点分散对称）
    addPlatform(b, 2, 2, 2, N)      -- x=2-3
    addBlock(b, 4, 2, P1)           -- P1出生
    addPlatform(b, 5, 2, 7, N)      -- x=5-11
    addBlock(b, 12, 2, P2)          -- P2出生
    addPlatform(b, 13, 2, 5, N)     -- x=13-17
    addBlock(b, 18, 2, P3)          -- P3出生
    addPlatform(b, 19, 2, 7, N)     -- x=19-25
    addBlock(b, 26, 2, P4)          -- P4出生
    addPlatform(b, 27, 2, 3, N)     -- x=27-29

    -- Y=5: 右侧台阶 (+3) - 窄段
    addPlatform(b, 15, 5, 4, N)     -- x=15-18 入口
    addPlatform(b, 21, 5, 8, N)     -- x=21-28 主段

    -- Y=8: 左侧台阶 (+3) - 长可破坏
    addPlatform(b, 3, 8, 12, N)     -- x=3-14 长可破坏
    addBlock(b, 10, 8, S)           -- x=10 单个锚

    -- Y=11: 右侧窄桥区 (+3) - 操作挑战
    addPlatform(b, 13, 11, 3, N)    -- x=13-15 入口
    addPlatform(b, 19, 11, 3, N)    -- x=19-21 窄中段（需跳过3格空隙）
    addPlatform(b, 25, 11, 4, N)    -- x=25-28 出口

    -- Y=14: 左侧断桥区 (+3) - 大面积可破坏
    addPlatform(b, 2, 14, 2, S)     -- x=2-3 起跳锚
    addPlatform(b, 4, 14, 10, N)    -- x=4-13 大面积可破坏
    addPlatform(b, 15, 14, 3, N)    -- x=15-17 延伸

    -- Y=17: 中央收束争桥 (+3)
    addPlatform(b, 7, 17, 6, N)     -- x=7-12 左桥
    addPlatform(b, 15, 17, 2, N)    -- x=15-16 窄中桥
    addPlatform(b, 19, 17, 6, N)    -- x=19-24 右桥

    -- Y=20: 终点层 (+3)
    addPlatform(b, 12, 20, 3, N)    -- x=12-14 左跳台
    addBlock(b, 15, 20, FI)         -- x=15 终点（单格）
    addPlatform(b, 16, 20, 4, N)    -- x=16-19 右跳台

    LevelsData.levels["level_003"] = {
        version = 1,
        name = "螺旋峰",
        width = 30,
        height = 24,
        blocks = b,
    }
end

-- ============================================================================
-- 关卡 4: "终点争桥" - 终盘戏剧型 (30×24)
-- 前半段宽松快速上升，后半段密集争桥，终点前窄通道
-- 层间距+3，Y=2→5→8→11→14→17→20
-- ============================================================================
do
    local b = {}

    -- Y=2: 宽敞中央起点
    addPlatform(b, 5, 2, 7, N)      -- x=5-11
    addBlock(b, 12, 2, P1)          -- P1出生
    addBlock(b, 13, 2, P2)          -- P2出生
    addPlatform(b, 14, 2, 4, N)     -- x=14-17
    addBlock(b, 18, 2, P3)          -- P3出生
    addBlock(b, 19, 2, P4)          -- P4出生
    addPlatform(b, 20, 2, 7, N)     -- x=20-26

    -- Y=5: 宽台快速上升 (+3)
    addPlatform(b, 4, 5, 23, N)     -- x=4-26 超宽可破坏

    -- Y=8: 分流 (+3) - 左右各一条
    addPlatform(b, 3, 8, 10, N)     -- x=3-12 左路
    addPlatform(b, 19, 8, 10, N)    -- x=19-28 右路

    -- Y=11: 汇合能量争夺 (+3)
    addPlatform(b, 6, 11, 19, N)    -- x=6-24 大平台可破坏
    addBlock(b, 15, 11, S)          -- x=15 中央唯一锚

    -- Y=14: 三条桥争夺 (+3)
    addPlatform(b, 3, 14, 5, N)     -- x=3-7 左桥
    addPlatform(b, 11, 14, 9, N)    -- x=11-19 中桥（宽但全可破坏）
    addPlatform(b, 23, 14, 5, N)    -- x=23-27 右桥

    -- Y=17: 终极窄桥 (+3)
    addPlatform(b, 8, 17, 4, N)     -- x=8-11 左入口
    addPlatform(b, 13, 17, 5, N)    -- x=13-17 窄中央桥
    addPlatform(b, 19, 17, 4, N)    -- x=19-22 右入口
    -- 远旁路（安全但慢）
    addPlatform(b, 2, 17, 3, S)     -- x=2-4 左远旁路
    addPlatform(b, 27, 17, 3, S)    -- x=27-29 右远旁路

    -- Y=20: 终点层 (+3)
    addPlatform(b, 12, 20, 3, N)    -- x=12-14 左跳台
    addBlock(b, 15, 20, FI)         -- x=15 终点（单格）
    addPlatform(b, 16, 20, 4, N)    -- x=16-19 右跳台

    LevelsData.levels["level_004"] = {
        version = 1,
        name = "终点争桥",
        width = 30,
        height = 24,
        blocks = b,
    }
end

return LevelsData
