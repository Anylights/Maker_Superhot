-- ============================================================================
-- Server.lua - 超级红温！ 联机服务端（持久世界模式）
-- 职责：连接管理、持久世界、个人会话、AI 密度管理
-- 架构：无大厅/房间/匹配 → 玩家连接即进入世界，独立 60s 会话
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
-- connData: { conn, connKey, slot, ready }
local connections_ = {}

-- 槽位池：slot → connKey 或 "AI" 或 nil（空闲）
-- slot 范围 1..MaxTotalEntities
local slots_ = {}

-- AI 管理
local aiSlots_ = {}            -- slot → { spawnSection }
local aiDensityTimer_ = 0

-- 世界是否已初始化
local worldReady_ = false
local mapSeed_ = 0

-- 服务端时间
local serverTime_ = 0

-- 广播计时器
local leaderboardTimer_ = 0
local scoreUpdateTimer_ = 0
local SCORE_UPDATE_INTERVAL = 0.5

-- ============================================================================
-- Slot Management
-- ============================================================================

--- 分配一个空闲槽位
---@return number|nil slot 编号，nil 表示已满
local function AllocateSlot()
    for i = 1, Config.MaxTotalEntities do
        if not slots_[i] then
            return i
        end
    end
    return nil
end

--- 释放槽位
---@param slot number
local function FreeSlot(slot)
    slots_[slot] = nil
end

--- 统计已使用的槽位数
---@return number humanCount, number aiCount, number totalCount
local function CountSlots()
    local humans, ais = 0, 0
    for i = 1, Config.MaxTotalEntities do
        if slots_[i] then
            if slots_[i] == "AI" then
                ais = ais + 1
            else
                humans = humans + 1
            end
        end
    end
    return humans, ais, humans + ais
end

-- ============================================================================
-- Helper: Find player by slot
-- ============================================================================

---@param slot number
---@return table|nil player
function Server.FindPlayerBySlot(slot)
    for _, p in ipairs(Player.list) do
        if p.index == slot then
            return p
        end
    end
    return nil
end

-- ============================================================================
-- Entry
-- ============================================================================

function Server.Start()
    SampleStart()
    graphics.windowTitle = Config.Title .. " [Server]"
    print("=== " .. Config.Title .. " (Server - Persistent World) ===")

    -- 网络发送频率与服务器实际 tick rate 对齐
    ---@diagnostic disable-next-line: undefined-global
    local serverTickRate = SERVER_TICK_RATE or 60
    network:SetUpdateFps(serverTickRate)
    print("[Server] network:SetUpdateFps(" .. serverTickRate .. ")")

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
    RandomPickup.Init(Map, Pickup, Player)

    -- 监听连接事件
    SubscribeToEvent("ClientConnected", "HandleClientConnected")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")

    -- 监听客户端远程事件（仅 CLIENT_READY 和 REQUEST_RESTART）
    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent(EVENTS.REQUEST_RESTART, "HandleRequestRestart")

    -- GameManager 回调
    GameManager.OnKill(function(killerIdx, victimIdx, multiKill, killStreak)
        Server.BroadcastKillEvent(killerIdx, victimIdx, multiKill, killStreak)
    end)

    GameManager.OnSessionEnd(function(playerIndex, totalScore)
        Server.OnPlayerSessionEnd(playerIndex, totalScore)
    end)

    -- 初始化世界
    Server.InitWorld()

    print("[Server] Started, waiting for connections...")
    print("[Server] All event handlers registered, server fully ready")
end

function Server.Stop()
    print("[Server] Stopped")
end

-- ============================================================================
-- World Init
-- ============================================================================

