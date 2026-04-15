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

-- 层级定义（与 MapData 中的垂直 zig-zag 对应）
-- 每层有：Y 范围、前进方向、通往下一层的楼梯 X 位置
local LEVELS = {
    { yMin = 0,  yMax = 5,  dir =  1, stairX = 36 },  -- L1: Y≈3, 向右，楼梯在右侧 x≈36
    { yMin = 5,  yMax = 9,  dir = -1, stairX = 5  },  -- L2: Y≈7, 向左，楼梯在左侧 x≈5
    { yMin = 9,  yMax = 13, dir =  1, stairX = 36 },  -- L3: Y≈11, 向右，楼梯在右侧
    { yMin = 13, yMax = 17, dir = -1, stairX = 5  },  -- L4: Y≈15, 向左，楼梯在左侧
    { yMin = 17, yMax = 21, dir =  1, stairX = 20 },  -- L5: Y≈19, 向右，楼梯在中间 x≈20
    { yMin = 21, yMax = 99, dir =  0, stairX = 20 },  -- Summit: 到达终点，向中间聚拢
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
    print("[AI] Initialized (vertical map)")
end

--- 为 AI 玩家创建状态
---@param playerData table
function AIController.Register(playerData)
    aiStates_[playerData.index] = {
        thinkTimer = math.random() * AI_THINK_INTERVAL,
        moveDir = 1,          -- 1=右 -1=左
        wantJump = false,
        wantDash = false,
        wantExplode = false,
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
    return LEVELS[#LEVELS]  -- 默认最高层
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
        p.jumpHeld = true           -- AI 始终满跳（持续按住）
        state.jumpHeldTimer = 0.3   -- AI 按住跳跃键 0.3 秒
        state.wantJump = false
    end

    -- AI 跳跃按住计时器
    if state.jumpHeldTimer and state.jumpHeldTimer > 0 then
        state.jumpHeldTimer = state.jumpHeldTimer - dt
        p.jumpHeld = true
    else
        p.jumpHeld = false
    end

    if state.wantDash then
        p.inputDash = true
        state.wantDash = false
    end

    if state.wantExplode then
        p.inputExplode = true
        state.wantExplode = false
    end
end

--- AI 思考（决策逻辑）
---@param p table
---@param state table
function AIController.Think(p, state)
    if p.node == nil then return end

    local pos = p.node.position
    local vel = p.body and p.body.linearVelocity or Vector3(0, 0, 0)

    -- 确定当前层级
    local level = GetLevel(pos.y)

    -- 决定移动方向
    if level.dir == 0 then
        -- 顶层：向终点（约 x=20）移动
        local targetX = 20
        if math.abs(pos.x - targetX) < 2 then
            state.moveDir = 0  -- 到了就停
        elseif pos.x < targetX then
            state.moveDir = 1
        else
            state.moveDir = -1
        end
    else
        -- 检查是否已到达楼梯区域（需要上楼）
        local atStair = math.abs(pos.x - level.stairX) < 3
        if atStair then
            -- 在楼梯附近：跳跃上去
            state.wantJump = true
            -- 继续沿原方向移动一小段到楼梯中心
            if math.abs(pos.x - level.stairX) > 1 then
                state.moveDir = pos.x < level.stairX and 1 or -1
            else
                state.moveDir = level.dir  -- 保持原方向微调
            end
        else
            -- 正常沿层方向前进
            state.moveDir = level.dir
        end
    end

    -- 卡住检测（同时检测水平和垂直）
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
            -- 长时间卡住：反向移动 + 冲刺
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

    -- 爆炸决策：能量满且附近有其他玩家
    if p.energy >= 1.0 then
        local shouldExplode = false

        for _, other in ipairs(playerModule_.list) do
            if other.index ~= p.index and other.alive and other.node then
                local diff = other.node.position - pos
                local dist = math.sqrt(diff.x * diff.x + diff.y * diff.y)
                if dist < AI_EXPLODE_RANGE then
                    -- 对方在更高处 = 领先，更想炸
                    if other.node.position.y > pos.y then
                        shouldExplode = true
                    elseif dist < 3.0 then
                        -- 很近就炸
                        shouldExplode = true
                    end
                end
            end
        end

        -- 随机性：不是每次满能量都立刻炸
        if shouldExplode and math.random() > 0.3 then
            state.wantExplode = true
        end
    end

    -- 冲刺决策：卡住或需要跨越大间隙
    if p.dashCooldown <= 0 and state.stuckTimer > 1.0 then
        state.wantDash = true
    end
end

return AIController
