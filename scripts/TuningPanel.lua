-- ============================================================================
-- TuningPanel.lua - 游戏内调参面板
-- 按 P 键切换显示/隐藏，运行时调节移动/跳跃/物理手感参数
-- 保存策略：滑块松手自动保存到 clientCloud（跨会话持久）
-- 仅限客户端使用（服务端不要加载此模块）
-- ============================================================================

---@diagnostic disable: undefined-global
-- cjson / fileSystem 是引擎内置全局变量

local Config = require("Config")
local UI = require("urhox-libs/UI")

local TuningPanel = {}

-- 面板状态
local visible_ = false
local uiInited_ = false
---@type Scene
local scene_ = nil

-- 保存相关
local SAVE_FILE = "tuning.json"        -- 本地缓存（仅 session 内有效，WASM 刷新会丢）
local CLOUD_KEY = "tuning_params"      -- 云端持久化 key（跨构建持久）
local cloudLoaded_ = false             -- 标记云端存档是否已加载
local cloudAvailable_ = false          -- clientCloud 是否可用
local lastSaveStatus_ = ""             -- 保存状态文本
local lastSaveTime_ = 0                -- 保存状态显示计时

-- 参数定义表
local PARAMS = {
    { key = "MoveSpeed",        label = "移动速度",       min = 2,    max = 25,   step = 0.5,  format = "%.1f" },
    { key = "JumpHeight",       label = "跳跃高度(m)",    min = 1.0,  max = 8.0,  step = 0.1,  format = "%.1f" },
    { key = "JumpRiseTime",     label = "上升时间(s)",     min = 0.05, max = 0.6,  step = 0.01, format = "%.2f" },
    { key = "JumpFallTime",     label = "下落时间(s)",     min = 0.05, max = 0.6,  step = 0.01, format = "%.2f" },
    { key = "JumpRiseExponent", label = "上升曲线指数",    min = 1.0,  max = 5.0,  step = 0.1,  format = "%.1f" },
    { key = "JumpFallExponent", label = "下落曲线指数",    min = 1.0,  max = 5.0,  step = 0.1,  format = "%.1f" },
    { key = "MaxJumps",         label = "最大跳跃次数",    min = 1,    max = 5,    step = 1,    format = "%d"   },
    { key = "AirControlRatio",  label = "空中控制系数",    min = 0.1,  max = 1.0,  step = 0.05, format = "%.2f" },
    { key = "CoyoteTime",       label = "土狼时间(s)",     min = 0,    max = 0.3,  step = 0.01, format = "%.2f" },
    { key = "JumpBufferTime",   label = "跳跃缓冲(s)",    min = 0,    max = 0.3,  step = 0.01, format = "%.2f" },
    { key = "JumpCutMultiplier",label = "松键速度衰减",    min = 0.1,  max = 1.0,  step = 0.05, format = "%.2f" },
    { key = "ApexHangThreshold",label = "顶点滞空区间",    min = 0,    max = 0.5,  step = 0.01, format = "%.2f" },
    { key = "ApexHangGravityMul",label = "滞空重力系数",   min = 0.05, max = 1.0,  step = 0.05, format = "%.2f" },
    { key = "DashSpeed",        label = "冲刺速度",       min = 5,    max = 35,   step = 1,    format = "%.1f" },
    { key = "DashDuration",     label = "冲刺时长(s)",    min = 0.05, max = 0.5,  step = 0.01, format = "%.2f" },
    { key = "DashCooldown",     label = "冲刺冷却(s)",    min = 0.5,  max = 5.0,  step = 0.1,  format = "%.1f" },
    { key = "GravityY",         label = "重力加速度",      min = -30,  max = -3,   step = 0.5,  format = "%.1f" },
    { key = "Friction",         label = "摩擦力",         min = 0,    max = 2.0,  step = 0.05, format = "%.2f" },
    { key = "LinearDamping",    label = "线性阻尼",       min = 0,    max = 1.0,  step = 0.01, format = "%.2f" },
    { key = "Mass",             label = "玩家质量",        min = 0.2,  max = 5.0,  step = 0.1,  format = "%.1f" },
}