function Server.InitWorld()
    if worldReady_ then return end

    mapSeed_ = os.time()
    GameManager.InitWorld(mapSeed_)
    worldReady_ = true

    -- 注册爆炸回调 → 广播给所有客户端
    Player.onExplode = function(playerIndex, centerGX, centerGY, actualRadius)
        Server.BroadcastExplodeSync(playerIndex, centerGX, centerGY, actualRadius)
    end

    -- 注册死亡回调 → 广播给所有客户端
    Player.onDeath = function(playerIndex, reason, killerIndex)
        Server.BroadcastPlayerDeath(playerIndex, reason, killerIndex)
    end

    -- 道具拾取回调 → 广播给所有客户端
    Pickup.onCollected = function(nodeId, playerIndex, size)
        local data = VariantMap()
        data["NodeID"] = Variant(nodeId)
        data["PlayerIndex"] = Variant(playerIndex)
        data["Size"] = Variant(size or "")
        Server.BroadcastToAll(EVENTS.PICKUP_COLLECTED, data)
    end

    -- 检查点回调 → 通知对应客户端
    Player.onCheckpoint = function(playerIndex, checkpointY)
        for _, cd in pairs(connections_) do
            if cd.slot == playerIndex and cd.conn and cd.ready then
                local data = VariantMap()
                data["CheckpointY"] = Variant(checkpointY)
                cd.conn:SendRemoteEvent(EVENTS.CHECKPOINT_ACTIVATED, true, data)
                break
            end
        end
    end

    print("[Server] World initialized with seed=" .. mapSeed_)
end

-- ============================================================================
-- Scene
-- ============================================================================

function Server.CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")

    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))
    -- 禁用服务端物理插值：确保发送给客户端的是干净的物理步进位置
    physicsWorld.interpolation = false

    -- 死亡区域（底部，与大世界适配）
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
-- Connection Lookup Helper
-- ============================================================================

local function DumpConnections(label)
    local count = 0
    for k, v in pairs(connections_) do
        count = count + 1
        print("[Server] " .. label .. " conn[" .. count .. "]: key=" .. k ..
              " ready=" .. tostring(v.ready) ..
              " slot=" .. tostring(v.slot))
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
        slot = 0,
        ready = false,
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

    -- 设置 scene（客户端已准备好接收场景数据）
    connection.scene = scene_
    connData.ready = true

    -- 分配槽位
    local slot = AllocateSlot()
    if not slot then
        print("[Server] ERROR: No available slots for player " .. connKey)
        return
    end

    connData.slot = slot
    slots_[slot] = connKey

    -- 创建玩家实体
    Player.Create(slot, true, { skipVisuals = true })

    -- 延迟一帧后发送 SESSION_START（等待场景复制完成）
    Shared.DelayOneFrame(function()
        Server.SendSessionStart(connData)
    end)

    print("[Server] CLIENT_READY: assigned slot " .. slot .. " to " .. connKey)
    DumpConnections("after-ready")
end

function HandleClientDisconnected(eventType, eventData)
    local connection, connKey, connData = FindConnection(eventData)

    if connData then
        local slot = connData.slot
        if slot and slot > 0 then
            -- 结束会话
            local p = Server.FindPlayerBySlot(slot)
            if p then
                if p.session.active then
                    GameManager.EndPlayerSession(slot)
                end
                -- 移除玩家节点
                if p.node then
                    p.node:Remove()
                end
            end

            -- 从 Player.list 移除
            for i, pl in ipairs(Player.list) do
                if pl.index == slot then
                    table.remove(Player.list, i)
                    break
                end
            end

            -- 释放槽位
            FreeSlot(slot)
        end

        connections_[connKey] = nil
    end

    print("[Server] Client disconnected: " .. connKey)
end

-- ============================================================================
-- Session Management
-- ============================================================================

--- 向客户端发送 SESSION_START 并开始会话
---@param connData table
function Server.SendSessionStart(connData)
    if not connData or not connData.conn then return end

    local slot = connData.slot

    -- 开始会话（内部会重置计分 + 重生玩家）
    GameManager.StartPlayerSession(slot)

    local data = VariantMap()
    data["Slot"] = Variant(slot)
    data["MapSeed"] = Variant(mapSeed_)
    data["MapWidth"] = Variant(MapData.Width)
    data["MapHeight"] = Variant(MapData.Height)
    data["SessionDuration"] = Variant(Config.SessionDuration)
    connData.conn:SendRemoteEvent(EVENTS.SESSION_START, true, data)

    print("[Server] SESSION_START sent to slot " .. slot)
end

