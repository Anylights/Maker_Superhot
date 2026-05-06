-- ============================================================================
-- Background.lua - 3D 动态背景模块（持久世界版）
-- 渐变底色 + 旋转菱形图案（3D 物体，在角色/平台后方）
-- 配色随时间平滑渐变，背景跟随相机 Y 位置
-- ============================================================================

local Config = require("Config")

local Background = {}

-- 配色方案列表（浅暖色系，与游戏风格一致）
-- 每个方案包含：渐变顶色、渐变底色、菱形颜色
local palettes_ = {
    -- 1: 温暖桃色
    {
        top    = { 0.98, 0.85, 0.70 },
        bottom = { 0.88, 0.65, 0.60 },
        diamond = { 0.92, 0.78, 0.62, 0.35 },
    },
    -- 2: 薰衣草紫
    {
        top    = { 0.88, 0.82, 0.95 },
        bottom = { 0.72, 0.62, 0.85 },
        diamond = { 0.80, 0.72, 0.92, 0.35 },
    },
    -- 3: 薄荷绿
    {
        top    = { 0.82, 0.95, 0.90 },
        bottom = { 0.60, 0.82, 0.75 },
        diamond = { 0.70, 0.90, 0.82, 0.35 },
    },
    -- 4: 天空蓝
    {
        top    = { 0.82, 0.90, 0.98 },
        bottom = { 0.62, 0.72, 0.90 },
        diamond = { 0.72, 0.82, 0.95, 0.35 },
    },
    -- 5: 柠檬黄
    {
        top    = { 0.98, 0.95, 0.78 },
        bottom = { 0.92, 0.82, 0.58 },
        diamond = { 0.95, 0.90, 0.68, 0.35 },
    },
    -- 6: 落日橙（高空奖励）
    {
        top    = { 1.00, 0.75, 0.50 },
        bottom = { 0.90, 0.50, 0.35 },
        diamond = { 0.95, 0.65, 0.40, 0.35 },
    },
}

-- 内部状态
local scene_ = nil              -- 场景引用
local gradientNode_ = nil       -- 渐变条父节点
local diamondNode_ = nil        -- 菱形父节点
local diamonds_ = {}            -- 菱形子节点列表
local stripMats_ = {}           -- 渐变条材质引用（用于动态更新颜色）

-- 菱形网格配置
local DIAMOND_Z = 3.5           -- 菱形 Z 位置
local TILE_WORLD = 3.0          -- 菱形间距
local DIAMOND_SIZE = 0.5        -- 菱形大小
local GRID_EXTENT = 120         -- 网格覆盖范围（世界单位，覆盖 ±60）
local SCROLL_SPEED = 1.5        -- 平移速度
local SPIN_SPEED = 0.2          -- 自转角速度

-- 时间配色参数
local PALETTE_CYCLE_TIME = 30.0 -- 每个配色持续时间（秒），然后渐变到下一个
local BLEND_DURATION = 5.0      -- 配色过渡时间（秒）

-- 跟随相机
local lastCameraY_ = 0

--- 获取配色方案数量
function Background.GetPaletteCount()
    return #palettes_
end

-- ============================================================================
-- 时间渐变：基于游戏运行时间在配色间平滑插值
-- ============================================================================