-- ============================================================================
-- 默认值（唯一真相来源）
-- 修改默认值时只需改这里，不需要版本号
-- ============================================================================
local function GetDefaults()
    return {
        MoveSpeed        = Config.MoveSpeed,        -- 8.0
        JumpHeight       = Config.JumpHeight,       -- 3.5
        JumpRiseTime     = Config.JumpRiseTime,     -- 0.22
        JumpFallTime     = Config.JumpFallTime,     -- 0.18
        JumpRiseExponent = Config.JumpRiseExponent, -- 2.0
        JumpFallExponent = Config.JumpFallExponent, -- 2.5
        MaxJumps         = Config.MaxJumps,         -- 1
        AirControlRatio  = Config.AirControlRatio,  -- 0.7
        CoyoteTime       = Config.CoyoteTime,       -- 0.10
        JumpBufferTime   = Config.JumpBufferTime,   -- 0.10
        JumpCutMultiplier = Config.JumpCutMultiplier, -- 0.4
        ApexHangThreshold = Config.ApexHangThreshold, -- 0.15
        ApexHangGravityMul = Config.ApexHangGravityMul, -- 0.3
        DashSpeed        = Config.DashSpeed,        -- 25.0
        DashDuration     = Config.DashDuration,     -- 0.22
        DashCooldown     = Config.DashCooldown,     -- 2.0
        GravityY         = -28.0,
        Friction         = 0.3,
        LinearDamping    = 0.05,
        Mass             = 1.0,
    }
end

-- 当前值（运行时）
local currentValues_ = {}

-- UI 引用
local rootPanel_ = nil
local saveStatusLabel_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化调参面板（在 Start 中调用）
---@param sceneRef Scene
function TuningPanel.Init(sceneRef)
    scene_ = sceneRef
    cloudAvailable_ = (clientCloud ~= nil)

    -- 从 Config 读取默认值
    currentValues_ = GetDefaults()

    -- 尝试加载存档（本地同步 + 云端异步）
    TuningPanel.Load()

    -- 立即应用到 Config（影响后续创建的玩家）
    TuningPanel.ApplyAllToConfig()

    print("[TuningPanel] Initialized (cloud " .. (cloudAvailable_ and "available" or "unavailable") .. ")")
end

--- 确保 UI 库已初始化（延迟初始化，首次打开面板时）
local function EnsureUIInit()
    if uiInited_ then return end
    UI.Init({
        fonts = {
            { family = "sans", weights = { normal = "Fonts/MiSans-Regular.ttf" } }
        },
        scale = UI.Scale.DEFAULT,
    })
    uiInited_ = true
    print("[TuningPanel] UI library initialized")
end

--- 关闭时清理 UI
function TuningPanel.Shutdown()
    if visible_ then
        TuningPanel.Hide()
    end
    if uiInited_ then
        UI.Shutdown()
        uiInited_ = false
    end
end

-- ============================================================================
-- 存档读写（核心修复：不再使用 CONFIG_VERSION 丢弃，改为合并策略）
-- ============================================================================