--- 当玩家会话结束时的回调（由 GameManager.OnSessionEnd 触发）
---@param playerIndex number
---@param totalScore number
function Server.OnPlayerSessionEnd(playerIndex, totalScore)
    -- 检查是否是 AI
    if aiSlots_[playerIndex] then
        -- AI 会话结束 → 标记待移除（在 UpdateAIDensity 中处理）
        aiSlots_[playerIndex].expired = true
        print("[Server] AI session ended, slot=" .. playerIndex .. " score=" .. totalScore)
        return
    end

    -- 找到对应的人类连接
    for _, cd in pairs(connections_) do
        if cd.slot == playerIndex and cd.conn then
            local data = VariantMap()
            data["Slot"] = Variant(playerIndex)
            data["TotalScore"] = Variant(totalScore)

            -- 获取分项得分
            local p = Server.FindPlayerBySlot(playerIndex)
            if p then
                data["HeightScore"] = Variant(p.session.heightScore)
                data["KillScore"] = Variant(p.session.killScore)
                data["PickupScore"] = Variant(p.session.pickupScore)
            end

            cd.conn:SendRemoteEvent(EVENTS.SESSION_END, true, data)
            print("[Server] SESSION_END sent to slot " .. playerIndex .. " score=" .. totalScore)
            break
        end
    end
end

--- 处理客户端请求重新开始
function HandleRequestRestart(eventType, eventData)
    print("[Server] >>> HandleRequestRestart ENTERED")
    local connection, connKey, connData = FindConnection(eventData)

    if not connData then
        print("[Server] REQUEST_RESTART: unknown connection, ignoring")
        return
    end

    local slot = connData.slot
    if not slot or slot <= 0 then
        print("[Server] REQUEST_RESTART: no slot assigned, ignoring")
        return
    end

    local p = Server.FindPlayerBySlot(slot)
    if not p then
        print("[Server] REQUEST_RESTART: player not found for slot " .. slot)
        return
    end

    -- 如果会话仍在进行，忽略
    if p.session.active then
        print("[Server] REQUEST_RESTART: session still active for slot " .. slot .. ", ignoring")
        return
    end

    -- 开始新会话（内部会重置计分 + 重生玩家）
    Shared.DelayOneFrame(function()
        Server.SendSessionStart(connData)
    end)

    print("[Server] Restarting session for slot " .. slot)
end

-- ============================================================================
-- AI Density Management
-- ============================================================================

--- 定期检查并调整 AI 密度
---@param dt number
function Server.UpdateAIDensity(dt)
    aiDensityTimer_ = aiDensityTimer_ + dt
    if aiDensityTimer_ < Config.AIDensityUpdateInterval then return end
    aiDensityTimer_ = aiDensityTimer_ - Config.AIDensityUpdateInterval

    local humanCount, aiCount, totalCount = CountSlots()

    -- 1) 清理过期 AI（会话结束的）
    for slot, aiData in pairs(aiSlots_) do
        if aiData.expired then
            Server.DespawnAI(slot)
        end
    end

    -- 重新统计
    humanCount, aiCount, totalCount = CountSlots()

    -- 如果没有人类玩家，不需要 AI
    if humanCount == 0 then
        -- 清除所有 AI
        for slot, _ in pairs(aiSlots_) do
            Server.DespawnAI(slot)
        end
        return
    end

    -- 2) 计算人类玩家所在分区
    local activeSections = {}  -- sectionIndex → humanCount
    for _, cd in pairs(connections_) do
        if cd.slot and cd.slot > 0 then
            local p = Server.FindPlayerBySlot(cd.slot)
            if p and p.node and p.session.active then
                local gridY = math.floor(p.node.position.y / Config.BlockSize)
                local section = math.floor(gridY / Config.AISectionLayers)
                activeSections[section] = (activeSections[section] or 0) + 1
            end
        end
    end

    -- 3) 统计 AI 所在分区
    local aiPerSection = {}
    for slot, aiData in pairs(aiSlots_) do
        local p = Server.FindPlayerBySlot(slot)
        if p and p.node then
            local gridY = math.floor(p.node.position.y / Config.BlockSize)
            local section = math.floor(gridY / Config.AISectionLayers)
            aiPerSection[section] = (aiPerSection[section] or 0) + 1
        end
    end

    -- 4) 在人类活跃分区中补充 AI
    -- 重新统计 totalCount（清理过期后可能变了）
    humanCount, aiCount, totalCount = CountSlots()

    for section, humansInSection in pairs(activeSections) do
        local aiInSection = aiPerSection[section] or 0
        local totalInSection = humansInSection + aiInSection
        local needed = Config.AIEntitiesPerSection - totalInSection

        if needed > 0 and totalCount < Config.MaxTotalEntities then
            local toSpawn = math.min(
                needed,
                Config.MaxTotalEntities - totalCount,
                Config.AIMaxPerSection - aiInSection
            )
            for _ = 1, toSpawn do
                Server.SpawnAI(section)
                totalCount = totalCount + 1
            end
        end
    end

    -- 5) 清除远离人类的 AI（±2 分区外）
    for slot, aiData in pairs(aiSlots_) do
        if not aiData.expired then
            local p = Server.FindPlayerBySlot(slot)
            if p and p.node then
                local gridY = math.floor(p.node.position.y / Config.BlockSize)
                local section = math.floor(gridY / Config.AISectionLayers)
                local nearHuman = false
                for s = section - 2, section + 2 do
                    if activeSections[s] then
                        nearHuman = true
                        break
                    end
                end
                if not nearHuman then
                    Server.DespawnAI(slot)
                end
            end
        end
    end
