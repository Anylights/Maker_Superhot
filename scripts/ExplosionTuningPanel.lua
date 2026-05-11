-- ============================================================================
-- ExplosionTuningPanel.lua - 爆炸相关调参面板
-- 按 O 键切换显示/隐藏，运行时调节爆炸/能量参数
-- 保存策略：滑块松手自动保存到 clientCloud（跨会话持久）
-- ============================================================================

---@diagnostic disable: undefined-global

local Config = require("Config")
local UI = require("urhox-libs/UI")

local ExplosionTuningPanel = {}

-- 面板状态
local visible_ = false
local uiInited_ = false
---@type Scene
local scene_ = nil

-- 保存相关
local SAVE_FILE = "explosion_tuning.json"
local CLOUD_KEY = "explosion_tuning_params"
local cloudLoaded_ = false
local cloudAvailable_ = false

-- 参数定义表
local PARAMS = {
    { key = "ExplosionWindup",    label = "爆炸前摇(s)",     min = 0.05, max = 2.0,  step = 0.05, format = "%.2f" },
    { key = "ExplosionRadius",    label = "爆炸范围(格)",    min = 1,    max = 15,   step = 1,    format = "%d"   },
    { key = "EnergyChargeTime",   label = "能量充满时间(s)", min = 2,    max = 60,   step = 1,    format = "%.0f" },
    { key = "SmallEnergyAmount",  label = "小道具能量",      min = 0.05, max = 1.0,  step = 0.05, format = "%.2f" },
    { key = "LargeEnergyAmount",  label = "大道具能量",      min = 0.05, max = 1.0,  step = 0.05, format = "%.2f" },
}

-- 默认值
local function GetDefaults()
    return {
        ExplosionWindup   = Config.ExplosionWindup,
        ExplosionRadius   = Config.ExplosionRadius,
        EnergyChargeTime  = Config.EnergyChargeTime,
        SmallEnergyAmount = Config.SmallEnergyAmount,
        LargeEnergyAmount = Config.LargeEnergyAmount,
    }
end

-- 当前值
local currentValues_ = {}

-- UI 引用
local rootPanel_ = nil
local saveStatusLabel_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

function ExplosionTuningPanel.Init(sceneRef)
    scene_ = sceneRef
    cloudAvailable_ = (clientCloud ~= nil)
    currentValues_ = GetDefaults()
    ExplosionTuningPanel.Load()
    ExplosionTuningPanel.ApplyAllToConfig()
    print("[ExplosionTuningPanel] Initialized")
end

local function EnsureUIInit()
    if uiInited_ then return end
    UI.Init({
        fonts = {
            { family = "sans", weights = { normal = "Fonts/MiSans-Regular.ttf" } }
        },
        scale = UI.Scale.DEFAULT,
    })
    uiInited_ = true
end

function ExplosionTuningPanel.Shutdown()
    if visible_ then
        ExplosionTuningPanel.Hide()
    end
    if uiInited_ then
        UI.Shutdown()
        uiInited_ = false
    end
end

-- ============================================================================
-- 存档
-- ============================================================================

function ExplosionTuningPanel.Save()
    local saveData = {}
    for k, v in pairs(currentValues_) do
        saveData[k] = v
    end

    local json = cjson.encode(saveData)
    pcall(function()
        local f = File(SAVE_FILE, FILE_WRITE)
        if f then f:WriteString(json); f:Close() end
    end)

    if cloudAvailable_ then
        clientCloud:Set(CLOUD_KEY, saveData, {
            ok = function()
                print("[ExplosionTuningPanel] Saved to cloud OK")
                if visible_ and saveStatusLabel_ then
                    saveStatusLabel_.text = "已保存到云端"
                    saveStatusLabel_.color = "#4CAF50"
                    saveStatusLabel_.height = 16
                end
            end,
            error = function(code, reason)
                print("[ExplosionTuningPanel] Cloud save error: " .. tostring(reason))
                if visible_ and saveStatusLabel_ then
                    saveStatusLabel_.text = "云端保存失败"
                    saveStatusLabel_.color = "#F44336"
                    saveStatusLabel_.height = 16
                end
            end,
        })
    end
end

local function MergeLoadedData(data, source)
    if type(data) ~= "table" then return false end
    local merged = 0
    for k, v in pairs(data) do
        if type(k) == "string" and not k:match("^_") and currentValues_[k] ~= nil then
            local valid = true
            for _, param in ipairs(PARAMS) do
                if param.key == k then
                    if type(v) == "number" and v >= param.min and v <= param.max then
                        valid = true
                    else
                        valid = false
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
        print("[ExplosionTuningPanel] Merged " .. merged .. " params from " .. source)
    end
    return merged > 0
