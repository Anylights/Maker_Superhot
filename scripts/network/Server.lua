-- ============================================================================
-- Server.lua - 超级红温！ 服务端逻辑（重构版）
-- 角色池 + 等待玩家 + 物理模拟 + 状态广播
--
-- 修复要点：
--   1. 移除 ClientIdentity 处理器，PulseButtonMask 合并到 HandleClientReady
--   2. 分离 EnsureMapBuilt() 和 TryStartGame()
--   3. 等待计时器仅在第一个客户端连接时设置一次，不再重置
--   4. ASSIGN_ROLE + MAP_DATA 在同一个 DelayOneFrame 中一起发送
-- ============================================================================

local Server = {}

require "LuaScripts/Utilities/Sample"

local Config = require("Config")
local NetConfig = require("NetConfig")
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
local Camera = require("Camera")

-- ============================================================================
-- Mock graphics for headless server
-- ============================================================================

if GetGraphics() == nil then
    local mockGraphics = {
        SetWindowIcon = function() end,
        SetWindowTitleAndIcon = function() end,
        GetWidth = function() return 1920 end,
        GetHeight = function() return 1080 end,
        GetDPR = function() return 1.0 end,
    }
    function GetGraphics() return mockGraphics end
    graphics = mockGraphics
    console = { background = {} }
    function GetConsole() return console end
    debugHud = {}
    function GetDebugHud() return debugHud end
end

-- ============================================================================
-- 常量 & 快捷引用
-- ============================================================================

local CTRL = NetConfig.CTRL
local EVENTS = NetConfig.EVENTS
local VARS = NetConfig.VARS
local PULSE_MASK = NetConfig.PULSE_MASK

-- 等待超时时间（秒）：第一个玩家连接后，最多等待这么久就开始
-- 设为 5 秒，给所有客户端充足的连接时间
local START_WAIT_TIME = 5.0

-- ============================================================================
-- 内部状态
-- ============================================================================

---@type Scene
local scene_ = nil

-- 角色池：rolePool_[roleId] = Node (REPLICATED)
local rolePool_ = {}
-- 角色分配：roleAssignments_[roleId] = connKey | nil
local roleAssignments_ = {}
-- 连接 → 角色映射：connectionRoles_[connKey] = roleId
local connectionRoles_ = {}
-- 连接实例缓存：serverConnections_[connKey] = Connection
local serverConnections_ = {}

-- 延迟回调
local pendingCallbacks_ = {}

-- ========== 游戏状态 ==========
local gameStarted_ = false        -- 游戏是否已经开始
local mapBuilt_ = false           -- 地图是否已构建
local waitTimer_ = -1             -- 等待计时器（-1 = 未激活）
local connectedPlayerCount_ = 0   -- 已连接的真人玩家数

-- 选中的关卡数据
local selectedLevelGrid_ = nil
local selectedLevelName_ = nil
local serializedMapData_ = nil    -- 缓存的序列化地图数据

-- ============================================================================
-- 生命周期
-- ============================================================================

function Server.Start()
    SampleStart()
    print("=== " .. Config.Title .. " (Server) ===")

    -- 注册远程事件
    Shared.RegisterEvents()

    -- 创建场景（服务端模式：无灯光、无背景）
    scene_ = Shared.CreateScene(true)

    -- 初始化子系统
    Map.Init(scene_)
    Player.Init(scene_, Map)
    Pickup.Init(scene_, Player)
    AIController.Init(Player, Map)
    SFX.Init(scene_)
    Camera.Init(scene_)
    GameManager.Init(Player, Map, Pickup, AIController, RandomPickup, Camera)
    RandomPickup.Init(Map, Pickup)
    LevelManager.Init()

    -- 创建角色池（REPLICATED 节点，需要在客户端连接前创建）
    CreateRolePool()

    -- 注册 GameManager 回调
    GameManager.OnStateChange(function(oldState, newState)
        BroadcastGameState(newState)
    end)
    GameManager.OnKill(function(killerIndex, victimIndex, multiKillCount, killStreak)
        BroadcastPlayerKill(killerIndex, victimIndex, multiKillCount, killStreak)
    end)

    -- 订阅连接事件
    -- 注意：不再订阅 ClientIdentity，PulseButtonMask 在 HandleClientReady 中设置
    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")

    gameStarted_ = false
    mapBuilt_ = false
    waitTimer_ = -1
    connectedPlayerCount_ = 0

    print("[Server] Started, waiting for players... (max " .. Config.NumPlayers .. ")")