end

--- 在指定分区生成 AI
---@param section number 分区索引
function Server.SpawnAI(section)
    local slot = AllocateSlot()
    if not slot then return end

    slots_[slot] = "AI"

    -- 创建 AI 玩家实体
    local p = Player.Create(slot, false, { skipVisuals = true })
    AIController.Register(p)

    -- 定位到分区中的某个检查点或随机位置
    local sectionBaseY = section * Config.AISectionLayers
    local spawnGridY = math.max(3, sectionBaseY + math.random(0, Config.AISectionLayers - 1))
    local sx, sy = MapData.GetCheckpointSpawnPosition(spawnGridY)
    if p.node then
        p.node.position = Vector3(sx, sy, 0)
    end

    -- 开始 AI 会话
    GameManager.StartPlayerSession(slot)

    aiSlots_[slot] = { spawnSection = section }

    print("[Server] AI spawned at section " .. section .. " slot=" .. slot)
end

--- 移除指定 AI
---@param slot number
function Server.DespawnAI(slot)
    local p = Server.FindPlayerBySlot(slot)
    if p then
        if p.session.active then
            Player.EndSession(p)
        end
        -- 从 AIController 注销
        if AIController.Unregister then
            AIController.Unregister(slot)
        end
        if p.node then
            p.node:Remove()
        end
    end

    -- 从 Player.list 移除
    for i, pl in ipairs(Player.list) do
        if pl.index == slot then
            table.remove(Player.list, i)
            break
        end
    end

    FreeSlot(slot)
    aiSlots_[slot] = nil

    print("[Server] AI despawned slot=" .. slot)
end

-- ============================================================================
-- Broadcasting
-- ============================================================================

--- 广播给所有已准备的客户端
---@param eventName string
---@param data VariantMap
function Server.BroadcastToAll(eventName, data)
    for _, cd in pairs(connections_) do
        if cd.conn and cd.ready then
            cd.conn:SendRemoteEvent(eventName, true, data)
        end
    end
end

--- 广播击杀事件
function Server.BroadcastKillEvent(killerIdx, victimIdx, multiKill, killStreak)
    local data = VariantMap()
    data["Killer"] = Variant(killerIdx)
    data["Victim"] = Variant(victimIdx)
    data["MultiKill"] = Variant(multiKill)
    data["KillStreak"] = Variant(killStreak)
    Server.BroadcastToAll(EVENTS.KILL_EVENT, data)
end

--- 广播爆炸同步
function Server.BroadcastExplodeSync(playerIndex, centerGX, centerGY, actualRadius)
    local data = VariantMap()
    data["PlayerIndex"] = Variant(playerIndex)
    data["CenterGX"] = Variant(centerGX)
    data["CenterGY"] = Variant(centerGY)
    data["Radius"] = Variant(actualRadius)
    Server.BroadcastToAll(EVENTS.EXPLODE_SYNC, data)
end

--- 广播玩家死亡
function Server.BroadcastPlayerDeath(playerIndex, reason, killerIndex)
    local data = VariantMap()
    data["PlayerIndex"] = Variant(playerIndex)
    data["Reason"] = Variant(reason or "")
    data["KillerIndex"] = Variant(killerIndex or 0)
    Server.BroadcastToAll(EVENTS.PLAYER_DEATH, data)