end

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

local function LoadCloud()
    if not cloudAvailable_ then return end
    clientCloud:Get(CLOUD_KEY, {
        ok = function(values)
            local data = values[CLOUD_KEY]
            if data and type(data) == "table" then
                local merged = MergeLoadedData(data, "cloud")
                if merged then
                    cloudLoaded_ = true
                    ExplosionTuningPanel.ApplyAllToConfig()
                    if visible_ then ExplosionTuningPanel.BuildUI() end
                end
            end
        end,
        error = function(code, reason)
            print("[ExplosionTuningPanel] Cloud load error: " .. tostring(reason))
        end,
    })
end

function ExplosionTuningPanel.Load()
    LoadLocal()
    LoadCloud()
end

-- ============================================================================
-- 应用参数
-- ============================================================================

function ExplosionTuningPanel.ApplyAllToConfig()
    Config.ExplosionWindup   = currentValues_.ExplosionWindup
    Config.ExplosionRadius   = math.floor(currentValues_.ExplosionRadius)
    Config.EnergyChargeTime  = currentValues_.EnergyChargeTime
    Config.SmallEnergyAmount = currentValues_.SmallEnergyAmount
    Config.LargeEnergyAmount = currentValues_.LargeEnergyAmount
end

-- ============================================================================
-- UI 构建
-- ============================================================================

function ExplosionTuningPanel.BuildUI()
    local rows = {}

    for _, param in ipairs(PARAMS) do
        local val = currentValues_[param.key]

        local valLabel = UI.Label {
            text = string.format(param.format, val),
            fontSize = 13,
            color = "#FF8A65",
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
                    width = 120,
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
                        ExplosionTuningPanel.ApplyAllToConfig()
                    end,
                    onChangeEnd = function(self, v)
                        ExplosionTuningPanel.Save()
                    end,
                },
                valLabel,
            }
        }
        table.insert(rows, row)
    end

    saveStatusLabel_ = UI.Label {
        text = cloudLoaded_ and "参数已从云端恢复" or "",
        fontSize = 11,
        color = "#4CAF50",
        textAlign = "center",
        width = "100%",
        height = cloudLoaded_ and 16 or 0,
    }

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
                    ExplosionTuningPanel.ResetDefaults()
                end,
            },
            UI.Button {
                text = "关闭 [O]",
                variant = "outlined",
                size = "small",
                onClick = function(self)
                    ExplosionTuningPanel.Hide()
                end,
            },
        }
    })

    table.insert(rows, saveStatusLabel_)

    -- 主面板（左上角浮窗，避免与手感调参面板重叠）
    rootPanel_ = UI.Panel {
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            UI.Panel {
                position = "absolute",
                left = 10,
                top = 10,
                width = 340,
                backgroundColor = "rgba(30, 15, 10, 0.93)",
                borderRadius = 8,
                padding = 12,
                children = {
                    UI.Label {
                        text = "爆炸调参 [O]",
                        fontSize = 16,
                        fontWeight = "bold",
                        color = "#FF8A65",
                        marginBottom = 4,
                        textAlign = "center",
                        width = "100%",
                    },
                    UI.Panel {
                        width = "100%", height = 1,
                        backgroundColor = "rgba(255,255,255,0.12)",
                        marginBottom = 8,
                    },
                    UI.Panel {
                        width = "100%",
                        children = rows,
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

function ExplosionTuningPanel.Show()
    if visible_ then return end
    EnsureUIInit()
    visible_ = true
    ExplosionTuningPanel.BuildUI()
    print("[ExplosionTuningPanel] Shown")
end

function ExplosionTuningPanel.Hide()
    if not visible_ then return end
    visible_ = false
    saveStatusLabel_ = nil
    if rootPanel_ then
        UI.SetRoot(nil, true)
        rootPanel_ = nil
    end
    print("[ExplosionTuningPanel] Hidden")
end

function ExplosionTuningPanel.Toggle()
    if visible_ then
        ExplosionTuningPanel.Hide()
    else
        ExplosionTuningPanel.Show()
    end
end

function ExplosionTuningPanel.IsVisible()
    return visible_
end

function ExplosionTuningPanel.IsPointerOver()
    if not visible_ or not uiInited_ then return false end
    return UI.IsPointerOverUI()
end

function ExplosionTuningPanel.ResetDefaults()
    currentValues_ = GetDefaults()
    ExplosionTuningPanel.ApplyAllToConfig()
    ExplosionTuningPanel.Save()
    if visible_ then ExplosionTuningPanel.BuildUI() end
    print("[ExplosionTuningPanel] Reset to defaults")
end

return ExplosionTuningPanel
