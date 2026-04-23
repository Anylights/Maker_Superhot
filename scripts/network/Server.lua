-- ============================================================================
-- Server.lua - 超级红温！ 联机服务端（精简版：仅快速匹配）
-- 状态机：IDLE → MATCHING → PLAYING → ENDED → IDLE
-- ============================================================================

require "LuaScripts/Utilities/Sample"

local Config = require("Config")
local Shared = require("network.Shared")
local Map = require("Map")
local MapData = require("MapData")
local Player = require("Player")
local Pickup = require("Pickup")
local AIController = require("AIController")
local GameManager = require("GameManager")
local SFX = require("SFX")
local RandomPickup = require("RandomPickup")
local LevelManager = require("LevelManager")

local EVENTS = Shared.EVENTS
local CTRL = Shared.CTRL
local VARS = Shared.VARS

local Server = {}

-- ============================================================================
-- Mock graphics for headless mode
-- ============================================================================

if GetGraphics() == nil then
    local mockGraphics = {
        SetWindowIcon = function() end,
        SetWindowTitleAndIcon = function() end,
        windowTitle = "",
        GetWidth = function() return 1920 end,
        GetHeight = function() return 1080 end,
    }
    function GetGraphics() return mockGraphics end
    graphics = mockGraphics
    console = { background = {} }
    function GetConsole() return console end
    debugHud = {}
    function GetDebugHud() return debugHud end
end

-- ============================================================================
-- State
-- ============================================================================

---@type Scene
local scene_ = nil

-- 服务端状态机
local STATE_IDLE     = "IDLE"
local STATE_MATCHING = "MATCHING"
local STATE_PLAYING  = "PLAYING"
local STATE_ENDED    = "ENDED"

local serverState_ = STATE_IDLE
local matchTimer_  = 0      -- MATCHING 状态倒计时（剩余秒数）
local serverTime_  = 0

-- 连接管理
-- connections_[connKey] = { conn, connKey, ready, inQueue, slot }
local connections_ = {}

-- 活跃对局：activePlayers_[1..NumPlayers] = { kind="human"|"ai", connKey=..., conn=..., disconnected=bool }
local activePlayers_ = nil

-- ============================================================================
-- Entry
-- ============================================================================

function Server.Start()
    SampleStart()
    graphics.windowTitle = Config.Title .. " [Server]"
    print("=== " .. Config.Title .. " (Server, quick-match only) ===")

    Server.CreateScene()

    Map.SetSkipVisuals(true)
    Map.Init(scene_)
    Player.SetNetworkMode("server")
    Player.Init(scene_, Map)
    Pickup.Init(scene_, Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, nil)
    RandomPickup.Init(Map, Pickup)
    LevelManager.Init()

    SubscribeToEvent("ClientConnected", "HandleClientConnected")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")

    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent(EVENTS.REQUEST_QUICK, "HandleRequestQuick")
    SubscribeToEvent(EVENTS.CANCEL_QUICK, "HandleCancelQuick")

    GameManager.OnKill(function(killerIdx, victimIdx, multiKill, killStreak)
        Server.BroadcastKillEvent(killerIdx, victimIdx, multiKill, killStreak)
    end)

    GameManager.OnStateChange(function(oldState, newState)
        if serverState_ ~= STATE_PLAYING then return end
        Server.BroadcastGameState()
        if newState == GameManager.STATE_MENU then
            Server.EndGame()
        end
    end)

    print("[Server] Ready, waiting for players...")
end

function Server.Stop()
    print("[Server] Stopped")
end

-- ============================================================================
-- Scene
-- ============================================================================

function Server.CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")

    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))

    local deathZone = scene_:CreateChild("DeathZone", LOCAL)
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)
    local dzBody = deathZone:CreateComponent("RigidBody")
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2
    local dzShape = deathZone:CreateComponent("CollisionShape")
    dzShape:SetBox(Vector3(1, 1, 1))

    print("[Server] Scene created")
