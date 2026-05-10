-- ============================================================================
-- Server.lua - 超级红温！ 服务端（常驻服务器模式）
-- ============================================================================
-- 职责：
--   1. 创建场景 + 地图 + 所有玩家节点（REPLICATED）
--   2. 管理客户端连接 → 分配角色
--   3. 读取 Controls → 驱动角色物理
--   4. 运行 AI、道具、计分
--   5. 通过 Remote Events 向客户端广播游戏事件
-- ============================================================================

require "LuaScripts/Utilities/Sample"

local Config   = require("Config")
local Shared   = require("Shared")
local Map      = require("Map")
local MapData  = require("MapData")
local Player   = require("Player")
local Pickup   = require("Pickup")
local AIController   = require("AIController")
local GameManager    = require("GameManager")
local RandomPickup   = require("RandomPickup")
local SFX            = require("SFX")

local EVENTS = Shared.EVENTS
local CTRL   = Shared.CTRL
local VARS   = Shared.VARS

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
-- Variables
-- ============================================================================

---@type Scene
local scene_ = nil

-- 连接管理: connKey → { connection, playerIndex }
local connections_ = {}

-- 玩家索引 → connKey（nil 表示 AI 控制）
local playerAssignments_ = {}

-- 延迟回调
local pendingCallbacks_ = {}

-- ============================================================================
-- Entry
-- ============================================================================

function Server.Start()
    SampleStart()
    print("=== " .. Config.Title .. " (Server - Persistent World) ===")

    -- 注册远程事件
    Shared.RegisterEvents()

    -- 创建场景
    scene_ = Shared.CreateScene(true)

    -- 初始化子系统（服务端不需要 Camera/HUD）
    Map.Init(scene_, true)  -- isServer=true: REPLICATED 节点，跳过视觉
    Player.Init(scene_, Map, true)  -- isServer=true: REPLICATED 节点，跳过视觉/音频
    Pickup.Init(scene_, Player, true)  -- isServer=true
    AIController.Init(Player, Map)
    SFX.Init(scene_)           -- 服务端 SFX 可以静默（无音频输出）
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, nil, true)  -- isServer=true
    RandomPickup.Init(Map, Pickup, Player)

    -- 构建地图和玩家
    Server.CreateGameContent()

    -- 订阅网络事件
    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent(EVENTS.START_GAME, "HandleStartGame")
    SubscribeToEvent(EVENTS.REQUEST_RESTART, "HandleRequestRestart")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")

    print("[Server] Started, waiting for connections...")
end

function Server.Stop()
    print("[Server] Stopped")
end

-- ============================================================================
-- Game Content
-- ============================================================================

function Server.CreateGameContent()
    -- 背景不在服务端创建（纯视觉）
    Map.Build()

    -- 创建所有玩家（全部先作为 AI）
    Player.CreateAll()

    -- 注册全部 AI
    for _, p in ipairs(Player.list) do
        AIController.Register(p)
    end

    RandomPickup.Reset()
    GameManager.InitWorld()

    -- 常驻服：服务端启动后 AI 就开始活动
    GameManager.EnterMenu()

    Shared.UpdateDeathZone(scene_)
    print("[Server] Game content created")
end

-- ============================================================================
-- Connection Handling
-- ============================================================================

--- 找到第一个未被人类占用的玩家槽位
---@return number|nil playerIndex
local function findFreeSlot()
    for _, p in ipairs(Player.list) do
        if not playerAssignments_[p.index] then
            return p.index
        end
    end
    return nil
end