end

function Server.Stop()
    print("[Server] Stopped")
end

-- ============================================================================
-- 角色池创建
-- ============================================================================

function CreateRolePool()
    for roleId = 1, Config.NumPlayers do
        local defaultX = roleId * 2
        local defaultY = 3

        -- REPLICATED 节点：位置/物理自动同步到客户端
        local roleNode = scene_:CreateChild("Player_" .. roleId, REPLICATED)
        roleNode.position = Vector3(defaultX, defaultY, 0)

        -- 物理组件（REPLICATED 自动同步）
        local body = roleNode:CreateComponent("RigidBody", REPLICATED)
        body.mass = 1.0
        body.friction = 0.3
        body.linearDamping = 0.05
        body.collisionLayer = 2
        body.collisionMask = 0xFFFF
        body.collisionEventMode = COLLISION_ALWAYS
        body.linearFactor = Vector3(1, 1, 0)
        body.angularFactor = Vector3(0, 0, 0)

        local shape = roleNode:CreateComponent("CollisionShape", REPLICATED)
        shape:SetCapsule(0.9, 1.0)

        -- 标记变量（客户端用于识别角色节点）
        roleNode:SetVar(VARS.IS_ROLE, Variant(true))
        roleNode:SetVar(VARS.PLAYER_INDEX, Variant(roleId))

        rolePool_[roleId] = roleNode
        roleAssignments_[roleId] = nil

        print("[Server] Created Role_" .. roleId .. " (ID: " .. roleNode.ID .. ")")
    end
end

-- ============================================================================
-- 懒加载地图构建（首个客户端连接时触发）
-- ============================================================================

