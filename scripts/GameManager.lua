-- ============================================================================
-- GameManager.lua - 会话管理器（持久世界模式）
-- 职责：管理每个玩家的独立 60 秒会话、计分、排行榜
-- 状态流程：Waiting → Playing → Results → (Restart) → Playing
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")
local BGM = require("BGM")
local Background = require("Background")

local GameManager = {}

-- 游戏状态（简化为 3 个：等待/进行中/结算）
GameManager.STATE_WAITING  = "waiting"   -- 等待会话开始（刚进入世界）
GameManager.STATE_PLAYING  = "playing"   -- 会话进行中
GameManager.STATE_RESULTS  = "results"   -- 会话结束，展示结算

-- 当前状态（本地玩家的状态，服务端按玩家维护）
GameManager.state = GameManager.STATE_WAITING
GameManager.stateTimer = 0

-- 击杀事件队列（供 HUD 消费，每帧清空）
GameManager.killEvents = {}

-- 排行榜缓存（由 Server 广播更新，或本地计算）
-- 格式: { {index=1, score=100, name="Player 1"}, ... }
GameManager.leaderboard = {}

-- 地图种子（所有玩家共用同一地图）
GameManager.mapSeed = 0

-- 模块引用
local playerModule_ = nil
local mapModule_ = nil
local pickupModule_ = nil
local aiModule_ = nil
local randomPickupModule_ = nil
local cameraModule_ = nil

-- 状态转换回调
local onStateChange_ = nil
-- 击杀事件回调（网络广播用）
local onKill_ = nil
-- 会话结束回调（网络广播用）
local onSessionEnd_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

---@param playerRef table
---@param mapRef table
---@param pickupRef table
---@param aiRef table
---@param randomPickupRef table
---@param cameraRef table|nil
function GameManager.Init(playerRef, mapRef, pickupRef, aiRef, randomPickupRef, cameraRef)
    playerModule_ = playerRef
    mapModule_ = mapRef
    pickupModule_ = pickupRef
    aiModule_ = aiRef
    randomPickupModule_ = randomPickupRef
    cameraModule_ = cameraRef

    -- 注册击杀事件回调
    if playerModule_ then
        playerModule_.onKill = function(killerIndex, victimIndex, multiKillCount, killStreak)
            GameManager.OnPlayerKill(killerIndex, victimIndex, multiKillCount, killStreak)
        end
    end

    print("[GameManager] Initialized (persistent world mode)")
end

--- 设置状态变化回调
---@param callback function
function GameManager.OnStateChange(callback)
    onStateChange_ = callback
end

--- 设置击杀事件回调（服务端广播用）
---@param callback function(killerIndex, victimIndex, multiKillCount, killStreak)
function GameManager.OnKill(callback)
    onKill_ = callback
end

--- 设置会话结束回调
---@param callback function(playerIndex, totalScore)
function GameManager.OnSessionEnd(callback)
    onSessionEnd_ = callback
end

-- ============================================================================
-- 地图初始化
-- ============================================================================

--- 初始化世界地图（服务端/单机调用）
---@param seed number|nil 地图种子，nil 则随机生成
function GameManager.InitWorld(seed)
    GameManager.mapSeed = seed or os.time()
    MapData.Generate(GameManager.mapSeed)
    if mapModule_ then
        mapModule_.Reset(GameManager.mapSeed)
    end
    if randomPickupModule_ then
        randomPickupModule_.Reset()
    end

    -- 设置背景
    Background.SetPaletteForRound(1)

    -- 播放 BGM
    BGM.PlayGameplay()

    print("[GameManager] World initialized with seed=" .. GameManager.mapSeed)
end

-- ============================================================================
-- 会话管理
-- ============================================================================

--- 开始指定玩家的会话（服务端/单机调用）
---@param playerIndex number
function GameManager.StartPlayerSession(playerIndex)
    if not playerModule_ then return end

    for _, p in ipairs(playerModule_.list) do
        if p.index == playerIndex then
            playerModule_.StartSession(p)

            -- 始终重生玩家（重置位置，避免重启时因高位置立即获得高度分）
            playerModule_.Respawn(p)

            print("[GameManager] Started session for player " .. playerIndex)
            return
        end
    end
    print("[GameManager] StartPlayerSession: player " .. playerIndex .. " not found")
end

--- 结束指定玩家的会话（服务端/单机调用）
---@param playerIndex number
function GameManager.EndPlayerSession(playerIndex)
    if not playerModule_ then return end

    for _, p in ipairs(playerModule_.list) do
        if p.index == playerIndex then
            playerModule_.EndSession(p)

            -- 通知外部（Server 广播用）
            if onSessionEnd_ then
                onSessionEnd_(playerIndex, p.session.totalScore)
            end

            print("[GameManager] Ended session for player " .. playerIndex
                .. " score=" .. p.session.totalScore)
            return
        end
    end