end

--- 向指定玩家发送分数更新
---@param playerIndex number
function Server.SendScoreUpdate(playerIndex)
    local p = Server.FindPlayerBySlot(playerIndex)
    if not p then return end

    for _, cd in pairs(connections_) do
        if cd.slot == playerIndex and cd.conn and cd.ready then
            local data = VariantMap()
            data["Slot"] = Variant(playerIndex)
            data["HeightScore"] = Variant(p.session.heightScore)
            data["KillScore"] = Variant(p.session.killScore)
            data["PickupScore"] = Variant(p.session.pickupScore)
            data["TotalScore"] = Variant(p.session.totalScore)
            data["Timer"] = Variant(math.max(0, p.session.timer))
            data["MaxGridY"] = Variant(p.session.maxGridY)
            data["Alive"] = Variant(p.alive and 1 or 0)
            data["Energy"] = Variant(p.energy or 0)
            data["Charging"] = Variant((p.charging and 1) or 0)
            data["ChargeProg"] = Variant(p.chargeProgress or 0)
            cd.conn:SendRemoteEvent(EVENTS.SCORE_UPDATE, true, data)
            break
        end
    end
end

--- 广播排行榜
function Server.BroadcastLeaderboard()
    local board = GameManager.CalcLeaderboard()
    if #board == 0 then return end

    local data = VariantMap()
    local count = math.min(#board, Config.LeaderboardMaxEntries)
    data["Count"] = Variant(count)
    for i = 1, count do
        data["Index" .. i] = Variant(board[i].index)
        data["Score" .. i] = Variant(board[i].score)
        data["IsHuman" .. i] = Variant(board[i].isHuman and 1 or 0)
    end
    Server.BroadcastToAll(EVENTS.LEADERBOARD_UPDATE, data)
end

-- ============================================================================
-- Input Processing
-- ============================================================================

function Server.ProcessInputs()
    for _, cd in pairs(connections_) do
        if cd.conn and cd.ready and cd.slot > 0 then
            local controls = cd.conn.controls
            local buttons = controls.buttons

            -- 查找对应玩家
            local p = Server.FindPlayerBySlot(cd.slot)
            if p and p.isHuman then
                p.inputMoveX = 0
                if buttons & CTRL.LEFT ~= 0 then p.inputMoveX = -1 end
                if buttons & CTRL.RIGHT ~= 0 then p.inputMoveX = 1 end

                -- 脉冲按钮（上升沿检测）
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

    -- 世界未就绪则跳过
    if not worldReady_ then return end

    -- 读取玩家输入
    Server.ProcessInputs()

    -- 更新游戏管理器（管理所有会话计时器）
    GameManager.Update(dt)

    -- 更新地图（破坏恢复等）
    Map.Update(dt)

    -- 更新 AI
    AIController.Update(dt)

    -- 冻结会话未激活的人类玩家输入
    for _, p in ipairs(Player.list) do
        if p.isHuman and not p.session.active then
            p.inputMoveX = 0
            p.inputJump = false
            p.inputDash = false
            p.inputCharging = false
            p.inputExplodeRelease = false
        end
    end

    -- 更新所有玩家
    Player.UpdateAll(dt)

    -- 更新道具
    Pickup.Update(dt)
    RandomPickup.Update(dt)

    -- AI 密度管理
    Server.UpdateAIDensity(dt)

    -- 定期发送分数更新
    scoreUpdateTimer_ = scoreUpdateTimer_ + dt
    if scoreUpdateTimer_ >= SCORE_UPDATE_INTERVAL then
        scoreUpdateTimer_ = scoreUpdateTimer_ - SCORE_UPDATE_INTERVAL
        for _, cd in pairs(connections_) do
            if cd.slot and cd.slot > 0 then
                Server.SendScoreUpdate(cd.slot)
            end
        end
    end

    -- 定期广播排行榜
    leaderboardTimer_ = leaderboardTimer_ + dt
    if leaderboardTimer_ >= Config.LeaderboardUpdateInterval then
        leaderboardTimer_ = leaderboardTimer_ - Config.LeaderboardUpdateInterval
        Server.BroadcastLeaderboard()
    end
end

function Server.HandlePostUpdate(dt)
    -- 服务端不需要后更新
end

return Server