--- 确保地图已构建（仅构建一次，结果缓存）
function EnsureMapBuilt()
    if mapBuilt_ then return end
    mapBuilt_ = true

    -- 选择随机关卡
    selectedLevelGrid_, selectedLevelName_ = LevelManager.GetRandom()
    if selectedLevelGrid_ then
        MapData.SetCustomGrid(selectedLevelGrid_)
        print("[Server] Selected level: " .. tostring(selectedLevelName_))
    else
        MapData.ClearCustomGrid()
        print("[Server] No custom levels, using default map")
    end

    Map.Build()
    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
    Shared.UpdateDeathZone(scene_)

    -- 更新角色池节点的出生位置
    for roleId = 1, Config.NumPlayers do
        local spawnX, spawnY = MapData.GetSpawnPosition(roleId)
        local roleNode = rolePool_[roleId]
        if roleNode then
            roleNode.position = Vector3(spawnX, spawnY, 0)
            local body = roleNode:GetComponent("RigidBody")
            if body then
                body:SetLinearVelocity(Vector3.ZERO)
                body:SetAngularVelocity(Vector3.ZERO)
            end
        end
    end

    -- 缓存序列化地图数据
    serializedMapData_ = SerializeMapGrid()
    print("[Server] Map built and cached (" .. #serializedMapData_ .. " bytes)")
end

-- ============================================================================
-- 游戏启动
-- ============================================================================

--- 当条件满足时启动游戏
function TryStartGame()
    if gameStarted_ then return end
    gameStarted_ = true

    -- 确保地图已构建（防御性调用）
    EnsureMapBuilt()

    -- 用角色池节点创建 Player 实例
    Player.list = {}
    for roleId = 1, Config.NumPlayers do
        local isHuman = (roleAssignments_[roleId] ~= nil)
        Player.Create(roleId, isHuman, {
            existingNode = rolePool_[roleId],
            skipVisuals = true,  -- 服务端不需要视觉组件
        })
    end

    -- 所有未分配的角色注册为 AI
    for roleId = 1, Config.NumPlayers do
        if roleAssignments_[roleId] == nil then
            local p = Player.list[roleId]
            if p then
                p.isHuman = false
                AIController.Register(p)
            end
        end
    end

    RandomPickup.Reset()

    -- 开始比赛（触发 OnStateChange → BroadcastGameState 给所有客户端）
    GameManager.StartMatch()

    print("[Server] Match started with " .. connectedPlayerCount_ .. " human players + " .. (Config.NumPlayers - connectedPlayerCount_) .. " AI")
end

-- ============================================================================
-- 角色查找
-- ============================================================================

function FindFreeRole()
    for roleId = 1, Config.NumPlayers do
        if roleAssignments_[roleId] == nil then
            return roleId
        end
    end
    return nil
end

-- ============================================================================
-- 连接管理
-- ============================================================================

--- 客户端准备就绪 → 设置脉冲按键 + 分配角色 + 发送地图数据
function HandleClientReady(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local connKey = tostring(connection)

    print("[Server] ClientReady received from " .. connKey)

    -- ① 设置脉冲按键掩码（从 ClientIdentity 合并到这里）
    connection:SetPulseButtonMask(PULSE_MASK)

    -- ② 分配场景
    connection.scene = scene_

    -- ③ 查找空闲角色
    local roleId = FindFreeRole()
    if roleId == nil then
        print("[Server] Server full, rejecting connection")
        connection:Disconnect()
        return
    end

    local roleNode = rolePool_[roleId]
    print("[Server] Assigning Role_" .. roleId .. " (NodeID: " .. roleNode.ID .. ") to " .. connKey)

    -- ④ 记录映射
    roleAssignments_[roleId] = connKey
    connectionRoles_[connKey] = roleId
    serverConnections_[connKey] = connection
    connectedPlayerCount_ = connectedPlayerCount_ + 1

    -- ⑤ 设置所有权（客户端可以对此节点发送 controls）
    roleNode:SetOwner(connection)

    -- ⑥ 确保地图已构建（首个客户端触发懒加载）
    EnsureMapBuilt()

    -- ⑦ 如果游戏已经开始，将 AI 切换为人类控制
    if gameStarted_ then
        local p = Player.list[roleId]
        if p then
            p.isHuman = true
            AIController.Unregister(p)
        end
    end

    -- ⑧ 延迟一帧发送 ASSIGN_ROLE + MAP_DATA（确保 REPLICATED 节点和 Vars 已同步）
    local nodeId = roleNode.ID
    local conn = connection
    local rid = roleId
    DelayOneFrame(function()
        -- 发送角色分配
        local assignData = VariantMap()
        assignData["NodeId"] = Variant(nodeId)
        assignData["RoleId"] = Variant(rid)
        conn:SendRemoteEvent(EVENTS.ASSIGN_ROLE, true, assignData)

        -- 紧跟着发送地图数据（同一帧，避免时序问题）
        local mapData = VariantMap()
        mapData["MapGrid"] = Variant(serializedMapData_)
        mapData["LevelName"] = Variant(selectedLevelName_ or "default")
        conn:SendRemoteEvent(EVENTS.MAP_DATA, true, mapData)

        print("[Server] Sent ASSIGN_ROLE(NodeId=" .. nodeId .. ",RoleId=" .. rid .. ") + MAP_DATA to " .. tostring(conn))

        -- 如果游戏已经开始，同步当前状态给后来的玩家
        if gameStarted_ then
            local stateData = VariantMap()
            stateData["State"] = Variant(GameManager.state)
            stateData["Round"] = Variant(GameManager.round)
            stateData["Timer"] = Variant(GameManager.stateTimer)
            stateData["RoundTime"] = Variant(GameManager.roundTimer)
            conn:SendRemoteEvent(EVENTS.GAME_STATE, true, stateData)

            BroadcastScoreUpdate()
        end
    end)

    -- ⑨ 等待逻辑
    if not gameStarted_ then
        if connectedPlayerCount_ >= Config.NumPlayers then
            -- 所有位置都有真人，立即开始
            print("[Server] All " .. Config.NumPlayers .. " slots filled, starting immediately!")
            DelayOneFrame(function()
                TryStartGame()
            end)
        elseif waitTimer_ < 0 then
            -- 第一个玩家连接：启动等待计时器（仅此一次，不再重置！）
            waitTimer_ = START_WAIT_TIME
            print("[Server] First player connected, wait timer started (" .. START_WAIT_TIME .. "s)")
        end
        -- 后续玩家连接不重置计时器，这是与旧代码的关键区别
    end
end

--- 客户端断开连接 → 释放角色，切回 AI
function HandleClientDisconnected(eventType, eventData)
    local connection = eventData:GetPtr("Connection", "Connection")
    local connKey = tostring(connection)

    local roleId = connectionRoles_[connKey]
    if roleId then
        print("[Server] Client disconnected, releasing Role_" .. roleId)

        roleAssignments_[roleId] = nil
        connectedPlayerCount_ = math.max(0, connectedPlayerCount_ - 1)

        local roleNode = rolePool_[roleId]
        if roleNode then
            roleNode:SetOwner(nil)
        end

        -- 切回 AI 控制
        local p = Player.list[roleId]
        if p then
            p.isHuman = false
            AIController.Register(p)
        end
    end

    connectionRoles_[connKey] = nil
    serverConnections_[connKey] = nil
end

-- ============================================================================
-- 主更新循环
-- ============================================================================

---@param dt number
function Server.HandleUpdate(dt)
    -- 处理延迟回调
    ProcessPendingCallbacks()

    -- ========== 等待玩家阶段 ==========
    if not gameStarted_ then
        if waitTimer_ >= 0 then
            waitTimer_ = waitTimer_ - dt
            if waitTimer_ <= 0 then
                print("[Server] Wait timer expired, starting with " .. connectedPlayerCount_ .. " humans + AI")
                TryStartGame()
            end
        end
        return  -- 游戏未开始，不执行游戏逻辑
    end

    -- ========== 游戏进行中 ==========

    -- 读取所有真人玩家的输入
    ReadPlayerInputs()

    -- 游戏逻辑更新
    GameManager.Update(dt)
    Map.Update(dt)

    if GameManager.CanPlayersMove() then
        AIController.Update(dt)
    else
        -- 冻结所有玩家输入
        for _, p in ipairs(Player.list) do
            p.inputMoveX = 0
            p.inputJump = false
            p.inputDash = false
            p.inputCharging = false
            p.inputExplodeRelease = false
        end
    end

    Player.UpdateAll(dt)
    Pickup.Update(dt)
    RandomPickup.Update(dt)

    -- 同步玩家状态变量到 REPLICATED 节点
    SyncPlayerVars()
end

---@param dt number
function Server.HandlePostUpdate(dt)
    -- 服务端不需要相机更新
end

-- ============================================================================
-- 输入读取：从 connection.controls.buttons 解码
-- ============================================================================

function ReadPlayerInputs()
    for roleId, connKey in pairs(roleAssignments_) do
        if connKey then
            local connection = serverConnections_[connKey]
            local p = Player.list[roleId]

            if connection and p and p.alive and not p.finished then
                local buttons = connection.controls.buttons

                -- 持续状态按键
                local moveLeft = (buttons & CTRL.MOVE_LEFT) ~= 0
                local moveRight = (buttons & CTRL.MOVE_RIGHT) ~= 0
                if moveLeft and not moveRight then
                    p.inputMoveX = -1
                elseif moveRight and not moveLeft then
                    p.inputMoveX = 1
                else
                    p.inputMoveX = 0
                end

                p.inputCharging = (buttons & CTRL.CHARGING) ~= 0

                -- 脉冲按键（由 PulseButtonMask 保证 reliable 传输）
                p.inputJump = (buttons & CTRL.JUMP) ~= 0
                p.inputDash = (buttons & CTRL.DASH) ~= 0
                p.inputExplodeRelease = (buttons & CTRL.EXPLODE_RELEASE) ~= 0
            end
        end
    end
end

-- ============================================================================
-- 状态同步
-- ============================================================================

--- 将 Player 数据写入 REPLICATED 节点 Vars（客户端读取）
function SyncPlayerVars()
    for roleId = 1, Config.NumPlayers do
        local p = Player.list[roleId]
        local node = rolePool_[roleId]
        if p and node then
            node:SetVar(VARS.ENERGY, Variant(p.energy))
            node:SetVar(VARS.ALIVE, Variant(p.alive))
            node:SetVar(VARS.CHARGING, Variant(p.charging))
            node:SetVar(VARS.CHARGE_PROGRESS, Variant(p.chargeProgress))
            node:SetVar(VARS.FINISHED, Variant(p.finished))
            node:SetVar(VARS.FINISH_ORDER, Variant(p.finishOrder))
            node:SetVar(VARS.FACE_DIR, Variant(p.lastFaceDir))
            node:SetVar(VARS.ON_GROUND, Variant(p.onGround))
            node:SetVar(VARS.DASH_COOLDOWN, Variant(p.dashCooldown))
            node:SetVar(VARS.INVINCIBLE, Variant(p.invincibleTimer > 0))
        end
    end
end

-- ============================================================================
-- 地图数据序列化
-- ============================================================================

--- 序列化关卡网格为字符串
--- 格式: "W,H|row1|row2|..." 每行用逗号分隔的方块类型
---@return string
function SerializeMapGrid()
    local w = MapData.Width
    local h = MapData.Height
    local parts = { w .. "," .. h }

    for y = 1, h do
        local row = {}
        for x = 1, w do
            local cell = 0
            if selectedLevelGrid_ and selectedLevelGrid_[y] and selectedLevelGrid_[y][x] then
                cell = selectedLevelGrid_[y][x]
            end
            row[x] = tostring(cell)
        end
        table.insert(parts, table.concat(row, ","))
    end

    return table.concat(parts, "|")
end

-- ============================================================================
-- 网络广播
-- ============================================================================

--- 广播游戏状态变化
---@param newState string
function BroadcastGameState(newState)
    local eventData = VariantMap()
    eventData["State"] = Variant(newState)
    eventData["Round"] = Variant(GameManager.round)
    eventData["Timer"] = Variant(GameManager.stateTimer)
    eventData["RoundTime"] = Variant(GameManager.roundTimer)

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.GAME_STATE, true, eventData)
    end
    print("[Server] Broadcast GAME_STATE: " .. newState)
end

--- 广播击杀事件
---@param killerIndex number
---@param victimIndex number
---@param multiKillCount number
---@param killStreak number
function BroadcastPlayerKill(killerIndex, victimIndex, multiKillCount, killStreak)
    local eventData = VariantMap()
    eventData["Killer"] = Variant(killerIndex)
    eventData["Victim"] = Variant(victimIndex)
    eventData["MultiKill"] = Variant(multiKillCount)
    eventData["KillStreak"] = Variant(killStreak)

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.PLAYER_KILL, true, eventData)
    end
end

--- 广播积分更新
function BroadcastScoreUpdate()
    local eventData = VariantMap()
    for i = 1, Config.NumPlayers do
        eventData["S" .. i] = Variant(GameManager.scores[i])
        eventData["K" .. i] = Variant(GameManager.killScores[i])
    end

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.SCORE_UPDATE, true, eventData)
    end
end

--- 广播回合结算
function BroadcastRoundResults()
    local eventData = VariantMap()
    for place, playerIndex in ipairs(GameManager.roundResults) do
        eventData["Place" .. place] = Variant(playerIndex)
    end
    eventData["Count"] = Variant(#GameManager.roundResults)

    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(EVENTS.ROUND_RESULTS, true, eventData)
    end
end

-- ============================================================================
-- 延迟执行工具
-- ============================================================================

function DelayOneFrame(callback)
    table.insert(pendingCallbacks_, callback)
end

function ProcessPendingCallbacks()
    if #pendingCallbacks_ > 0 then
        local callbacks = pendingCallbacks_
        pendingCallbacks_ = {}
        for _, cb in ipairs(callbacks) do
            cb()
        end
    end
end

return Server
