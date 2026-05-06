-- ============================================================================
-- Server.lua - 超级红温！ 联机服务端
-- 职责：连接管理、快速匹配队列、房间系统、权威游戏运行
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

-- 连接 → 数据映射（key = tostring(connection)）
local connections_ = {}  -- { conn, connKey, slot, roomCode, inQuick }

-- 快速匹配队列
local quickQueue_ = {}        -- { connKey, joinTime }
local quickAICount_ = 0       -- 快速匹配队列中的 AI 数量
local quickTimer_ = 0         -- 快速匹配队列计时器
local quickLastAITime_ = 0    -- 上次添加 AI 的时间

-- 房间系统
local rooms_ = {}             -- rooms_[roomCode] = { hostKey, players={connKey,...}, aiCount, state }

-- 游戏会话
local activeGame_ = nil       -- { players={...}, roomCode, isQuick, state }

-- 服务端时间
local serverTime_ = 0

-- 定期广播游戏状态的间隔计时器
local gameStateBroadcastTimer_ = 0
local GAME_STATE_BROADCAST_INTERVAL = 1.0  -- 每秒广播一次

-- ============================================================================
-- Entry
-- ============================================================================

function Server.Start()
    SampleStart()
    graphics.windowTitle = Config.Title .. " [Server]"
    print("=== " .. Config.Title .. " (Server) ===")

    -- 网络发送频率与服务器实际 tick rate 对齐
    -- SERVER_TICK_RATE 由框架注入，代表服务器实际物理/逻辑更新频率
    -- 如果 SetUpdateFps > SERVER_TICK_RATE，多出的网络包只是重复发送相同位置数据（浪费带宽）
    -- 如果 SetUpdateFps < SERVER_TICK_RATE，物理步进间的位置更新会被跳过（增大延迟）
    ---@diagnostic disable-next-line: undefined-global
    local serverTickRate = SERVER_TICK_RATE or 60
    network:SetUpdateFps(serverTickRate)
    print("[Server] network:SetUpdateFps(" .. serverTickRate .. ") — aligned with SERVER_TICK_RATE")

    -- [DIAG] 输出服务器配置信息
    ---@diagnostic disable-next-line: undefined-global
    print("[Server.DIAG] SERVER_TICK_RATE = " .. tostring(SERVER_TICK_RATE or "nil"))
    ---@diagnostic disable-next-line: undefined-global
    print("[Server.DIAG] SERVER_MAX_PLAYERS = " .. tostring(SERVER_MAX_PLAYERS or "nil"))
    ---@diagnostic disable-next-line: undefined-global
    print("[Server.DIAG] SERVER_MODE = " .. tostring(SERVER_MODE or "nil"))

    -- 创建场景
    Server.CreateScene()

    -- 初始化子系统（服务端不需要视觉）
    Map.SetSkipVisuals(true)
    Map.Init(scene_)
    Player.SetNetworkMode("server")
    Player.Init(scene_, Map)
    Pickup.SetNetworkMode("server")
    Pickup.Init(scene_, Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, nil)
    RandomPickup.Init(Map, Pickup)

    -- LevelManager.Init() 内部已分离缓存填充和文件 I/O：
    -- 缓存填充是纯内存操作，永远成功；文件 I/O 已有 pcall 保护
    -- 因此这里不再需要外层 pcall
    LevelManager.Init()

    -- 监听连接事件
    SubscribeToEvent("ClientConnected", "HandleClientConnected")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")

    -- 监听客户端远程事件
    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent(EVENTS.REQUEST_QUICK, "HandleRequestQuick")
    SubscribeToEvent(EVENTS.CANCEL_QUICK, "HandleCancelQuick")
    SubscribeToEvent(EVENTS.REQUEST_CREATE, "HandleRequestCreate")
    SubscribeToEvent(EVENTS.REQUEST_JOIN, "HandleRequestJoin")
    SubscribeToEvent(EVENTS.REQUEST_LEAVE, "HandleRequestLeave")
    SubscribeToEvent(EVENTS.REQUEST_DISMISS, "HandleRequestDismiss")
    SubscribeToEvent(EVENTS.REQUEST_ADD_AI, "HandleRequestAddAI")
    SubscribeToEvent(EVENTS.REQUEST_START, "HandleRequestStart")

    -- GameManager 击杀回调
    GameManager.OnKill(function(killerIdx, victimIdx, multiKill, killStreak)
        Server.BroadcastKillEvent(killerIdx, victimIdx, multiKill, killStreak)
    end)

    print("[Server] Started, waiting for connections...")
    print("[Server] ✅ All event handlers registered, server fully ready")
