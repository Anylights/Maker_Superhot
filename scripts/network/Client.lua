-- ============================================================================
-- Client.lua - 超级红温！ 客户端逻辑（重构版）
-- 菜单 → 匹配 → 输入发送 → 状态读取 → HUD 渲染
-- background_match 模式：脚本先加载，ServerReady 后连接
--
-- 修复要点：
--   1. CLIENT_READY 立即发送（不等用户点击，仿 TPS 示例）
--   2. 移除 userRequestedPlay_ / clientReadySent_ 门控
--   3. TryFinishSetup 检查全部条件后才创建 Player（无 LOCAL 占位）
--   4. GAME_STATE 自动从 MENU/MATCHING 过渡
-- ============================================================================

local Client = {}

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
local HUD = require("HUD")
local SFX = require("SFX")
local Camera = require("Camera")
local RandomPickup = require("RandomPickup")
local LevelManager = require("LevelManager")
local LevelEditor = require("LevelEditor")

-- ============================================================================
-- 常量 & 快捷引用
-- ============================================================================

local CTRL = NetConfig.CTRL
local EVENTS = NetConfig.EVENTS
local VARS = NetConfig.VARS

-- ============================================================================
-- 内部状态
-- ============================================================================

---@type Scene
local scene_ = nil

-- 网络连接
local serverConn_ = nil       -- ServerConnection（ServerReady 后获取）
local connected_ = false       -- 是否已连接

-- 角色绑定
local myRoleId_ = 0            -- 被分配的角色 ID（1~4）
local myRoleNode_ = nil        -- 被分配的角色节点

-- 关键标志（仿 TPS 示例，无用户门控）
local needSendReady_ = false   -- 是否需要发送 CLIENT_READY
local setupDone_ = false       -- 玩家设置是否已完成（防重复）

-- 数据就绪标志
local mapReady_ = false        -- 地图数据是否已接收并构建
local roleAssigned_ = false    -- 是否已收到 ASSIGN_ROLE

-- 待处理
local pendingNodeId_ = 0       -- ASSIGN_ROLE 收到但节点尚未 replicate 时缓存
local pendingRoleNodes_ = {}   -- NodeAdded 事件缓存的 replicated 节点

-- 蓄力追踪（用于检测松开）
local wasChargingInput_ = false

-- ============================================================================
-- 生命周期
-- ============================================================================

function Client.Start()
    SampleStart()
    graphics.windowTitle = Config.Title
    print("=== " .. Config.Title .. " (Client) ===")

    -- 注册远程事件
    Shared.RegisterEvents()

    -- 创建场景（客户端模式：含灯光和背景）
    scene_ = Shared.CreateScene(false)

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

    -- 设置视口
    local viewport = Viewport:new(scene_, Camera.GetCamera())
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
    renderer.defaultZone.fogColor = Color(0.95, 0.82, 0.68)

    -- 创建背景
    Shared.CreateBackgroundPlane(scene_)

    -- 初始化 HUD（菜单 UI）
    HUD.Init(Player, GameManager, Map)

    -- 初始化关卡编辑器（本地功能，不依赖网络）
    LevelEditor.Init(HUD.GetNVGContext(), GameManager, Map)
    HUD.SetLevelEditor(LevelEditor)

    GameManager.EnterMenu()

    -- 订阅网络事件
    SubscribeToEvent(EVENTS.ASSIGN_ROLE, "HandleAssignRole")
    SubscribeToEvent(EVENTS.GAME_STATE, "HandleGameState")
    SubscribeToEvent(EVENTS.PLAYER_KILL, "HandlePlayerKill")
    SubscribeToEvent(EVENTS.SCORE_UPDATE, "HandleScoreUpdate")
    SubscribeToEvent(EVENTS.ROUND_RESULTS, "HandleRoundResults")
    SubscribeToEvent(EVENTS.MAP_DATA, "HandleMapData")
    SubscribeToEvent(scene_, "NodeAdded", "HandleNodeAdded")

    -- 检查连接是否已经存在（非 background_match 或已经连上）
    local conn = network:GetServerConnection()
    if conn then
        OnServerReady(conn)
    else
        SubscribeToEvent("ServerReady", "HandleServerReady")
        print("[Client] Waiting for ServerReady event (background_match mode)")
    end

    -- 关键修复：立即标记需要发送 CLIENT_READY（仿 TPS 示例）
    -- 不等用户点击菜单按钮！平台 background_match 会自动匹配
    needSendReady_ = true

    print("[Client] Started, showing menu")
