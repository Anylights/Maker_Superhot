-- ============================================================================
-- AIController.lua - AI 控制器（路径点导航 v4）
-- 核心改进：
--   1) 只在水平接近目标时才为"上跳"触发跳跃，不再一路弹跳
--   2) 爆炸更有策略性：优先攻击前方对手，不在互相挤压时浪费能量
--   3) 卡住恢复更快，包含冲刺脱困
--   4) 掉落后快速重定位到最近可达路径点
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local AIController = {}

-- AI 决策参数
local AI_THINK_INTERVAL = 0.10
local AI_EXPLODE_RANGE  = 6.0
local AI_WP_REACH_H     = 2.5   -- 水平方向到达判定
local AI_WP_REACH_V     = 2.0   -- 垂直方向到达判定
local AI_JUMP_NEAR_X    = 3.5   -- 离目标多近(水平)才为了上跳而跳
local AI_GAP_LOOK       = 2.0   -- 前方间隙检测距离
local AI_WALL_LOOK      = 0.9   -- 前方墙壁检测距离

-- ============================================================================
-- 路径点定义
-- x = 世界坐标 X（大致站的位置）
-- y = 世界坐标 Y（角色中心，≈ 平台 gridY + 0.5）
-- ============================================================================

local ROUTE_A = {
    -- U1: 起点 → 向右
    { x = 6,  y = 4 },
    { x = 20, y = 4 },
    { x = 36, y = 4 },
    { x = 42, y = 4 },
    -- U1→U2: 右侧台阶
    { x = 44, y = 7 },      -- step onto grid y=6
    { x = 42, y = 10 },     -- step onto grid y=9
    -- U2: 入口→中央→左路
    { x = 40, y = 13 },
    { x = 25, y = 13 },
    { x = 17, y = 13 },
    { x = 8,  y = 14 },
    { x = 7,  y = 15 },
    -- U2 左路出口
    { x = 9,  y = 18 },
    { x = 13, y = 20 },
    -- U3: 左入→中央→右出
    { x = 8,  y = 22 },
    { x = 16, y = 23 },
    { x = 25, y = 24 },
    { x = 34, y = 26 },
    -- U3→U4
    { x = 40, y = 28 },
    -- U4 下层（安全）
    { x = 42, y = 29 },
    { x = 28, y = 29 },
    { x = 12, y = 29 },
    { x = 6,  y = 29 },
    -- U4→U5 左出口
    { x = 6,  y = 35 },
    -- U5 左路→汇合
    { x = 9,  y = 38 },
    { x = 16, y = 39 },
    { x = 25, y = 40 },
    { x = 25, y = 42 },
    -- U6 终点
    { x = 25, y = 44 },
    { x = 25, y = 46 },
    { x = 25, y = 49 },
}

local ROUTE_B = {
    -- U1
    { x = 6,  y = 4 },
    { x = 20, y = 4 },
    { x = 36, y = 4 },
    { x = 42, y = 4 },
    -- U1→U2
    { x = 44, y = 7 },
    { x = 42, y = 10 },
    -- U2: 入口→右路
    { x = 40, y = 13 },
    { x = 35, y = 13 },
    { x = 39, y = 16 },
    -- U2 右路出口
    { x = 43, y = 18 },
    { x = 38, y = 20 },
    -- U3: 右入→中央→左出
    { x = 40, y = 22 },
    { x = 34, y = 23 },
    { x = 25, y = 24 },
    { x = 14, y = 26 },
    -- U3→U4
    { x = 10, y = 28 },
    -- U4 上层（冒险）
    { x = 8,  y = 32 },
    { x = 16, y = 33 },
    { x = 24, y = 32 },
    { x = 32, y = 33 },
    { x = 40, y = 32 },
    -- U4→U5 右出口
    { x = 45, y = 32 },
    { x = 44, y = 35 },
    -- U5 右路→汇合
    { x = 39, y = 38 },
    { x = 34, y = 39 },
    { x = 25, y = 40 },
    { x = 25, y = 42 },
    -- U6
    { x = 25, y = 44 },
    { x = 25, y = 46 },
    { x = 25, y = 49 },
}

local ROUTE_C = {
    -- U1（走上方跳台捷径）
    { x = 6,  y = 4 },
    { x = 15, y = 4 },
    { x = 18, y = 7 },
    { x = 30, y = 7 },
    { x = 36, y = 4 },
    { x = 42, y = 4 },
    -- U1→U2
    { x = 44, y = 7 },
    { x = 42, y = 10 },
    -- U2 右路
    { x = 40, y = 13 },
    { x = 36, y = 13 },
    { x = 39, y = 16 },
    { x = 43, y = 18 },
    { x = 38, y = 20 },
    -- U3 右入→中央→右出
    { x = 40, y = 22 },
    { x = 34, y = 23 },
    { x = 25, y = 24 },
    { x = 34, y = 26 },
    -- U3→U4 右过渡
    { x = 40, y = 28 },
    -- U4 下层
    { x = 38, y = 29 },
    { x = 20, y = 29 },
    { x = 6,  y = 29 },
    -- U4→U5 左
    { x = 6,  y = 35 },
    -- U5
    { x = 9,  y = 38 },
    { x = 16, y = 39 },
    { x = 25, y = 40 },
    { x = 25, y = 42 },
    -- U6（走左旁路安全线）
    { x = 25, y = 44 },
    { x = 15, y = 45 },
    { x = 20, y = 47 },
    { x = 25, y = 49 },
}

