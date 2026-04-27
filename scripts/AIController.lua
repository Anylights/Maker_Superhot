-- ============================================================================
-- AIController.lua - AI 控制器（完全重写 v6）
-- 核心改进：
--   1) 精确起跳点计算：AI 先移到最佳起跳 X 再跳
--   2) 空中制导：跳跃中持续修正水平速度对准落点
--   3) 分层状态机：NAVIGATE → APPROACH_JUMP → JUMPING → FALLING
--   4) 更激进的战术：主动寻找爆炸机会、灵活使用冲刺
--   5) 快速脱困：检测到卡住后立即采取行动
--   6) 路径选择更聪明：优先选物理上容易执行的路径
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local AIController = {}

-- Forward declarations（解决 local function 前向引用问题）
local findDetourPickup

-- 可选模块（懒加载，避免循环依赖）
local pickupModule_lazy_ = nil
local function getPickupModule()
    if pickupModule_lazy_ == nil then
        local ok, mod = pcall(require, "Pickup")
        if ok then pickupModule_lazy_ = mod else pickupModule_lazy_ = false end
    end
    return pickupModule_lazy_ or nil
end

-- ============================================================================
-- 物理常量
-- ============================================================================
local GRAVITY       = 9.81
local JUMP_SPEED    = Config.JumpSpeed           -- 14.0
local MOVE_SPEED    = Config.MoveSpeed            -- 8.0
local AIR_CONTROL   = Config.AirControlRatio      -- 0.7
local FALL_GRAV_MUL = Config.FallGravityMul       -- 2.2
local DASH_SPEED    = Config.DashSpeed            -- 25.0
local DASH_DUR      = Config.DashDuration         -- 0.22

-- 跳跃物理推导
local SINGLE_JUMP_HEIGHT = (JUMP_SPEED * JUMP_SPEED) / (2 * GRAVITY)    -- ~10.0（单次跳跃）
local MAX_JUMPS          = Config.MaxJumps                               -- 2（二段跳）
-- 二段跳最大高度：第一跳到顶后第二跳（近似2倍单跳高度）
local MAX_JUMP_HEIGHT    = SINGLE_JUMP_HEIGHT * MAX_JUMPS                -- ~20.0
local TIME_TO_PEAK       = JUMP_SPEED / GRAVITY                          -- ~1.43s（单次）
local AIR_HORIZ_SPEED   = MOVE_SPEED * AIR_CONTROL                      -- ~5.6 m/s
local DASH_DISTANCE     = DASH_SPEED * DASH_DUR                          -- ~5.5m

-- 角色尺寸
local CHAR_HALF_W = 0.45
local CHAR_HALF_H = 0.50

-- AI 参数
local THINK_INTERVAL         = 0.08     -- 思考间隔（更频繁）
local PLATFORM_SCAN_INTERVAL = 0.4      -- 平台扫描间隔
local REPATH_INTERVAL_MIN    = 1.5      -- 最短重寻路间隔
local REPATH_INTERVAL_MAX    = 2.5      -- 最长重寻路间隔

-- AI 状态枚举
local STATE_NAVIGATE     = 1   -- 在平台上行走向目标方向
local STATE_APPROACH     = 2   -- 对准起跳点
local STATE_JUMP         = 3   -- 已起跳，空中制导
local STATE_FALLING      = 4   -- 自由下落（不是主动跳跃）
local STATE_DASH         = 5   -- 冲刺中
local STATE_STUCK        = 6   -- 卡住恢复

-- ============================================================================
-- 战术参数（炸弹/道具决策）
-- ============================================================================
-- 炸弹决策
local BOMB_KILL_RANGE        = 5.0    -- 敌人在此距离内才考虑炸（< 爆炸最大半径 7）
local BOMB_KILL_VERTICAL     = 3.0    -- 垂直距离限制
local BOMB_CHARGE_TIME       = 1.4    -- 蓄力 1.4s（约 7 * 1.4/2.5 ≈ 4 格半径）
local BOMB_RECHECK_INTERVAL  = 0.25   -- 蓄力中每 0.25s 重新评估
local BOMB_SAFE_RADIUS       = 3      -- 自身脚下"安全保留区"格数
-- 道具捡取
local PICKUP_DETOUR_MAX_DX   = 4.0    -- 道具与主路径横向偏离上限（米）

-- 调试日志开关（首次交付时打开，确认行为后可关）
local VERBOSE_JUMP_LOG       = true
local PICKUP_DETOUR_MAX_DY   = 2.0    -- 道具与当前高度的垂直差上限
local PICKUP_TARGET_TIMEOUT  = 4.0    -- 单次道具目标追踪上限

-- ============================================================================
-- 平台扫描
-- ============================================================================

---@param mapModule table
---@return table platforms
local function scanPlatforms(mapModule)
    local platforms = {}
    local bs = Config.BlockSize

    for gy = 1, MapData.Height do
        local segStart = nil

        for gx = 1, MapData.Width + 1 do
            local block = Config.BLOCK_EMPTY
            if gx <= MapData.Width then
                block = mapModule.GetBlock(gx, gy)
            end

            local isSolid = (block ~= Config.BLOCK_EMPTY)
            local aboveEmpty = true
            if gx <= MapData.Width then
                if mapModule.GetBlock(gx, gy + 1) ~= Config.BLOCK_EMPTY then
                    aboveEmpty = false
                end
            end

            local isValidSurface = isSolid and aboveEmpty
            local isFinish = (block == Config.BLOCK_FINISH)

            if isValidSurface then
                if segStart == nil then
                    segStart = { x = gx, isFinish = isFinish }
                end
                if isFinish then segStart.isFinish = true end
            else
                if segStart then
                    local wx1 = (segStart.x - 1) * bs
                    local wx2 = (gx - 1) * bs
                    table.insert(platforms, {
                        x1 = wx1,
                        x2 = wx2,
                        y  = gy * bs,                 -- 平台表面 Y
                        charY = gy * bs + CHAR_HALF_H, -- 角色中心 Y
                        isFinish = segStart.isFinish,
                        width = wx2 - wx1,
                        cx = (wx1 + wx2) * 0.5,       -- 平台中心 X
                        gridY = gy,
                    })
                    segStart = nil
                end
            end
        end
    end

    return platforms