end

function Client.Stop()
    print("[Client] Stopped")
end

-- ============================================================================
-- 服务器就绪处理
-- ============================================================================

function HandleServerReady(eventType, eventData)
    print("[Client] ServerReady received!")
    local conn = network:GetServerConnection()
    if conn then
        OnServerReady(conn)
    else
        print("[Client] ERROR: ServerReady fired but GetServerConnection() returned nil")
    end
end

function OnServerReady(conn)
    serverConn_ = conn
    connected_ = true

    -- 关键步骤：设置场景（必须在服务端设置 connection.scene 之前）
    serverConn_.scene = scene_

    print("[Client] Connected to server")
    -- 不在这里发送 CLIENT_READY，由 HandleUpdate 的主循环统一处理
end

-- ============================================================================
-- 远程事件处理
-- ============================================================================

--- 收到角色分配
function HandleAssignRole(eventType, eventData)
    local nodeId = eventData["NodeId"]:GetUInt()
    local roleId = eventData["RoleId"]:GetInt()

    print("[Client] ASSIGN_ROLE: NodeId=" .. nodeId .. " RoleId=" .. roleId)

    myRoleId_ = roleId
    roleAssigned_ = true

    -- 自动过渡 UI：如果还在菜单，进入匹配状态
    if GameManager.state == GameManager.STATE_MENU then
        GameManager.EnterMatching("quickStart")
    end
    -- 如果在匹配中，显示匹配完成
    if GameManager.state == GameManager.STATE_MATCHING then
        GameManager.ForceMatchingComplete()
    end

    -- 尝试绑定节点
    local roleNode = scene_:GetNode(nodeId)
    if roleNode then
        myRoleNode_ = roleNode
    else
        -- 节点尚未 replicate 完成，缓存等待
        pendingNodeId_ = nodeId
        print("[Client] Node " .. nodeId .. " not yet available, pending...")
    end

    -- 尝试完成设置（如果所有条件已满足）
    TryFinishSetup()
end

