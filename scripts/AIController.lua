-- ============================================================================
-- AIController.lua - AI 控制器（路径点导航版）
-- 基于预定义路径点序列导航，AI 会沿路径点逐一移动/跳跃
-- 支持多条路线随机选择，增加行为多样性
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local AIController = {}

-- AI 决策参数
local AI_THINK_INTERVAL = 0.10   -- 决策间隔（秒）
local AI_EXPLODE_RANGE = 6.0     -- 爆炸考虑范围
local AI_WAYPOINT_REACH = 1.8    -- 到达路径点的判定半径
local AI_JUMP_THRESHOLD_Y = 0.8  -- 目标点高于当前多少就跳
local AI_PLATFORM_LOOK = 2.0     -- 前方地面检测距离

-- ============================================================================
-- 路径点定义
-- 每个路径点: { x, y }（世界坐标，站在平台上的大致位置）
-- 多条路线供 AI 随机选择
-- ============================================================================

-- 路线 A: 偏左路线
local ROUTE_A = {
    -- U1: 起点→向右跑
    { x = 6, y = 4 },       -- 起点
    { x = 15, y = 4 },      -- 主路中段
    { x = 25, y = 4 },      -- 主路中段
    { x = 36, y = 4 },      -- 主路右段
    -- U1→U2: 右侧台阶上升
    { x = 43, y = 4 },      -- 右端
    { x = 44, y = 7 },      -- 台阶 Y=6
    { x = 42, y = 10 },     -- 台阶 Y=9
    -- U2: 入口→中央→左路
    { x = 40, y = 13 },     -- 入口平台 Y=12
    { x = 25, y = 13 },     -- 中央分流
    { x = 17, y = 13 },     -- 向左
    { x = 8, y = 14 },      -- 左路入口 Y=13
    { x = 7, y = 15 },      -- 左路主平台 Y=14
    -- U2→U3: 左路出口上升
    { x = 9, y = 18 },      -- 左路出口 Y=17
    { x = 13, y = 20 },     -- 过渡 Y=19
    -- U3: 左入口→中央交叉→右出口
    { x = 8, y = 22 },      -- 左路 Y=21
    { x = 16, y = 23 },     -- 过渡 Y=22
    { x = 25, y = 24 },     -- 中央交叉 Y=23
    { x = 34, y = 26 },     -- 右出口 Y=25
    -- U3→U4: 右过渡
    { x = 40, y = 28 },     -- 右过渡 Y=27
    -- U4: 走下层（安全稳定）
    { x = 44, y = 29 },     -- 下层右端 Y=28
    { x = 28, y = 29 },     -- 下层中段
    { x = 12, y = 29 },     -- 下层左段
    { x = 6, y = 29 },      -- 下层左端
    -- U4→U5: 左侧出口上升
    { x = 6, y = 35 },      -- 左台阶 Y=34
    -- U5: 左路上升→汇合
    { x = 9, y = 38 },      -- 左路 Y=37
    { x = 16, y = 39 },     -- 左路 Y=38
    { x = 25, y = 40 },     -- 汇合大平台 Y=39
    { x = 25, y = 42 },     -- 向上 Y=41
    -- U6: 终点
    { x = 25, y = 44 },     -- Y=43
    { x = 25, y = 46 },     -- 断桥 Y=45
    { x = 25, y = 49 },     -- 终点 Y=48
}