end

-- ============================================================================
-- 跳跃可达性分析（严格物理公式）
-- ============================================================================

--- 计算从平台 A 到平台 B 的可达性和最佳起跳信息
---@return boolean reachable
---@return table|nil jumpInfo { type, launchX, landX, dir, dy }
local function analyzeReachability(fromPlat, toPlat)
    local dy = toPlat.charY - fromPlat.charY  -- 正=上方
    local info = { dy = dy }

    -- 同平台（高度相同且X重叠）
    if math.abs(dy) < 0.1 and fromPlat.x2 > toPlat.x1 and fromPlat.x1 < toPlat.x2 then
        info.type = "walk"
        info.dir = 0
        return true, info
    end

    -- 确定水平方向和距离
    local dir, horizGap
    if toPlat.cx >= fromPlat.cx then
        dir = 1  -- 向右
        horizGap = math.max(0, toPlat.x1 - fromPlat.x2)
    else
        dir = -1 -- 向左
        horizGap = math.max(0, fromPlat.x1 - toPlat.x2)
    end
    info.dir = dir

    -- ========== 目标在下方或同层 ==========
    if dy <= 0.5 then
        local absDy = math.abs(math.min(0, dy))

        if horizGap <= 0.3 and absDy < 1.0 then
            -- 直接走过去
            info.type = "walk"
            return true, info
        end

        -- 下落或平跳
        if dy < -0.5 then
            -- 下落：计算落到目标高度所需时间
            local fallDist = absDy
            local effectiveG = GRAVITY * FALL_GRAV_MUL
            local fallTime = math.sqrt(2 * fallDist / effectiveG)
            -- 跳出去再落的话有更多水平位移
            local totalAirTime = TIME_TO_PEAK + math.sqrt(2 * (MAX_JUMP_HEIGHT + fallDist) / effectiveG)
            local maxHorizJump = AIR_HORIZ_SPEED * totalAirTime

            if horizGap > maxHorizJump + 1.0 then
                return false, nil
            end

            -- 确定起跳点和落点
            if horizGap < 1.0 then
                -- 间隙小，走到边缘掉下去即可
                info.type = "fall"
                info.launchX = (dir > 0) and fromPlat.x2 - 0.3 or fromPlat.x1 + 0.3
                info.landX = toPlat.cx
            else
                -- 需要跳过间隙
                info.type = "jump_across"
                info.launchX = (dir > 0) and (fromPlat.x2 - 0.5) or (fromPlat.x1 + 0.5)
                info.landX = (dir > 0) and (toPlat.x1 + math.min(1.5, toPlat.width * 0.3))
                                        or  (toPlat.x2 - math.min(1.5, toPlat.width * 0.3))
            end
            return true, info
        end

        -- 同层跳跃（跨间隙）
        local airTime = 2 * TIME_TO_PEAK * 0.8
        local maxJumpHoriz = AIR_HORIZ_SPEED * airTime
        if horizGap > maxJumpHoriz then
            return false, nil
        end
        info.type = "jump_across"
        info.launchX = (dir > 0) and (fromPlat.x2 - 0.5) or (fromPlat.x1 + 0.5)
        info.landX = (dir > 0) and (toPlat.x1 + math.min(1.5, toPlat.width * 0.3))
                                or  (toPlat.x2 - math.min(1.5, toPlat.width * 0.3))
        return true, info
    end

    -- ========== 目标在上方 ==========
    if dy > MAX_JUMP_HEIGHT - 0.3 then
        return false, nil  -- 跳不到（即使二段跳也不够）
    end

    -- 判断是否需要二段跳（目标高度超过单次跳跃极限）
    local needDoubleJump = (dy > SINGLE_JUMP_HEIGHT - 0.3)

    -- 解方程：对于二段跳，使用等效的更大跳跃高度
    -- 简化模型：二段跳约等于总跳跃时间翻倍
    local effectiveJumpSpeed = JUMP_SPEED
    local effectivePeakTime = TIME_TO_PEAK
    if needDoubleJump then
        -- 二段跳：在第一跳顶点附近再跳一次，总滞空时间约 2*TIME_TO_PEAK
        effectivePeakTime = TIME_TO_PEAK * 2
    end

    local disc = effectiveJumpSpeed * effectiveJumpSpeed - 2 * GRAVITY * math.min(dy, SINGLE_JUMP_HEIGHT - 0.5)
    if disc < 0 then disc = 0 end
    local tReachUp   = (effectiveJumpSpeed - math.sqrt(disc)) / GRAVITY
    local tReachDown = needDoubleJump and (effectivePeakTime * 2) or ((effectiveJumpSpeed + math.sqrt(disc)) / GRAVITY)

    -- 角色实际可在 [tReachUp, tReachDown] 之间的任意时刻落上目标平台
    -- 因此可用的水平滞空时间 = tReachDown
    local maxHorizAtH = AIR_HORIZ_SPEED * tReachDown + 1.5  -- +1.5 含起跳前的助跑

    if horizGap > maxHorizAtH then
        return false, nil
    end

    info.type = "jump_up"

    -- 简化策略：起跳点 = 目标平台 X 投影到出发平台上的位置
    -- 这样起跳后空中制导只需要小幅修正
    info.launchX = math.max(fromPlat.x1 + 0.3, math.min(fromPlat.x2 - 0.3, toPlat.cx))
    info.landX = toPlat.cx
    -- 落点 X 与起跳 X 的差决定空中方向
    local needHoriz = info.landX - info.launchX
    if math.abs(needHoriz) < 0.3 then
        info.dir = 0  -- 垂直跳
    else
        info.dir = needHoriz > 0 and 1 or -1
    end

    return true, info
end

-- ============================================================================
-- 寻找当前平台
-- ============================================================================

---@param px number 角色世界 X
---@param py number 角色世界 Y
---@param platforms table
---@return table|nil
local function findCurrentPlatform(px, py, platforms)
    local best = nil
    local bestScore = math.huge

    for _, plat in ipairs(platforms) do
        if px >= plat.x1 - 0.8 and px <= plat.x2 + 0.8 then
            local dy = py - plat.charY
            -- 站在上面（dy ~ 0）或刚离开（dy 略正）
            if dy >= -0.5 and dy <= 2.5 then
                local xDist = math.max(0, plat.x1 - px) + math.max(0, px - plat.x2)
                local score = math.abs(dy) * 2 + xDist
                if score < bestScore then
                    bestScore = score
                    best = plat
                end
            end
        end
    end
    return best
