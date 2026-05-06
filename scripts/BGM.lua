-- ============================================================================
-- BGM.lua - 背景音乐系统
-- 持久 SoundSource + 防重复 + 对局曲目交替
-- ============================================================================

local BGM = {}

---@type Scene
local scene_ = nil
---@type Node|nil
local bgmNode_ = nil
---@type SoundSource|nil
local source_ = nil

-- 资源路径（assets 是资源根目录）
local TRACK_MENU       = "audio/超级红温开始界面.ogg"
local TRACK_GAMEPLAY_A = "audio/跳跳糖关卡.ogg"
local TRACK_GAMEPLAY_B = "audio/跳跳糖关卡-2.ogg"

-- 预加载
local sounds_ = {}

-- 当前曲目（用于去重）
local currentTrack_ = nil

-- 对局曲目交替计数器
local gameRoundCounter_ = 0

-- 默认音量
local DEFAULT_GAIN = 0.5

--- 初始化（仅客户端/单机调用）
---@param scene Scene
function BGM.Init(scene)
    scene_ = scene

    -- 预加载三首曲目，并设为循环
    for _, path in ipairs({ TRACK_MENU, TRACK_GAMEPLAY_A, TRACK_GAMEPLAY_B }) do
        local s = cache:GetResource("Sound", path)
        if s then
            s.looped = true
            sounds_[path] = s
            print("[BGM] Loaded: " .. path)
        else
            print("[BGM] Warning: Failed to load " .. path)
        end
    end

    -- 创建持久 SoundSource 节点（LOCAL 模式：仅客户端，避免复制冲突）
    bgmNode_ = scene_:CreateChild("BGM_Player", LOCAL)
    source_ = bgmNode_:CreateComponent("SoundSource")
    source_.soundType = "Music"
    source_.gain = DEFAULT_GAIN

    print("[BGM] Initialized")
end

--- 切换曲目（去重：相同曲目不重新播放）
---@param path string
local function PlayTrack(path)
    if source_ == nil then return end
    if currentTrack_ == path then
        -- 已经在播放此曲，避免从头打断
        return
    end
    local sound = sounds_[path]
    if sound == nil then
        print("[BGM] Track not loaded: " .. path)
        return
    end
    source_:Stop()
    source_:Play(sound)
    currentTrack_ = path
    print("[BGM] Now playing: " .. path)
end

--- 播放主菜单/匹配/房间页面 BGM
function BGM.PlayMenu()
    PlayTrack(TRACK_MENU)
end

--- 播放对局 BGM（自动在两首"跳跳糖关卡"之间交替）
function BGM.PlayGameplay()
    local track = (gameRoundCounter_ % 2 == 0) and TRACK_GAMEPLAY_A or TRACK_GAMEPLAY_B
    gameRoundCounter_ = gameRoundCounter_ + 1
    PlayTrack(track)
end

--- 停止 BGM（关卡编辑器等场景）
function BGM.Stop()
    if source_ == nil then return end
    if currentTrack_ == nil then return end
    source_:Stop()
    currentTrack_ = nil
    print("[BGM] Stopped")
end

--- 设置音量
---@param gain number
function BGM.SetGain(gain)
    if source_ then source_.gain = gain end
end

return BGM
