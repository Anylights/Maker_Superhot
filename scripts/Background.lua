-- ============================================================================
-- Background.lua - 3D 动态背景模块
-- 渐变底色 + 旋转菱形图案（3D 物体，正确在角色/平台后方）
-- 支持多配色方案，每局自动切换
-- ============================================================================

local Config = require("Config")

local Background = {}

-- 配色方案列表（浅暖色系，与游戏风格一致）
-- 每个方案包含：渐变顶色、渐变底色、菱形颜色
local palettes_ = {
    -- 1: 温暖桃色（原配色）
    {
        top    = { 0.98, 0.85, 0.70 },
        bottom = { 0.88, 0.65, 0.60 },
        diamond = { 0.92, 0.78, 0.62, 0.35 },  -- RGBA (alpha 0~1)
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
}

-- 内部状态
local scene_ = nil              -- 场景引用（由 Create 传入）
local gradientNode_ = nil       -- 渐变条父节点
local diamondNode_ = nil        -- 菱形父节点
local diamonds_ = {}            -- 菱形子节点列表
local currentPalette_ = 1       -- 当前配色索引
local lastPaletteRound_ = 0     -- 上次切换配色的回合号

-- 菱形网格配置
local DIAMOND_Z = 3.5           -- 菱形 Z 位置（背景板Z=5，游戏物体Z≈0）
local TILE_WORLD = 3.0          -- 菱形间距（世界单位）
local DIAMOND_SIZE = 0.5        -- 菱形大小（世界单位，对角线半长）
local GRID_EXTENT = 120         -- 网格覆盖范围（世界单位，覆盖 ±60）
local SCROLL_SPEED = 1.5        -- 平移速度（世界单位/秒）
local SPIN_SPEED = 0.2          -- 自转角速度（弧度/秒）

--- 获取配色方案数量
function Background.GetPaletteCount()
    return #palettes_
end

--- 根据回合号选择配色（自动轮换，避免连续相同）
---@param round number 当前回合号
function Background.SetPaletteForRound(round)
    if round == lastPaletteRound_ then return end
    lastPaletteRound_ = round
    currentPalette_ = ((round - 1) % #palettes_) + 1
    Background.ApplyPalette()
end

--- 手动设置配色索引
---@param index number 配色索引 (1-based)
function Background.SetPalette(index)
    currentPalette_ = math.max(1, math.min(#palettes_, index))
    Background.ApplyPalette()
end

--- 应用当前配色到所有 3D 物体
function Background.ApplyPalette()
    local p = palettes_[currentPalette_]
    if not p then return end

    -- 更新渐变条颜色
    if gradientNode_ then
        local strips = 8
        for i = 0, strips - 1 do
            local stripNode = gradientNode_:GetChild("Strip" .. i, false)
            if stripNode then
                local model = stripNode:GetComponent("StaticModel")
                if model then
                    local t = (i + 0.5) / strips
                    local r = p.top[1] + (p.bottom[1] - p.top[1]) * t
                    local g = p.top[2] + (p.bottom[2] - p.top[2]) * t
                    local b = p.top[3] + (p.bottom[3] - p.top[3]) * t
                    local mat = model:GetMaterial(0)
                    if mat then
                        mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, b, 1.0)))
                        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(r * 0.3, g * 0.3, b * 0.3)))
                    end
                end
            end
        end
    end

    -- 更新菱形颜色
    if diamondNode_ then
        local dc = p.diamond
        for _, info in ipairs(diamonds_) do
            if info.mat then
                info.mat:SetShaderParameter("MatDiffColor", Variant(Color(dc[1], dc[2], dc[3], dc[4])))
                info.mat:SetShaderParameter("MatEmissiveColor", Variant(Color(dc[1] * 0.15, dc[2] * 0.15, dc[3] * 0.15)))
            end
        end
    end

    -- 更新雾颜色与渐变底色一致
    if scene_ then
        local zone = scene_:GetComponent("Zone")
        if zone then
            local fogR = (p.top[1] + p.bottom[1]) * 0.5
            local fogG = (p.top[2] + p.bottom[2]) * 0.5
            local fogB = (p.top[3] + p.bottom[3]) * 0.5
            zone.fogColor = Color(fogR, fogG, fogB)
        end
    end

    print("[Background] Applied palette #" .. currentPalette_)
end

--- 创建背景（渐变条 + 菱形网格）
--- 在 Standalone 或 Client 模式下调用一次
---@param sceneRef Scene 场景引用
---@param isLocal boolean 是否使用 LOCAL 模式创建节点（客户端需要）
function Background.Create(sceneRef, isLocal)
    scene_ = sceneRef
    local createMode = isLocal and LOCAL or REPLICATED

    -- ========== 渐变底色 ==========
    local p = palettes_[currentPalette_]
    local size = 200
    local strips = 8
    gradientNode_ = scene_:CreateChild("BackgroundGradient", createMode)
    gradientNode_.position = Vector3(0, 0, 5)

    local pbrTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

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
            -- 菱形 = 45° 旋转的扁平方块
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

    print("[Background] Created: " .. #diamonds_ .. " diamonds, palette #" .. currentPalette_)
end

--- 每帧更新菱形动画（平移 + 自转）
---@param dt number
function Background.Update(dt)
    if diamondNode_ == nil then return end

    local t = (time and time.GetElapsedTime) and time:GetElapsedTime() or 0

    -- 整体平移（向左下漂移，与菜单 NanoVG 效果一致）
    local offX = -math.fmod(t * SCROLL_SPEED, TILE_WORLD)
    -- 垂直周期是 2*TILE（错位栅格）
    local offY = math.fmod(t * SCROLL_SPEED, TILE_WORLD * 2)

    diamondNode_.position = Vector3(offX, offY, DIAMOND_Z)

    -- 自转（绕 Z 轴，在菱形 45° 基础上叠加）
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
    scene_ = nil
end

return Background