end

-- ============================================================================
-- A* 寻路 - 优化版
-- ============================================================================

---@param startPlat table
---@param platforms table
---@return table|nil path, table|nil jumpInfos
local function findPathToFinish(startPlat, platforms)
    -- 找终点
    local finishPlats = {}
    for _, p in ipairs(platforms) do
        if p.isFinish then
            table.insert(finishPlats, p)
        end
    end
    if #finishPlats == 0 then return nil, nil end

    -- 平台索引映射
    local platIndex = {}
    for i, p in ipairs(platforms) do
        platIndex[p] = i
    end
    local startIdx = platIndex[startPlat]
    if not startIdx then return nil, nil end

    -- 构建邻接表（带 jumpInfo）
    local adjacency = {}
    local jumpInfoMap = {}  -- [fromIdx][toIdx] = jumpInfo

    for i = 1, #platforms do
        adjacency[i] = {}
        jumpInfoMap[i] = {}
    end

    local MAX_DY_UP   = MAX_JUMP_HEIGHT + 1.0
    local MAX_DY_DOWN = 25.0
    local MAX_DX      = 20.0

    for i = 1, #platforms do
        local pi = platforms[i]
        for j = 1, #platforms do
            if i ~= j then
                local pj = platforms[j]
                local dy = pj.charY - pi.charY
                if dy <= MAX_DY_UP and dy >= -MAX_DY_DOWN then
                    local dxCenter = math.abs(pj.cx - pi.cx)
                    if dxCenter <= MAX_DX then
                        local reachable, jinfo = analyzeReachability(pi, pj)
                        if reachable and jinfo then
                            -- 代价函数：首要目标=向上爬升（保持非负，靠相对差异引导）
                            local cost = 1.0
                            -- 向上跳：极低代价
                            if dy > 0.5 then
                                cost = 0.1
                            -- 下降：巨大惩罚（除非别无选择）
                            elseif dy < -0.5 then
                                cost = 50.0 + math.abs(dy) * 10.0
                            else
                                -- 同层移动：中等代价
                                cost = 10.0 + dxCenter * 0.2
                            end
                            -- 接近跳跃极限高度时增加风险代价
                            if jinfo.type == "jump_up" then
                                local diffRatio = dy / MAX_JUMP_HEIGHT
                                if diffRatio > 0.85 then
                                    cost = cost + (diffRatio - 0.85) * 20.0
                                end
                            end

                            table.insert(adjacency[i], { idx = j, cost = cost })
                            jumpInfoMap[i][j] = jinfo
                        end
                    end
                end
            end
        end
    end

    -- 启发式
    local function heuristic(idx)
        local p = platforms[idx]
        local minH = math.huge
        for _, fp in ipairs(finishPlats) do
            local h = math.max(0, fp.charY - p.charY) * 0.2
                    + math.abs(fp.cx - p.cx) * 0.15
            if h < minH then minH = h end
        end
        return minH
    end

    -- A*
    local gScore = { [startIdx] = 0 }
    local cameFrom = {}
    local cameEdge = {}  -- 记录使用的边（含 jumpInfo）
    local closedSet = {}
    local openSet = { { idx = startIdx, f = heuristic(startIdx) } }

    while #openSet > 0 do
        -- 找 f 最小
        local bestI = 1
        for i = 2, #openSet do
            if openSet[i].f < openSet[bestI].f then bestI = i end
        end
        local current = openSet[bestI]
        table.remove(openSet, bestI)

        if platforms[current.idx].isFinish then
            -- 回溯路径
            local path = {}
            local jumpInfos = {}
            local c = current.idx
            while c do
                table.insert(path, 1, platforms[c])
                if cameFrom[c] then
                    table.insert(jumpInfos, 1, jumpInfoMap[cameFrom[c]][c])
                end
                c = cameFrom[c]
            end
            return path, jumpInfos
        end

        closedSet[current.idx] = true

        for _, edge in ipairs(adjacency[current.idx]) do
            if not closedSet[edge.idx] then
                local tentG = (gScore[current.idx] or math.huge) + edge.cost
                if tentG < (gScore[edge.idx] or math.huge) then
                    gScore[edge.idx] = tentG
                    cameFrom[edge.idx] = current.idx

                    local found = false
                    for _, o in ipairs(openSet) do
                        if o.idx == edge.idx then
                            o.f = tentG + heuristic(edge.idx)
                            found = true
                            break
                        end
                    end
                    if not found then
                        table.insert(openSet, { idx = edge.idx, f = tentG + heuristic(edge.idx) })
                    end
                end
            end
        end
    end

    return nil, nil
end

-- ============================================================================
-- 共享缓存
-- ============================================================================
local cachedPlatforms_ = {}
local platformScanTimer_ = 0
local aiStates_ = {}
local playerModule_ = nil
local mapModule_ = nil

-- ============================================================================
-- 初始化 & 注册
-- ============================================================================

function AIController.Init(playerRef, mapRef)
    playerModule_ = playerRef
    mapModule_ = mapRef
    aiStates_ = {}
    cachedPlatforms_ = {}
    platformScanTimer_ = 0
    print("[AI] Initialized (smart nav v6)")
end

function AIController.Register(playerData)
    aiStates_[playerData.index] = {
        thinkTimer     = math.random() * THINK_INTERVAL,
        repathTimer    = 0,

        moveDir        = 0,
        wantJump       = false,
        wantDash       = false,
        wantSlam       = false,

        aiState        = STATE_NAVIGATE,
        path           = nil,
        jumpInfos      = nil,
        pathIdx        = 1,

        jumpTarget     = nil,
        jumpLandX      = nil,
        jumpLaunchX    = nil,
        jumpDir        = 0,

        stuckTimer     = 0,
        lastX          = 0,
        lastY          = 0,
        stuckJumps     = 0,

        lastPlatform   = nil,

        -- 战术：炸弹
        chargeTimer    = 0,         -- 已蓄力时间（仅 AI 内部估算）
        bombRecheck    = 0,         -- 蓄力期间下次重评估倒计时
        bombTargetIdx  = nil,       -- 当前炸弹目标的玩家索引

        -- 战术：道具
        pickupTarget   = nil,       -- { x, y } 当前正在追的道具
        pickupTimer    = 0,         -- 追道具的剩余时长
    }
    print("[AI] Player " .. playerData.index .. " registered (race+combat v7)")
