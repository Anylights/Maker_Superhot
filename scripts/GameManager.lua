-- ============================================================================
-- GameManager.lua - 游戏流程管理（大地图攀登模式）
-- 状态机：Menu → Countdown → Playing → Result
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")
local RandomEvent = require("RandomEvent")
local PowerUp = require("PowerUp")

local GameManager = {}

-- 游戏状态
GameManager.STATE_MENU      = "menu"
GameManager.STATE_COUNTDOWN = "countdown"
GameManager.STATE_PLAYING   = "playing"
GameManager.STATE_RESULT    = "result"
GameManager.STATE_TUTORIAL  = "tutorial"
GameManager.STATE_REVIVE    = "revive"

-- 当前状态
GameManager.state = GameManager.STATE_MENU
GameManager.stateTimer = 0

-- 游戏模式
GameManager.gameMode = Config.GAMEMODE_NORMAL

-- 游戏计时（倒计时，秒）
GameManager.gameTimer = 0

-- 复活系统（一命通天模式，per-run）
GameManager.reviveCoinUsed   = 0      -- 已用金币复活次数 (max 2)
GameManager.reviveAdUsed     = 0      -- 已用广告复活次数 (max 1)
GameManager.reviveWaitingAd  = false  -- 是否正在等待广告回调
GameManager.reviveDeadPlayer = nil    -- 当前等待复活的玩家引用

-- 一命通天模式：累计存活时间
GameManager.elapsedTime = 0

-- 击杀事件队列（供 HUD 消费）
GameManager.killEvents = {}

-- 结算快照（EndGame 时保存，防止玩家死亡/复活后数据归零）
GameManager.resultSnapshot = nil

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

--- 进入新手教程
function GameManager.EnterTutorial()
    -- 教程强制用普通模式，防止 ONELIFE 模式的死亡逻辑（respawnTimer=99999）干扰复活
    GameManager.gameMode = Config.GAMEMODE_NORMAL
    -- 解冻玩家：游戏结束时 FreezeAll() 会设置 Player.frozen=true，
    -- 若不解冻，Player.Kill 会直接 return，导致教程中掉落无法死亡/复活
    if playerModule_ and playerModule_.UnfreezeAll then
        playerModule_.UnfreezeAll()
    end
    GameManager.SetState(GameManager.STATE_TUTORIAL)
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
    -- 清除上一局结算快照
    GameManager.resultSnapshot = nil
    -- 一命通天模式：无限时间
    if GameManager.gameMode == Config.GAMEMODE_ONELIFE then
        GameManager.gameTimer = 99999
        GameManager.elapsedTime = 0
    else
        GameManager.gameTimer = Config.GameDuration
    end
    GameManager.killEvents = {}

    -- 重置复活计数器
    GameManager.reviveCoinUsed   = 0
    GameManager.reviveAdUsed     = 0
    GameManager.reviveWaitingAd  = false
    GameManager.reviveDeadPlayer = nil

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
    -- 重置道具 buff
    PowerUp.ClearAll()
    -- 重置随机事件
    RandomEvent.Init()

    -- 注册事件触发回调（超级嗜血：开始时回满所有玩家能量）
    RandomEvent.onTrigger = function(def)
        if def.id == "bloodlust" and playerModule_ then
            for _, p in ipairs(playerModule_.list) do
                if p.alive then
                    p.energy = 1.0
                end
            end
            print("[GameManager] Bloodlust triggered: all players energy refilled")
        end
    end

    -- 重置倒计时音效跟踪
    lastCountdownNum_ = math.ceil(Config.CountdownTime) + 1

    GameManager.SetState(GameManager.STATE_COUNTDOWN, Config.CountdownTime)

    -- 倒计时阶段全员幽灵无敌 + 禁止玩家间碰撞（防止开局前被推下去）
    if playerModule_ then
        for _, p in ipairs(playerModule_.list) do
            p.invincibleTimer = Config.CountdownTime + 3  -- 倒计时 + 开始后3秒
            p.countdownProtected = true  -- 倒计时保护（不闪烁）
            -- 修改碰撞掩码：去掉 Layer 2（玩家层），防止被其他玩家物理推动
            if p.body then
                p.body.collisionMask = 0xFFFD  -- 0xFFFF & ~2
            end
        end
    end

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
    elseif state == GameManager.STATE_TUTORIAL then
        return  -- 教程由 Tutorial 模块自行管理
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
        -- 倒计时结束：解除倒计时保护，保留3秒无敌闪烁，恢复碰撞
        if playerModule_ then
            for _, p in ipairs(playerModule_.list) do
                p.countdownProtected = false  -- 解除保护，开始闪烁
                -- invincibleTimer 还剩约3秒，继续无敌+闪烁
                if p.invincibleTimer <= 0 then
                    p.invincibleTimer = 3.0
                end
                -- 恢复碰撞掩码（默认与所有层碰撞）
                if p.body then
                    p.body.collisionMask = 0xFFFF
                end
            end
        end
        SFX.Play("go", 0.8)
        GameManager.SetState(GameManager.STATE_PLAYING)
    end
