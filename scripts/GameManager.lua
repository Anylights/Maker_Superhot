-- ============================================================================
-- GameManager.lua - 游戏流程管理（大地图攀登模式）
-- 状态机：Menu → Countdown → Playing → Result
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")

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

--- 开始新游戏
function GameManager.StartGame()
    GameManager.gameTimer = Config.GameDuration
    GameManager.killEvents = {}

    -- 重置地图和玩家
    if mapModule_ then mapModule_.Reset() end
    if playerModule_ then playerModule_.ResetAll() end
    if pickupModule_ then pickupModule_.Reset() end
    if randomPickupModule_ then randomPickupModule_.Reset() end

    -- 重置倒计时音效跟踪
    lastCountdownNum_ = math.ceil(Config.CountdownTime) + 1

    GameManager.SetState(GameManager.STATE_COUNTDOWN, Config.CountdownTime)
    print("[GameManager] Game starting (countdown)")
end

--- 重新开始（从结算画面回到游戏）
function GameManager.Restart()
    GameManager.StartGame()
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
    print("[GameManager] Game ended → result screen")
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

return GameManager