end

-- ============================================================================
-- 更新
-- ============================================================================

---@param dt number
function GameManager.Update(dt)
    -- 更新所有活跃会话的计时器（服务端/单机）
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.session.active then
                p.session.timer = p.session.timer - dt
                if p.session.timer <= 0 then
                    GameManager.EndPlayerSession(p.index)
                end
            end
        end
    end

    -- 清空上帧击杀事件（HUD 应在渲染时读取后自行清空或在此被清）
    -- 注：killEvents 由 HUD 在使用后自行管理生命周期
end

-- ============================================================================
-- 本地玩家状态管理（客户端/单机用）
-- ============================================================================

--- 设置本地玩家状态
---@param newState string
---@param timer number|nil
function GameManager.SetState(newState, timer)
    local oldState = GameManager.state
    GameManager.state = newState
    GameManager.stateTimer = timer or 0

    -- BGM 状态联动
    if newState == GameManager.STATE_PLAYING then
        BGM.PlayGameplay()
    elseif newState == GameManager.STATE_WAITING then
        BGM.PlayMenu()
    end

    -- 相机模式联动
    if cameraModule_ then
        if newState == GameManager.STATE_PLAYING then
            -- 跟随玩家
            cameraModule_.ReleaseFixed()
        end
    end

    if onStateChange_ then
        onStateChange_(oldState, newState)
    end

    print("[GameManager] Local state: " .. oldState .. " → " .. newState)
end

-- ============================================================================
-- 击杀事件处理
-- ============================================================================

--- 处理击杀事件（由 Player.onKill 回调触发）
---@param killerIndex number
---@param victimIndex number
---@param multiKillCount number
---@param killStreak number
function GameManager.OnPlayerKill(killerIndex, victimIndex, multiKillCount, killStreak)
    -- 生成击杀事件（供 HUD 显示）
    local event = {
        killerIndex = killerIndex,
        victimIndex = victimIndex,
        multiKillCount = multiKillCount,
        killStreak = killStreak,
        time = os.clock(),
    }
    table.insert(GameManager.killEvents, event)

    -- 网络回调
    if onKill_ then
        onKill_(killerIndex, victimIndex, multiKillCount, killStreak)
    end

    print("[GameManager] Kill: P" .. killerIndex .. " → P" .. victimIndex
        .. " (multi=" .. multiKillCount .. ", streak=" .. killStreak .. ")")
end

-- ============================================================================
-- 排行榜
-- ============================================================================

--- 计算当前排行榜（服务端/单机用）
---@return table 排行榜数组 {{index, score, isHuman}, ...}
function GameManager.CalcLeaderboard()
    local board = {}
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.session.active or p.session.totalScore > 0 then
                table.insert(board, {
                    index = p.index,
                    score = p.session.totalScore,
                    isHuman = p.isHuman,
                })
            end
        end
    end
    -- 按分数降序排列
    table.sort(board, function(a, b) return a.score > b.score end)
    GameManager.leaderboard = board
    return board
end

--- 设置排行榜数据（客户端从服务端接收时调用）
---@param data table
function GameManager.SetLeaderboard(data)
    GameManager.leaderboard = data or {}
end

-- ============================================================================
-- 查询接口
-- ============================================================================

--- 获取指定玩家的会话剩余时间
---@param playerIndex number
---@return number 剩余秒数
function GameManager.GetPlayerTimer(playerIndex)
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.index == playerIndex then
                return math.max(0, p.session.timer)
            end
        end
    end
    return 0
end

--- 获取指定玩家的总分
---@param playerIndex number
---@return number
function GameManager.GetPlayerScore(playerIndex)
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.index == playerIndex then
                return p.session.totalScore
            end
        end
    end
    return 0
end

--- 玩家是否可以移动
---@param playerIndex number|nil 不传则检查本地人类玩家
---@return boolean
function GameManager.CanPlayerMove(playerIndex)
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if playerIndex then
                if p.index == playerIndex then
                    return p.session.active and p.alive
                end
            else
                if p.isHuman then
                    return p.session.active and p.alive
                end
            end
        end
    end
    return false
end

--- 兼容旧接口：玩家是否可以移动（全局）
---@return boolean
function GameManager.CanPlayersMove()
    -- 持久世界中，只要玩家会话激活就可以移动
    -- 此接口主要供输入系统判断
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.isHuman then
                return p.session.active
            end
        end
    end
    return false
end

--- 获取人类玩家数据
---@return table|nil
function GameManager.GetHumanPlayer()
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.isHuman then
                return p
            end
        end
    end
    return nil
end

return GameManager