end

-- ============================================================================
-- Connection lookup helper
-- ============================================================================

local function FindConnection(eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local connData = connections_[connKey]
    if connData then return connection, connKey, connData end

    for k, v in pairs(connections_) do
        if v.conn == connection then
            return connection, k, v
        end
    end
    return connection, connKey, nil
end

-- ============================================================================
-- Connection Handling
-- ============================================================================

function HandleClientConnected(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)

    connection:SetPulseButtonMask(CTRL.JUMP | CTRL.DASH | CTRL.EXPLODE_RELEASE)

    connections_[connKey] = {
        conn = connection,
        connKey = connKey,
        ready = false,
        inQueue = false,
        slot = 0,
    }

    print("[Server] Client connected: " .. connKey)
end

function HandleClientReady(eventType, eventData)
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then return end

    connection.scene = scene_
    connData.ready = true
    print("[Server] CLIENT_READY: " .. connKey)
end

function HandleClientDisconnected(eventType, eventData)
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] Disconnect from unknown: " .. connKey)
        return
    end

    -- 1) 从队列中移除
    if connData.inQueue then
        connData.inQueue = false
    end

    -- 2) 如果在对局中 → 转 AI
    if serverState_ == STATE_PLAYING and activePlayers_ then
        for _, ap in ipairs(activePlayers_) do
            if ap.connKey == connKey then
                ap.disconnected = true
                ap.kind = "ai"
                ap.conn = nil
                for _, p in ipairs(Player.list) do
                    if p.index == ap.slot then
                        p.isHuman = false
                        AIController.Register(p)
                        break
                    end
                end
                break
            end
        end
    end

    connections_[connKey] = nil
    print("[Server] Client disconnected: " .. connKey)

    -- 队列空了 → 回 IDLE
    if serverState_ == STATE_MATCHING then
        Server.RecountAndMaybeIdle()
    end
end

-- ============================================================================
-- Quick Match
-- ============================================================================

function HandleRequestQuick(eventType, eventData)
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then return end

    -- 对局进行中 → 暂存到队列，等待下一局
    if connData.inQueue then return end

    connData.inQueue = true
    print("[Server] " .. connKey .. " joined quick queue")

    if serverState_ == STATE_IDLE then
        serverState_ = STATE_MATCHING
        matchTimer_ = Config.MatchingTimeout
        print("[Server] State: IDLE -> MATCHING (" .. matchTimer_ .. "s)")
    end

    Server.BroadcastQuickUpdate()

    -- 立即检查是否凑满 NumPlayers 真人 → 立刻开局
    if Server.GetQueueCount() >= Config.NumPlayers and serverState_ == STATE_MATCHING then
        Server.StartGameFromQueue()
    end
end

function HandleCancelQuick(eventType, eventData)
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then return end
    if not connData.inQueue then return end

    connData.inQueue = false
    print("[Server] " .. connKey .. " cancelled quick match")
    Server.BroadcastQuickUpdate()
    Server.RecountAndMaybeIdle()
end

function Server.GetQueueCount()
    local count = 0
    for _, cd in pairs(connections_) do
        if cd.inQueue then count = count + 1 end
    end
    return count
end

function Server.RecountAndMaybeIdle()
    if serverState_ ~= STATE_MATCHING then return end
    if Server.GetQueueCount() == 0 then
        serverState_ = STATE_IDLE
        matchTimer_ = 0
        print("[Server] State: MATCHING -> IDLE (queue empty)")
    end
end

function Server.BroadcastQuickUpdate()
    local humanCount = Server.GetQueueCount()
    local timeLeft = (serverState_ == STATE_MATCHING) and matchTimer_ or Config.MatchingTimeout
    for _, cd in pairs(connections_) do
        if cd.inQueue and cd.conn then
            local data = VariantMap()
            data["PlayerCount"] = Variant(humanCount)
            data["TimeLeft"] = Variant(timeLeft)
            data["Required"] = Variant(Config.NumPlayers)
            cd.conn:SendRemoteEvent(EVENTS.QUICK_UPDATE, true, data)
        end
    end
