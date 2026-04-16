-- ============================================================================
-- AIController.lua - AI 控制器（垂直攀登地图版）
-- AI 行为：根据所在层级判断前进方向，遇到间隙/台阶跳跃，能量满了就炸
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")

local AIController = {}

-- AI 决策参数
local AI_THINK_INTERVAL = 0.15   -- 决策间隔（秒）
local AI_JUMP_LOOKAHEAD = 2.0    -- 前方检测距离（米）
local AI_EXPLODE_RANGE = 6.0     -- 爆炸考虑范围

-- 层级定义（与新地图 6 单元结构对应）
-- 每层有：Y 范围、移动方向（主路线）、上升目标 X
-- dir: 1=向右移动, -1=向左, 0=向中央收束
-- targetX: AI 应该往哪个 X 去寻找上升台阶
local LEVELS = {
    -- U1 暖身区 (Y=3~10): 向右跑到右侧台阶上升
    { yMin = 0,  yMax = 10, dir =  1, targetX = 44 },
    -- U2 分流竞争区 (Y=10~19): 从右入口→中央→选左或右路→向上
    { yMin = 10, yMax = 19, dir = -1, targetX = 25 },
    -- U3 8字交叉区 (Y=19~27): 从两侧→中央交叉→继续上升
    { yMin = 19, yMax = 27, dir =  0, targetX = 25 },
    -- U4 双层追击区 (Y=27~35): 向两侧→优先走下层稳定路线→右侧出口上升
    { yMin = 27, yMax = 35, dir =  1, targetX = 44 },
    -- U5 收束攀升区 (Y=35~43): 向中央汇合
    { yMin = 35, yMax = 43, dir =  0, targetX = 25 },
    -- U6 终点戏剧区 (Y=43~99): 向中央终点
    { yMin = 43, yMax = 99, dir =  0, targetX = 25 },
}

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
    print("[AI] Initialized (vertical map v2)")
end

--- 为 AI 玩家创建状态
---@param playerData table
function AIController.Register(playerData)
    aiStates_[playerData.index] = {
        thinkTimer = math.random() * AI_THINK_INTERVAL,
        moveDir = 1,          -- 1=右 -1=左
        wantJump = false,
        wantDash = false,
        -- 蓄力爆炸状态
        isCharging = false,
        chargeHoldTime = 0,
        chargeElapsed = 0,
        stuckTimer = 0,
        lastX = 0,
        lastY = 0,
    }
end

--- 获取玩家所在层级
---@param wy number 世界 Y 坐标
---@return table 层级信息
local function GetLevel(wy)
    for _, lv in ipairs(LEVELS) do
        if wy >= lv.yMin and wy < lv.yMax then
            return lv
        end
    end
    return LEVELS[#LEVELS]
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
        state.thinkTimer = AI_THINK_INTERVAL + math.random() * 0.05
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

    -- 蓄力爆炸：AI 持续按住右键，到达目标时间后松开
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

--- AI 思考（决策逻辑）
---@param p table
---@param state table
function AIController.Think(p, state)
    if p.node == nil then return end

    local pos = p.node.position

    -- 确定当前层级
    local level = GetLevel(pos.y)

    -- 决定移动方向
    if level.dir == 0 then
        -- 向目标 X 收束
        local diff = level.targetX - pos.x
        if math.abs(diff) < 2 then
            -- 接近目标X，尝试跳跃上升
            state.moveDir = diff > 0 and 1 or -1
            state.wantJump = true
        elseif diff > 0 then
            state.moveDir = 1
        else
            state.moveDir = -1
        end
    else
        -- 按层级方向前进
        state.moveDir = level.dir

        -- 检查是否接近目标X（需要上升的位置）
        local atTarget = math.abs(pos.x - level.targetX) < 4
        if atTarget then
            state.wantJump = true
            -- 微调方向朝向目标X
            if math.abs(pos.x - level.targetX) > 1 then
                state.moveDir = pos.x < level.targetX and 1 or -1
            end
        end
    end

    -- 卡住检测
    local dx = math.abs(pos.x - state.lastX)
    local dy = math.abs(pos.y - state.lastY)
    if dx < 0.1 and dy < 0.1 then
        state.stuckTimer = state.stuckTimer + AI_THINK_INTERVAL
    else
        state.stuckTimer = 0
    end
    state.lastX = pos.x
    state.lastY = pos.y

    -- 卡住太久就跳跃 + 随机换方向
    if state.stuckTimer > 0.5 then
        state.wantJump = true
        if state.stuckTimer > 1.2 then
            state.moveDir = -state.moveDir
            if state.moveDir == 0 then state.moveDir = 1 end
            state.stuckTimer = 0
        end
    end

    -- 前方地面检测：如果前方没有地面就跳
    if mapModule_ and state.moveDir ~= 0 then
        local checkX = pos.x + state.moveDir * AI_JUMP_LOOKAHEAD
        local checkY = pos.y - 1.0
        local gx, gy = mapModule_.WorldToGrid(checkX, checkY)
        local block = mapModule_.GetBlock(gx, gy)
        if block == Config.BLOCK_EMPTY then
            state.wantJump = true
        end
    end

    -- 看到台阶或高台时跳跃
    if mapModule_ and state.moveDir ~= 0 then
        local aboveX = pos.x + state.moveDir * 1.5
        local aboveY = pos.y + 1.5
        local gx, gy = mapModule_.WorldToGrid(aboveX, aboveY)
        local block = mapModule_.GetBlock(gx, gy)
        if block ~= Config.BLOCK_EMPTY then
            state.wantJump = true
        end
    end

    -- 爆炸决策：能量满且附近有其他玩家 → 开始蓄力
    if p.energy >= 1.0 and not state.isCharging then
        local shouldExplode = false

        for _, other in ipairs(playerModule_.list) do
            if other.index ~= p.index and other.alive and other.node then
                local diff = other.node.position - pos
                local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
                if dist < AI_EXPLODE_RANGE then
                    if other.node.position.y > pos.y then
                        shouldExplode = true
                    elseif dist < 3.0 then
                        shouldExplode = true
                    end
                end
            end
        end

        if shouldExplode and math.random() > 0.3 then
            state.isCharging = true
            state.chargeHoldTime = 0.8 + math.random() * 0.7
            state.chargeElapsed = 0
        end
    end

    -- 冲刺决策：卡住或需要跨越大间隙
    if p.dashCooldown <= 0 and state.stuckTimer > 1.0 then
        state.wantDash = true
    end
end

return AIController