end

--- 取消 AI 注册（玩家切为人类控制时调用）
---@param playerData table
function AIController.Unregister(playerData)
    if playerData and aiStates_[playerData.index] then
        aiStates_[playerData.index] = nil
        print("[AI] Player " .. playerData.index .. " unregistered")
    end
end

-- ============================================================================
-- 主更新
-- ============================================================================

function AIController.Update(dt)
    if not playerModule_ or not mapModule_ then return end

    -- 定期扫描平台
    platformScanTimer_ = platformScanTimer_ - dt
    if platformScanTimer_ <= 0 then
        platformScanTimer_ = PLATFORM_SCAN_INTERVAL
        cachedPlatforms_ = scanPlatforms(mapModule_)
    end

    for _, p in ipairs(playerModule_.list) do
        if not p.isHuman and p.alive and not p.finished then
            AIController.UpdateOne(p, dt)
        end
    end
end

function AIController.UpdateOne(p, dt)
    local state = aiStates_[p.index]
    if not state then
        AIController.Register(p)
        state = aiStates_[p.index]
    end

    -- 战术决策（每帧检查，炸弹/道具时序敏感）
    AIController.UpdateBomb(p, state, dt)

    state.thinkTimer = state.thinkTimer - dt
    if state.thinkTimer <= 0 then
        state.thinkTimer = THINK_INTERVAL + math.random() * 0.03
        AIController.Think(p, state)
    end

    -- 应用输入
    p.inputMoveX = state.moveDir

    if state.wantJump then
        p.inputJump = true
        state.wantJump = false
    end
    if state.wantDash then
        p.inputDash = true
        state.wantDash = false
    end
    if state.wantSlam then
        p.inputSlam = true
        state.wantSlam = false
    end
    -- 炸弹输入（持续 / 一次性）
    if state.wantCharging then
        p.inputCharging = true
    end
    if state.wantExplodeRelease then
        p.inputExplodeRelease = true
        state.wantExplodeRelease = false
    end
end

-- ============================================================================
-- 核心思考
-- ============================================================================

function AIController.Think(p, state)
    if not p.node then return end

    local pos = p.node.position
    local px, py = pos.x, pos.y
    local vel = p.body and p.body.linearVelocity or Vector3.ZERO
    local vx, vy = vel.x, vel.y

    -- 是否在空中
    local inAir = not p.onGround

    -- =========================================
    -- 0) 路径管理
    -- =========================================
    state.repathTimer = state.repathTimer - THINK_INTERVAL
    local needRepath = false
    if state.path == nil then
        needRepath = true
    elseif state.repathTimer <= 0 then
        needRepath = true
    elseif state.pathIdx > #state.path then
        needRepath = true
    end

    if needRepath then
        AIController.Repath(p, state, px, py)
        state.repathTimer = REPATH_INTERVAL_MIN + math.random() * (REPATH_INTERVAL_MAX - REPATH_INTERVAL_MIN)
    end

    -- =========================================
    -- 1) 空中制导（跳跃中或下落中）
    -- =========================================
    if inAir then
        AIController.ThinkInAir(p, state, px, py, vx, vy)
        AIController.UpdateStuck(p, state, px, py)
        return
    end

    -- =========================================
    -- 2) 地面行为
    -- =========================================
    local curPlat = findCurrentPlatform(px, py, cachedPlatforms_)
    state.lastPlatform = curPlat

    -- 获取下一个目标平台和跳跃信息
    local targetPlat, jumpInfo = AIController.GetNextTarget(state)

    if not targetPlat then
        -- 没路：主动找正上方最近的平台并尝试跳过去
        local bestUp = nil
        local bestUpScore = math.huge
        for _, plat in ipairs(cachedPlatforms_) do
            local plDy = plat.charY - py
            if plDy > 0.5 and plDy <= MAX_JUMP_HEIGHT - 0.5 then
                local plDx = math.abs(plat.cx - px)
                -- 优先：高一点 + X 接近
                local score = plDx + plDy * 0.3
                if score < bestUpScore then
                    bestUpScore = score
                    bestUp = plat
                end
            end
        end
        if bestUp then
            local dx = bestUp.cx - px
            state.moveDir = math.abs(dx) > 1.0 and (dx > 0 and 1 or -1) or 0
            if p.onGround and math.abs(dx) <= 2.0 then
                state.wantJump = true
                state.jumpTarget = bestUp
                state.jumpLandX = bestUp.cx
            end
        else
            state.moveDir = (math.random() > 0.5) and 1 or -1
            if p.onGround then state.wantJump = true end
        end
        state.path = nil
        AIController.UpdateStuck(p, state, px, py)
        return
    end

    -- 检查是否已到达当前目标平台
    if curPlat == targetPlat then
        -- 已到达！推进路径
        state.pathIdx = state.pathIdx + 1
        targetPlat, jumpInfo = AIController.GetNextTarget(state)
        if not targetPlat then
            state.path = nil
            AIController.UpdateStuck(p, state, px, py)
            return
        end
    end

    -- =========================================
    -- 3) 根据跳跃信息决定行动
    -- =========================================
    if jumpInfo then
        local jtype = jumpInfo.type

        if jtype == "walk" then
            -- 直接走过去
            local targetX = targetPlat.cx
            local dx = targetX - px
            if math.abs(dx) > 0.3 then
                state.moveDir = dx > 0 and 1 or -1
            else
                state.moveDir = 0
                -- 已到达，推进
                state.pathIdx = state.pathIdx + 1
            end
            -- 走路时检测前方间隙
            AIController.CheckGapAndJump(p, state, px, py)

        elseif jtype == "jump_up" or jtype == "jump_across" then
            -- 需要跳跃：先对准起跳点（容差宽松，靠空中制导修正）
            local launchX = jumpInfo.launchX or px
            local dx = launchX - px
            local absDx = math.abs(dx)

            -- 必须在当前平台上才考虑起跳（防止悬空乱跳）
            local onCurPlat = curPlat and (px >= curPlat.x1 - 0.3 and px <= curPlat.x2 + 0.3)

            -- 把 launchX 限制在当前平台范围内（避免追到平台外）
            local clampedLaunchX = launchX
            if curPlat then
                clampedLaunchX = math.max(curPlat.x1 + 0.3, math.min(curPlat.x2 - 0.3, launchX))
            end
            local dxClamped = clampedLaunchX - px

            -- 起跳方向：斜跳用 jumpInfo.dir；垂直跳根据目标 X 偏移决定（容差 0.3m 内才真正垂直）
            local jumpMoveDir
            if jumpInfo.dir and jumpInfo.dir ~= 0 then
                jumpMoveDir = jumpInfo.dir
            else
                local cxDx = targetPlat.cx - px
                if math.abs(cxDx) < 0.3 then
                    jumpMoveDir = 0  -- 真垂直跳
                else
                    jumpMoveDir = cxDx > 0 and 1 or -1
                end
            end

            -- 容差放宽到 1.5m，到位就跳（不要追求完美）
            if math.abs(dxClamped) > 1.5 then
                state.moveDir = dxClamped > 0 and 1 or -1
                state.aiState = STATE_APPROACH
            else
                -- 接近起跳点
                state.moveDir = jumpMoveDir
                if p.onGround and onCurPlat then
                    state.wantJump = true
                    state.aiState = STATE_JUMP
                    state.jumpTarget = targetPlat
                    state.jumpLandX = jumpInfo.landX or targetPlat.cx
                    state.jumpDir = jumpInfo.dir or state.moveDir
                    if VERBOSE_JUMP_LOG then
                        print(string.format(
                            "[AI#%d] JUMP %s px=%.2f launchX=%.2f landX=%.2f targetY=%.2f dy=%.2f dir=%d",
                            p.index, jtype, px, launchX, state.jumpLandX,
                            targetPlat.charY, jumpInfo.dy or 0, state.jumpDir or 0))
                    end
                end
            end

        elseif jtype == "fall" then
            -- 走到边缘掉下去
            local edgeX = jumpInfo.launchX or
                ((jumpInfo.dir or 1) > 0 and curPlat and curPlat.x2 or curPlat and curPlat.x1 or px)
            local dx = edgeX - px
            if math.abs(dx) > 0.3 then
                state.moveDir = dx > 0 and 1 or -1
            else
                -- 在边缘了，继续走出去
                state.moveDir = jumpInfo.dir or 1
            end
            state.jumpTarget = targetPlat
            state.jumpLandX = jumpInfo.landX or targetPlat.cx
            state.jumpDir = jumpInfo.dir or state.moveDir
        end
    else
        -- 没有 jumpInfo（不该发生，但 fallback）
        -- 重算路径中的可达性
        if curPlat and targetPlat then
            local reachable, jinfo = analyzeReachability(curPlat, targetPlat)
            if reachable and jinfo then
                -- 用新计算的 jumpInfo
                if state.jumpInfos and state.pathIdx - 1 >= 1 then
                    state.jumpInfos[state.pathIdx - 1] = jinfo
                end
            else
                -- 不可达，重新寻路
                state.path = nil
            end
        end
        -- fallback 行为
        state.moveDir = targetPlat.cx > px and 1 or -1
        AIController.CheckGapAndJump(p, state, px, py)
    end

    -- 4) 顺路捡道具：在不破坏导航主干的前提下，微调 moveDir 朝道具方向
    AIController.ThinkPickupDetour(p, state, px, py, curPlat, targetPlat)

    -- 5) 直线疾跑：在长平台上同向冲刺加速
    AIController.ThinkSprintDash(p, state, px, py, curPlat, targetPlat)

    -- 6) 卡住检测
    AIController.UpdateStuck(p, state, px, py)
