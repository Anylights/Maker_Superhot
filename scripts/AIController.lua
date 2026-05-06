-- ============================================================================
-- AIController.lua - AI 控制器（v7 开放世界）
-- 核心改进：
--   1) 精确起跳点计算：AI 先移到最佳起跳 X 再跳
--   2) 空中制导：跳跃中持续修正水平速度对准落点
--   3) 分层状态机：NAVIGATE → APPROACH_JUMP → JUMPING → FALLING
--   4) 更激进的战术：主动寻找爆炸机会、灵活使用冲刺
--   5) 快速脱困：检测到卡住后立即采取行动
--   6) 路径选择更聪明：优先选物理上容易执行的路径
--   7) 开放世界：局部平台扫描 ±25 层，向上寻路（无终点）
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local AIController = {}

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
local MAX_JUMP_HEIGHT   = (JUMP_SPEED * JUMP_SPEED) / (2 * GRAVITY)     -- ~10.0
local TIME_TO_PEAK      = JUMP_SPEED / GRAVITY                          -- ~1.43s
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
-- 平台扫描（局部：仅扫描 minGY..maxGY 范围内的层）
-- ============================================================================

local AI_SCAN_RANGE = 25  -- 上下各扫描 25 层

---@param mapModule table
---@param minGY number 起始网格 Y（>=1）
---@param maxGY number 结束网格 Y（<=MapData.Height）
---@return table platforms
local function scanPlatforms(mapModule, minGY, maxGY)
    local platforms = {}
    local bs = Config.BlockSize
    minGY = math.max(1, minGY)
    maxGY = math.min(MapData.Height, maxGY)

    for gy = minGY, maxGY do
        local segStart = nil

        for gx = 1, MapData.Width + 1 do
            local block = Config.BLOCK_EMPTY
            if gx <= MapData.Width then
                block = mapModule.GetBlock(gx, gy)
            end

            local isSolid = (block ~= Config.BLOCK_EMPTY)
            local aboveEmpty = true
            if gx <= MapData.Width then
                if gy + 1 <= MapData.Height then
                    if mapModule.GetBlock(gx, gy + 1) ~= Config.BLOCK_EMPTY then
                        aboveEmpty = false
                    end
                end
            end

            local isValidSurface = isSolid and aboveEmpty

            if isValidSurface then
                if segStart == nil then
                    segStart = { x = gx }
                end
            else
                if segStart then
                    local wx1 = (segStart.x - 1) * bs
                    local wx2 = (gx - 1) * bs
                    table.insert(platforms, {
                        x1 = wx1,
                        x2 = wx2,
                        y  = gy * bs,                 -- 平台表面 Y
                        charY = gy * bs + CHAR_HALF_H, -- 角色中心 Y
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
    if dy > MAX_JUMP_HEIGHT - 1.5 then
        return false, nil  -- 跳不到
    end

    -- 解方程：到达高度 dy 的时间
    local disc = JUMP_SPEED * JUMP_SPEED - 2 * GRAVITY * dy
    if disc < 0 then return false, nil end
    local tReach = (JUMP_SPEED - math.sqrt(disc)) / GRAVITY

    -- 在 tReach 时间内能走多远
    local maxHorizAtH = AIR_HORIZ_SPEED * tReach + 1.5  -- +1.5 含起跳前的走动

    if horizGap > maxHorizAtH then
        return false, nil
    end

    info.type = "jump_up"

    -- 起跳点：如果目标在正上方，从目标下方起跳；否则从边缘起跳
    if horizGap < 1.0 then
        -- 几乎正上方，对齐目标中心
        info.launchX = math.max(fromPlat.x1 + 0.3, math.min(fromPlat.x2 - 0.3, toPlat.cx))
        info.landX = toPlat.cx
    else
        -- 需要侧向跳
        info.launchX = (dir > 0) and (fromPlat.x2 - 0.5) or (fromPlat.x1 + 0.5)
        -- 尽量落在目标平台靠近我侧的位置
        info.landX = (dir > 0) and (toPlat.x1 + math.min(1.5, toPlat.width * 0.3))
                                or  (toPlat.x2 - math.min(1.5, toPlat.width * 0.3))
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

--- 向上寻路：贪心 BFS 找一条向上攀爬的路径（约 8-12 步）
---@param startPlat table
---@param platforms table
---@return table|nil path, table|nil jumpInfos
local function findPathUpward(startPlat, platforms)
    local MAX_PATH_STEPS = 12
    local MAX_DY_UP   = MAX_JUMP_HEIGHT + 1.0
    local MAX_DY_DOWN = 8.0
    local MAX_DX      = 20.0

    local path = { startPlat }
    local jumpInfos = {}
    local visited = { [startPlat] = true }
    local current = startPlat

    for _ = 1, MAX_PATH_STEPS do
        -- 从当前平台找最佳的下一个向上平台
        local bestPlat = nil
        local bestInfo = nil
        local bestScore = -math.huge

        for _, plat in ipairs(platforms) do
            if not visited[plat] and plat ~= current then
                local dy = plat.charY - current.charY
                if dy <= MAX_DY_UP and dy >= -MAX_DY_DOWN then
                    local dxCenter = math.abs(plat.cx - current.cx)
                    if dxCenter <= MAX_DX then
                        local reachable, jinfo = analyzeReachability(current, plat)
                        if reachable and jinfo then
                            -- 评分：优先高度增益，其次宽平台、近距离
                            local score = dy * 5.0              -- 高度增益（核心）
                            score = score - dxCenter * 0.3      -- 水平距离惩罚
                            score = score + plat.width * 0.2    -- 宽平台加分
                            -- 跳跃难度惩罚
                            if jinfo.type == "jump_up" and dy > 0 then
                                local diffRatio = dy / MAX_JUMP_HEIGHT
                                score = score - diffRatio * diffRatio * 3.0
                            end
                            -- 窄平台惩罚
                            if plat.width < 2.0 then
                                score = score - (2.0 - plat.width) * 1.0
                            end
                            -- 轻微随机扰动避免重复路径
                            score = score + (math.random() - 0.5) * 1.0

                            if score > bestScore then
                                bestScore = score
                                bestPlat = plat
                                bestInfo = jinfo
                            end
                        end
                    end
                end
            end
        end

        if not bestPlat then break end

        visited[bestPlat] = true
        table.insert(path, bestPlat)
        table.insert(jumpInfos, bestInfo)
        current = bestPlat
    end

    if #path <= 1 then return nil, nil end
    return path, jumpInfos
end

-- ============================================================================
-- 状态
-- ============================================================================
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
    print("[AI] Initialized (v7 open-world)")
end

function AIController.Register(playerData)
    local personality = {
        aggression  = 0.35 + math.random() * 0.50,   -- 0.35~0.85
        dashLove    = 0.25 + math.random() * 0.45,    -- 0.25~0.70
        patience    = 0.4 + math.random() * 0.4,      -- 0.4~0.8
        precision   = 0.6 + math.random() * 0.35,     -- 0.6~0.95（精准度影响起跳时机）
    }

    aiStates_[playerData.index] = {
        -- 计时器
        thinkTimer     = math.random() * THINK_INTERVAL,
        repathTimer    = 0,
        platScanTimer  = 0,           -- 局部平台扫描计时器

        -- 移动输出
        moveDir        = 0,
        wantJump       = false,
        wantDash       = false,

        -- 蓄力
        isCharging     = false,
        chargeHoldTime = 0,
        chargeElapsed  = 0,

        -- 状态机
        aiState        = STATE_NAVIGATE,
        -- 路径
        path           = nil,
        jumpInfos      = nil,
        pathIdx        = 1,        -- 当前要去的下一平台在 path 中的索引

        -- 跳跃制导
        jumpTarget     = nil,      -- 跳跃目标平台
        jumpLandX      = nil,      -- 目标落点 X
        jumpLaunchX    = nil,      -- 起跳 X
        jumpDir        = 0,        -- 跳跃方向

        -- 卡住
        stuckTimer     = 0,
        lastX          = 0,
        lastY          = 0,
        stuckEscapeDir = 0,
        stuckJumps     = 0,

        -- 性格
        personality    = personality,

        -- 上次所在平台
        lastPlatform   = nil,

        -- 局部平台缓存
        cachedPlatforms = {},
    }
    print("[AI] Player " .. playerData.index .. " registered (v7, aggr=" ..
          string.format("%.2f", personality.aggression) .. ")")
end

--- 取消 AI 注册
--- 接受 playerData 对象或直接传 slot/index 数字
---@param playerDataOrIndex table|number
function AIController.Unregister(playerDataOrIndex)
    local idx
    if type(playerDataOrIndex) == "number" then
        idx = playerDataOrIndex
    elseif type(playerDataOrIndex) == "table" and playerDataOrIndex.index then
        idx = playerDataOrIndex.index
    end
    if idx and aiStates_[idx] then
        aiStates_[idx] = nil
        print("[AI] Player " .. idx .. " unregistered")
    end
end

-- ============================================================================
-- 主更新
-- ============================================================================

function AIController.Update(dt)
    if not playerModule_ or not mapModule_ then return end

    for _, p in ipairs(playerModule_.list) do
        -- 会话活跃且存活的 AI 才更新
        local sessionActive = p.session and p.session.active
        if not p.isHuman and p.alive and sessionActive then
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

    -- 局部平台扫描（每个 AI 独立，基于自身位置）
    state.platScanTimer = state.platScanTimer - dt
    if state.platScanTimer <= 0 then
        state.platScanTimer = PLATFORM_SCAN_INTERVAL
        if p.node then
            local py = p.node.position.y
            local centerGY = math.floor(py / Config.BlockSize)
            state.cachedPlatforms = scanPlatforms(mapModule_, centerGY - AI_SCAN_RANGE, centerGY + AI_SCAN_RANGE)
        end
    end

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
        -- 空中也检测爆炸机会
        AIController.ThinkExplode(p, state, px, py)
        AIController.UpdateStuck(p, state, px, py)
        return
    end

    -- =========================================
    -- 2) 地面行为
    -- =========================================
    local curPlat = findCurrentPlatform(px, py, state.cachedPlatforms)
    state.lastPlatform = curPlat

    -- 获取下一个目标平台和跳跃信息
    local targetPlat, jumpInfo = AIController.GetNextTarget(state)

    if not targetPlat then
        -- 没路：向上跳试试
        state.moveDir = (math.random() > 0.5) and 1 or -1
        if p.onGround then state.wantJump = true end
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
            -- 需要跳跃：先对准起跳点
            local launchX = jumpInfo.launchX or px
            local dx = launchX - px

            if math.abs(dx) > 0.6 then
                -- 还没到起跳点，走过去
                state.moveDir = dx > 0 and 1 or -1
                state.aiState = STATE_APPROACH
            else
                -- 到达起跳点附近，起跳！
                state.moveDir = jumpInfo.dir or (targetPlat.cx > px and 1 or -1)
                if p.onGround then
                    state.wantJump = true
                    state.aiState = STATE_JUMP
                    state.jumpTarget = targetPlat
                    state.jumpLandX = jumpInfo.landX or targetPlat.cx
                    state.jumpDir = jumpInfo.dir or state.moveDir
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

    -- =========================================
    -- 4) 战术：爆炸、冲刺
    -- =========================================
    AIController.ThinkExplode(p, state, px, py)
    AIController.ThinkDash(p, state, px, py, curPlat, targetPlat)

    -- =========================================
    -- 5) 卡住检测
    -- =========================================
    AIController.UpdateStuck(p, state, px, py)
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
    -- 如果有跳跃目标，朝目标落点修正
    if state.jumpTarget and state.jumpLandX then
        local landX = state.jumpLandX
        local dx = landX - px
        local absDx = math.abs(dx)

        if absDx > 0.3 then
            state.moveDir = dx > 0 and 1 or -1
        elseif absDx < 0.3 then
            -- 接近目标 X，减速
            state.moveDir = 0
        end
    else
        -- 没有明确跳跃目标，尝试找最近的可落地平台
        local bestPlat = nil
        local bestScore = math.huge

        for _, plat in ipairs(state.cachedPlatforms) do
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

    -- 着地后清除跳跃目标
    if p.onGround then
        -- 检查是否落到了目标平台附近
        if state.jumpTarget then
            local tp = state.jumpTarget
            if px >= tp.x1 - 1.0 and px <= tp.x2 + 1.0 and
               math.abs(py - tp.charY) < 2.0 then
                -- 成功着陆到目标！推进路径
                state.pathIdx = state.pathIdx + 1
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
        if p.dashCooldown <= 0 and not state.isCharging then
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
    -- 确保有局部平台缓存
    if #state.cachedPlatforms == 0 then
        local centerGY = math.floor(py / Config.BlockSize)
        state.cachedPlatforms = scanPlatforms(mapModule_, centerGY - AI_SCAN_RANGE, centerGY + AI_SCAN_RANGE)
    end

    local curPlat = findCurrentPlatform(px, py, state.cachedPlatforms)
    if not curPlat then
        -- 找最近平台
        local bestDist = math.huge
        for _, plat in ipairs(state.cachedPlatforms) do
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

    local path, jumpInfos = findPathUpward(curPlat, state.cachedPlatforms)
    state.path = path
    state.jumpInfos = jumpInfos
    state.pathIdx = 2  -- 跳过当前平台
    state.jumpTarget = nil
    state.jumpLandX = nil
