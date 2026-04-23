-- ============================================================================
-- GameManager.lua - 游戏流程管理
-- 状态机：Menu → Countdown → Racing → RoundEnd → ScoreScreen → Racing/MatchEnd
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local SFX = require("SFX")

local GameManager = {}

-- 游戏状态
GameManager.STATE_MENU       = "menu"
GameManager.STATE_INTRO      = "intro"
GameManager.STATE_COUNTDOWN  = "countdown"
GameManager.STATE_RACING     = "racing"
GameManager.STATE_ROUND_END  = "roundEnd"
GameManager.STATE_SCORE      = "score"
GameManager.STATE_MATCH_END  = "matchEnd"
GameManager.STATE_MATCHING   = "matching"
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

-- 匹配系统
local matchingTimer_ = 0
local matchingSlotCount_ = 0  -- 已填入的玩家槽位数（含自己）
local matchingComplete_ = false

-- 匹配模式
GameManager.matchMode = "quickStart"

-- 试玩模式
GameManager.testPlayMode = false
GameManager.testPlayLevelFile = nil

-- 模块引用
local playerModule_ = nil
local mapModule_ = nil
local pickupModule_ = nil
local aiModule_ = nil
local randomPickupModule_ = nil
local cameraModule_ = nil

-- 击杀统计（每回合）
GameManager.killScores = { 0, 0, 0, 0 }  -- 每个玩家的击杀积分

-- 击杀事件队列（供 HUD 消费，每帧清空）
GameManager.killEvents = {}

-- 状态转换回调
local onStateChange_ = nil
local onBeforeRound_ = nil  -- 每局开始前触发（在 Map.Reset 之前），用于切换关卡
-- 击杀事件回调（网络广播用）
local onKill_ = nil

-- 倒计时音效跟踪
local lastCountdownNum_ = 0

-- 开场镜头动画子阶段
-- 1 = 聚焦终点, 2 = 平移到起点, 3 = 放大+文字
local introPhase_ = 0
local introPhaseTimer_ = 0
local introTextAlpha_ = 0  -- "更快到达终点!" 文字透明度（0~1）
local introSpawnCenterX_ = 0  -- 出生点中心（阶段2计算，阶段3复用）
local introSpawnCenterY_ = 0

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

    GameManager.scores = {}
    GameManager.killScores = {}
    for i = 1, Config.NumPlayers do
        GameManager.scores[i] = 0
        GameManager.killScores[i] = 0
    end

    -- 注册击杀事件回调
    if playerModule_ then
        playerModule_.onKill = function(killerIndex, victimIndex, multiKillCount, killStreak)
            GameManager.OnPlayerKill(killerIndex, victimIndex, multiKillCount, killStreak)
        end
    end

    print("[GameManager] Initialized")
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

--- 设置每局开始前的回调（在 Map.Reset 之前触发，用于切换关卡）
---@param callback function(roundIndex)
function GameManager.OnBeforeRound(callback)
    onBeforeRound_ = callback
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

    -- 重置击杀积分
    for i = 1, Config.NumPlayers do
        GameManager.killScores[i] = 0
    end
    GameManager.killEvents = {}

    -- 切换关卡（必须在 Map.Reset 之前）
    if onBeforeRound_ then
        onBeforeRound_(GameManager.round)
    end

    -- 重置地图和玩家
    if mapModule_ then mapModule_.Reset() end
    if playerModule_ then playerModule_.ResetAll() end
    if pickupModule_ then pickupModule_.Reset() end
    if randomPickupModule_ then randomPickupModule_.Reset() end

    -- 重置倒计时音效跟踪
    lastCountdownNum_ = math.ceil(Config.CountdownTime) + 1

    -- 进入开场镜头动画
    introPhase_ = 0
    introPhaseTimer_ = 0
    introTextAlpha_ = 0
    local totalIntroTime = Config.IntroFocusFinishTime + Config.IntroPanToSpawnTime + Config.IntroZoomTextTime + Config.IntroZoomOutTime
    GameManager.SetState(GameManager.STATE_INTRO, totalIntroTime)

    print("[GameManager] Round " .. GameManager.round .. " starting (intro)")
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
    elseif state == GameManager.STATE_MATCHING then
        GameManager.UpdateMatching(dt)
    elseif state == GameManager.STATE_INTRO then
        GameManager.UpdateIntro(dt)
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