--- 收到地图数据
function HandleMapData(eventType, eventData)
    local mapGridStr = eventData["MapGrid"]:GetString()
    local levelName = eventData["LevelName"]:GetString()

    print("[Client] MAP_DATA received: level=" .. levelName .. " (" .. #mapGridStr .. " bytes)")

    -- 反序列化地图网格
    local grid, w, h = DeserializeMapGrid(mapGridStr)
    if not grid then
        print("[Client] ERROR: Failed to deserialize map grid!")
        return
    end

    -- 设置地图数据并构建
    MapData.SetDimensions(w, h)
    MapData.SetCustomGrid(grid)
    Map.Build()
    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
    Shared.UpdateDeathZone(scene_)

    mapReady_ = true
    print("[Client] Map built from server data (" .. w .. "x" .. h .. ")")

    -- 尝试完成设置
    TryFinishSetup()
end

--- 反序列化地图网格
--- 格式: "W,H|row1|row2|..." 每行用逗号分隔的方块类型
---@param str string
---@return table|nil grid, number w, number h
function DeserializeMapGrid(str)
    local parts = {}
    for part in str:gmatch("[^|]+") do
        table.insert(parts, part)
    end

    if #parts < 2 then return nil, 0, 0 end

    -- 解析尺寸
    local header = parts[1]
    local w, h = header:match("(%d+),(%d+)")
    w = tonumber(w)
    h = tonumber(h)
    if not w or not h then return nil, 0, 0 end

    -- 解析行数据
    local grid = {}
    for y = 1, h do
        grid[y] = {}
        local rowStr = parts[y + 1]
        if rowStr then
            local x = 1
            for cellStr in rowStr:gmatch("[^,]+") do
                grid[y][x] = tonumber(cellStr) or 0
                x = x + 1
            end
            -- 填充剩余列
            for xx = x, w do
                grid[y][xx] = 0
            end
        else
            -- 空行
            for x = 1, w do
                grid[y][x] = 0
            end
        end
    end

    return grid, w, h
end

-- ============================================================================
-- 玩家设置（核心修复：必须满足全部条件才创建）
-- ============================================================================

--- 尝试完成玩家设置
--- 条件：mapReady_ + roleAssigned_ + myRoleNode_ + 全部4个 REPLICATED 节点可用
--- 不满足任何条件则静默返回，等下次调用
function TryFinishSetup()
    if setupDone_ then return end
    if not mapReady_ then return end
    if not roleAssigned_ then return end
    if myRoleId_ <= 0 then return end

    -- 确保自己的角色节点已到达
    if not myRoleNode_ then
        if pendingNodeId_ ~= 0 then
            local node = scene_:GetNode(pendingNodeId_)
            if node then
                myRoleNode_ = node
                pendingNodeId_ = 0
            end
        end
        if not myRoleNode_ then return end  -- 仍未到达
    end

    -- 关键修复：检查全部4个 REPLICATED 角色节点是否已到达
    -- 不到齐则不创建任何 Player（避免 LOCAL 占位导致重复）
    for i = 1, Config.NumPlayers do
        local node = scene_:GetChild("Player_" .. i, true)
        if not node then
            print("[Client] TryFinishSetup: Player_" .. i .. " not yet replicated, waiting...")
            return
        end
    end

    -- ========== 全部条件满足，创建 Player 实例 ==========
    setupDone_ = true
    print("[Client] TryFinishSetup: All conditions met, creating players...")

    Player.list = {}
    for i = 1, Config.NumPlayers do
        local isHuman = (i == myRoleId_)
        local roleNode = scene_:GetChild("Player_" .. i, true)
        Player.Create(i, isHuman, {
            existingNode = roleNode,  -- 始终使用 REPLICATED 节点，无 LOCAL 回退
            skipVisuals = false,      -- 客户端需要视觉组件
        })
    end

    RandomPickup.Reset()
    print("[Client] Player setup complete, bound to Role_" .. myRoleId_)
end

-- ============================================================================
-- 游戏状态处理
-- ============================================================================

--- 收到游戏状态变化
function HandleGameState(eventType, eventData)
    local newState = eventData["State"]:GetString()
    local round = eventData["Round"]:GetInt()
    local timer = eventData["Timer"]:GetFloat()

    print("[Client] GAME_STATE: " .. newState .. " round=" .. round)

    -- 自动过渡：如果在菜单或匹配状态，服务端已开始游戏
    local currentState = GameManager.state
    if currentState == GameManager.STATE_MENU or currentState == GameManager.STATE_MATCHING then
        if newState ~= GameManager.STATE_MENU and newState ~= GameManager.STATE_MATCHING then
            -- 先确保进入匹配状态（用于 HUD 动画过渡）
            if currentState == GameManager.STATE_MENU then
                GameManager.EnterMatching("quickStart")
            end
            GameManager.ForceMatchingComplete()
        end
    end

    -- 设置状态数据
    GameManager.round = round
    GameManager.stateTimer = timer

    if eventData["RoundTime"] then
        local roundTime = eventData["RoundTime"]:GetFloat()
        if roundTime > 0 then
            GameManager.roundTimer = roundTime
        end
    end

    -- 直接设置状态（不走 SetState 的回调，避免循环）
    GameManager.state = newState

    -- 特殊处理：新回合开始时重置玩家状态
    if newState == GameManager.STATE_COUNTDOWN or newState == GameManager.STATE_INTRO then
        Player.ResetAll()
        Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
    end

    -- 也尝试完成设置（GAME_STATE 可能在 ASSIGN_ROLE/MAP_DATA 之后到达）
    TryFinishSetup()
end

--- 收到击杀事件
function HandlePlayerKill(eventType, eventData)
    local killerIndex = eventData["Killer"]:GetInt()
    local victimIndex = eventData["Victim"]:GetInt()
    local multiKill = eventData["MultiKill"]:GetInt()
    local killStreak = eventData["KillStreak"]:GetInt()

    local event = {
        killerIndex = killerIndex,
        victimIndex = victimIndex,
        multiKillCount = multiKill,
        killStreak = killStreak,
        time = os.clock(),
    }
    table.insert(GameManager.killEvents, event)
end

--- 收到积分更新
function HandleScoreUpdate(eventType, eventData)
    for i = 1, Config.NumPlayers do
        local scoreVar = eventData["S" .. i]
        if scoreVar and not scoreVar:IsEmpty() then
            GameManager.scores[i] = scoreVar:GetInt()
        end
        local killVar = eventData["K" .. i]
        if killVar and not killVar:IsEmpty() then
            GameManager.killScores[i] = killVar:GetInt()
        end
    end
end

--- 收到回合结算
function HandleRoundResults(eventType, eventData)
    local count = eventData["Count"]:GetInt()
    GameManager.roundResults = {}
    for place = 1, count do
        local playerIndex = eventData["Place" .. place]:GetInt()
        table.insert(GameManager.roundResults, playerIndex)
    end
end

--- NodeAdded：缓存新到达的 REPLICATED 节点
function HandleNodeAdded(eventType, eventData)
    local node = eventData["Node"]:GetPtr("Node")
    if node and node.replicated then
        table.insert(pendingRoleNodes_, node.ID)
    end
end

-- ============================================================================
-- 主更新循环
-- ============================================================================

---@param dt number
function Client.HandleUpdate(dt)
    -- ========== 立即发送 CLIENT_READY（无用户门控！） ==========
    if needSendReady_ and connected_ and serverConn_ then
        needSendReady_ = false
        serverConn_:SendRemoteEvent(EVENTS.CLIENT_READY, true)
        print("[Client] Sent CLIENT_READY (immediate, no user gate)")
    end

    -- ---- 主菜单 ----
    if GameManager.state == GameManager.STATE_MENU then
        local btn = HUD.GetMenuButtonClicked()
        if btn == "quickStart" then
            -- 菜单按钮仅控制本地 UI（匹配已由平台自动处理）
            GameManager.EnterMatching("quickStart")
            -- 如果角色+地图已就绪，立即跳过匹配动画
            if roleAssigned_ and mapReady_ then
                GameManager.ForceMatchingComplete()
            end
        elseif btn == "withFriends" then
            GameManager.EnterMatching("createRoom")
            if roleAssigned_ and mapReady_ then
                GameManager.ForceMatchingComplete()
            end
        elseif btn == "editor" then
            HUD.RefreshLevelList()
            GameManager.EnterLevelList()
        end
        return
    end

    -- ---- 匹配状态 ----
    if GameManager.state == GameManager.STATE_MATCHING then
        if input:GetKeyPress(KEY_ESCAPE) then
            GameManager.CancelMatching()
            return
        end
        -- 仅更新匹配计时器用于 HUD 显示
        GameManager.UpdateMatchingTimer(dt)
        return
    end

    -- ---- 关卡列表（本地功能） ----
    if GameManager.state == GameManager.STATE_LEVEL_LIST then
        if HUD.IsPersistClicked() then
            LevelManager.ExportToLog()
        end
        local action = HUD.GetLevelListAction()
        if action then
            if action.action == "play" then
                local grid = LevelManager.Load(action.filename)
                if grid then
                    MapData.SetCustomGrid(grid)
                    Map.Build()
                    Player.CreateAll()
                    for _, p in ipairs(Player.list) do
                        if not p.isHuman then AIController.Register(p) end
                    end
                    RandomPickup.Reset()
                    GameManager.StartTestPlay(action.filename)
                    Camera.SetFixedForMap(MapData.Width, MapData.Height, 2)
                    Shared.UpdateDeathZone(scene_)
                end
            elseif action.action == "edit" then
                Camera.ReleaseFixed()
                GameManager.EnterEditor()
                LevelEditor.LoadFile(action.filename)
                LevelEditor.Enter()
            elseif action.action == "delete" then
                LevelManager.Delete(action.filename)
                HUD.RefreshLevelList()
            elseif action.action == "new" then
                Camera.ReleaseFixed()
                GameManager.EnterEditor()
                LevelEditor.NewLevel()
                LevelEditor.Enter()
            elseif action.action == "back" then
                GameManager.ExitLevelList()
            end
        end
        return
    end

    -- ---- 关卡编辑器（本地功能） ----
    if GameManager.state == GameManager.STATE_EDITOR then
        LevelEditor.Update(dt)
        return
    end

    -- ---- 试玩模式（完全本地运行） ----
    if GameManager.testPlayMode then
        if input:GetKeyPress(KEY_ESCAPE) or HUD.IsTestPlayExitClicked() then
            GameManager.ExitTestPlay()
            HUD.RefreshLevelList()
            return
        end
        GameManager.Update(dt)
        Map.Update(dt)
        if GameManager.CanPlayersMove() then
            Client.HandleLocalPlayerInput()
            AIController.Update(dt)
        end
        Player.UpdateAll(dt)
        Pickup.Update(dt)
        RandomPickup.Update(dt)
        return
    end

    -- ========== 联机游戏运行中 ==========

    -- 处理待绑定的节点
    ProcessPendingNodes()

    -- 从 REPLICATED 节点读取状态到 Player.list
    ReadPlayerVars()

    -- 客户端计时器递减（实际状态由服务端推送）
    if GameManager.state == GameManager.STATE_COUNTDOWN then
        GameManager.stateTimer = GameManager.stateTimer - dt
    elseif GameManager.state == GameManager.STATE_RACING then
        GameManager.roundTimer = GameManager.roundTimer - dt
    elseif GameManager.state == GameManager.STATE_ROUND_END then
        GameManager.stateTimer = GameManager.stateTimer - dt
    elseif GameManager.state == GameManager.STATE_SCORE then
        GameManager.stateTimer = GameManager.stateTimer - dt
    elseif GameManager.state == GameManager.STATE_MATCH_END then
        GameManager.stateTimer = GameManager.stateTimer - dt
        if GameManager.stateTimer <= 0 then
            -- 比赛结束，回到菜单
            GameManager.EnterMenu()
            ResetNetworkState()
        end
    end

    -- 发送输入到服务端
    if connected_ and serverConn_ and GameManager.CanPlayersMove() then
        SendPlayerInput()
    end

    -- 地图视觉更新（碎片动画、方块重生动画）
    Map.Update(dt)

    -- 拾取物视觉更新
    Pickup.Update(dt)
    RandomPickup.Update(dt)
end

---@param dt number
function Client.HandlePostUpdate(dt)
    -- 相机跟随
    local positions = Player.GetAlivePositions()
    local humanPos = Player.GetHumanPosition()
    Camera.Update(dt, positions, humanPos)
end

-- ============================================================================
-- 网络状态重置（比赛结束后为下次比赛做准备）
-- ============================================================================

function ResetNetworkState()
    setupDone_ = false
    mapReady_ = false
    roleAssigned_ = false
    myRoleId_ = 0
    myRoleNode_ = nil
    pendingNodeId_ = 0
    pendingRoleNodes_ = {}
    -- 注意：connected_ 和 serverConn_ 不重置（连接可能仍然有效）
    -- needSendReady_ 也不设为 true，因为下次比赛需要新的 ServerReady
    print("[Client] Network state reset for next match")
end

-- ============================================================================
-- 待绑定节点处理
-- ============================================================================

function ProcessPendingNodes()
    local needRetry = false

    -- 检查 ASSIGN_ROLE 待处理节点
    if pendingNodeId_ ~= 0 then
        local roleNode = scene_:GetNode(pendingNodeId_)
        if roleNode then
            pendingNodeId_ = 0
            myRoleNode_ = roleNode
            needRetry = true
        end
    end

    -- 处理 NodeAdded 缓存的 REPLICATED 节点：挂载视觉组件
    if #pendingRoleNodes_ > 0 then
        local nodesToCheck = pendingRoleNodes_
        pendingRoleNodes_ = {}
        for _, nodeId in ipairs(nodesToCheck) do
            local node = scene_:GetNode(nodeId)
            if node then
                local isRoleVar = node:GetVar(VARS.IS_ROLE)
                if not isRoleVar:IsEmpty() and isRoleVar:GetBool() then
                    local playerIdx = 0
                    local idxVar = node:GetVar(VARS.PLAYER_INDEX)
                    if not idxVar:IsEmpty() then
                        playerIdx = idxVar:GetInt()
                    end
                    -- 确保对应 Player 有视觉组件
                    if playerIdx >= 1 and playerIdx <= Config.NumPlayers then
                        local p = Player.list[playerIdx]
                        if p then
                            Player.AttachVisuals(p)
                        end
                    end
                    needRetry = true
                end
            end
        end
    end

    -- 新节点到达后，重新尝试设置（可能满足"全部4节点到齐"条件）
    if needRetry then
        TryFinishSetup()
    end
end

-- ============================================================================
-- 输入发送：写入 serverConn_.controls.buttons
-- ============================================================================

function SendPlayerInput()
    if serverConn_ == nil then return end

    local controls = serverConn_.controls
    local buttons = 0

    -- 方向键
    if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
        buttons = buttons | CTRL.MOVE_LEFT
    end
    if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
        buttons = buttons | CTRL.MOVE_RIGHT
    end

    -- 跳跃（脉冲）
    if input:GetKeyPress(KEY_SPACE) then
        buttons = buttons | CTRL.JUMP
    end

    -- 冲刺（脉冲）
    if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
        buttons = buttons | CTRL.DASH
    end

    -- 蓄力（持续）
    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
    if leftDown then
        buttons = buttons | CTRL.CHARGING
    end

    -- 爆炸松开（脉冲）
    if wasChargingInput_ and not leftDown then
        buttons = buttons | CTRL.EXPLODE_RELEASE
    end
    wasChargingInput_ = leftDown

    controls.buttons = buttons
end

-- ============================================================================
-- 状态读取：从 REPLICATED 节点 Vars 填充 Player.list
-- ============================================================================

function ReadPlayerVars()
    for i = 1, Config.NumPlayers do
        local p = Player.list[i]
        if p and p.node then
            local node = p.node

            local energyVar = node:GetVar(VARS.ENERGY)
            if not energyVar:IsEmpty() then p.energy = energyVar:GetFloat() end

            local aliveVar = node:GetVar(VARS.ALIVE)
            if not aliveVar:IsEmpty() then p.alive = aliveVar:GetBool() end

            local chargingVar = node:GetVar(VARS.CHARGING)
            if not chargingVar:IsEmpty() then p.charging = chargingVar:GetBool() end

            local chargeVar = node:GetVar(VARS.CHARGE_PROGRESS)
            if not chargeVar:IsEmpty() then p.chargeProgress = chargeVar:GetFloat() end

            local finVar = node:GetVar(VARS.FINISHED)
            if not finVar:IsEmpty() then p.finished = finVar:GetBool() end

            local finOrderVar = node:GetVar(VARS.FINISH_ORDER)
            if not finOrderVar:IsEmpty() then p.finishOrder = finOrderVar:GetInt() end

            local faceDirVar = node:GetVar(VARS.FACE_DIR)
            if not faceDirVar:IsEmpty() then p.lastFaceDir = faceDirVar:GetInt() end

            local groundVar = node:GetVar(VARS.ON_GROUND)
            if not groundVar:IsEmpty() then p.onGround = groundVar:GetBool() end

            local dashCdVar = node:GetVar(VARS.DASH_COOLDOWN)
            if not dashCdVar:IsEmpty() then p.dashCooldown = dashCdVar:GetFloat() end

            local invVar = node:GetVar(VARS.INVINCIBLE)
            if not invVar:IsEmpty() then
                p.invincibleTimer = invVar:GetBool() and 1.0 or 0
            end
        end
    end
end

-- ============================================================================
-- 本地输入处理（试玩模式专用）
-- ============================================================================

function Client.HandleLocalPlayerInput()
    for _, p in ipairs(Player.list) do
        if p.isHuman and p.alive and not p.finished then
            local moveX = 0
            if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
                moveX = -1
            elseif input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
                moveX = 1
            end
            p.inputMoveX = moveX

            if input:GetKeyPress(KEY_SPACE) then p.inputJump = true end
            if input:GetKeyPress(KEY_SHIFT) or input:GetMouseButtonPress(MOUSEB_RIGHT) then p.inputDash = true end

            local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)
            if leftDown then p.inputCharging = true end
            if p.wasChargingInput and not leftDown then p.inputExplodeRelease = true end
            p.wasChargingInput = leftDown
        end
    end
end

return Client
