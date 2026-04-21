-- ============================================================================
-- GameManager.lua - 游戏流程管理
-- 状态机：Menu → Countdown → Racing → RoundEnd → ScoreScreen → Racing/MatchEnd
-- ============================================================================

local Config = require("Config")
local SFX = require("SFX")

local GameManager = {}

-- 游戏状态
GameManager.STATE_MENU       = "menu"
GameManager.STATE_COUNTDOWN  = "countdown"
GameManager.STATE_RACING     = "racing"
GameManager.STATE_ROUND_END  = "roundEnd"
GameManager.STATE_SCORE      = "score"
GameManager.STATE_MATCH_END  = "matchEnd"
GameManager.STATE_EDITOR     = "editor"
GameManager.STATE_LEVEL_LIST = "levelList"

-- 当前状态
GameManager.state = GameManager.STATE_MENU
GameManager.stateTimer = 0

-- 比赛数据
GameManager.round = 1
GameManager.roundTimer = 0
GameManager.scores = { 0, 0, 0, 0 }
GameManager.finishCount = 0      -- 当前回合已到达终点的人数
GameManager.roundResults = {}     -- 当前回合名次

-- 试玩模式
GameManager.testPlayMode = false
GameManager.testPlayLevelFile = nil

-- 模块引用
local playerModule_ = nil
local mapModule_ = nil
local pickupModule_ = nil
local aiModule_ = nil
local randomPickupModule_ = nil

-- 状态转换回调
local onStateChange_ = nil

-- 倒计时音效跟踪
local lastCountdownNum_ = 0

-- ============================================================================
-- 初始化
-- ============================================================================

---@param playerRef table
---@param mapRef table
---@param pickupRef table
---@param aiRef table
function GameManager.Init(playerRef, mapRef, pickupRef, aiRef, randomPickupRef)
    playerModule_ = playerRef
    mapModule_ = mapRef
    pickupModule_ = pickupRef
    aiModule_ = aiRef
    randomPickupModule_ = randomPickupRef

    GameManager.scores = {}
    for i = 1, Config.NumPlayers do
        GameManager.scores[i] = 0
    end

    print("[GameManager] Initialized")
end

--- 设置状态变化回调
---@param callback function
function GameManager.OnStateChange(callback)
    onStateChange_ = callback
end

--- 进入主菜单
function GameManager.EnterMenu()
    GameManager.SetState(GameManager.STATE_MENU)
end

--- 开始新比赛
function GameManager.StartMatch()
    GameManager.round = 0
    for i = 1, Config.NumPlayers do
        GameManager.scores[i] = 0
    end
    GameManager.StartRound()
end

--- 开始新回合
function GameManager.StartRound()
    GameManager.round = GameManager.round + 1
    GameManager.roundTimer = Config.RoundDuration
    GameManager.finishCount = 0
    GameManager.roundResults = {}

    -- 重置地图和玩家
    if mapModule_ then mapModule_.Reset() end
    if playerModule_ then playerModule_.ResetAll() end
    if pickupModule_ then pickupModule_.Reset() end
    if randomPickupModule_ then randomPickupModule_.Reset() end

    -- 重置倒计时音效跟踪
    lastCountdownNum_ = math.ceil(Config.CountdownTime) + 1

    -- 进入倒计时
    GameManager.SetState(GameManager.STATE_COUNTDOWN, Config.CountdownTime)

    print("[GameManager] Round " .. GameManager.round .. " starting")
end

--- 设置状态
---@param newState string
---@param timer number|nil
function GameManager.SetState(newState, timer)
    local oldState = GameManager.state
    GameManager.state = newState
    GameManager.stateTimer = timer or 0

    if onStateChange_ then
        onStateChange_(oldState, newState)
    end

    print("[GameManager] State: " .. oldState .. " → " .. newState)
end

-- ============================================================================
-- 更新
-- ============================================================================

---@param dt number
function GameManager.Update(dt)
    local state = GameManager.state

    if state == GameManager.STATE_MENU then
        -- 菜单状态不做任何更新，等待外部调用 StartMatch
        return
    elseif state == GameManager.STATE_COUNTDOWN then
        GameManager.UpdateCountdown(dt)
    elseif state == GameManager.STATE_RACING then
        GameManager.UpdateRacing(dt)
    elseif state == GameManager.STATE_ROUND_END then
        GameManager.UpdateRoundEnd(dt)
    elseif state == GameManager.STATE_SCORE then
        GameManager.UpdateScoreScreen(dt)
    elseif state == GameManager.STATE_MATCH_END then
        GameManager.UpdateMatchEnd(dt)
    elseif state == GameManager.STATE_EDITOR then
        -- 编辑器状态由 LevelEditor 模块自行管理，这里不做任何更新
        return
    elseif state == GameManager.STATE_LEVEL_LIST then
        -- 关卡列表状态由 HUD + main 管理
        return
    end
end

function GameManager.UpdateCountdown(dt)
    GameManager.stateTimer = GameManager.stateTimer - dt

    -- 每整秒播放倒计时音效（3, 2, 1）
    local num = math.ceil(GameManager.stateTimer)
    if num ~= lastCountdownNum_ and num >= 1 and num <= 3 then
        lastCountdownNum_ = num
        SFX.Play("countdown", 0.7)
    end

    if GameManager.stateTimer <= 0 then
        SFX.Play("go", 0.8)
        GameManager.SetState(GameManager.STATE_RACING)
    end
end