--- 线性插值两个颜色数组
---@param a table {r,g,b} 或 {r,g,b,a}
---@param b table
---@param t number 0~1
---@return table
local function LerpColor(a, b, t)
    local result = {}
    for i = 1, math.max(#a, #b) do
        local va = a[i] or 0
        local vb = b[i] or 0
        result[i] = va + (vb - va) * t
    end
    return result
end

--- 根据时间获取混合后的配色
---@param elapsed number 运行时间（秒）
---@return table 混合配色 {top, bottom, diamond}
local function GetBlendedPalette(elapsed)
    local totalCycle = PALETTE_CYCLE_TIME + BLEND_DURATION
    local cyclePos = math.fmod(elapsed, totalCycle * #palettes_)
    local paletteFloat = cyclePos / totalCycle
    local paletteIdx = math.floor(paletteFloat) + 1
    local frac = paletteFloat - math.floor(paletteFloat)

    local curIdx = ((paletteIdx - 1) % #palettes_) + 1
    local nextIdx = (paletteIdx % #palettes_) + 1

    local cur = palettes_[curIdx]
    local nxt = palettes_[nextIdx]

    -- 在持续阶段 t=0，在过渡阶段 t=0→1
    local blendT = 0
    local holdRatio = PALETTE_CYCLE_TIME / totalCycle
    if frac > holdRatio then
        blendT = (frac - holdRatio) / (1 - holdRatio)
        blendT = math.min(1.0, math.max(0.0, blendT))
        -- 平滑插值（smoothstep）
        blendT = blendT * blendT * (3 - 2 * blendT)
    end

    return {
        top = LerpColor(cur.top, nxt.top, blendT),
        bottom = LerpColor(cur.bottom, nxt.bottom, blendT),
        diamond = LerpColor(cur.diamond, nxt.diamond, blendT),
    }
end

--- 手动设置配色索引（兼容旧接口，立即切换）
---@param index number 配色索引 (1-based)
function Background.SetPalette(index)
    -- 兼容旧接口，直接应用指定配色
    local p = palettes_[math.max(1, math.min(#palettes_, index))]
    if p then
        Background.ApplyColors(p)
    end
end

--- 兼容旧接口（不再按回合切换，改为时间驱动）
---@param round number
function Background.SetPaletteForRound(round)
    -- 不做操作，配色由 Update 中基于时间驱动
end

--- 应用颜色到所有 3D 物体
---@param p table {top, bottom, diamond}
function Background.ApplyColors(p)
    if not p then return end

    -- 更新渐变条颜色
    local strips = #stripMats_
    for i = 1, strips do
        local t = (i - 0.5) / strips
        local r = p.top[1] + (p.bottom[1] - p.top[1]) * t
        local g = p.top[2] + (p.bottom[2] - p.top[2]) * t
        local b = p.top[3] + (p.bottom[3] - p.top[3]) * t
        local mat = stripMats_[i]
        if mat then
            mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 1.0)))
            mat:SetShaderParameter("MatEmissiveColor", Variant(Color(r * 0.3, g * 0.3, b * 0.3)))
        end
    end

    -- 更新菱形颜色
    local dc = p.diamond
    for _, info in ipairs(diamonds_) do
        if info.mat then
            info.mat:SetShaderParameter("MatDiffColor", Variant(Color(dc[1], dc[2], dc[3], dc[4])))
            info.mat:SetShaderParameter("MatEmissiveColor", Variant(Color(dc[1] * 0.15, dc[2] * 0.15, dc[3] * 0.15)))
        end
    end

    -- 更新雾颜色
    if scene_ then
        local zone = scene_:GetComponent("Zone")
        if zone then
            local fogR = (p.top[1] + p.bottom[1]) * 0.5
            local fogG = (p.top[2] + p.bottom[2]) * 0.5
            local fogB = (p.top[3] + p.bottom[3]) * 0.5
            zone.fogColor = Color(fogR, fogG, fogB)
        end
    end
end

--- 创建背景（渐变条 + 菱形网格）
---@param sceneRef Scene 场景引用
---@param isLocal boolean 是否使用 LOCAL 模式创建节点
function Background.Create(sceneRef, isLocal)
    scene_ = sceneRef
    local createMode = isLocal and LOCAL or REPLICATED

    local p = palettes_[1]  -- 初始配色
    local size = 200
    local strips = 8

    -- ========== 渐变底色 ==========
    gradientNode_ = scene_:CreateChild("BackgroundGradient", createMode)
    gradientNode_.position = Vector3(0, 0, 5)

    local pbrTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")
    stripMats_ = {}

    for i = 0, strips - 1 do
        local t0 = i / strips
        local t1 = (i + 1) / strips
        local t = (t0 + t1) * 0.5
        local r = p.top[1] + (p.bottom[1] - p.top[1]) * t
        local g = p.top[2] + (p.bottom[2] - p.top[2]) * t
        local b = p.top[3] + (p.bottom[3] - p.top[3]) * t

        local stripNode = gradientNode_:CreateChild("Strip" .. i, createMode)
        local yTop = size * (1 - t0 * 2)
        local yBot = size * (1 - t1 * 2)
        stripNode.position = Vector3(0, (yTop + yBot) * 0.5, 0)
        stripNode.scale = Vector3(size * 2, yTop - yBot, 0.1)

        local model = stripNode:CreateComponent("StaticModel", createMode)
        model.model = cache:GetResource("Model", "Models/Box.mdl")
        model.castShadows = false

        local mat = Material:new()
        mat:SetTechnique(0, pbrTech)
        mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 1.0)))
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(r * 0.3, g * 0.3, b * 0.3)))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(1.0))
        model:SetMaterial(mat)

        table.insert(stripMats_, mat)
    end

    -- ========== 菱形网格 ==========
    local alphaTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml")
    local dc = p.diamond

    diamondNode_ = scene_:CreateChild("BackgroundDiamonds", createMode)
    diamondNode_.position = Vector3(0, 0, DIAMOND_Z)
    diamonds_ = {}

    local cols = math.ceil(GRID_EXTENT / TILE_WORLD)
    local rows = math.ceil(GRID_EXTENT / TILE_WORLD)
    local halfCols = math.floor(cols / 2)
    local halfRows = math.floor(rows / 2)

    for ri = -halfRows, halfRows do
        local rowOdd = (ri % 2 ~= 0) and (TILE_WORLD * 0.5) or 0
        for ci = -halfCols, halfCols do
            local wx = ci * TILE_WORLD + rowOdd
            local wy = ri * TILE_WORLD

            local dn = diamondNode_:CreateChild("D", createMode)
            dn.position = Vector3(wx, wy, 0)
            dn.rotation = Quaternion(45, Vector3.FORWARD)
            dn.scale = Vector3(DIAMOND_SIZE, DIAMOND_SIZE, 0.02)

            local dm = dn:CreateComponent("StaticModel", createMode)
            dm.model = cache:GetResource("Model", "Models/Box.mdl")
            dm.castShadows = false

            local mat = Material:new()
            mat:SetTechnique(0, alphaTech)
            mat:SetShaderParameter("MatDiffColor", Variant(Color(dc[1], dc[2], dc[3], dc[4])))
            mat:SetShaderParameter("MatEmissiveColor", Variant(Color(dc[1] * 0.15, dc[2] * 0.15, dc[3] * 0.15)))
            mat:SetShaderParameter("Metallic", Variant(0.0))
            mat:SetShaderParameter("Roughness", Variant(1.0))
            dm:SetMaterial(mat)

            table.insert(diamonds_, { node = dn, mat = mat, baseX = wx, baseY = wy })
        end
    end

    -- ========== 恢复场景光照阴影 ==========
    Background.EnsureShadows(sceneRef)

    print("[Background] Created: " .. #diamonds_ .. " diamonds (time-varying palette)")
end

--- 确保场景中的方向光启用阴影投射
---@param sceneRef Scene
function Background.EnsureShadows(sceneRef)
    -- 遍历 LightGroup 子节点，找到方向光并启用阴影
    local lightGroup = sceneRef:GetChild("LightGroup", true)
    if lightGroup then
        for i = 0, lightGroup.numChildren - 1 do
            local child = lightGroup:GetChild(i)
            local light = child:GetComponent("Light")
            if light and light.lightType == LIGHT_DIRECTIONAL then
                light.castShadows = true
                light.shadowBias = BiasParameters(0.00025, 0.5)
                light.shadowCascade = CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
                print("[Background] Enabled shadows on directional light")
            end
            -- 递归检查子节点
            for j = 0, child.numChildren - 1 do
                local grandchild = child:GetChild(j)
                local light2 = grandchild:GetComponent("Light")
                if light2 and light2.lightType == LIGHT_DIRECTIONAL then
                    light2.castShadows = true
                    light2.shadowBias = BiasParameters(0.00025, 0.5)
                    light2.shadowCascade = CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
                    print("[Background] Enabled shadows on directional light (nested)")
                end
            end
        end
    end

    -- 也检查 fallback 方向光
    local dlNode = sceneRef:GetChild("DirectionalLight", true)
    if dlNode then
        local light = dlNode:GetComponent("Light")
        if light then
            light.castShadows = true
            light.shadowBias = BiasParameters(0.00025, 0.5)
            light.shadowCascade = CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
        end
    end
end

--- 每帧更新：菱形动画 + 跟随相机 + 时间配色
---@param dt number
---@param cameraY number|nil 相机 Y 位置（用于跟随）
function Background.Update(dt, cameraY)
    if diamondNode_ == nil then return end

    local t = (time and time.GetElapsedTime) and time:GetElapsedTime() or 0

    -- 时间渐变配色
    local blended = GetBlendedPalette(t)
    Background.ApplyColors(blended)

    -- 跟随相机 Y（渐变底色 + 菱形网格都跟随）
    local targetY = cameraY or lastCameraY_
    lastCameraY_ = targetY

    if gradientNode_ then
        gradientNode_.position = Vector3(0, targetY, 5)
    end

    -- 菱形整体平移（向左下漂移）+ 跟随相机 Y
    local offX = -math.fmod(t * SCROLL_SPEED, TILE_WORLD)
    local offY = math.fmod(t * SCROLL_SPEED, TILE_WORLD * 2)

    if diamondNode_ then
        diamondNode_.position = Vector3(offX, targetY + offY, DIAMOND_Z)
    end

    -- 菱形自转
    local spinAngle = 45 + math.deg(t * SPIN_SPEED)
    local spinRot = Quaternion(spinAngle, Vector3.FORWARD)

    for _, info in ipairs(diamonds_) do
        info.node.rotation = spinRot
    end
end

--- 清理背景节点
function Background.Destroy()
    if gradientNode_ then
        gradientNode_:Remove()
        gradientNode_ = nil
    end
    if diamondNode_ then
        diamondNode_:Remove()
        diamondNode_ = nil
    end
    diamonds_ = {}
    stripMats_ = {}
    scene_ = nil
end

return Background
