-- ============================================================================
-- MapData.lua - 超级红温！程序化大世界地图生成 v5
-- 方块类型：0=空 1=普通 2=安全 3=能量托台 5=检查点 10-13=P1~P4出生点
-- 坐标系：X 右，Y 上，每格 1m
-- 地图尺寸：默认 30x500（大世界攀爬）
-- ============================================================================

local Config = require("Config")

local MapData = {}

-- 方块类型常量（简写）
local E  = Config.BLOCK_EMPTY
local N  = Config.BLOCK_NORMAL
local S  = Config.BLOCK_SAFE
local CP = Config.BLOCK_CHECKPOINT

-- 地图宽高
MapData.Width  = Config.DefaultMapWidth
MapData.Height = Config.DefaultMapHeight

-- 检查点行号列表（由 Generate 填充，升序）
MapData.Checkpoints = {}

-- 自定义地图网格（编辑器使用）
local customGrid_ = nil

-- 能量拾取点位置列表（由 RandomPickup 动态管理，此处保留为空）
MapData.EnergyPickups = {}

-- ============================================================================
-- 简易确定性伪随机数生成器（基于种子，跨平台一致）
-- ============================================================================
local RNG = {}
RNG.__index = RNG

function RNG.new(seed)
    local self = setmetatable({}, RNG)
    self.state = seed or 12345
    return self
end

--- 返回 [0, 1) 之间的浮点数
function RNG:next()
    -- 线性同余生成器 (LCG)，参数来自 Numerical Recipes
    self.state = (self.state * 1103515245 + 12345) % 2147483648
    return (self.state % 1000000) / 1000000.0
end

--- 返回 [min, max] 之间的整数
function RNG:nextInt(min, max)
    return min + math.floor(self:next() * (max - min + 1))
end

--- 返回 [min, max] 之间的浮点数
function RNG:nextFloat(min, max)
    return min + self:next() * (max - min)
end

-- ============================================================================
-- 公开 API
-- ============================================================================

--- 设置地图尺寸
---@param w number
---@param h number
function MapData.SetDimensions(w, h)
    MapData.Width = w or Config.DefaultMapWidth
    MapData.Height = h or Config.DefaultMapHeight
end

--- 判断某行是否是检查点行
---@param gridY number 网格行号（1-based）
---@return boolean
function MapData.IsCheckpoint(gridY)
    -- 检查点位于 CheckpointInterval 的整数倍行（从底部安全区之上开始）
    -- 底部安全区 y=1~3，第一个检查点在 y = 3 + CheckpointInterval
    local baseY = 3  -- 安全区顶部
    local interval = Config.CheckpointInterval
    if gridY <= baseY then return false end
    return ((gridY - baseY) % interval) == 0
end

--- 获取所有检查点的网格行号（升序）
---@return table  -- { gridY1, gridY2, ... }
function MapData.GetCheckpoints()
    return MapData.Checkpoints
end

--- 获取指定高度以下最近的检查点行号
--- 如果没有激活的检查点，返回底部安全区
---@param gridY number 当前网格行号
---@param activatedCheckpoints table|nil 已激活检查点集合 {[gridY]=true}
---@return number  -- 最近的检查点行号（或底部安全区行号 3）
function MapData.GetNearestCheckpointBelow(gridY, activatedCheckpoints)
    if activatedCheckpoints then
        -- 从高到低遍历已激活的检查点
        local best = 3  -- 默认底部安全区
        for _, cpY in ipairs(MapData.Checkpoints) do
            if cpY <= gridY and activatedCheckpoints[cpY] then
                best = cpY
            end
        end
        return best
    end
    -- 无激活记录时，返回最近的检查点行（向下）
    local best = 3
    for _, cpY in ipairs(MapData.Checkpoints) do
        if cpY <= gridY then
            best = cpY
        else
            break
        end
    end
    return best
end