--- 更新开场镜头动画（3个子阶段）
function GameManager.UpdateIntro(dt)
    GameManager.stateTimer = GameManager.stateTimer - dt

    -- 阶段 0 → 1：初始化，聚焦终点
    if introPhase_ == 0 then
        introPhase_ = 1
        introPhaseTimer_ = Config.IntroFocusFinishTime

        -- 计算终点中心位置
        local fx, fy = 0, 0
        if #MapData.FinishBlocks > 0 then
            for _, fb in ipairs(MapData.FinishBlocks) do
                fx = fx + fb.x
                fy = fy + fb.y
            end
            fx = fx / #MapData.FinishBlocks
            fy = fy / #MapData.FinishBlocks
        else
            fx = MapData.Width * Config.BlockSize * 0.5
            fy = MapData.Height * Config.BlockSize * 0.5
        end

        if cameraModule_ then
            -- 先瞬移到全局视角，然后动画缩放到终点
            cameraModule_.SetFixedForMap(MapData.Width, MapData.Height, 2)
            cameraModule_.AnimateTo(Vector3(fx, fy, 0), Config.IntroFinishOrtho, Config.IntroFocusFinishTime * 0.8)
        end
        print("[GameManager] Intro phase 1: focus finish at (" .. string.format("%.1f,%.1f", fx, fy) .. ")")
        return
    end

    -- 阶段 1：聚焦终点
    if introPhase_ == 1 then
        introPhaseTimer_ = introPhaseTimer_ - dt
        if cameraModule_ then
            cameraModule_.UpdateAnimation(dt)
        end
        if introPhaseTimer_ <= 0 then
            introPhase_ = 2
            introPhaseTimer_ = Config.IntroPanToSpawnTime

            -- 计算所有出生点的中心
            local sx, sy = 0, 0
            local count = 0
            for i = 1, Config.NumPlayers do
                local sp = MapData.SpawnPositions[i]
                if sp then
                    sx = sx + sp.x
                    sy = sy + sp.y
                    count = count + 1
                end
            end
            if count > 0 then
                sx = sx / count
                sy = sy / count
            else
                sx = MapData.SpawnX
                sy = MapData.SpawnY
            end

            -- 保存出生点中心供阶段3复用
            introSpawnCenterX_ = sx
            introSpawnCenterY_ = sy

            if cameraModule_ then
                cameraModule_.AnimateTo(Vector3(sx, sy, 0), Config.IntroSpawnOrtho, Config.IntroPanToSpawnTime * 0.9)
            end
            print("[GameManager] Intro phase 2: pan to spawn at (" .. string.format("%.1f,%.1f", sx, sy) .. ")")
        end
        return
    end

    -- 阶段 2：平移到起点
    if introPhase_ == 2 then
        introPhaseTimer_ = introPhaseTimer_ - dt
        if cameraModule_ then
            cameraModule_.UpdateAnimation(dt)
        end
        if introPhaseTimer_ <= 0 then
            introPhase_ = 3
            introPhaseTimer_ = Config.IntroZoomTextTime
            introTextAlpha_ = 0

            -- "更快到达终点!" 文字出现 → 直接拉远到全景
            if cameraModule_ then
                local bs = Config.BlockSize
                local padding = 2
                local totalW = MapData.Width * bs + padding * 2
                local totalH = MapData.Height * bs + padding * 2
                local mapCx = MapData.Width * bs * 0.5
                local mapCy = MapData.Height * bs * 0.5
                local aspect = cameraModule_.camera and cameraModule_.camera.aspectRatio or (16.0 / 9.0)
                if aspect <= 0 then aspect = 16.0 / 9.0 end
                local fullOrtho = math.max(totalW / aspect, totalH)

                cameraModule_.AnimateTo(
                    Vector3(mapCx, mapCy, 0),
                    fullOrtho,
                    Config.IntroZoomTextTime * 0.6
                )
            end
            print("[GameManager] Intro phase 3: zoom out to full map + text")
        end
        return
    end

    -- 阶段 3：放大 + 显示文字
    if introPhase_ == 3 then
        introPhaseTimer_ = introPhaseTimer_ - dt
        if cameraModule_ then
            cameraModule_.UpdateAnimation(dt)
        end

        -- 文字淡入（前半段淡入，后半段保持）
        local progress = 1.0 - (introPhaseTimer_ / Config.IntroZoomTextTime)
        if progress < 0.3 then
            introTextAlpha_ = progress / 0.3
        else
            introTextAlpha_ = 1.0
        end

        if introPhaseTimer_ <= 0 then
            -- 进入阶段 4：平滑拉远回全景
            introPhase_ = 4
            introPhaseTimer_ = Config.IntroZoomOutTime

            -- 计算全景目标参数（与 SetFixedForMap 相同逻辑）
            local bs = Config.BlockSize
            local padding = 2
            local totalW = MapData.Width * bs + padding * 2
            local totalH = MapData.Height * bs + padding * 2
            local mapCx = MapData.Width * bs * 0.5
            local mapCy = MapData.Height * bs * 0.5
            local aspect = cameraModule_ and cameraModule_.camera and cameraModule_.camera.aspectRatio or (16.0 / 9.0)
            if aspect <= 0 then aspect = 16.0 / 9.0 end
            local orthoFromW = totalW / aspect
            local orthoFromH = totalH
            local fullOrtho = math.max(orthoFromW, orthoFromH)

            if cameraModule_ then
                cameraModule_.AnimateTo(Vector3(mapCx, mapCy, 0), fullOrtho, Config.IntroZoomOutTime * 0.9)
            end
            print("[GameManager] Intro phase 4: zoom out to full map")
        end
        return
    end

    -- 阶段 4：拉远回全景
    if introPhase_ == 4 then
        introPhaseTimer_ = introPhaseTimer_ - dt
        if cameraModule_ then
            cameraModule_.UpdateAnimation(dt)
        end

        -- 文字淡出
        local progress = 1.0 - (introPhaseTimer_ / Config.IntroZoomOutTime)
        introTextAlpha_ = math.max(0, 1.0 - progress * 2.0)  -- 前半段快速淡出

        if introPhaseTimer_ <= 0 then
            -- 过渡完成，设置固定全景并进入倒计时
            if cameraModule_ then
                cameraModule_.StopAnimation()
                cameraModule_.SetFixedForMap(MapData.Width, MapData.Height, 2)
            end
            introPhase_ = 0
            introTextAlpha_ = 0
            lastCountdownNum_ = math.ceil(Config.CountdownTime) + 1
            GameManager.SetState(GameManager.STATE_COUNTDOWN, Config.CountdownTime)
            print("[GameManager] Intro complete → countdown")
        end
    end