end

function Server.Stop()
    print("[Server] Stopped")
end

-- ============================================================================
-- Scene
-- ============================================================================

function Server.CreateScene()
    scene_ = Scene()
    -- Octree/PhysicsWorld 必须保持 REPLICATED（默认）：scene 核心组件，影响同步根
    scene_:CreateComponent("Octree")

    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))
    -- 禁用服务端物理插值：确保发送给客户端的是干净的物理步进位置，
    -- 而非 Bullet 在渲染帧间插值的中间态（中间态会导致客户端抖动）
    physicsWorld.interpolation = false

    -- 死亡区域（服务端独有 LOCAL，不复制到客户端）
    local deathZone = scene_:CreateChild("DeathZone", LOCAL)
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)
    local dzBody = deathZone:CreateComponent("RigidBody", LOCAL)
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2
    local dzShape = deathZone:CreateComponent("CollisionShape", LOCAL)
    dzShape:SetBox(Vector3(1, 1, 1))

    print("[Server] Scene created")
end

-- ============================================================================
-- Connection Lookup Helper（防止 tostring 不一致）
-- ============================================================================

--- 从 eventData 中提取 connection 并查找对应的 connData
--- 如果 tostring 匹配失败，会遍历 connections_ 按对象引用查找
---@return Connection|nil, string, table|nil
local function DumpConnections(label)
    local count = 0
    for k, v in pairs(connections_) do
        count = count + 1
        print("[Server] " .. label .. " conn[" .. count .. "]: key=" .. k ..
              " ready=" .. tostring(v.ready) ..
              " inQuick=" .. tostring(v.inQuick) ..
              " roomCode=" .. tostring(v.roomCode))
    end
    if count == 0 then
        print("[Server] " .. label .. " connections_ is EMPTY!")
    end
end