--- 获取随机出生位置（世界坐标）
--- 新玩家在底部安全区随机位置出生
---@param rng table|nil  可选的RNG实例，不传则用 math.random
---@return number, number  -- worldX, worldY
function MapData.GetRandomSpawnPosition(rng)
    -- 底部安全区 y=3，在 x 方向 [4, Width-3] 范围随机
    local minX = 4
    local maxX = MapData.Width - 3
    local gridX
    if rng then
        gridX = rng:nextInt(minX, maxX)
    else
        gridX = math.random(minX, maxX)
    end
    local worldX = (gridX - 1) * Config.BlockSize + Config.BlockSize * 0.5
    -- y=3 行顶面 + 玩家半身高(0.5) + 安全余量(0.05)
    local worldY = 3 * Config.BlockSize + 0.55
    return worldX, worldY
end

--- 获取指定检查点行的出生位置（世界坐标）
---@param checkpointGridY number 检查点行号
---@param rng table|nil  可选的RNG实例
---@return number, number  -- worldX, worldY
function MapData.GetCheckpointSpawnPosition(checkpointGridY, rng)
    local minX = 4
    local maxX = MapData.Width - 3
    local gridX
    if rng then
        gridX = rng:nextInt(minX, maxX)
    else
        gridX = math.random(minX, maxX)
    end
    local worldX = (gridX - 1) * Config.BlockSize + Config.BlockSize * 0.5
    local worldY = checkpointGridY * Config.BlockSize + 0.55
    return worldX, worldY
end

-- ============================================================================
-- 程序化地图生成
-- ============================================================================