--- 保存到云端 + 本地缓存
---@param showFeedback boolean|nil  是否在 UI 上显示保存反馈
function TuningPanel.Save(showFeedback)
    local saveData = {}
    for k, v in pairs(currentValues_) do
        saveData[k] = v
    end

    -- 1. 本地缓存（仅 session 内可用，作为快速启动备用）
    local json = cjson.encode(saveData)
    pcall(function()
        local f = File(SAVE_FILE, FILE_WRITE)
        if f then
            f:WriteString(json)
            f:Close()
        end
    end)

    -- 2. 云端持久化（跨会话、跨构建）
    if cloudAvailable_ then
        clientCloud:Set(CLOUD_KEY, saveData, {
            ok = function()
                print("[TuningPanel] Saved to cloud OK")
                lastSaveStatus_ = "已保存到云端"
                lastSaveTime_ = 3.0
                if visible_ and saveStatusLabel_ then
                    saveStatusLabel_.text = lastSaveStatus_
                    saveStatusLabel_.color = "#4CAF50"
                    saveStatusLabel_.height = 16
                end
            end,
            error = function(code, reason)
                print("[TuningPanel] Cloud save error: " .. tostring(reason))
                lastSaveStatus_ = "云端保存失败: " .. tostring(reason)
                lastSaveTime_ = 5.0
                if visible_ and saveStatusLabel_ then
                    saveStatusLabel_.text = lastSaveStatus_
                    saveStatusLabel_.color = "#F44336"
                    saveStatusLabel_.height = 16
                end
            end,
        })
    else
        -- 没有云端，只保存到本地（WASM 刷新后会丢失）
        print("[TuningPanel] Cloud unavailable, saved local only (will not persist across rebuild)")
        lastSaveStatus_ = "仅本地保存（重建后会丢失）"
        lastSaveTime_ = 5.0
        if visible_ and saveStatusLabel_ then
            saveStatusLabel_.text = lastSaveStatus_
            saveStatusLabel_.color = "#FF9800"
            saveStatusLabel_.height = 16
        end
    end
end

--- 从存档数据合并参数（无版本校验，安全合并）
--- 策略：存档中存在且当前也有的 key → 用存档值；存档中没有的新 key → 保持默认值
---@param data table 存档数据
---@param source string 来源描述
---@return boolean 是否成功合并了至少一个值
local function MergeLoadedData(data, source)
    if type(data) ~= "table" then return false end

    local merged = 0
    for k, v in pairs(data) do
        -- 跳过元数据字段（如旧的 _version）
        if type(k) == "string" and not k:match("^_") and currentValues_[k] ~= nil then
            -- 校验值在合法范围内
            local valid = true
            for _, param in ipairs(PARAMS) do
                if param.key == k then
                    if type(v) == "number" and v >= param.min and v <= param.max then
                        valid = true
                    else
                        valid = false
                        print("[TuningPanel] " .. source .. ": skipping invalid " .. k .. "=" .. tostring(v))
                    end
                    break
                end
            end
            if valid and type(v) == "number" then
                currentValues_[k] = v
                merged = merged + 1
            end
        end
    end

    if merged > 0 then
        print("[TuningPanel] Merged " .. merged .. " params from " .. source)
    end
    return merged > 0
end

--- 从本地缓存加载（同步，快速启动）
local function LoadLocal()
    if not fileSystem:FileExists(SAVE_FILE) then return false end
    local success = false
    pcall(function()
        local f = File(SAVE_FILE, FILE_READ)
        if f and f:IsOpen() then
            local str = f:ReadString()
            f:Close()
            if str and #str > 0 then
                local data = cjson.decode(str)
                success = MergeLoadedData(data, "local cache")
            end
        end
    end)
    return success
end

--- 从云端加载（异步，优先级高于本地）
local function LoadCloud()
    if not cloudAvailable_ then
        print("[TuningPanel] clientCloud not available, skipping cloud load")
        return
    end

    clientCloud:Get(CLOUD_KEY, {
        ok = function(values, iscores)
            local data = values[CLOUD_KEY]
            if data and type(data) == "table" then
                local merged = MergeLoadedData(data, "cloud")
                if merged then
                    cloudLoaded_ = true
                    -- 关键：云数据到达后，重新应用到 Config 和所有已存在的玩家物理体
                    TuningPanel.ApplyAllToConfig()
                    TuningPanel.ApplyPhysicsToExistingPlayers()
                    print("[TuningPanel] Cloud data applied to game")

                    -- 同步更新本地缓存
                    pcall(function()
                        local saveData = {}
                        for k, v in pairs(currentValues_) do
                            saveData[k] = v
                        end
                        local f = File(SAVE_FILE, FILE_WRITE)
                        if f then
                            f:WriteString(cjson.encode(saveData))
                            f:Close()
                        end
                    end)

                    -- 如果面板正在显示，重建 UI 以反映云端数据
                    if visible_ then
                        TuningPanel.BuildUI()
                    end
                end
            else
                print("[TuningPanel] No cloud data found, using defaults")
            end
        end,
        error = function(code, reason)
            print("[TuningPanel] Cloud load error: " .. tostring(reason))
        end,
    })