end

-- ============================================================================
-- 爆炸策略（更聪明）
-- ============================================================================

function AIController.ThinkExplode(p, state, px, py)
    if p.energy < 1.0 or state.isCharging then return end

    local bestScore = -999
    local bestDist = 0

    for _, other in ipairs(playerModule_.list) do
        if other.index ~= p.index and other.alive and other.node then
            local ox = other.node.position.x
            local oy = other.node.position.y
            local ddx = ox - px
            local ddy = oy - py
            local dist = math.sqrt(ddx * ddx + ddy * ddy)

            if dist < 8.0 then
                local score = 0

                -- 核心：对手在上方 = 领先 = 必须炸
                if ddy > 3.0 then
                    score = score + 45
                elseif ddy > 1.5 then
                    score = score + 30
                elseif ddy > 0.3 then
                    score = score + 15
                end

                -- 距离分（近 = 更容易炸到）
                if dist < 2.0 then
                    score = score + 40
                elseif dist < 3.5 then
                    score = score + 25
                elseif dist < 5.0 then
                    score = score + 10
                end

                -- 人类优先
                if other.isHuman then score = score + 8 end

                -- 对手也在蓄力 = 先发制人
                if other.charging then score = score + 30 end

                -- 对手在下方 = 浪费（除非很近可以炸死）
                if ddy < -2.0 then
                    if dist > 3.0 then
                        score = score - 40
                    else
                        score = score - 10
                    end
                end

                if score > bestScore then
                    bestScore = score
                    bestDist = dist
                end
            end
        end
    end

    -- 阈值：低攻击性=高阈值
    local threshold = 30 - state.personality.aggression * 20  -- 10~30

    if bestScore >= threshold and math.random() > 0.1 then
        state.isCharging = true
        -- 蓄力时间：近距离短蓄力，远距离长蓄力
        local chargeRatio = math.min(1.0, bestDist / 7.0)
        state.chargeHoldTime = 0.25 + chargeRatio * 1.5 + math.random() * 0.3
        state.chargeElapsed = 0
    end
end

-- ============================================================================
-- 冲刺策略（更积极）
-- ============================================================================

function AIController.ThinkDash(p, state, px, py, curPlat, targetPlat)
    if p.dashCooldown > 0 or state.isCharging or not p.onGround then return end
    if not curPlat then return end

    -- 条件1：在长平台上且目标在同一方向
    if curPlat.width > 3.0 and targetPlat then
        local dx = targetPlat.cx - px
        local absDx = math.abs(dx)
        local dy = math.abs(targetPlat.charY - py)

        -- 同层或接近同层、方向一致、距离够远
        if dy < 2.0 and absDx > 3.0 then
            local dashDir = dx > 0 and 1 or -1
            local dashEnd = px + dashDir * DASH_DISTANCE
            -- 确保冲刺终点还在平台上
            if dashEnd >= curPlat.x1 + 0.5 and dashEnd <= curPlat.x2 - 0.5 then
                if math.random() < state.personality.dashLove then
                    state.wantDash = true
                    state.moveDir = dashDir
                end
            end
        end
    end

end

return AIController