function GameManager.UpdateRacing(dt)
    -- 倒计时
    GameManager.roundTimer = GameManager.roundTimer - dt

    -- 检查玩家是否到达终点
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            if p.alive and p.finished and p.finishOrder == 0 then
                GameManager.finishCount = GameManager.finishCount + 1
                p.finishOrder = GameManager.finishCount
                table.insert(GameManager.roundResults, p.index)
                print("[GameManager] Player " .. p.index .. " finished in place " .. GameManager.finishCount)
            end
        end
    end

    -- 回合结束条件
    local allFinished = (GameManager.finishCount >= Config.NumPlayers)
    local timeUp = (GameManager.roundTimer <= 0)

    if allFinished or timeUp then
        GameManager.EndRound()
    end
end

function GameManager.UpdateRoundEnd(dt)
    GameManager.stateTimer = GameManager.stateTimer - dt
    if GameManager.stateTimer <= 0 then
        -- 检查是否有人达到胜利分数
        local matchOver = false
        for i = 1, Config.NumPlayers do
            if GameManager.scores[i] >= Config.WinScore then
                matchOver = true
                break
            end
        end

        if matchOver then
            GameManager.SetState(GameManager.STATE_MATCH_END, 5.0)
        else
            GameManager.SetState(GameManager.STATE_SCORE, 3.0)
        end
    end
end

function GameManager.UpdateScoreScreen(dt)
    GameManager.stateTimer = GameManager.stateTimer - dt
    if GameManager.stateTimer <= 0 then
        GameManager.StartRound()
    end
end

function GameManager.UpdateMatchEnd(dt)
    GameManager.stateTimer = GameManager.stateTimer - dt
    if GameManager.stateTimer <= 0 then
        if GameManager.testPlayMode then
            GameManager.ExitTestPlay()
        else
            GameManager.EnterMenu()
        end
    end
end

--- 结束当前回合，计算积分
function GameManager.EndRound()
    -- 补充未到达终点的玩家（按进度排序）
    if playerModule_ then
        -- 收集未完成玩家
        local unfinished = {}
        for _, p in ipairs(playerModule_.list) do
            if p.finishOrder == 0 then
                local progress = 0
                if p.node then
                    progress = p.node.position.y  -- 垂直地图：Y越高=进度越大
                end
                table.insert(unfinished, { index = p.index, progress = progress })
            end
        end

        -- 按进度排序（高在前）
        table.sort(unfinished, function(a, b) return a.progress > b.progress end)

        -- 补充名次
        for _, u in ipairs(unfinished) do
            GameManager.finishCount = GameManager.finishCount + 1
            table.insert(GameManager.roundResults, u.index)
            -- 找到玩家并设置 finishOrder
            for _, p in ipairs(playerModule_.list) do
                if p.index == u.index then
                    p.finishOrder = GameManager.finishCount
                    break
                end
            end
        end
    end

    -- 分配积分
    for place, playerIndex in ipairs(GameManager.roundResults) do
        local points = Config.PlaceScores[place] or 0
        GameManager.scores[playerIndex] = GameManager.scores[playerIndex] + points
        print("[GameManager] Player " .. playerIndex .. " place " .. place .. " +" .. points .. " pts (total: " .. GameManager.scores[playerIndex] .. ")")
    end

    SFX.Play("round_end", 0.7)
    GameManager.SetState(GameManager.STATE_ROUND_END, 2.0)
end

--- 获取倒计时整数（用于 HUD 显示）
---@return number
function GameManager.GetCountdownNumber()
    return math.ceil(GameManager.stateTimer)
end

--- 获取回合剩余时间
---@return number
function GameManager.GetRoundTime()
    return math.max(0, GameManager.roundTimer)
end

--- 获取胜者索引（比赛结束时）
---@return number|nil
function GameManager.GetWinner()
    local maxScore = 0
    local winner = nil
    for i = 1, Config.NumPlayers do
        if GameManager.scores[i] > maxScore then
            maxScore = GameManager.scores[i]
            winner = i
        end
    end
    return winner
end

--- 玩家是否可以移动（倒计时和回合结束时不能）
---@return boolean
function GameManager.CanPlayersMove()
    return GameManager.state == GameManager.STATE_RACING
end

-- ============================================================================
-- 编辑器状态
-- ============================================================================

--- 进入编辑器
function GameManager.EnterEditor()
    GameManager.SetState(GameManager.STATE_EDITOR)
    print("[GameManager] Entered editor mode")
end

--- 退出编辑器，回到主菜单
function GameManager.ExitEditor()
    GameManager.SetState(GameManager.STATE_MENU)
    print("[GameManager] Exited editor mode, back to menu")
end

-- ============================================================================
-- 关卡列表状态
-- ============================================================================

--- 进入关卡列表
function GameManager.EnterLevelList()
    GameManager.SetState(GameManager.STATE_LEVEL_LIST)
    print("[GameManager] Entered level list")
end

--- 退出关卡列表，回到主菜单
function GameManager.ExitLevelList()
    GameManager.SetState(GameManager.STATE_MENU)
    print("[GameManager] Exited level list, back to menu")
end

-- ============================================================================
-- 试玩模式
-- ============================================================================

--- 开始试玩（标记模式后启动比赛）
---@param levelFile string|nil 关卡文件名
function GameManager.StartTestPlay(levelFile)
    GameManager.testPlayMode = true
    GameManager.testPlayLevelFile = levelFile
    GameManager.StartMatch()
    print("[GameManager] Test play started: " .. tostring(levelFile))
end

--- 退出试玩，回到关卡列表
function GameManager.ExitTestPlay()
    GameManager.testPlayMode = false
    GameManager.testPlayLevelFile = nil
    GameManager.EnterLevelList()
    print("[GameManager] Test play ended, back to level list")
end

return GameManager