end

-- ============================================================================
-- 顺路捡道具：仅当 (1) 当前在地面、(2) 道具与目标平台同侧、(3) 偏离很小 时生效
-- ============================================================================
function AIController.ThinkPickupDetour(p, state, px, py, curPlat, targetPlat)
    if not p.onGround or not curPlat or not targetPlat then return end
    if p.energy >= 0.95 then return end  -- 满能量不绕

    -- 道具目标维护
    state.pickupTimer = (state.pickupTimer or 0) - THINK_INTERVAL
    if not state.pickupTarget or state.pickupTimer <= 0 then
        state.pickupTarget = findDetourPickup(p, state)
        state.pickupTimer = PICKUP_TARGET_TIMEOUT
    end

    if not state.pickupTarget then return end

    local pk = state.pickupTarget
    local toPickup = pk.x - px

    -- 道具必须在当前平台横向范围内，否则别绕（避免冲下悬崖去捡）
    if pk.x < curPlat.x1 - 0.5 or pk.x > curPlat.x2 + 0.5 then
        state.pickupTarget = nil
        return
    end
    -- 道具必须大致在当前高度（避免向下/向上绕远）
    if math.abs(pk.y - py) > 1.8 then
        state.pickupTarget = nil
        return
    end

    -- 道具方向必须与主路径目标方向一致或非常近
    local toTarget = targetPlat.cx - px
    if (toTarget >= 0) ~= (toPickup >= -0.5) and math.abs(toPickup) > 0.5 then
        -- 反向道具，放弃
        state.pickupTarget = nil
        return
    end

    -- 微调方向朝道具
    if math.abs(toPickup) > 0.4 then
        state.moveDir = toPickup > 0 and 1 or -1
    end
end

-- ============================================================================
-- 战术：炸弹决策
-- ============================================================================