end

function TuningPanel.Load()
    -- 先加载本地缓存（同步，立即可用）
    LoadLocal()
    -- 再异步加载云端（到达后覆盖本地）
    LoadCloud()
end

--- 导出当前参数为 Markdown 文件到 docs/
function TuningPanel.ExportToMarkdown()
    pcall(function()
        fileSystem:CreateDir("docs")
    end)

    local lines = {}
    table.insert(lines, "# 超级红温！ 调参数据备份")
    table.insert(lines, "")
    table.insert(lines, string.format("> 导出时间: %s", os.date("%Y-%m-%d %H:%M:%S")))
    table.insert(lines, "")
    table.insert(lines, "| 参数 | 值 |")
    table.insert(lines, "|------|-----|")

    for _, param in ipairs(PARAMS) do
        local val = currentValues_[param.key]
        local formatted = string.format(param.format, val)
        table.insert(lines, string.format("| %s | %s |", param.label, formatted))
    end

    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
    table.insert(lines, "```lua")
    table.insert(lines, "-- 可直接复制到 Config.lua 使用")
    for _, param in ipairs(PARAMS) do
        local val = currentValues_[param.key]
        if param.key ~= "GravityY" and param.key ~= "Friction"
           and param.key ~= "LinearDamping" and param.key ~= "Mass" then
            local formatted = string.format(param.format, val)
            table.insert(lines, string.format("Config.%-16s = %s", param.key, formatted))
        end
    end
    table.insert(lines, "```")
    table.insert(lines, "")

    local content = table.concat(lines, "\n")
    local filename = "docs/tuning_backup.md"

    local f = File(filename, FILE_WRITE)
    if f and f:IsOpen() then
        f:WriteString(content)
        f:Close()
        print("[TuningPanel] Exported to " .. filename)
        return true
    else
        print("[TuningPanel] Failed to export to " .. filename)
        return false
    end
end

-- ============================================================================
-- 应用参数
-- ============================================================================

--- 将所有值应用到 Config 和物理系统
function TuningPanel.ApplyAllToConfig()
    Config.MoveSpeed        = currentValues_.MoveSpeed
    Config.JumpHeight       = currentValues_.JumpHeight
    Config.JumpRiseTime     = currentValues_.JumpRiseTime
    Config.JumpFallTime     = currentValues_.JumpFallTime
    Config.JumpRiseExponent = currentValues_.JumpRiseExponent
    Config.JumpFallExponent = currentValues_.JumpFallExponent
    Config.MaxJumps         = math.floor(currentValues_.MaxJumps)
    Config.AirControlRatio  = currentValues_.AirControlRatio
    Config.CoyoteTime       = currentValues_.CoyoteTime
    Config.JumpBufferTime   = currentValues_.JumpBufferTime
    Config.JumpCutMultiplier = currentValues_.JumpCutMultiplier
    Config.ApexHangThreshold = currentValues_.ApexHangThreshold
    Config.ApexHangGravityMul = currentValues_.ApexHangGravityMul
    Config.DashSpeed        = currentValues_.DashSpeed
    Config.DashDuration     = currentValues_.DashDuration
    Config.DashCooldown     = currentValues_.DashCooldown

    -- 应用物理参数（有 apply 回调的项）
    for _, param in ipairs(PARAMS) do
        if param.apply then
            param.apply(currentValues_[param.key])
        end
    end
end