local function FindConnection(eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local connData = connections_[connKey]

    if connData then
        return connection, connKey, connData
    end

    -- tostring 可能不一致，遍历查找
    for k, v in pairs(connections_) do
        if v.conn == connection then
            print("[Server] WARNING: tostring mismatch! event=" .. connKey .. " stored=" .. k)
            return connection, k, v
        end
    end

    print("[Server] WARNING: FindConnection FAILED for connKey=" .. connKey)
    DumpConnections("FindConnection-dump")
    return connection, connKey, nil
end

-- ============================================================================
-- Connection Handling
-- ============================================================================

function HandleClientConnected(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)

    -- ⚠️ 不要在这里设置 connection.scene！
    -- 等客户端发送 CLIENT_READY 后再设置，否则会导致场景同步时序问题

    -- 设置脉冲按钮掩码（一次性输入走 reliable 通道，防止丢包）
    connection:SetPulseButtonMask(CTRL.JUMP | CTRL.DASH | CTRL.EXPLODE_RELEASE)

    connections_[connKey] = {
        conn = connection,
        connKey = connKey,
        slot = 0,         -- 分配的玩家编号（游戏中才有）
        roomCode = nil,
        inQuick = false,
        ready = false,    -- 是否已收到 CLIENT_READY
    }

    print("[Server] Client connected: " .. connKey .. " (waiting for CLIENT_READY)")
    DumpConnections("after-connect")
end

function HandleClientReady(eventType, eventData)
    print("[Server] >>> HandleClientReady ENTERED")
    local connection, connKey, connData = FindConnection(eventData)

    if not connData then
        print("[Server] ERROR: CLIENT_READY from unknown connection, ignoring")
        return
    end

    -- 现在才设置 connection.scene（客户端已准备好接收场景数据）
    connection.scene = scene_
    connData.ready = true

    print("[Server] CLIENT_READY received, scene assigned: " .. connKey)
    DumpConnections("after-ready")
end

function HandleClientDisconnected(eventType, eventData)
    local connection, connKey, connData = FindConnection(eventData)

    if connData then
        -- 从快速匹配队列移除
        if connData.inQuick then
            Server.RemoveFromQuickQueue(connKey)
        end

        -- 从房间移除
        if connData.roomCode then
            local room = rooms_[connData.roomCode]
            if room then
                if room.hostKey == connKey then
                    -- 房主断线 → 解散房间
                    Server.DismissRoom(connData.roomCode)
                else
                    -- 普通玩家断线 → 从房间移除
                    Server.RemoveFromRoom(connData.roomCode, connKey)
                end
            end
        end

        -- 从活跃游戏移除（如果正在游戏中）
        if activeGame_ then
            for i, gp in ipairs(activeGame_.players) do
                if gp.connKey == connKey then
                    gp.disconnected = true
                    -- 将对应玩家改为 AI 控制
                    for _, p in ipairs(Player.list) do
                        if p.index == gp.slot then
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
    end

    print("[Server] Client disconnected: " .. connKey)
end

-- ============================================================================
-- Quick Match
-- ============================================================================

function HandleRequestQuick(eventType, eventData)
    print("[Server] >>> HandleRequestQuick ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] REQUEST_QUICK: FindConnection returned nil! connKey=" .. tostring(connKey))
        DumpConnections("REQUEST_QUICK-fail")
        return
    end
    print("[Server] REQUEST_QUICK from " .. connKey .. " (ready=" .. tostring(connData.ready) .. ", inQuick=" .. tostring(connData.inQuick) .. ", roomCode=" .. tostring(connData.roomCode) .. ")")

    -- 如果已在队列或房间中，忽略
    if connData.inQuick then
        print("[Server] REQUEST_QUICK: already in quick queue, ignoring")
        return
    end
    if connData.roomCode then
        print("[Server] REQUEST_QUICK: already in room " .. connData.roomCode .. ", ignoring")
        return
    end

    connData.inQuick = true
    table.insert(quickQueue_, { connKey = connKey, joinTime = serverTime_ })

    -- 重置 AI 计时器（从有新人加入时开始计时）
    quickLastAITime_ = serverTime_

    print("[Server] Player joined quick queue: " .. connKey .. " (total: " .. #quickQueue_ .. "+" .. quickAICount_ .. " AI)")

    -- 广播当前队列人数
    Server.BroadcastQuickUpdate()
end

function HandleCancelQuick(eventType, eventData)
    print("[Server] >>> HandleCancelQuick ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] CANCEL_QUICK: FindConnection returned nil! connKey=" .. tostring(connKey))
        return
    end
    print("[Server] CANCEL_QUICK from " .. connKey)
    Server.RemoveFromQuickQueue(connKey)
end

function Server.RemoveFromQuickQueue(connKey)
    local connData = connections_[connKey]
    if connData then connData.inQuick = false end

    for i = #quickQueue_, 1, -1 do
        if quickQueue_[i].connKey == connKey then
            table.remove(quickQueue_, i)
            break
        end
    end

    print("[Server] Player left quick queue: " .. connKey)
    Server.BroadcastQuickUpdate()
end

function Server.UpdateQuickMatch(dt)
    local totalPlayers = #quickQueue_ + quickAICount_
    if totalPlayers == 0 then return end

    -- 每 QuickAIInterval 秒添加 1 个 AI
    if totalPlayers < Config.NumPlayers then
        if serverTime_ - quickLastAITime_ >= Config.QuickAIInterval then
            quickAICount_ = quickAICount_ + 1
            quickLastAITime_ = serverTime_
            totalPlayers = #quickQueue_ + quickAICount_
            print("[Server] Quick match: added AI (total: " .. #quickQueue_ .. " players + " .. quickAICount_ .. " AI)")
            Server.BroadcastQuickUpdate()
        end
    end

    -- 凑满了 → 开始游戏
    if totalPlayers >= Config.NumPlayers then
        Server.StartQuickGame()
    end
end

function Server.BroadcastQuickUpdate()
    local totalPlayers = #quickQueue_ + quickAICount_
    for _, entry in ipairs(quickQueue_) do
        local connData = connections_[entry.connKey]
        if connData and connData.conn then
            local data = VariantMap()
            data["PlayerCount"] = Variant(totalPlayers)
            data["HumanCount"] = Variant(#quickQueue_)
            connData.conn:SendRemoteEvent(EVENTS.QUICK_UPDATE, true, data)
        end
    end
end

function Server.StartQuickGame()
    print("[Server] Quick match ready! Starting game...")

    -- 收集参与的连接（最多 NumPlayers 个真人，其余 AI）
    local gamePlayers = {}
    local slot = 1

    for _, entry in ipairs(quickQueue_) do
        if slot > Config.NumPlayers then break end
        local connData = connections_[entry.connKey]
        if connData then
            table.insert(gamePlayers, {
                connKey = entry.connKey,
                conn = connData.conn,
                slot = slot,
                isAI = false,
                disconnected = false,
            })
            connData.inQuick = false
            slot = slot + 1
        end
    end

    -- 补 AI
    while slot <= Config.NumPlayers do
        table.insert(gamePlayers, {
            connKey = nil,
            conn = nil,
            slot = slot,
            isAI = true,
            disconnected = false,
        })
        slot = slot + 1
    end

    -- 清空队列
    quickQueue_ = {}
    quickAICount_ = 0
    quickLastAITime_ = 0

    -- 通知所有玩家匹配成功
    for _, gp in ipairs(gamePlayers) do
        if gp.conn then
            local data = VariantMap()
            data["Slot"] = Variant(gp.slot)
            gp.conn:SendRemoteEvent(EVENTS.MATCH_FOUND, true, data)
        end
    end

    -- 延迟一帧后开始游戏
    Shared.DelayOneFrame(function()
        Server.StartGame(gamePlayers, true, nil)
    end)
end

-- ============================================================================
-- Room System
-- ============================================================================

function Server.GenerateRoomCode()
    local code = ""
    for i = 1, Config.RoomCodeLength do
        code = code .. tostring(math.random(0, 9))
    end
    -- 确保不重复
    if rooms_[code] then
        return Server.GenerateRoomCode()
    end
    return code
end

function HandleRequestCreate(eventType, eventData)
    print("[Server] >>> HandleRequestCreate ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] REQUEST_CREATE: FindConnection returned nil! connKey=" .. tostring(connKey))
        DumpConnections("REQUEST_CREATE-fail")
        return
    end
    print("[Server] REQUEST_CREATE from " .. connKey .. " (ready=" .. tostring(connData.ready) .. ", inQuick=" .. tostring(connData.inQuick) .. ", roomCode=" .. tostring(connData.roomCode) .. ")")

    -- 如果已在房间或队列中，忽略
    if connData.roomCode then
        print("[Server] REQUEST_CREATE: already in room " .. connData.roomCode .. ", ignoring")
        return
    end
    if connData.inQuick then
        print("[Server] REQUEST_CREATE: already in quick queue, ignoring")
        return
    end

    local roomCode = Server.GenerateRoomCode()
    rooms_[roomCode] = {
        hostKey = connKey,
        players = { connKey },
        aiCount = 0,
        state = "waiting",
    }
    connData.roomCode = roomCode

    -- 通知房主
    local data = VariantMap()
    data["RoomCode"] = Variant(roomCode)
    print("[Server] Sending ROOM_CREATED to " .. connKey .. " with roomCode=" .. roomCode)
    connection:SendRemoteEvent(EVENTS.ROOM_CREATED, true, data)

    -- 广播房间状态
    Server.BroadcastRoomUpdate(roomCode)

    print("[Server] Room created: " .. roomCode .. " by " .. connKey)
end

function HandleRequestJoin(eventType, eventData)
    print("[Server] >>> HandleRequestJoin ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] REQUEST_JOIN: FindConnection returned nil! connKey=" .. tostring(connKey))
        DumpConnections("REQUEST_JOIN-fail")
        return
    end
    print("[Server] REQUEST_JOIN from " .. connKey .. " (ready=" .. tostring(connData.ready) .. ")")

    local roomCode = eventData["RoomCode"]:GetString()
    local room = rooms_[roomCode]

    -- 验证
    if not room then
        local data = VariantMap()
        data["Reason"] = Variant("房间不存在")
        connection:SendRemoteEvent(EVENTS.JOIN_FAILED, true, data)
        return
    end

    if room.state ~= "waiting" then
        local data = VariantMap()
        data["Reason"] = Variant("游戏已开始")
        connection:SendRemoteEvent(EVENTS.JOIN_FAILED, true, data)
        return
    end

    if #room.players + room.aiCount >= Config.MaxRoomPlayers then
        local data = VariantMap()
        data["Reason"] = Variant("房间已满")
        connection:SendRemoteEvent(EVENTS.JOIN_FAILED, true, data)
        return
    end

    -- 加入
    table.insert(room.players, connKey)
    connData.roomCode = roomCode

    -- 通知加入者
    local joinData = VariantMap()
    joinData["RoomCode"] = Variant(roomCode)
    connection:SendRemoteEvent(EVENTS.ROOM_JOINED, true, joinData)

    -- 广播更新
    Server.BroadcastRoomUpdate(roomCode)

    print("[Server] Player " .. connKey .. " joined room " .. roomCode)
end

function HandleRequestLeave(eventType, eventData)
    print("[Server] >>> HandleRequestLeave ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] REQUEST_LEAVE: FindConnection returned nil!")
        return
    end
    print("[Server] REQUEST_LEAVE from " .. connKey)
    if not connData.roomCode then
        print("[Server] REQUEST_LEAVE: not in any room, ignoring")
        return
    end

    local roomCode = connData.roomCode
    local room = rooms_[roomCode]
    if not room then
        print("[Server] REQUEST_LEAVE: room " .. roomCode .. " not found, ignoring")
        return
    end

    -- 房主不能离开，只能解散
    if room.hostKey == connKey then
        print("[Server] REQUEST_LEAVE: is host, must use dismiss instead")
        return
    end

    Server.RemoveFromRoom(roomCode, connKey)
end

function HandleRequestDismiss(eventType, eventData)
    print("[Server] >>> HandleRequestDismiss ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] REQUEST_DISMISS: FindConnection returned nil!")
        return
    end
    print("[Server] REQUEST_DISMISS from " .. connKey)
    if not connData.roomCode then
        print("[Server] REQUEST_DISMISS: not in any room, ignoring")
        return
    end

    local roomCode = connData.roomCode
    local room = rooms_[roomCode]
    if not room then
        print("[Server] REQUEST_DISMISS: room " .. roomCode .. " not found")
        return
    end
    if room.hostKey ~= connKey then
        print("[Server] REQUEST_DISMISS: not host (host=" .. room.hostKey .. "), ignoring")
        return
    end

    Server.DismissRoom(roomCode)
end

function HandleRequestAddAI(eventType, eventData)
    print("[Server] >>> HandleRequestAddAI ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] REQUEST_ADD_AI: FindConnection returned nil!")
        return
    end
    print("[Server] REQUEST_ADD_AI from " .. connKey)
    if not connData.roomCode then
        print("[Server] REQUEST_ADD_AI: not in any room, ignoring")
        return
    end

    local roomCode = connData.roomCode
    local room = rooms_[roomCode]
    if not room then
        print("[Server] REQUEST_ADD_AI: room " .. roomCode .. " not found")
        return
    end
    if room.hostKey ~= connKey then
        print("[Server] REQUEST_ADD_AI: not host, ignoring")
        return
    end

    if #room.players + room.aiCount >= Config.MaxRoomPlayers then
        print("[Server] REQUEST_ADD_AI: room full (" .. #room.players .. "+" .. room.aiCount .. "), ignoring")
        return
    end

    room.aiCount = room.aiCount + 1
    Server.BroadcastRoomUpdate(roomCode)

    print("[Server] AI added to room " .. roomCode .. " (ai=" .. room.aiCount .. ")")
end

function HandleRequestStart(eventType, eventData)
    print("[Server] >>> HandleRequestStart ENTERED")
    local connection, connKey, connData = FindConnection(eventData)
    if not connData then
        print("[Server] REQUEST_START: FindConnection returned nil!")
        return
    end
    print("[Server] REQUEST_START from " .. connKey)
    if not connData.roomCode then
        print("[Server] REQUEST_START: not in any room, ignoring")
        return
    end

    local roomCode = connData.roomCode
    local room = rooms_[roomCode]
    if not room then
        print("[Server] REQUEST_START: room " .. roomCode .. " not found")
        return
    end
    if room.hostKey ~= connKey then
        print("[Server] REQUEST_START: not host (host=" .. room.hostKey .. "), ignoring")
        return
    end
    if room.state ~= "waiting" then
        print("[Server] REQUEST_START: room state=" .. room.state .. ", not waiting")
        return
    end

    -- 补齐 AI 到 NumPlayers
    local total = #room.players + room.aiCount
    if total < Config.NumPlayers then
        room.aiCount = Config.NumPlayers - #room.players
    end

    room.state = "starting"

    -- 收集游戏玩家
    local gamePlayers = {}
    local slot = 1

    for _, playerKey in ipairs(room.players) do
        local cd = connections_[playerKey]
        if cd then
            table.insert(gamePlayers, {
                connKey = playerKey,
                conn = cd.conn,
                slot = slot,
                isAI = false,
                disconnected = false,
            })
            slot = slot + 1
        end
    end

    -- 补 AI
    while slot <= Config.NumPlayers do
        table.insert(gamePlayers, {
            connKey = nil,
            conn = nil,
            slot = slot,
            isAI = true,
            disconnected = false,
        })
        slot = slot + 1
    end

    -- 通知所有玩家游戏即将开始
    for _, gp in ipairs(gamePlayers) do
        if gp.conn then
            local data = VariantMap()
            data["Slot"] = Variant(gp.slot)
            gp.conn:SendRemoteEvent(EVENTS.GAME_STARTING, true, data)
        end
    end

    -- 延迟后开始
    Shared.DelayOneFrame(function()
        Server.StartGame(gamePlayers, false, roomCode)
    end)

    print("[Server] Room " .. roomCode .. " starting game!")
end

function Server.RemoveFromRoom(roomCode, connKey)
    local room = rooms_[roomCode]
    if not room then return end

    for i = #room.players, 1, -1 do
        if room.players[i] == connKey then
            table.remove(room.players, i)
            break
        end
    end

    local connData = connections_[connKey]
    if connData then connData.roomCode = nil end

    Server.BroadcastRoomUpdate(roomCode)
    print("[Server] Player " .. connKey .. " removed from room " .. roomCode)
end

function Server.DismissRoom(roomCode)
    local room = rooms_[roomCode]
    if not room then return end

    -- 通知所有玩家
    for _, playerKey in ipairs(room.players) do
        local cd = connections_[playerKey]
        if cd then
            cd.roomCode = nil
            if cd.conn then
                cd.conn:SendRemoteEvent(EVENTS.ROOM_DISMISSED, true)
            end
        end
    end

    rooms_[roomCode] = nil
    print("[Server] Room " .. roomCode .. " dismissed")
end

function Server.BroadcastRoomUpdate(roomCode)
    local room = rooms_[roomCode]
    if not room then return end

    local playerCount = #room.players
    local aiCount = room.aiCount
    local total = playerCount + aiCount

    for _, playerKey in ipairs(room.players) do
        local cd = connections_[playerKey]
        if cd and cd.conn then
            local data = VariantMap()
            data["RoomCode"] = Variant(roomCode)
            data["PlayerCount"] = Variant(playerCount)
            data["AICount"] = Variant(aiCount)
            data["Total"] = Variant(total)
            data["IsHost"] = Variant(playerKey == room.hostKey)
            cd.conn:SendRemoteEvent(EVENTS.ROOM_UPDATE, true, data)
        end
    end
end

-- ============================================================================
-- Game Session
-- ============================================================================

function Server.StartGame(gamePlayers, isQuick, roomCode)
    if activeGame_ then
        print("[Server] WARNING: game already active, ignoring")
        return
    end

    -- 随机选关
    local grid, fn = LevelManager.GetRandom()
    if grid then
        MapData.SetCustomGrid(grid)
        print("[Server] Selected level: " .. tostring(fn))
    else
        MapData.ClearCustomGrid()
        print("[Server] Using default map")
    end

    -- 注意：不要在这里调用 Map.Build()！
    -- GameManager.StartMatch() → StartRound() → Map.Reset() 会调用 Map.Build()
    -- 重复调用会导致不必要的场景节点翻腾

    -- 创建玩家
    Player.list = {}
    for _, gp in ipairs(gamePlayers) do
        local p = Player.Create(gp.slot, not gp.isAI, { skipVisuals = true })
        if gp.isAI then
            AIController.Register(p)
        end
    end

    -- 注意：不要在这里调用 Pickup.Reset() / RandomPickup.Reset()！
    -- StartRound() 内部已包含这些调用

    -- 设置活跃游戏
    activeGame_ = {
        players = gamePlayers,
        roomCode = roomCode,
        isQuick = isQuick,
        state = "running",
    }

    -- 为真人玩家分配角色（包含关卡文件名，让客户端加载同一张地图）
    local levelFile = fn or ""
    for _, gp in ipairs(gamePlayers) do
        if gp.conn then
            local connData = connections_[gp.connKey]
            if connData then
                connData.slot = gp.slot
            end

            Shared.DelayOneFrame(function()
                local data = VariantMap()
                data["Slot"] = Variant(gp.slot)
                data["MapWidth"] = Variant(MapData.Width)
                data["MapHeight"] = Variant(MapData.Height)
                data["LevelFile"] = Variant(levelFile)
                gp.conn:SendRemoteEvent(EVENTS.ASSIGN_ROLE, true, data)
            end)
        end
    end

    -- 注册爆炸回调 → 广播给所有客户端
    -- 道具拾取广播：服务端 Remove 节点同步可能延迟，主动通知客户端立即移除视觉
    Pickup.onCollected = function(nodeId, playerIndex, size)
        if not activeGame_ then return end
        local data = VariantMap()
        data["NodeID"] = Variant(nodeId)
        data["PlayerIndex"] = Variant(playerIndex)
        data["Size"] = Variant(size or "")
        for _, gp in ipairs(activeGame_.players) do
            if gp.conn and not gp.disconnected then
                gp.conn:SendRemoteEvent(EVENTS.PICKUP_COLLECTED, true, data)
            end
        end
    end

    Player.onExplode = function(playerIndex, centerGX, centerGY, actualRadius)
        Server.BroadcastExplodeSync(playerIndex, centerGX, centerGY, actualRadius)
    end

    -- 注册死亡回调 → 广播给所有客户端
    Player.onDeath = function(playerIndex, reason, killerIndex)
        Server.BroadcastPlayerDeath(playerIndex, reason, killerIndex)
    end

    -- 开始比赛（内部调用 StartRound → Map.Build + Pickup.Reset + RandomPickup.Reset）
    GameManager.StartMatch()

    -- 状态变化回调
    GameManager.OnStateChange(function(oldState, newState)
        Server.BroadcastGameState()
        -- 比赛结束 → 清理
        if newState == GameManager.STATE_MENU then
            Server.EndGame()
        end
    end)

    print("[Server] Game started! Players: " .. #gamePlayers)
end

function Server.EndGame()
    if not activeGame_ then return end

    -- 清理房间状态
    if activeGame_.roomCode then
        local room = rooms_[activeGame_.roomCode]
        if room then
            room.state = "waiting"
            room.aiCount = 0
        end
    end

    -- 重置所有玩家连接状态（清空 slot/roomCode/inQuick，否则下一局点匹配/建房会被忽略）
    for _, gp in ipairs(activeGame_.players) do
        if gp.connKey then
            local connData = connections_[gp.connKey]
            if connData then
                connData.slot = 0
                connData.roomCode = nil
                connData.inQuick = false
            end
        end
    end

    activeGame_ = nil

    -- 移除旧的 REPLICATED 玩家节点，防止下一局 CreateChild 产生重名节点
    for _, p in ipairs(Player.list) do
        if p.node then
            p.node:Remove()
        end
    end
    Player.list = {}

    Map.Clear()

    print("[Server] Game ended, returning to lobby")
end

function Server.BroadcastGameState()
    if not activeGame_ then return end

    local data = VariantMap()
    data["State"] = Variant(GameManager.state)
    data["Round"] = Variant(GameManager.round)
    data["NumRounds"] = Variant(Config.NumRounds)
    data["RoundTimer"] = Variant(GameManager.GetRoundTime())
    data["CountdownTimer"] = Variant(GameManager.stateTimer)

    -- 分数 + 玩家状态（能量/生命/完赛）
    for i = 1, Config.NumPlayers do
        data["Score" .. i] = Variant(GameManager.scores[i])
        data["KillScore" .. i] = Variant(GameManager.killScores[i])
        local p = Player.list[i]
        if p then
            data["Energy" .. i] = Variant(p.energy or 0)
            data["Alive" .. i] = Variant(p.alive and 1 or 0)
            data["Finished" .. i] = Variant(p.finished and 1 or 0)
            data["Charging" .. i] = Variant((p.charging and 1) or 0)
            data["ChargeProg" .. i] = Variant(p.chargeProgress or 0)
        else
            data["Energy" .. i] = Variant(0)
            data["Alive" .. i] = Variant(0)
            data["Finished" .. i] = Variant(0)
            data["Charging" .. i] = Variant(0)
            data["ChargeProg" .. i] = Variant(0)
        end
    end

    -- 回合结果
    for i, playerIdx in ipairs(GameManager.roundResults) do
        data["Result" .. i] = Variant(playerIdx)
    end
    data["ResultCount"] = Variant(#GameManager.roundResults)

    -- 胜者
    local winner = GameManager.GetWinner()
    if winner then
        data["Winner"] = Variant(winner)
    end

    -- 广播给所有玩家
    for _, gp in ipairs(activeGame_.players) do
        if gp.conn and not gp.disconnected then
            gp.conn:SendRemoteEvent(EVENTS.GAME_STATE, true, data)
        end
    end
end

function Server.BroadcastKillEvent(killerIdx, victimIdx, multiKill, killStreak)
    if not activeGame_ then return end

    local data = VariantMap()
    data["Killer"] = Variant(killerIdx)
    data["Victim"] = Variant(victimIdx)
    data["MultiKill"] = Variant(multiKill)
    data["KillStreak"] = Variant(killStreak)

    for _, gp in ipairs(activeGame_.players) do
        if gp.conn and not gp.disconnected then
            gp.conn:SendRemoteEvent(EVENTS.KILL_EVENT, true, data)
        end
    end
end

function Server.BroadcastExplodeSync(playerIndex, centerGX, centerGY, actualRadius)
    if not activeGame_ then return end
    print("[Server.FX-DIAG] BroadcastExplodeSync: player=" .. playerIndex
        .. " gx=" .. centerGX .. " gy=" .. centerGY .. " r=" .. actualRadius)

    local data = VariantMap()
    data["PlayerIndex"] = Variant(playerIndex)
    data["CenterGX"] = Variant(centerGX)
    data["CenterGY"] = Variant(centerGY)
    data["Radius"] = Variant(actualRadius)

    local sentCount = 0
    for _, gp in ipairs(activeGame_.players) do
        if gp.conn and not gp.disconnected then
            gp.conn:SendRemoteEvent(EVENTS.EXPLODE_SYNC, true, data)
            sentCount = sentCount + 1
        end
    end
    print("[Server.FX-DIAG] EXPLODE_SYNC sent to " .. sentCount .. " clients")
end

function Server.BroadcastPlayerDeath(playerIndex, reason, killerIndex)
    if not activeGame_ then return end

    local data = VariantMap()
    data["PlayerIndex"] = Variant(playerIndex)
    data["Reason"] = Variant(reason or "")
    data["KillerIndex"] = Variant(killerIndex or 0)

    for _, gp in ipairs(activeGame_.players) do
        if gp.conn and not gp.disconnected then
            gp.conn:SendRemoteEvent(EVENTS.PLAYER_DEATH, true, data)
        end
    end
end

-- ============================================================================
-- Input Processing (Server reads controls.buttons from each connection)
-- ============================================================================

function Server.ProcessInputs()
    if not activeGame_ then return end

    for _, gp in ipairs(activeGame_.players) do
        if gp.conn and not gp.disconnected and not gp.isAI then
            local controls = gp.conn.controls
            local buttons = controls.buttons

            -- 查找对应玩家
            for _, p in ipairs(Player.list) do
                if p.index == gp.slot and p.isHuman then
                    p.inputMoveX = 0
                    if buttons & CTRL.LEFT ~= 0 then p.inputMoveX = -1 end
                    if buttons & CTRL.RIGHT ~= 0 then p.inputMoveX = 1 end

                    -- 脉冲按钮（上升沿检测：仅 0→1 跳变时触发，防止 pulse hold 多帧重复触发）
                    local jumpDown = (buttons & CTRL.JUMP ~= 0)
                    if jumpDown and not p.wasJumpDown then p.inputJump = true end
                    p.wasJumpDown = jumpDown

                    local dashDown = (buttons & CTRL.DASH ~= 0)
                    if dashDown and not p.wasDashDown then p.inputDash = true end
                    p.wasDashDown = dashDown

                    local explodeReleaseDown = (buttons & CTRL.EXPLODE_RELEASE ~= 0)
                    if explodeReleaseDown and not p.wasExplodeReleaseDown then
                        p.inputExplodeRelease = true
                    end
                    p.wasExplodeReleaseDown = explodeReleaseDown

                    -- 蓄力
                    local chargeDown = (buttons & CTRL.CHARGE ~= 0)
                    if chargeDown then p.inputCharging = true end
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

    -- 延迟回调
    Shared.UpdateDelayed()

    -- 快速匹配更新
    Server.UpdateQuickMatch(dt)

    -- 如果有活跃游戏 → 运行游戏逻辑
    if activeGame_ then
        -- 读取玩家输入
        Server.ProcessInputs()

        -- 更新游戏管理器
        GameManager.Update(dt)

        -- 更新地图（破坏恢复等）
        Map.Update(dt)

        -- 移动能力开放时更新 AI
        if GameManager.CanPlayersMove() then
            AIController.Update(dt)
        else
            -- 冻结所有人类输入
            for _, p in ipairs(Player.list) do
                if p.isHuman then
                    p.inputMoveX = 0
                    p.inputJump = false
                    p.inputDash = false
                    p.inputCharging = false
                    p.inputExplodeRelease = false
                end
            end
        end

        -- 更新所有玩家
        Player.UpdateAll(dt)

        -- 更新道具
        Pickup.Update(dt)
        RandomPickup.Update(dt)

        -- 定期广播游戏状态（确保客户端计时器、分数等持续同步）
        gameStateBroadcastTimer_ = gameStateBroadcastTimer_ + dt
        if gameStateBroadcastTimer_ >= GAME_STATE_BROADCAST_INTERVAL then
            gameStateBroadcastTimer_ = gameStateBroadcastTimer_ - GAME_STATE_BROADCAST_INTERVAL
            Server.BroadcastGameState()
        end
    end
end

function Server.HandlePostUpdate(dt)
    -- 服务端不需要后更新
end

return Server