--- 检查脚下"炸完是否还能站住"：自身爆炸圈内必须有非普通块（SAFE）或圈外可达
---@param p table 玩家
---@param radius number 估算的爆炸格半径
---@return boolean safe
local function isBombSelfSafe(p, radius)
    if not p.node or not mapModule_ then return false end
    local px, py = p.node.position.x, p.node.position.y
    -- 角色脚下格子
    local fgx, fgy = mapModule_.WorldToGrid(px, py - CHAR_HALF_H - 0.1)
    -- 在爆炸半径内寻找一块"安全方块"：SAFE 或紧邻爆炸圈外的实心块
    local r = math.max(2, math.floor(radius))
    -- 1) 脚下圈内有 SAFE 块 → 安全
    for dx = -r, r do
        for dy = -1, 1 do
            local gx, gy = fgx + dx, fgy + dy
            local block = mapModule_.GetBlock(gx, gy)
            if block == Config.BLOCK_SAFE then
                return true
            end
        end
    end
    -- 2) 圈外 1~2 格内有任意实心块（爆炸不会摧毁），且与角色高度差不大
    for dx = -(r + 2), r + 2 do
        if math.abs(dx) > r then
            for dy = -2, 2 do
                local gx, gy = fgx + dx, fgy + dy
                local block = mapModule_.GetBlock(gx, gy)
                if block ~= Config.BLOCK_EMPTY then
                    return true
                end
            end
        end
    end
    return false
end

--- 寻找适合炸的目标玩家：在杀伤范围内 + 活着 + 不是自己 + 不是已完赛
---@param p table 自身
---@return table|nil targetPlayer, number distSq
local function findBombTarget(p)
    if not playerModule_ or not p.node then return nil, math.huge end
    local px, py = p.node.position.x, p.node.position.y
    local best, bestD2 = nil, math.huge
    for _, q in ipairs(playerModule_.list) do
        if q.index ~= p.index and q.alive and not q.finished and q.node then
            local qpos = q.node.position
            local dx = qpos.x - px
            local dy = qpos.y - py
            if math.abs(dx) <= BOMB_KILL_RANGE and math.abs(dy) <= BOMB_KILL_VERTICAL then
                local d2 = dx * dx + dy * dy
                if d2 < bestD2 then
                    bestD2 = d2
                    best = q
                end
            end
        end
    end
    return best, bestD2
end

--- 每帧炸弹决策：决定是否开始/维持/释放蓄力
function AIController.UpdateBomb(p, state, dt)
    -- 重置持续输入（默认不蓄力）
    state.wantCharging = false

    if not p.alive or p.finished then
        state.chargeTimer = 0
        state.bombTargetIdx = nil
        return
    end

    -- 已经炸过/能量没了 → 清状态
    if p.energy < 1.0 and not p.charging then
        state.chargeTimer = 0
        state.bombTargetIdx = nil
        return
    end

    -- 当前 Player 端蓄力中：维持 + 计时 + 决定何时释放
    if p.charging then
        state.chargeTimer = state.chargeTimer + dt
        state.bombRecheck = state.bombRecheck - dt
        state.wantCharging = true  -- 持续按住

        local target, _ = findBombTarget(p)

        -- 失去目标且已蓄力一段时间 → 立即释放（别浪费）
        if not target and state.chargeTimer > 0.4 then
            state.wantCharging = false
            state.wantExplodeRelease = true
            state.chargeTimer = 0
            state.bombTargetIdx = nil
            return
        end

        -- 蓄力达到目标时长 → 释放
        if state.chargeTimer >= BOMB_CHARGE_TIME then
            state.wantCharging = false
            state.wantExplodeRelease = true
            state.chargeTimer = 0
            state.bombTargetIdx = nil
            return
        end

        -- 周期性安全检查：如果脚下变得不安全，立即释放避免被自己困死
        if state.bombRecheck <= 0 then
            state.bombRecheck = BOMB_RECHECK_INTERVAL
            local approxRadius = math.max(1, math.floor(Config.ExplosionRadius * (state.chargeTimer / Config.ExplosionChargeTime)))
            if not isBombSelfSafe(p, approxRadius) then
                -- 已不安全：立即释放（已经按了能量没办法吞回）
                state.wantCharging = false
                state.wantExplodeRelease = true
                state.chargeTimer = 0
                state.bombTargetIdx = nil
                return
            end
        end
        return
    end

    -- 未蓄力：满能量 + 找到目标 + 自身安全 → 开始蓄力
    if p.energy >= 1.0 and p.onGround then
        local target, _ = findBombTarget(p)
        if target and isBombSelfSafe(p, math.floor(Config.ExplosionRadius * (BOMB_CHARGE_TIME / Config.ExplosionChargeTime))) then
            state.wantCharging = true
            state.chargeTimer = 0
            state.bombRecheck = BOMB_RECHECK_INTERVAL
            state.bombTargetIdx = target.index
        end
    end
end

-- ============================================================================
-- 战术：顺路捡道具
-- ============================================================================

--- 在主路径附近找一个值得绕的道具，返回坐标或 nil
---@param p table
---@param state table
---@return table|nil pickup { x, y, amount }
findDetourPickup = function(p, state)
    local PickupMod = getPickupModule()
    if not PickupMod or not p.node then return nil end
    if not state.path or state.pathIdx > #state.path then return nil end

    local pos = p.node.position
    local px, py = pos.x, pos.y
    -- 主路径下一个目标的位置
    local nextPlat = state.path[state.pathIdx]
    if not nextPlat then return nil end

    -- 满能量就别绕了，能量会浪费
    if p.energy >= 0.95 then return nil end

    local list = PickupMod.GetActivePickups()
    if #list == 0 then return nil end

    local best, bestScore = nil, -math.huge
    for _, pk in ipairs(list) do
        local dx = pk.x - px
        local dy = pk.y - py
        -- 限制：不能偏离当前位置太远，且大致在同一高度（避免下来再上去）
        if math.abs(dx) <= PICKUP_DETOUR_MAX_DX and math.abs(dy) <= PICKUP_DETOUR_MAX_DY then
            -- 必须在通往目标的方向上（同侧）才考虑
            local toTarget = nextPlat.cx - px
            local sameSide = (toTarget >= 0 and dx >= -1.0) or (toTarget < 0 and dx <= 1.0)
            if sameSide then
                -- 评分：amount 大 + 距离近 + 顺路（dx 与 toTarget 同号更好）
                local distScore = -math.sqrt(dx * dx + dy * dy * 1.5)
                local sizeScore = (pk.amount or 0.2) * 5.0
                local detourPenalty = math.abs(dx - toTarget) * 0.2
                local score = distScore + sizeScore - detourPenalty
                if score > bestScore then
                    bestScore = score
                    best = pk
                end
            end
        end
    end
    return best
end

-- ============================================================================
-- 获取下一个目标平台
-- ============================================================================