end

function Server.UpdateMatching(dt)
    if serverState_ ~= STATE_MATCHING then return end

    matchTimer_ = matchTimer_ - dt
    if matchTimer_ < 0 then matchTimer_ = 0 end

    -- 每 0.5s 推送一次进度
    Server._broadcastTimer = (Server._broadcastTimer or 0) + dt
    if Server._broadcastTimer >= 0.5 then
        Server._broadcastTimer = 0
        Server.BroadcastQuickUpdate()
    end

    -- 超时 → 用 AI 补齐开局
    if matchTimer_ <= 0 and Server.GetQueueCount() >= 1 then
        Server.StartGameFromQueue()
    end
end

function Server.StartGameFromQueue()
    -- 收集真人玩家
    local humans = {}
    for _, cd in pairs(connections_) do
        if cd.inQueue then
            table.insert(humans, cd)
            cd.inQueue = false
        end
    end

    -- 限制为 NumPlayers
    while #humans > Config.NumPlayers do
        local extra = table.remove(humans)
        extra.inQueue = true  -- 留在队列等下一局
    end

    activePlayers_ = {}
    local slot = 1
    for _, cd in ipairs(humans) do
        cd.slot = slot
        table.insert(activePlayers_, {
            kind = "human",
            connKey = cd.connKey,
            conn = cd.conn,
            slot = slot,
            disconnected = false,
        })
        slot = slot + 1
    end
    while slot <= Config.NumPlayers do
        table.insert(activePlayers_, {
            kind = "ai",
            connKey = nil,
            conn = nil,
            slot = slot,
            disconnected = false,
        })
        slot = slot + 1
    end

    print(string.format("[Server] Starting game: %d humans + %d AI",
        #humans, Config.NumPlayers - #humans))

    -- 通知所有真人匹配成功
    for _, ap in ipairs(activePlayers_) do
        if ap.conn then
            local data = VariantMap()
            data["Slot"] = Variant(ap.slot)
            ap.conn:SendRemoteEvent(EVENTS.MATCH_FOUND, true, data)
        end
    end

    serverState_ = STATE_PLAYING
    matchTimer_ = 0

    Shared.DelayOneFrame(function()
        Server.StartGame()
    end)
end

-- ============================================================================
-- Game Session
-- ============================================================================

function Server.StartGame()
    -- 选关
    local grid, fn = LevelManager.GetRandom()
    if grid then
        MapData.SetCustomGrid(grid)
    else
        MapData.ClearCustomGrid()
    end

    Map.Build()

    -- 创建玩家
    Player.list = {}
    for _, ap in ipairs(activePlayers_) do
        local p = Player.Create(ap.slot, ap.kind == "human", { skipVisuals = true })
        if ap.kind == "ai" then
            AIController.Register(p)
        end
    end

    Pickup.Reset()
    RandomPickup.Reset()

    -- 给真人发送 ASSIGN_ROLE
    for _, ap in ipairs(activePlayers_) do
        if ap.conn then
            Shared.DelayOneFrame(function()
                local data = VariantMap()
                data["Slot"] = Variant(ap.slot)
                data["MapWidth"] = Variant(MapData.Width)
                data["MapHeight"] = Variant(MapData.Height)
                ap.conn:SendRemoteEvent(EVENTS.ASSIGN_ROLE, true, data)
            end)
        end
    end

    GameManager.StartMatch()
    print("[Server] Game running with " .. #activePlayers_ .. " players")
end

function Server.EndGame()
    print("[Server] Game ended, cleaning up")

    if activePlayers_ then
        for _, ap in ipairs(activePlayers_) do
            if ap.connKey then
                local cd = connections_[ap.connKey]
                if cd then cd.slot = 0 end
            end
        end
    end

    activePlayers_ = nil
    Player.list = {}
    Map.Clear()

    serverState_ = STATE_ENDED

    -- 立即过渡到 IDLE，未关闭连接的人若仍 inQueue 则进入下一轮
    serverState_ = STATE_IDLE
    matchTimer_ = 0
    if Server.GetQueueCount() > 0 then
        serverState_ = STATE_MATCHING
        matchTimer_ = Config.MatchingTimeout
        print("[Server] State: ENDED -> MATCHING (queued players present)")
    else
        print("[Server] State: ENDED -> IDLE")
    end
end

function Server.BroadcastGameState()
    if not activePlayers_ then return end

    local data = VariantMap()
    data["State"] = Variant(GameManager.state)
    data["Round"] = Variant(GameManager.round)
    data["RoundTimer"] = Variant(GameManager.GetRoundTime())
    data["CountdownTimer"] = Variant(GameManager.stateTimer)

    for i = 1, Config.NumPlayers do
        data["Score" .. i] = Variant(GameManager.scores[i])
        data["KillScore" .. i] = Variant(GameManager.killScores[i])
    end

    for i, playerIdx in ipairs(GameManager.roundResults) do
        data["Result" .. i] = Variant(playerIdx)
    end
    data["ResultCount"] = Variant(#GameManager.roundResults)

    local winner = GameManager.GetWinner()
    if winner then data["Winner"] = Variant(winner) end

    for _, ap in ipairs(activePlayers_) do
        if ap.conn and not ap.disconnected then
            ap.conn:SendRemoteEvent(EVENTS.GAME_STATE, true, data)
        end
    end
end

function Server.BroadcastKillEvent(killerIdx, victimIdx, multiKill, killStreak)
    if not activePlayers_ then return end

    local data = VariantMap()
    data["Killer"] = Variant(killerIdx)
    data["Victim"] = Variant(victimIdx)
    data["MultiKill"] = Variant(multiKill)
    data["KillStreak"] = Variant(killStreak)

    for _, ap in ipairs(activePlayers_) do
        if ap.conn and not ap.disconnected then
            ap.conn:SendRemoteEvent(EVENTS.KILL_EVENT, true, data)
        end
    end
end

-- ============================================================================
-- Input Processing
-- ============================================================================

function Server.ProcessInputs()
    if not activePlayers_ then return end

    for _, ap in ipairs(activePlayers_) do
        if ap.kind == "human" and ap.conn and not ap.disconnected then
            local controls = ap.conn.controls
            local buttons = controls.buttons

            for _, p in ipairs(Player.list) do
                if p.index == ap.slot and p.isHuman then
                    p.inputMoveX = 0
                    if buttons & CTRL.LEFT ~= 0 then p.inputMoveX = -1 end
                    if buttons & CTRL.RIGHT ~= 0 then p.inputMoveX = 1 end

                    if buttons & CTRL.JUMP ~= 0 then p.inputJump = true end
                    if buttons & CTRL.DASH ~= 0 then p.inputDash = true end

                    local chargeDown = (buttons & CTRL.CHARGE ~= 0)
                    if chargeDown then p.inputCharging = true end
                    if buttons & CTRL.EXPLODE_RELEASE ~= 0 then
                        p.inputExplodeRelease = true
                    end
                    p.wasChargingInput = chargeDown
                    break
                end
            end
        end
    end
end

-- ============================================================================
-- Update Loop
-- ============================================================================

---@param dt number
function Server.HandleUpdate(dt)
    serverTime_ = serverTime_ + dt

    Shared.UpdateDelayed()

    if serverState_ == STATE_MATCHING then
        Server.UpdateMatching(dt)
    end

    -- 客户端各自独立模拟自己的世界（含 AI 补位）。
    -- 服务端只负责匹配 + 通知客户端开始/结束，不再运行游戏循环。
end

function Server.HandlePostUpdate(dt)
end

return Server
