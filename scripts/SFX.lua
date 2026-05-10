-- ============================================================================
-- SFX.lua - 音效系统
-- 使用 SoundSource（2D）播放游戏音效
-- ============================================================================

local SFX = {}

---@type Scene
local scene_ = nil

-- 预加载的音效资源
local sounds_ = {}

-- 音效文件映射
local SFX_FILES = {
    explosion    = "audio/sfx/explosion.ogg",
    jump         = "audio/sfx/jump.ogg",
    dash         = "audio/sfx/dash.ogg",
    pickup_small = "audio/sfx/pickup_small.ogg",
    pickup_large = "audio/sfx/pickup_large.ogg",
    death        = "audio/sfx/death.ogg",
    countdown    = "audio/sfx/countdown_tick.ogg",
    go           = "audio/sfx/countdown_go.ogg",
    round_end    = "audio/sfx/round_end.ogg",
    match_ready  = "audio/sfx/match_ready.ogg",
}

--- 初始化音效系统
---@param scene Scene
function SFX.Init(scene)
    scene_ = scene

    -- 预加载所有音效
    for name, path in pairs(SFX_FILES) do
        local sound = cache:GetResource("Sound", path)
        if sound then
            sounds_[name] = sound
            print("[SFX] Loaded: " .. name)
        else
            print("[SFX] Warning: Failed to load " .. path)
        end
    end

    print("[SFX] Initialized with " .. SFX.Count() .. " sounds")
end

--- 播放音效
---@param name string 音效名称
---@param gain number|nil 音量（默认 1.0）
---@param wx number|nil 世界 X 坐标（传入时做摄像机视野裁剪）
---@param wy number|nil 世界 Y 坐标
function SFX.Play(name, gain, wx, wy)
    if scene_ == nil then return end

    local sound = sounds_[name]
    if sound == nil then return end

    -- 带世界坐标时：检查是否在摄像机视野内（加 margin），否则不播放
    local finalGain = gain or 1.0
    if wx ~= nil and wy ~= nil then
        local Camera = require("Camera")
        if Camera.camera and Camera.node then
            local camPos = Camera.node.position
            local ortho = Camera.camera.orthoSize
            local aspect = Camera.camera.aspectRatio
            if aspect <= 0 then aspect = 16.0 / 9.0 end
            local halfH = ortho * 0.5
            local halfW = halfH * aspect
            -- 加 50% margin，视野边缘外一点的音效也能听到（衰减播放）
            local marginW = halfW * 1.5
            local marginH = halfH * 1.5
            local dx = math.abs(wx - camPos.x)
            local dy = math.abs(wy - camPos.y)
            if dx > marginW or dy > marginH then
                return  -- 完全超出范围，不播放
            end
            -- 视野边缘处衰减音量
            local distRatio = math.max(dx / halfW, dy / halfH)
            if distRatio > 1.0 then
                local fade = 1.0 - (distRatio - 1.0) / 0.5  -- 1.0~1.5 范围线性衰减
                finalGain = finalGain * math.max(0.05, fade)
            end
        end
    end

    -- 创建临时节点播放音效
    local sfxNode = scene_:CreateChild("SFX_" .. name, LOCAL)
    local source = sfxNode:CreateComponent("SoundSource")
    source.soundType = "Effect"
    source.gain = finalGain
    source.autoRemoveMode = REMOVE_NODE
    source:Play(sound)
end

--- 已加载音效数量
---@return number
function SFX.Count()
    local count = 0
    for _ in pairs(sounds_) do count = count + 1 end
    return count
end

return SFX