---@return table|nil targetPlat, table|nil jumpInfo
function AIController.GetNextTarget(state)
    if not state.path then return nil, nil end
    if state.pathIdx > #state.path then return nil, nil end

    local targetPlat = state.path[state.pathIdx]
    local jumpInfo = nil
    if state.jumpInfos and state.pathIdx - 1 >= 1 then
        jumpInfo = state.jumpInfos[state.pathIdx - 1]
    end
    return targetPlat, jumpInfo
end

-- ============================================================================
-- 空中制导
-- ============================================================================

function AIController.ThinkInAir(p, state, px, py, vx, vy)
    -- 如果有跳跃目标，朝目标平台修正
    if state.jumpTarget then
        local tp = state.jumpTarget
        -- 目标"安全落区"：平台中段，避免落到边缘掉下去
        local safeL = tp.x1 + math.min(0.6, tp.width * 0.2)
        local safeR = tp.x2 - math.min(0.6, tp.width * 0.2)
        if safeL > safeR then  -- 平台太窄
            safeL, safeR = tp.cx - 0.2, tp.cx + 0.2
        end

        -- 还没到安全区 → 持续朝平台方向飞
        if px < safeL then
            state.moveDir = 1
        elseif px > safeR then
            state.moveDir = -1
        else
            -- 已经在安全区上方：根据水平速度决定是否反向制动
            -- 如果还在快速向某方向飞，会冲出安全区 → 反向减速
            if vx > 2.0 and px > tp.cx + 0.3 then
                state.moveDir = -1
            elseif vx < -2.0 and px < tp.cx - 0.3 then
                state.moveDir = 1
            else
                -- 维持轻微水平输入保持位置
                state.moveDir = (tp.cx > px) and 1 or -1
            end
        end
    else
        -- 没有明确跳跃目标，尝试找最近的可落地平台
        local bestPlat = nil
        local bestScore = math.huge

        for _, plat in ipairs(cachedPlatforms_) do
            -- 只看下方或同层的平台
            if plat.charY <= py + 1.0 then
                local platDx = math.max(0, plat.x1 - px) + math.max(0, px - plat.x2)
                local platDy = py - plat.charY
                if platDy >= -1.0 and platDy < 20.0 then
                    -- 偏好宽的、高的、近的平台
                    local score = platDx * 1.5 + platDy * 0.5 - plat.width * 0.3
                    -- 偏好更高的平台（不要掉太远）
                    score = score + math.max(0, platDy - 3) * 2.0
                    if score < bestScore then
                        bestScore = score
                        bestPlat = plat
                    end
                end
            end
        end

        if bestPlat then
            local targetX = math.max(bestPlat.x1 + 0.5, math.min(bestPlat.x2 - 0.5, px))
            local dx = targetX - px
            if math.abs(dx) > 0.5 then
                state.moveDir = dx > 0 and 1 or -1
            else
                state.moveDir = 0
            end
        end
    end

    -- 二段跳：如果目标在上方且当前正在下落（vy < 0），且还有跳跃次数，使用二段跳
    if state.jumpTarget and vy < -1.0 and p.jumpCount < MAX_JUMPS then
        local tp = state.jumpTarget
        local needHeight = tp.charY - py
        -- 预测：按当前速度继续下落能否到达目标高度？如果不能，二段跳
        -- 简单判断：目标在上方且正在下落 → 二段跳
        if needHeight > 1.0 then
            state.wantJump = true
            if VERBOSE_JUMP_LOG then
                print(string.format("[AI#%d] DOUBLE JUMP vy=%.2f needH=%.2f jumpCount=%d",
                    p.index, vy, needHeight, p.jumpCount))
            end
        end
    end

    -- 下砸战术：空中正下方有其他玩家且距离合适时使用下砸
    if not p.slamming and vy < 0 and playerModule_ then
        local slamRadius = Config.SlamRadius or 3.0
        for _, other in ipairs(playerModule_.list) do
            if other.index ~= p.index and other.alive and not other.finished and other.node then
                local opos = other.node.position
                local dx = math.abs(opos.x - px)
                local dy = py - opos.y  -- 正值表示 AI 在上方
                -- 正下方（水平距离小）且高度差适中（2~8米）
                if dx < slamRadius * 0.6 and dy > 2.0 and dy < 8.0 then
                    state.wantSlam = true
                    if VERBOSE_JUMP_LOG then
                        print(string.format("[AI#%d] SLAM dx=%.2f dy=%.2f target=#%d",
                            p.index, dx, dy, other.index))
                    end
                    break
                end
            end
        end
    end

    -- 着地后清除跳跃目标
    if p.onGround then
        -- 检查是否落到了目标平台附近
        if state.jumpTarget then
            local tp = state.jumpTarget
            local hit = (px >= tp.x1 - 1.0 and px <= tp.x2 + 1.0 and
                         math.abs(py - tp.charY) < 2.0)
            if hit then
                state.pathIdx = state.pathIdx + 1
                if VERBOSE_JUMP_LOG then
                    print(string.format("[AI#%d] LAND OK  px=%.2f py=%.2f targetY=%.2f",
                        p.index, px, py, tp.charY))
                end
            else
                if VERBOSE_JUMP_LOG then
                    print(string.format("[AI#%d] LAND MISS px=%.2f py=%.2f target [%.2f~%.2f]@%.2f -> repath",
                        p.index, px, py, tp.x1, tp.x2, tp.charY))
                end
                -- 没落到目标 → 强制重寻路，避免反复尝试同一失败跳跃
                state.path = nil
                state.repathTimer = 0
            end
        end
        state.jumpTarget = nil
        state.jumpLandX = nil
        state.aiState = STATE_NAVIGATE
    end
end

-- ============================================================================
-- 间隙/墙壁跳跃检测
-- ============================================================================