-- 路线 B: 偏右路线
local ROUTE_B = {
    -- U1: 同 A
    { x = 6, y = 4 },
    { x = 20, y = 4 },
    { x = 36, y = 4 },
    -- U1→U2: 右侧台阶上升
    { x = 43, y = 4 },
    { x = 44, y = 7 },
    { x = 42, y = 10 },
    -- U2: 入口→中央→右路
    { x = 40, y = 13 },
    { x = 30, y = 13 },     -- 中央偏右
    { x = 36, y = 13 },     -- 右路连接
    { x = 39, y = 16 },     -- 右路断桥平台 Y=15
    -- U2→U3: 右路出口上升
    { x = 43, y = 18 },     -- 右路出口 Y=17
    { x = 38, y = 20 },     -- 过渡 Y=19
    -- U3: 右入口→中央交叉→左出口
    { x = 40, y = 22 },     -- 右路 Y=21
    { x = 34, y = 23 },     -- 过渡 Y=22
    { x = 25, y = 24 },     -- 中央交叉 Y=23
    { x = 14, y = 26 },     -- 左出口 Y=25
    -- U3→U4: 左过渡
    { x = 10, y = 28 },     -- 左过渡 Y=27
    -- U4: 走上层（快速冒险）
    { x = 8, y = 32 },      -- 上层左端 Y=31
    { x = 16, y = 33 },     -- 上层 Y=32
    { x = 24, y = 32 },     -- 上层 Y=31
    { x = 32, y = 33 },     -- 上层 Y=32
    { x = 40, y = 32 },     -- 上层右端 Y=31
    -- U4→U5: 右侧出口上升
    { x = 45, y = 32 },     -- 右出口台阶 Y=31
    { x = 44, y = 35 },     -- 右台阶 Y=34
    -- U5: 右路上升→汇合
    { x = 39, y = 38 },     -- 右路 Y=37
    { x = 34, y = 39 },     -- 右路 Y=38
    { x = 25, y = 40 },     -- 汇合大平台 Y=39
    { x = 25, y = 42 },     -- 向上 Y=41
    -- U6: 终点
    { x = 25, y = 44 },
    { x = 25, y = 46 },
    { x = 25, y = 49 },
}

-- 路线 C: 混合路线（左→右→左交替）
local ROUTE_C = {
    -- U1
    { x = 6, y = 4 },
    { x = 18, y = 7 },      -- 走上方捷径跳台
    { x = 30, y = 7 },      -- 第二个跳台
    { x = 42, y = 4 },
    -- U1→U2
    { x = 44, y = 7 },
    { x = 42, y = 10 },
    -- U2: 右路
    { x = 40, y = 13 },
    { x = 36, y = 13 },
    { x = 39, y = 16 },
    { x = 43, y = 18 },
    { x = 38, y = 20 },
    -- U3: 右入口→中央→右出口（不交叉）
    { x = 40, y = 22 },
    { x = 34, y = 23 },
    { x = 25, y = 24 },
    { x = 34, y = 26 },
    -- U3→U4: 右过渡
    { x = 40, y = 28 },
    -- U4: 下层
    { x = 38, y = 29 },
    { x = 20, y = 29 },
    { x = 6, y = 29 },
    -- U4→U5: 左侧
    { x = 6, y = 35 },
    -- U5
    { x = 9, y = 38 },
    { x = 16, y = 39 },
    { x = 25, y = 40 },
    { x = 25, y = 42 },
    -- U6
    { x = 25, y = 44 },
    { x = 15, y = 45 },     -- 走左旁路（更安全）
    { x = 20, y = 47 },     -- 左台阶
    { x = 25, y = 49 },
}

local ALL_ROUTES = { ROUTE_A, ROUTE_B, ROUTE_C }

-- AI 状态
local aiStates_ = {}

-- 引用
local playerModule_ = nil
local mapModule_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化 AI 系统
---@param playerRef table
---@param mapRef table
function AIController.Init(playerRef, mapRef)
    playerModule_ = playerRef
    mapModule_ = mapRef
    aiStates_ = {}
    print("[AI] Initialized (waypoint navigation v3)")
end