local ALL_ROUTES = { ROUTE_A, ROUTE_B, ROUTE_C }

-- AI 状态
local aiStates_ = {}
local playerModule_ = nil
local mapModule_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

function AIController.Init(playerRef, mapRef)
    playerModule_ = playerRef
    mapModule_ = mapRef
    aiStates_ = {}
    print("[AI] Initialized (waypoint nav v4)")
end

function AIController.Register(playerData)
    local routeIdx = math.random(1, #ALL_ROUTES)
    aiStates_[playerData.index] = {
        thinkTimer    = math.random() * AI_THINK_INTERVAL,
        moveDir       = 0,
        wantJump      = false,
        wantDash      = false,
        -- 蓄力
        isCharging    = false,
        chargeHoldTime = 0,
        chargeElapsed = 0,
        -- 导航
        route         = ALL_ROUTES[routeIdx],
        wpIdx         = 1,
        -- 卡住
        stuckTimer    = 0,
        stuckJumps    = 0,
        lastX         = 0,
        lastY         = 0,
        -- 掉落恢复
        fallRecovery  = false,
    }
    print("[AI] Player " .. playerData.index .. " route " .. routeIdx)
end

-- ============================================================================
-- 更新
-- ============================================================================

function AIController.Update(dt)
    if playerModule_ == nil then return end
    for _, p in ipairs(playerModule_.list) do
        if not p.isHuman and p.alive and not p.finished then
            AIController.UpdateOne(p, dt)
        end
    end
end

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

-- ============================================================================
-- 思考（核心决策）
-- ============================================================================

function AIController.Think(p, state)
    if p.node == nil then return end

    local pos = p.node.position
    local px, py = pos.x, pos.y
    local route = state.route

    -- ===================
    -- 掉落检测：如果 Y 比当前目标低很多，重新定位
    -- ===================
    local wp = route[state.wpIdx]
    if wp and (py < wp.y - 6) then
        -- 掉落了，找最近的同层或更低的路径点
        local bestIdx = state.wpIdx
        local bestDist = math.huge
        for i = 1, #route do
            local w = route[i]
            local dy = w.y - py
            -- 只考虑当前层或略高（不超过3格）的点
            if dy > -2 and dy < 3 then
                local d = math.abs(w.x - px) + math.abs(dy)
                if d < bestDist then
                    bestDist = d
                    bestIdx = i
                end
            end
        end
        state.wpIdx = bestIdx
        state.stuckTimer = 0
        state.stuckJumps = 0
    end

    -- 安全索引
    if state.wpIdx > #route then state.wpIdx = #route end
    wp = route[state.wpIdx]
    if wp == nil then return end

    local dx = wp.x - px
    local dy = wp.y - py
    local absDx = math.abs(dx)
    local absDy = math.abs(dy)

    -- ===================
    -- 路径点推进：到达当前点→下一个
    -- ===================
    if absDx < AI_WP_REACH_H and absDy < AI_WP_REACH_V then
        state.wpIdx = math.min(state.wpIdx + 1, #route)
        state.stuckTimer = 0
        state.stuckJumps = 0
        wp = route[state.wpIdx]
        if wp == nil then return end
        dx = wp.x - px
        dy = wp.y - py
        absDx = math.abs(dx)
        absDy = math.abs(dy)
    end

    -- ===================
    -- 移动方向
    -- ===================
    if absDx > 0.5 then
        state.moveDir = dx > 0 and 1 or -1
    elseif absDx > 0.15 then
        state.moveDir = dx > 0 and 1 or -1
    else
        state.moveDir = 0
    end

    -- ===================
    -- 跳跃决策（精确时机）
    -- ===================
    state.wantJump = false

    -- 规则 1: 目标在上方 且 水平已经接近 → 跳
    if dy > 0.8 and absDx < AI_JUMP_NEAR_X then
        state.wantJump = true
    end

    -- 规则 2: 前方有间隙（目标在前方时才跳过去）
    if mapModule_ and state.moveDir ~= 0 then
        local gapX = px + state.moveDir * AI_GAP_LOOK
        local gapY = py - 1.0
        local gx, gy = mapModule_.WorldToGrid(gapX, gapY)
        local block = mapModule_.GetBlock(gx, gy)
        if block == Config.BLOCK_EMPTY then
            -- 确认目标在间隙另一侧（同方向）
            if (state.moveDir > 0 and dx > 1) or (state.moveDir < 0 and dx < -1) or dy > 0.5 then
                state.wantJump = true
            end
        end
    end

    -- 规则 3: 前方有墙（要跳过或跳上）
    if mapModule_ and state.moveDir ~= 0 then
        local wallX = px + state.moveDir * AI_WALL_LOOK
        local wallY = py + 0.2  -- 稍高于脚部
        local gx, gy = mapModule_.WorldToGrid(wallX, wallY)
        if mapModule_.GetBlock(gx, gy) ~= Config.BLOCK_EMPTY then
            state.wantJump = true
        end
    end

    -- 规则 4: 如果身体下方是空的（正在掉落）不主动跳（除非有多段跳）
    -- （当前只有1段跳，掉落时不浪费跳跃）

    -- ===================
    -- 卡住检测
    -- ===================
    local moveDist = math.abs(px - state.lastX) + math.abs(py - state.lastY)
    if moveDist < 0.1 then
        state.stuckTimer = state.stuckTimer + AI_THINK_INTERVAL
    else
        state.stuckTimer = math.max(0, state.stuckTimer - AI_THINK_INTERVAL * 2)
        state.stuckJumps = 0
    end
    state.lastX = px
    state.lastY = py

    -- 卡住 0.25 秒 → 跳
    if state.stuckTimer > 0.25 then
        state.wantJump = true
        state.stuckJumps = state.stuckJumps + 1

        -- 连续跳 4 次没效果 → 换方向
        if state.stuckJumps >= 4 then
            state.moveDir = -state.moveDir
            if state.moveDir == 0 then state.moveDir = (math.random() > 0.5) and 1 or -1 end
            state.stuckJumps = 0
        end

        -- 卡住 1.5 秒 → 冲刺脱困
        if state.stuckTimer > 1.5 and p.dashCooldown <= 0 then
            state.wantDash = true
            state.stuckTimer = 0.5  -- 重置但不完全归零
        end

        -- 卡住 3 秒 → 重新定位路径点
        if state.stuckTimer > 3.0 then
            -- 找最近的路径点（不限制方向）
            local bestI = state.wpIdx
            local bestD = math.huge
            for i = 1, #route do
                local w = route[i]
                local d = math.abs(w.x - px) + math.abs(w.y - py)
                if d < bestD then
                    bestD = d
                    bestI = i
                end
            end
            -- 如果最近点在后方且距离很近，跳到下一个
            local nearWp = route[bestI]
            if nearWp and nearWp.y < py - 1.0 and bestI < #route then
                bestI = bestI + 1
            end
            state.wpIdx = bestI
            state.stuckTimer = 0
            state.stuckJumps = 0
            -- 随机反向
            state.moveDir = (math.random() > 0.5) and 1 or -1
        end
    end

    -- ===================
    -- 爆炸决策（更有策略）
    -- ===================
    if p.energy >= 1.0 and not state.isCharging then
        local shouldExplode = false
        local bestTarget = nil
        local bestScore = -999

        for _, other in ipairs(playerModule_.list) do
            if other.index ~= p.index and other.alive and other.node then
                local ox = other.node.position.x
                local oy = other.node.position.y
                local ddx = ox - px
                local ddy = oy - py
                local dist = math.sqrt(ddx * ddx + ddy * ddy)

                if dist < AI_EXPLODE_RANGE then
                    local score = 0

                    -- 对手在上方(领先)→高分，应该炸
                    if ddy > 1.0 then
                        score = score + 30
                    end

                    -- 对手非常近→也值得炸
                    if dist < 3.0 then
                        score = score + 20
                    end

                    -- 对手是人类玩家→稍微优先
                    if other.isHuman then
                        score = score + 5
                    end

                    -- 对手在下方（落后）→不太值得炸
                    if ddy < -2.0 then
                        score = score - 20
                    end

                    if score > bestScore then
                        bestScore = score
                        bestTarget = other
                    end
                end
            end
        end

        -- 只有分数够高才炸（避免无意义爆炸）
        if bestTarget and bestScore >= 15 and math.random() > 0.2 then
            shouldExplode = true
        end

        if shouldExplode then
            state.isCharging = true
            state.chargeHoldTime = 0.5 + math.random() * 1.0
            state.chargeElapsed = 0
        end
    end

    -- ===================
    -- 冲刺决策
    -- ===================
    if p.dashCooldown <= 0 and not state.isCharging then
        -- 长距离水平移动 + 在地面 → 偶尔冲刺
        if absDx > 10 and absDy < 2 and p.onGround then
            if math.random() > 0.7 then
                state.wantDash = true
            end
        end
    end
end

return AIController
