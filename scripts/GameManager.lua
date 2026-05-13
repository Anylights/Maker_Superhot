-- ============================================================================
-- GameManager.lua - 游戏流程管理（大地图攀登模式）
-- 状态机：Menu → Countdown → Playing → Result
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")
local RandomEvent = require("RandomEvent")

local GameManager = {}

-- 游戏状态
GameManager.STATE_MENU      = "menu"
GameManager.STATE_COUNTDOWN = "countdown"
GameManager.STATE_PLAYING   = "playing"
GameManager.STATE_RESULT    = "result"

-- 当前状态
GameManager.state = GameManager.STATE_MENU
GameManager.stateTimer = 0

-- 游戏计时（倒计时，秒）
GameManager.gameTimer = 0

-- 击杀事件队列（供 HUD 消费）
GameManager.killEvents = {}

-- 模块引用
local playerModule_ = nil
local mapModule_ = nil
local pickupModule_ = nil
local aiModule_ = nil
local randomPickupModule_ = nil
local cameraModule_ = nil

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
        playerModule_.onCheckpointBonus = function(playerIndex, totalBonus)
            GameManager.checkpointBonusEvents = GameManager.checkpointBonusEvents or {}
            table.insert(GameManager.checkpointBonusEvents, {
                playerIndex = playerIndex,
                totalBonus = totalBonus,
            })
        end
    end

    print("[GameManager] Initialized (climb mode)")
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

--- 初始化持久世界（首次加载时调用，散布 AI）
function GameManager.InitWorld()
    GameManager.gameTimer = Config.GameDuration
    GameManager.killEvents = {}
    -- 将 AI 散布到检查点位置，模拟已经在攀爬
    if playerModule_ and playerModule_.ScatterAI then
        playerModule_.ScatterAI()
    end
    if pickupModule_ then pickupModule_.Reset() end
    if randomPickupModule_ then randomPickupModule_.Reset() end
    print("[GameManager] World initialized (AI scattered)")
end

--- 玩家加入游戏（点击"开始"或"再来一局"）
--- 只重置分数和人类玩家位置，AI 保持当前位置继续攀爬
function GameManager.JoinGame()
    GameManager.gameTimer = Config.GameDuration
    GameManager.killEvents = {}

    -- 解冻所有玩家（上一局结束时冻结了物理）
    if playerModule_ and playerModule_.UnfreezeAll then
        playerModule_.UnfreezeAll()
    end

    -- 不重置地图、不重置 AI 位置
    -- 只重置所有玩家分数
    if playerModule_ and playerModule_.ResetScoresOnly then
        playerModule_.ResetScoresOnly()
    end
    -- 只重置人类玩家到出生点
    if playerModule_ and playerModule_.ResetHumanToSpawn then
        playerModule_.ResetHumanToSpawn()
    end
    -- 重置道具（公平分布）
    if pickupModule_ then pickupModule_.Reset() end
    if randomPickupModule_ then randomPickupModule_.Reset() end
    -- 重置随机事件
    RandomEvent.Init()

    -- 重置倒计时音效跟踪
    lastCountdownNum_ = math.ceil(Config.CountdownTime) + 1

    GameManager.SetState(GameManager.STATE_COUNTDOWN, Config.CountdownTime)
    print("[GameManager] Player joining game (countdown)")
end

--- 开始新游戏（兼容旧调用，实际走 JoinGame）
function GameManager.StartGame()
    GameManager.JoinGame()
end

--- 重新开始（从结算画面回到游戏）
function GameManager.Restart()
    GameManager.JoinGame()
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
        return
    elseif state == GameManager.STATE_COUNTDOWN then
        GameManager.UpdateCountdown(dt)
    elseif state == GameManager.STATE_PLAYING then
        GameManager.UpdatePlaying(dt)
    elseif state == GameManager.STATE_RESULT then
        -- 结算画面：等待外部调用 Restart 或 EnterMenu
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
        GameManager.SetState(GameManager.STATE_PLAYING)
    end
end

function GameManager.UpdatePlaying(dt)
    -- 倒计时
    GameManager.gameTimer = GameManager.gameTimer - dt

    -- 时间到 → 结算
    if GameManager.gameTimer <= 0 then
        GameManager.gameTimer = 0
        GameManager.EndGame()
    end
end

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

    print("[GameManager] Kill event: P" .. killerIndex .. " killed P" .. victimIndex
        .. " (multi=" .. multiKillCount .. ", streak=" .. killStreak .. ")")
end

--- 结束游戏，进入结算
function GameManager.EndGame()
    SFX.Play("round_end", 0.7)
    GameManager.SetState(GameManager.STATE_RESULT)
    -- 冻结所有玩家物理体，防止结算后分数/高度继续变化
    if playerModule_ and playerModule_.FreezeAll then
        playerModule_.FreezeAll()
    end
    print("[GameManager] Game ended → result screen (players frozen)")
end

--- 获取倒计时整数（用于 HUD 显示）
---@return number
function GameManager.GetCountdownNumber()
    return math.ceil(GameManager.stateTimer)
end

--- 获取游戏剩余时间
---@return number
function GameManager.GetGameTime()
    return math.max(0, GameManager.gameTimer)
end

--- 获取排名列表（按总分降序排列的玩家索引）
---@return table rankings  每项 { index, score, heightScore, killScore, pickupScore, deaths }
function GameManager.GetRankings()
    local rankings = {}
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            table.insert(rankings, {
                index = p.index,
                score = p.score or 0,
                heightScore = p.heightScore or 0,
                killScore = p.killScore or 0,
                pickupScore = p.pickupScore or 0,
                deaths = p.deaths or 0,
                maxHeight = p.maxHeight or 0,
                kills = p.kills or 0,
                slamHits = p.slamHits or 0,
                gotSlammed = p.gotSlammed or 0,
                gotKilled = p.gotKilled or 0,
            })
        end
        table.sort(rankings, function(a, b) return a.score > b.score end)
    end
    return rankings
end

--- 获取胜者索引（得分最高的玩家）
---@return number|nil
function GameManager.GetWinner()
    local rankings = GameManager.GetRankings()
    if #rankings > 0 then
        return rankings[1].index
    end
    return nil
end

--- 玩家是否可以移动（倒计时和结算时不能）
---@return boolean
function GameManager.CanPlayersMove()
    return GameManager.state == GameManager.STATE_PLAYING
end

--- AI 是否可以移动（菜单、游戏中、结算时都可以，持久世界）
---@return boolean
function GameManager.CanAIMove()
    return GameManager.state == GameManager.STATE_MENU
        or GameManager.state == GameManager.STATE_PLAYING
end

return GameManager