--- 为 AI 玩家创建状态
---@param playerData table
function AIController.Register(playerData)
    -- 随机选一条路线
    local routeIdx = math.random(1, #ALL_ROUTES)
    local route = ALL_ROUTES[routeIdx]

    aiStates_[playerData.index] = {
        thinkTimer = math.random() * AI_THINK_INTERVAL,
        moveDir = 0,
        wantJump = false,
        wantDash = false,
        -- 蓄力爆炸状态
        isCharging = false,
        chargeHoldTime = 0,
        chargeElapsed = 0,
        -- 路径点导航
        route = route,
        waypointIdx = 1,       -- 当前目标路径点索引
        -- 卡住检测
        stuckTimer = 0,
        stuckJumpTimer = 0,    -- 卡住后连续跳跃计时
        lastX = 0,
        lastY = 0,
        -- 性格偏差（增加多样性）
        speedVariance = 0.85 + math.random() * 0.3,  -- 0.85~1.15
        jumpEagerness = 0.3 + math.random() * 0.5,   -- 提前跳跃的距离
    }
    print("[AI] Player " .. playerData.index .. " assigned route " .. routeIdx)
end

-- ============================================================================
-- 更新
-- ============================================================================

--- 每帧更新所有 AI
---@param dt number
function AIController.Update(dt)
    if playerModule_ == nil then return end

    for _, p in ipairs(playerModule_.list) do
        if not p.isHuman and p.alive and not p.finished then
            AIController.UpdateOne(p, dt)
        end
    end
end

--- 更新单个 AI
---@param p table
---@param dt number
function AIController.UpdateOne(p, dt)
    local state = aiStates_[p.index]
    if state == nil then
        AIController.Register(p)
        state = aiStates_[p.index]
    end

    state.thinkTimer = state.thinkTimer - dt
    if state.thinkTimer <= 0 then
        state.thinkTimer = AI_THINK_INTERVAL + math.random() * 0.03
        AIController.Think(p, state)
    end

    -- 应用 AI 决策到输入
    p.inputMoveX = state.moveDir

    if state.wantJump then
        p.inputJump = true
        state.wantJump = false
    end

    if state.wantDash then
        p.inputDash = true
        state.wantDash = false
    end

    -- 蓄力爆炸
    if state.isCharging then
        state.chargeElapsed = state.chargeElapsed + dt
        if state.chargeElapsed >= state.chargeHoldTime then
            p.inputExplodeRelease = true
            p.inputCharging = false
            state.isCharging = false
            state.chargeElapsed = 0
        else
            p.inputCharging = true
        end
    end
end

--- 找到最接近当前位置的路径点索引
---@param route table 路径点列表
---@param px number 当前 X
---@param py number 当前 Y
---@return number 最近路径点索引
local function FindNearestWaypoint(route, px, py)
    local bestIdx = 1
    local bestDist = math.huge
    for i, wp in ipairs(route) do
        local dx = wp.x - px
        local dy = wp.y - py
        local dist = dx * dx + dy * dy
        if dist < bestDist then
            bestDist = dist
            bestIdx = i
        end
    end
    return bestIdx
end

--- 找到最接近且在前方（Y更高或索引更大）的路径点
---@param route table
---@param px number
---@param py number
---@param currentIdx number
---@return number
local function FindBestForwardWaypoint(route, px, py, currentIdx)
    -- 从当前索引开始，找最近的前方点
    local bestIdx = currentIdx
    local bestDist = math.huge

    -- 搜索范围：当前索引附近（-2 到 +5）
    local searchStart = math.max(1, currentIdx - 2)
    local searchEnd = math.min(#route, currentIdx + 5)

    for i = searchStart, searchEnd do
        local wp = route[i]
        local dx = wp.x - px
        local dy = wp.y - py
        local dist = math.sqrt(dx * dx + dy * dy)

        if dist < AI_WAYPOINT_REACH and i > bestIdx then
            -- 已经到达这个点，推进到下一个
            bestIdx = i + 1
        elseif i >= currentIdx and dist < bestDist then
            bestDist = dist
            bestIdx = i
        end
    end

    return math.min(bestIdx, #route)
end

--- AI 思考（决策逻辑）
---@param p table
---@param state table
function AIController.Think(p, state)
    if p.node == nil then return end

    local pos = p.node.position
    local px, py = pos.x, pos.y
    local route = state.route

    -- =====================
    -- 路径点推进
    -- =====================
    local wp = route[state.waypointIdx]
    if wp then
        local dx = wp.x - px
        local dy = wp.y - py
        local dist = math.sqrt(dx * dx + dy * dy)

        -- 到达当前路径点 → 推进到下一个
        if dist < AI_WAYPOINT_REACH then
            state.waypointIdx = math.min(state.waypointIdx + 1, #route)
            wp = route[state.waypointIdx]
            if wp then
                dx = wp.x - px
                dy = wp.y - py
            end
        end
    end

    -- 如果路径点走完了，目标就是终点
    if state.waypointIdx > #route then
        state.waypointIdx = #route
    end
    wp = route[state.waypointIdx]
    if wp == nil then return end

    local dx = wp.x - px
    local dy = wp.y - py

    -- =====================
    -- 移动方向：朝目标路径点
    -- =====================
    if math.abs(dx) > 0.5 then
        state.moveDir = dx > 0 and 1 or -1
    else
        -- 接近目标 X，微调或保持
        state.moveDir = dx > 0.1 and 1 or (dx < -0.1 and -1 or 0)
    end

    -- =====================
    -- 跳跃决策
    -- =====================
    state.wantJump = false

    -- 1) 目标点在上方 → 跳
    if dy > AI_JUMP_THRESHOLD_Y then
        state.wantJump = true
    end

    -- 2) 前方没有地面 → 跳（跨越间隙）
    if mapModule_ and state.moveDir ~= 0 then
        local checkX = px + state.moveDir * AI_PLATFORM_LOOK
        local checkY = py - 1.0
        local gx, gy = mapModule_.WorldToGrid(checkX, checkY)
        local block = mapModule_.GetBlock(gx, gy)
        if block == Config.BLOCK_EMPTY then
            -- 间隙在前方，但只有当目标在前方或上方时才跳
            if (state.moveDir > 0 and dx > 0) or (state.moveDir < 0 and dx < 0) or dy > 0.3 then
                state.wantJump = true
            end
        end
    end

    -- 3) 前方有墙壁/高台 → 跳
    if mapModule_ and state.moveDir ~= 0 then
        local wallX = px + state.moveDir * 0.8
        local wallY = py + 0.3
        local gx, gy = mapModule_.WorldToGrid(wallX, wallY)
        local block = mapModule_.GetBlock(gx, gy)
        if block ~= Config.BLOCK_EMPTY then
            state.wantJump = true
        end
    end

    -- =====================
    -- 卡住检测（更敏感）
    -- =====================
    local moveDX = math.abs(px - state.lastX)
    local moveDY = math.abs(py - state.lastY)
    if moveDX < 0.08 and moveDY < 0.08 then
        state.stuckTimer = state.stuckTimer + AI_THINK_INTERVAL
    else
        state.stuckTimer = 0
        state.stuckJumpTimer = 0
    end
    state.lastX = px
    state.lastY = py

    -- 卡住 0.3 秒 → 跳
    if state.stuckTimer > 0.3 then
        state.wantJump = true
        state.stuckJumpTimer = state.stuckJumpTimer + AI_THINK_INTERVAL

        -- 卡住跳了 0.6 秒还没动 → 换方向
        if state.stuckJumpTimer > 0.6 then
            state.moveDir = -state.moveDir
            if state.moveDir == 0 then state.moveDir = 1 end
            state.stuckJumpTimer = 0
        end

        -- 卡住超过 2 秒 → 重新定位最近路径点
        if state.stuckTimer > 2.0 then
            state.waypointIdx = FindNearestWaypoint(route, px, py)
            -- 确保不会倒退，至少推进1步
            local nearWp = route[state.waypointIdx]
            if nearWp then
                local nearDY = nearWp.y - py
                if nearDY < -1 then
                    -- 最近点在下方，跳过它
                    state.waypointIdx = math.min(state.waypointIdx + 1, #route)
                end
            end
            state.stuckTimer = 0
            state.stuckJumpTimer = 0
            -- 卡住时尝试冲刺脱困
            if p.dashCooldown <= 0 then
                state.wantDash = true
            end
        end
    end

    -- =====================
    -- 爆炸决策
    -- =====================
    if p.energy >= 1.0 and not state.isCharging then
        local shouldExplode = false

        for _, other in ipairs(playerModule_.list) do
            if other.index ~= p.index and other.alive and other.node then
                local diffX = other.node.position.x - px
                local diffY = other.node.position.y - py
                local dist = math.sqrt(diffX * diffX + diffY * diffY)
                if dist < AI_EXPLODE_RANGE then
                    -- 优先炸在自己上方的对手（阻碍竞争）
                    if diffY > 0 then
                        shouldExplode = true
                    elseif dist < 3.5 then
                        shouldExplode = true
                    end
                end
            end
        end

        if shouldExplode and math.random() > 0.25 then
            state.isCharging = true
            state.chargeHoldTime = 0.6 + math.random() * 0.8
            state.chargeElapsed = 0
        end
    end

    -- =====================
    -- 冲刺决策
    -- =====================
    if p.dashCooldown <= 0 then
        -- 长距离水平目标且在地面 → 冲刺加速
        if math.abs(dx) > 8 and math.abs(dy) < 2 and p.onGround then
            if math.random() > 0.6 then
                state.wantDash = true
            end
        end
    end
end

return AIController