-- 物理参数的 apply 回调（延迟定义，避免前向引用问题）
PARAMS[17].apply = function(val)  -- GravityY
    if scene_ then
        local pw = scene_:GetComponent("PhysicsWorld")
        if pw then pw:SetGravity(Vector3(0, val, 0)) end
    end
end

PARAMS[18].apply = function(val)  -- Friction
    TuningPanel.ApplyBodyParam("friction", val)
end

PARAMS[19].apply = function(val)  -- LinearDamping
    TuningPanel.ApplyBodyParam("linearDamping", val)
end

PARAMS[20].apply = function(val)  -- Mass
    TuningPanel.ApplyBodyParam("mass", val)
end

--- 应用物理体参数到所有玩家
---@param field string
---@param val number
function TuningPanel.ApplyBodyParam(field, val)
    local ok, Player = pcall(require, "Player")
    if not ok or not Player.list then return end
    for _, p in ipairs(Player.list) do
        if p.body then
            p.body[field] = val
        end
    end
end

--- 云数据回调后，强制将所有物理参数重新应用到已存在的玩家
--- 这解决了 TuningPanel.Init 在 Player.CreateAll 之后调用的时序问题
function TuningPanel.ApplyPhysicsToExistingPlayers()
    local ok, Player = pcall(require, "Player")
    if not ok or not Player.list then return end

    for _, p in ipairs(Player.list) do
        if p.body then
            p.body.friction = currentValues_.Friction
            p.body.linearDamping = currentValues_.LinearDamping
            p.body.mass = currentValues_.Mass
        end
    end

    -- 重力
    if scene_ then
        local pw = scene_:GetComponent("PhysicsWorld")
        if pw then
            pw:SetGravity(Vector3(0, currentValues_.GravityY, 0))
        end
    end

    print("[TuningPanel] Physics re-applied to " .. #Player.list .. " existing players")
end

-- ============================================================================
-- UI 构建
-- ============================================================================

function TuningPanel.BuildUI()
    local rows = {}

    for _, param in ipairs(PARAMS) do
        local val = currentValues_[param.key]

        local valLabel = UI.Label {
            text = string.format(param.format, val),
            fontSize = 13,
            color = "#FFD54F",
            width = 55,
            textAlign = "right",
        }

        local row = UI.Panel {
            flexDirection = "row",
            alignItems = "center",
            width = "100%",
            paddingVertical = 3,
            children = {
                UI.Label {
                    text = param.label,
                    fontSize = 13,
                    color = "#E0E0E0",
                    width = 110,
                },
                UI.Slider {
                    value = val,
                    min = param.min,
                    max = param.max,
                    step = param.step,
                    flexGrow = 1,
                    height = 24,
                    onChange = function(self, v)
                        currentValues_[param.key] = v
                        valLabel.text = string.format(param.format, v)
                        TuningPanel.ApplyAllToConfig()
                    end,
                    onChangeEnd = function(self, v)
                        -- 松手即保存
                        TuningPanel.Save(true)
                    end,
                },
                valLabel,
            }
        }
        table.insert(rows, row)
    end

    -- 保存状态标签（全局引用，云端回调可更新）
    saveStatusLabel_ = UI.Label {
        text = cloudLoaded_ and "参数已从云端恢复" or "",
        fontSize = 11,
        color = "#4CAF50",
        textAlign = "center",
        width = "100%",
        height = cloudLoaded_ and 16 or 0,
    }

    -- 云端状态指示
    local cloudStatusText = ""
    if cloudAvailable_ then
        cloudStatusText = cloudLoaded_ and "云端同步: 已连接" or "云端同步: 等待中..."
    else
        cloudStatusText = "云端同步: 不可用（仅本地保存）"
    end

    -- 底部按钮行
    table.insert(rows, UI.Panel {
        flexDirection = "row",
        justifyContent = "center",
        width = "100%",
        paddingTop = 8,
        gap = 8,
        children = {
            UI.Button {
                text = "重置默认",
                variant = "outlined",
                size = "small",
                onClick = function(self)
                    TuningPanel.ResetDefaults()
                end,
            },
            UI.Button {
                text = "手动保存",
                variant = "primary",
                size = "small",
                onClick = function(self)
                    TuningPanel.Save(true)
                    if saveStatusLabel_ then
                        saveStatusLabel_.text = "正在保存..."
                        saveStatusLabel_.color = "#FFD54F"
                        saveStatusLabel_.height = 16
                    end
                end,
            },
            UI.Button {
                text = "导出备份",
                variant = "outlined",
                size = "small",
                onClick = function(self)
                    local ok = TuningPanel.ExportToMarkdown()
                    if saveStatusLabel_ then
                        if ok then
                            saveStatusLabel_.text = "已导出到 docs/tuning_backup.md"
                            saveStatusLabel_.color = "#4CAF50"
                        else
                            saveStatusLabel_.text = "导出失败"
                            saveStatusLabel_.color = "#F44336"
                        end
                        saveStatusLabel_.height = 16
                    end
                end,
            },
            UI.Button {
                text = "关闭 [P]",
                variant = "outlined",
                size = "small",
                onClick = function(self)
                    TuningPanel.Hide()
                end,
            },
        }
    })

    -- 保存状态提示行
    table.insert(rows, saveStatusLabel_)

    -- 主面板（右上角浮窗）
    rootPanel_ = UI.Panel {
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            UI.Panel {
                position = "absolute",
                right = 10,
                top = 10,
                width = 380,
                backgroundColor = "rgba(20, 20, 30, 0.93)",
                borderRadius = 8,
                padding = 12,
                children = {
                    UI.Label {
                        text = "手感调参 [P]",
                        fontSize = 16,
                        fontWeight = "bold",
                        color = "#FFFFFF",
                        marginBottom = 4,
                        textAlign = "center",
                        width = "100%",
                    },
                    UI.Label {
                        text = cloudStatusText,
                        fontSize = 10,
                        color = cloudAvailable_ and "#66BB6A" or "#FF9800",
                        marginBottom = 6,
                        textAlign = "center",
                        width = "100%",
                    },
                    UI.Panel {
                        width = "100%", height = 1,
                        backgroundColor = "rgba(255,255,255,0.12)",
                        marginBottom = 8,
                    },
                    UI.ScrollView {
                        width = "100%",
                        maxHeight = 420,
                        children = {
                            UI.Panel {
                                width = "100%",
                                children = rows,
                            }
                        }
                    },
                }
            },
        }
    }

    UI.SetRoot(rootPanel_, true)