end

function GameManager.UpdatePlaying(dt)
    if GameManager.gameMode == Config.GAMEMODE_ONELIFE then
        -- 一命通天：累计存活时间，不做倒计时结束
        GameManager.elapsedTime = GameManager.elapsedTime + dt
    else
        -- 普通模式：倒计时
        GameManager.gameTimer = GameManager.gameTimer - dt
        -- 时间到 → 结算
        if GameManager.gameTimer <= 0 then
            GameManager.gameTimer = 0
            GameManager.EndGame()
        end
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

--- 一命通天模式：玩家死亡/掉落回调
---@param p table 死亡的玩家
function GameManager.OnPlayerDeath(p)
    if GameManager.gameMode ~= Config.GAMEMODE_ONELIFE then return end
    if not p.isHuman then return end
    if GameManager.state ~= GameManager.STATE_PLAYING then return end

    -- 检查是否还有复活机会（金币最多2次 + 广告最多1次）
    local hasChance = (GameManager.reviveCoinUsed < 2) or (GameManager.reviveAdUsed < 1)
    if hasChance then
        print("[GameManager] Onelife mode: human died → revive offer (coin=" .. GameManager.reviveCoinUsed .. "/2, ad=" .. GameManager.reviveAdUsed .. "/1)")
        GameManager.reviveDeadPlayer = p
        GameManager.SetState(GameManager.STATE_REVIVE)
        -- 冻结所有玩家，暂停游戏
        if playerModule_ and playerModule_.FreezeAll then
            playerModule_.FreezeAll()
        end
    else
        print("[GameManager] Onelife mode: human died, no revive left → ending game")
        GameManager.EndGame()
    end
end

--- 执行复活：恢复玩家并回到 PLAYING 状态
function GameManager.RevivePlayer()
    local p = GameManager.reviveDeadPlayer
    if not p then return end
    local Player = require("Player")
    Player.Respawn(p)
    -- 解冻所有玩家
    if playerModule_ and playerModule_.UnfreezeAll then
        playerModule_.UnfreezeAll()
    end
    GameManager.reviveDeadPlayer = nil
    GameManager.reviveWaitingAd = false
    GameManager.SetState(GameManager.STATE_PLAYING)
    print("[GameManager] Player revived → back to playing")
end

--- 放弃复活：进入结算
function GameManager.GiveUpRevive()
    GameManager.reviveDeadPlayer = nil
    GameManager.reviveWaitingAd = false
    print("[GameManager] Player gave up revive → ending game")
    GameManager.EndGame()
end

--- 结束游戏，进入结算
function GameManager.EndGame()
    SFX.Play("round_end", 0.7)
    -- 在冻结前保存快照，确保结算数据为游戏结束瞬间的真实值
    if playerModule_ then
        local snapshot = {}
        for _, p in ipairs(playerModule_.list) do
            table.insert(snapshot, {
                index       = p.index,
                score       = p.score or 0,
                heightScore = p.heightScore or 0,
                killScore   = p.killScore or 0,
                pickupScore = p.pickupScore or 0,
                deaths      = p.deaths or 0,
                maxHeight   = p.maxHeight or 0,
                kills       = p.kills or 0,
                slamHits    = p.slamHits or 0,
                gotSlammed  = p.gotSlammed or 0,
                gotKilled   = p.gotKilled or 0,
                elapsedTime = GameManager.elapsedTime or 0,
            })
        end
        table.sort(snapshot, function(a, b) return a.score > b.score end)
        GameManager.resultSnapshot = snapshot
        print("[GameManager] Result snapshot saved (" .. #snapshot .. " players)")
    end
    GameManager.SetState(GameManager.STATE_RESULT)
    -- 冻结所有玩家物理体
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
    -- 结算状态优先返回快照，防止玩家死亡/复活后数据归零
    if GameManager.state == GameManager.STATE_RESULT and GameManager.resultSnapshot then
        return GameManager.resultSnapshot
    end
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
                elapsedTime = GameManager.elapsedTime or 0,
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

--- 玩家是否可以移动（倒计时和结算时不能，教程中可以）
---@return boolean
function GameManager.CanPlayersMove()
    return GameManager.state == GameManager.STATE_PLAYING
        or GameManager.state == GameManager.STATE_TUTORIAL
end

--- AI 是否可以移动（菜单、游戏中、结算时都可以，教程中不动）
---@return boolean
function GameManager.CanAIMove()
    return GameManager.state == GameManager.STATE_MENU
        or GameManager.state == GameManager.STATE_PLAYING
        or GameManager.state == GameManager.STATE_RESULT
end

return GameManager