--- 客户端准备就绪 → 分配角色
function HandleClientReady(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    print("[Server] ClientReady from " .. connKey)

    -- 绑定场景
    connection.scene = scene_

    -- 找空位
    local playerIndex = findFreeSlot()
    if not playerIndex then
        print("[Server] Server full, rejecting")
        connection:Disconnect()
        return
    end

    local p = Player.list[playerIndex]
    print("[Server] Assigning Player_" .. playerIndex .. " (nodeID=" .. p.node.ID .. ")")

    -- 记录分配关系
    connections_[connKey] = {
        connection = connection,
        playerIndex = playerIndex,
    }
    playerAssignments_[playerIndex] = connKey

    -- 设置为人类控制
    p.isHuman = true
    -- 从 AI 注销
    AIController.Unregister(p)

    -- 设置 Owner（客户端可通过 SmoothedTransform 平滑）
    p.node:SetOwner(connection)

    -- 设置 PulseButtonMask（防止一次性输入丢包）
    connection:SetPulseButtonMask(Shared.PULSE_BUTTONS)

    -- 延迟一帧发送 AssignRole（确保场景数据先到达客户端）
    local nodeId = p.node.ID
    local idx = playerIndex
    local conn = connection
    DelayOneFrame(function()
        local data = VariantMap()
        data["NodeId"] = Variant(nodeId)
        data["PlayerIndex"] = Variant(idx)
        conn:SendRemoteEvent(EVENTS.ASSIGN_ROLE, true, data)
        print("[Server] Sent ASSIGN_ROLE: nodeId=" .. nodeId .. " index=" .. idx)
    end)
end

--- 客户端断开 → 回收角色
function HandleClientDisconnected(eventType, eventData)
    local connection = eventData:GetPtr("Connection", "Connection")
    local connKey = tostring(connection)

    local info = connections_[connKey]
    if not info then return end

    local playerIndex = info.playerIndex
    local p = Player.list[playerIndex]
    if p then
        -- 恢复为 AI
        p.isHuman = false
        p.node:SetOwner(nil)
        AIController.Register(p)
        print("[Server] Player_" .. playerIndex .. " returned to AI")
    end

    playerAssignments_[playerIndex] = nil
    connections_[connKey] = nil
    print("[Server] Client disconnected: " .. connKey)
end

-- ============================================================================
-- Remote Event Handlers
-- ============================================================================

function HandleStartGame(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local info = connections_[connKey]
    if not info then return end

    print("[Server] StartGame requested by Player_" .. info.playerIndex)

    if GameManager.state == GameManager.STATE_MENU then
        GameManager.StartGame()
        Shared.UpdateDeathZone(scene_)

        -- 广播游戏状态给所有客户端
        Server.BroadcastGameState(GameManager.STATE_COUNTDOWN)
    end
end

function HandleRequestRestart(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)
    local info = connections_[connKey]
    if not info then return end

    print("[Server] Restart requested by Player_" .. info.playerIndex)

    if GameManager.state == GameManager.STATE_RESULT then
        GameManager.Restart()
        Shared.UpdateDeathZone(scene_)
        Server.BroadcastGameState(GameManager.STATE_COUNTDOWN)
    end
end

-- ============================================================================
-- Broadcast Helpers
-- ============================================================================

--- 广播游戏状态变更给所有已连接客户端
---@param state number
function Server.BroadcastGameState(state)
    local data = VariantMap()
    data["State"] = Variant(state)
    data["TimeLeft"] = Variant(GameManager.timeLeft or 0)
    for _, info in pairs(connections_) do
        info.connection:SendRemoteEvent(EVENTS.GAME_STATE, true, data)
    end
end

--- 广播击杀事件
---@param killerIndex number
---@param victimIndex number
---@param killType string  "dash"|"slam"|"explode"|"fall"
function Server.BroadcastKillEvent(killerIndex, victimIndex, killType)
    local data = VariantMap()
    data["KillerIndex"] = Variant(killerIndex)
    data["VictimIndex"] = Variant(victimIndex)
    data["KillType"]    = Variant(killType)
    for _, info in pairs(connections_) do
        info.connection:SendRemoteEvent(EVENTS.KILL_EVENT, true, data)
    end
end

--- 广播分数更新
---@param playerIndex number
---@param score number
function Server.BroadcastScoreUpdate(playerIndex, score)
    local data = VariantMap()
    data["PlayerIndex"] = Variant(playerIndex)
    data["Score"]       = Variant(score)
    for _, info in pairs(connections_) do
        info.connection:SendRemoteEvent(EVENTS.SCORE_UPDATE, true, data)
    end
end

-- ============================================================================
-- Update Loop
-- ============================================================================

---@param dt number
function Server.HandleUpdate(dt)
    -- 处理延迟回调
    ProcessPendingCallbacks()

    -- 读取每个人类玩家的 Controls
    for connKey, info in pairs(connections_) do
        local p = Player.list[info.playerIndex]
        if p and p.alive then
            if GameManager.CanPlayersMove() then
                Shared.ApplyControlsToPlayer(p, info.connection.controls)
            else
                -- 禁止移动时清空输入
                p.inputMoveX = 0
                p.inputJump = false
                p.inputDash = false
                p.inputCharging = false
                p.inputExplodeRelease = false
            end
        end
    end

    -- 更新游戏逻辑
    GameManager.Update(dt)
    Map.Update(dt)

    -- AI 驱动（常驻世界，AI 一直活动）
    if GameManager.CanAIMove() then
        AIController.Update(dt)
    end

    Player.UpdateAll(dt)
    Pickup.Update(dt)
    RandomPickup.Update(dt)
end

---@param dt number
function Server.HandlePostUpdate(dt)
    -- 服务端无相机，PostUpdate 可留空或做调试
end

-- ============================================================================
-- Delayed Execution
-- ============================================================================

function DelayOneFrame(callback)
    table.insert(pendingCallbacks_, callback)
end

function ProcessPendingCallbacks()
    if #pendingCallbacks_ > 0 then
        local cbs = pendingCallbacks_
        pendingCallbacks_ = {}
        for _, cb in ipairs(cbs) do cb() end
    end
end

return Server