--- 生成程序化大世界地图
--- grid[y][x] = 方块类型（Lua 索引从 1 开始）
---@param seed number|nil  随机种子（相同种子 = 相同地图）
---@return table  -- grid[y][x]
function MapData.Generate(seed)
    seed = seed or 42
    local rng = RNG.new(seed)

    local W = MapData.Width
    local H = MapData.Height
    local interval = Config.CheckpointInterval

    -- 初始化空网格
    local grid = {}
    for y = 1, H do
        grid[y] = {}
        for x = 1, W do
            grid[y][x] = E
        end
    end

    -- 辅助：放置一段平台
    local function placePlatform(startX, y, length, blockType)
        for x = startX, startX + length - 1 do
            if x >= 1 and x <= W and y >= 1 and y <= H then
                grid[y][x] = blockType
            end
        end
    end

    -- ------------------------------------------------------------------
    -- 1) 底部安全区 (y=1~3)
    -- ------------------------------------------------------------------
    -- y=1,2: 实心地基
    placePlatform(1, 1, W, S)
    placePlatform(1, 2, W, S)
    -- y=3: 出生平台（安全方块）
    placePlatform(1, 3, W, S)

    -- ------------------------------------------------------------------
    -- 2) 重置检查点列表
    -- ------------------------------------------------------------------
    MapData.Checkpoints = {}

    -- ------------------------------------------------------------------
    -- 3) 逐层生成平台（y=4 到 H）
    -- ------------------------------------------------------------------
    -- 难度参数随高度变化：
    --   - 低层(0~100): 平台宽 5~8, 间距短, 密度高
    --   - 中层(100~300): 平台宽 4~7, 间距中等
    --   - 高层(300~500): 平台宽 3~6, 间距大, 密度低
    -- ------------------------------------------------------------------

    -- 追踪上一个有平台的行，确保垂直可达性
    local lastPlatformY = 3

    local y = 4
    while y <= H do
        local baseY = 3  -- 安全区顶部

        -- ----- 检查点行 -----
        if MapData.IsCheckpoint(y) then
            -- 检查点：全宽安全平台
            placePlatform(1, y, W, S)
            -- 中间放置检查点标记方块（视觉醒目）
            local cpStart = math.floor(W / 2) - 1
            for cx = cpStart, cpStart + 3 do
                if cx >= 1 and cx <= W then
                    grid[y][cx] = CP
                end
            end
            table.insert(MapData.Checkpoints, y)
            lastPlatformY = y
            y = y + 1
        else
            -- ----- 普通行：根据难度生成随机平台 -----
            local progress = (y - baseY) / (H - baseY)  -- 0~1 进度

            -- 难度曲线
            local minPlatWidth, maxPlatWidth
            local platformDensity  -- 每行平台数的期望值
            local gapChance        -- 某行完全无平台的概率

            if progress < 0.2 then
                -- 低区：简单
                minPlatWidth = 5
                maxPlatWidth = 8
                platformDensity = 3.5
                gapChance = 0.05
            elseif progress < 0.6 then
                -- 中区：中等
                minPlatWidth = 4
                maxPlatWidth = 7
                platformDensity = 2.8
                gapChance = 0.15
            else
                -- 高区：困难
                minPlatWidth = 3
                maxPlatWidth = 6
                platformDensity = 2.2
                gapChance = 0.25
            end

            -- 垂直间距控制：如果距离上一个平台太远，强制生成
            local gapFromLast = y - lastPlatformY
            local forceGenerate = (gapFromLast >= 3)  -- 双跳最大高度约6m，间距3保证可达

            if forceGenerate or rng:next() > gapChance then
                -- 生成这一行的平台
                local numPlatforms = rng:nextInt(
                    math.max(1, math.floor(platformDensity - 1)),
                    math.floor(platformDensity + 1)
                )

                -- 将地图宽度分成若干段，每段放一个平台
                local sectionWidth = math.floor(W / numPlatforms)

                for p = 1, numPlatforms do
                    local platWidth = rng:nextInt(minPlatWidth, maxPlatWidth)
                    -- 段的起始和结束
                    local secStart = (p - 1) * sectionWidth + 1
                    local secEnd = p * sectionWidth
                    if p == numPlatforms then secEnd = W end  -- 最后一段取满

                    -- 平台在段内随机偏移
                    local maxStart = math.max(secStart, secEnd - platWidth + 1)
                    local startX = rng:nextInt(secStart, maxStart)

                    -- 确保不超边界
                    if startX + platWidth - 1 > W then
                        startX = W - platWidth + 1
                    end
                    if startX < 1 then startX = 1 end

                    -- 偶尔放安全方块（不可破坏支撑点）
                    local blockType = N
                    if rng:next() < 0.12 then
                        blockType = S  -- 12% 概率为安全方块
                    end

                    placePlatform(startX, y, platWidth, blockType)
                end

                lastPlatformY = y
            end

            y = y + 1
        end
    end

    -- ------------------------------------------------------------------
    -- 4) 在非空行偶尔添加能量托台
    -- ------------------------------------------------------------------
    for row = 4, H do
        if not MapData.IsCheckpoint(row) then
            for x = 1, W do
                if grid[row][x] == N and rng:next() < 0.03 then
                    grid[row][x] = Config.BLOCK_ENERGY_PAD
                end
            end
        end
    end

    -- ------------------------------------------------------------------
    -- 5) 验证可达性：确保每两个相邻检查点之间有足够的平台跳板
    -- ------------------------------------------------------------------
    local allCheckpoints = { 3 }  -- 底部安全区也算
    for _, cpY in ipairs(MapData.Checkpoints) do
        table.insert(allCheckpoints, cpY)
    end

    for i = 1, #allCheckpoints - 1 do
        local fromY = allCheckpoints[i]
        local toY = allCheckpoints[i + 1]

        -- 检查这个区间内是否有连续超过3行无平台的情况
        local emptyStreak = 0
        for checkY = fromY + 1, toY - 1 do
            local hasBlock = false
            for x = 1, W do
                if grid[checkY][x] ~= E then
                    hasBlock = true
                    break
                end
            end
            if hasBlock then
                emptyStreak = 0
            else
                emptyStreak = emptyStreak + 1
                if emptyStreak >= 3 then
                    -- 补救：在这里插入一个小平台
                    local repairWidth = rng:nextInt(4, 7)
                    local repairX = rng:nextInt(1, W - repairWidth + 1)
                    placePlatform(repairX, checkY, repairWidth, N)
                    emptyStreak = 0
                end
            end
        end
    end

    print(string.format("[MapData] Generated procedural map %dx%d (seed=%d, %d checkpoints)",
        W, H, seed, #MapData.Checkpoints))

    return grid
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
    -- 扫描自定义地图中的检查点
    MapData.Checkpoints = {}
    for y = 1, MapData.Height do
        for x = 1, MapData.Width do
            if customGrid_[y][x] == CP then
                table.insert(MapData.Checkpoints, y)
                break  -- 一行只记一次
            end
        end
    end
    table.sort(MapData.Checkpoints)
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
    MapData.Width = Config.DefaultMapWidth
    MapData.Height = Config.DefaultMapHeight
    MapData.Checkpoints = {}
    print("[MapData] Custom grid cleared, using default map")
end

return MapData