end

--- 获取开场动画当前阶段（供 HUD 使用）
---@return number -- 0=未开始, 1=聚焦终点, 2=平移起点, 3=文字显示
function GameManager.GetIntroPhase()
    return introPhase_
end

--- 获取开场文字透明度（供 HUD 使用）
---@return number -- 0~1
function GameManager.GetIntroTextAlpha()
    return introTextAlpha_
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

--- 处理击杀事件（由 Player.onKill 回调触发）
---@param killerIndex number
---@param victimIndex number
---@param multiKillCount number
---@param killStreak number
function GameManager.OnPlayerKill(killerIndex, victimIndex, multiKillCount, killStreak)
    -- 击杀加分
    local killPts = Config.KillScore
    GameManager.scores[killerIndex] = GameManager.scores[killerIndex] + killPts
    GameManager.killScores[killerIndex] = GameManager.killScores[killerIndex] + killPts

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

    print("[GameManager] Kill event: P" .. killerIndex .. " killed P" .. victimIndex
        .. " (multi=" .. multiKillCount .. ", streak=" .. killStreak
        .. ", score=" .. GameManager.scores[killerIndex] .. ")")
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
-- 匹配状态
-- ============================================================================

--- 进入匹配状态
function GameManager.EnterMatching()
    matchingTimer_ = 0
    matchingSlotCount_ = 1  -- 玩家自己先占一个槽
    matchingComplete_ = false
    GameManager.SetState(GameManager.STATE_MATCHING)
    print("[GameManager] Entering matching...")
end

--- 更新匹配逻辑
---@param dt number
function GameManager.UpdateMatching(dt)
    matchingTimer_ = matchingTimer_ + dt

    -- 模拟逐个玩家加入（间隔 0.6~1.2 秒随机加一个）
    local slotsNeeded = Config.NumPlayers
    if matchingSlotCount_ < slotsNeeded then
        -- 根据时间进度模拟填充
        local fillInterval = Config.MatchingTimeout / (slotsNeeded - 1)
        local expectedSlots = 1 + math.floor(matchingTimer_ / fillInterval)
        if expectedSlots > matchingSlotCount_ and matchingSlotCount_ < slotsNeeded then
            matchingSlotCount_ = math.min(expectedSlots, slotsNeeded)
        end
    end

    -- 超时 → 全部就绪
    if matchingTimer_ >= Config.MatchingTimeout then
        matchingSlotCount_ = slotsNeeded
        if not matchingComplete_ then
            matchingComplete_ = true
            SFX.Play("match_ready", 0.8)
            print("[GameManager] Matching complete! All players ready.")
        end
    end
end

--- 仅更新匹配计时器（客户端联机模式专用，不做本地槽位模拟）
---@param dt number
function GameManager.UpdateMatchingTimer(dt)
    matchingTimer_ = matchingTimer_ + dt
end

--- 取消匹配，返回菜单
function GameManager.CancelMatching()
    GameManager.SetState(GameManager.STATE_MENU)
    print("[GameManager] Matching cancelled")
end

--- 获取匹配计时
---@return number
function GameManager.GetMatchingTime()
    return matchingTimer_
end

--- 获取已匹配玩家数
---@return number
function GameManager.GetMatchingSlots()
    return matchingSlotCount_
end

--- 匹配是否完成
---@return boolean
function GameManager.IsMatchingComplete()
    return matchingComplete_
end

--- 强制匹配完成（服务端分配角色后调用，用于视觉反馈）
function GameManager.ForceMatchingComplete()
    matchingSlotCount_ = Config.NumPlayers
    matchingComplete_ = true
    matchingTimer_ = Config.MatchingTimeout
    SFX.Play("match_ready", 0.8)
    print("[GameManager] Matching force-completed (server assigned role)")
end

--- 设置匹配槽位数（外部通知玩家加入时更新 UI）
---@param count number
function GameManager.SetMatchingSlots(count)
    matchingSlotCount_ = math.min(count, Config.NumPlayers)
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
