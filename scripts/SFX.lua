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
function SFX.Play(name, gain)
    if scene_ == nil then return end

    local sound = sounds_[name]
    if sound == nil then return end

    -- 创建临时节点播放音效
    local sfxNode = scene_:CreateChild("SFX_" .. name, LOCAL)
    local source = sfxNode:CreateComponent("SoundSource")
    source.soundType = "Effect"
    source.gain = gain or 1.0
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