function AIController.CheckGapAndJump(p, state, px, py)
    if not mapModule_ or state.moveDir == 0 or not p.onGround then return end

    local dir = state.moveDir

    -- 检测前方1.2格地面是否存在
    local checkX = px + dir * 1.2
    local footY = py - CHAR_HALF_H - 0.3
    local gx, gy = mapModule_.WorldToGrid(checkX, footY)
    local block = mapModule_.GetBlock(gx, gy)
    if block == Config.BLOCK_EMPTY then
        -- 前方有间隙 → 但如果目标在下方就不跳（直接走下去）
        local targetPlat = AIController.GetNextTarget(state)
        if targetPlat and targetPlat.charY < py - 1.0 then
            -- 目标在下方，不跳，让自己掉下去
            return
        end
        state.wantJump = true
        return
    end

    -- 检测前方0.7格是否有墙（身体范围内）
    checkX = px + dir * 0.7
    local midY = py
    local gxW, gyW = mapModule_.WorldToGrid(checkX, midY)
    if mapModule_.GetBlock(gxW, gyW) ~= Config.BLOCK_EMPTY then
        -- 前方有墙，跳！
        state.wantJump = true
    end
end

-- ============================================================================
-- 卡住检测与恢复
-- ============================================================================

function AIController.UpdateStuck(p, state, px, py)
    local moveDist = math.abs(px - state.lastX) + math.abs(py - state.lastY)

    if moveDist < 0.05 then
        state.stuckTimer = state.stuckTimer + THINK_INTERVAL
    else
        state.stuckTimer = math.max(0, state.stuckTimer - THINK_INTERVAL * 3)
        state.stuckJumps = 0
    end
    state.lastX = px
    state.lastY = py

    -- 分级恢复
    if state.stuckTimer > 0.2 and p.onGround then
        -- 阶段1：跳跃
        state.wantJump = true
        state.stuckJumps = state.stuckJumps + 1

        -- 每 2 次跳跃换方向
        if state.stuckJumps % 2 == 0 then
            state.moveDir = -state.moveDir
            if state.moveDir == 0 then state.moveDir = (math.random() > 0.5) and 1 or -1 end
        end
    end

    if state.stuckTimer > 0.8 then
        -- 阶段2：冲刺脱困
        if p.dashCooldown <= 0 then
            state.wantDash = true
            state.stuckTimer = 0.2
        end
    end

    if state.stuckTimer > 1.5 then
        -- 阶段3：重新寻路 + 强制换方向
        state.path = nil
        state.stuckTimer = 0
        state.stuckJumps = 0
        state.moveDir = (math.random() > 0.5) and 1 or -1
    end
end

-- ============================================================================
-- 寻路
-- ============================================================================

function AIController.Repath(p, state, px, py)
    if #cachedPlatforms_ == 0 then
        cachedPlatforms_ = scanPlatforms(mapModule_)
    end

    local curPlat = findCurrentPlatform(px, py, cachedPlatforms_)
    if not curPlat then
        -- 找最近平台
        local bestDist = math.huge
        for _, plat in ipairs(cachedPlatforms_) do
            local cx = math.max(plat.x1, math.min(plat.x2, px))
            local d = math.abs(cx - px) + math.abs(plat.charY - py) * 2
            if d < bestDist then
                bestDist = d
                curPlat = plat
            end
        end
    end

    if not curPlat then
        state.path = nil
        state.jumpInfos = nil
        return
    end

    local path, jumpInfos = findPathToFinish(curPlat, cachedPlatforms_)
    state.path = path
    state.jumpInfos = jumpInfos
    state.pathIdx = 2  -- 跳过当前平台
    state.jumpTarget = nil
    state.jumpLandX = nil
end

-- ============================================================================
-- 直线疾跑：在长平台上沿目标方向冲刺加速（不攻击其他玩家）
-- ============================================================================

function AIController.ThinkSprintDash(p, state, px, py, curPlat, targetPlat)
    if p.dashCooldown > 0 or not p.onGround or not curPlat or not targetPlat then return end

    -- 平台够长 + 同层/接近同层 + 距离够远才冲
    if curPlat.width <= 3.0 then return end
    local dx = targetPlat.cx - px
    local absDx = math.abs(dx)
    local dy = math.abs(targetPlat.charY - py)
    if dy >= 2.0 or absDx <= 3.0 then return end

    local dashDir = dx > 0 and 1 or -1
    local dashEnd = px + dashDir * DASH_DISTANCE
    -- 冲刺终点必须仍在当前平台上，避免冲下悬崖
    if dashEnd < curPlat.x1 + 0.5 or dashEnd > curPlat.x2 - 0.5 then return end

    state.wantDash = true
    state.moveDir = dashDir
end

-- ============================================================================
-- 调试可视化导出
-- ============================================================================

--- 获取所有 AI 的调试信息（供 HUD 可视化使用）
---@return table debugList 每项含 { playerIdx, path={{x,y},...}, jumpInfos, currentTarget={x,y}, currentLaunch={x,y}, currentLand={x,y} }
function AIController.GetDebugInfo()
    local result = {}
    if not playerModule_ then return result end

    for _, p in ipairs(playerModule_.list) do
        local state = aiStates_[p.index]
        if state and not p.isHuman and p.alive and not p.finished then
            local entry = { playerIdx = p.index }

            -- 路径平台中心点列表
            if state.path then
                entry.path = {}
                for i, plat in ipairs(state.path) do
                    table.insert(entry.path, { x = plat.cx, y = plat.charY, w = plat.width })
                end
                entry.pathIdx = state.pathIdx
            end

            -- 当前目标 / 起跳点 / 落点
            if state.path and state.pathIdx <= #state.path then
                local tp = state.path[state.pathIdx]
                if tp then entry.currentTarget = { x = tp.cx, y = tp.charY } end
                local jinfo = state.jumpInfos and state.jumpInfos[state.pathIdx - 1]
                if jinfo then
                    if jinfo.launchX then
                        local fromPlat = state.path[state.pathIdx - 1]
                        local launchY = fromPlat and fromPlat.charY or 0
                        entry.currentLaunch = { x = jinfo.launchX, y = launchY }
                    end
                    if jinfo.landX then
                        entry.currentLand = { x = jinfo.landX, y = tp.charY }
                    end
                    entry.jumpType = jinfo.type
                end
            end

            -- 当前空中跳跃目标（即时反馈）
            if state.jumpTarget and state.jumpLandX then
                entry.airLand = { x = state.jumpLandX, y = state.jumpTarget.charY }
            end

            entry.aiState = state.aiState
            entry.moveDir = state.moveDir

            table.insert(result, entry)
        end
    end

    return result
end

return AIController