end

-- ============================================================================
-- 显示 / 隐藏
-- ============================================================================

function TuningPanel.Show()
    if visible_ then return end
    EnsureUIInit()
    visible_ = true
    TuningPanel.BuildUI()
    print("[TuningPanel] Shown")
end

function TuningPanel.Hide()
    if not visible_ then return end
    visible_ = false
    saveStatusLabel_ = nil
    if rootPanel_ then
        UI.SetRoot(nil, true)
        rootPanel_ = nil
    end
    print("[TuningPanel] Hidden")
end

function TuningPanel.Toggle()
    if visible_ then
        TuningPanel.Hide()
    else
        TuningPanel.Show()
    end
end

function TuningPanel.IsVisible()
    return visible_
end

--- 检查鼠标是否在面板上（用于阻止游戏输入穿透）
function TuningPanel.IsPointerOver()
    if not visible_ or not uiInited_ then return false end
    return UI.IsPointerOverUI()
end

-- ============================================================================
-- 重置
-- ============================================================================

function TuningPanel.ResetDefaults()
    currentValues_ = GetDefaults()

    TuningPanel.ApplyAllToConfig()
    TuningPanel.ApplyPhysicsToExistingPlayers()
    TuningPanel.Save(true)

    -- 重建 UI 刷新滑块位置
    if visible_ then
        TuningPanel.BuildUI()
    end

    print("[TuningPanel] Reset to defaults")
end

return TuningPanel
