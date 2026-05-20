-- ============================================================================
-- FaceSkin.lua - 面部皮肤定义模块（纯装饰，不影响属性）
-- 每个皮肤通过修改眼球参数 + 新增 Box 配件节点实现表情变化
-- ============================================================================

local FaceSkin = {}

-- ============================================================================
-- 皮肤定义
-- ============================================================================

---@class SkinEyeOverride
---@field scaleMul number|nil    半径倍率（默认1.0）
---@field offsetX number|nil     X偏移增量
---@field offsetY number|nil     Y偏移增量
---@field flattenY number|nil    Y轴压扁倍率（<1=压扁）
---@field rotZ number|nil        Z轴旋转角度
---@field visible boolean|nil    是否可见（默认true）

---@class SkinAccessoryDef
---@field name string            子节点名
---@field pos Vector3             相对位置
---@field scale Vector3           缩放
---@field rot table|nil           旋转 {angle, axis} 或 nil
---@field colorFromOutline boolean 是否使用描边色（true=描边色, false=自定义黑色）

---@class SkinDef
---@field id string
---@field name string
---@field desc string
---@field price number
---@field icon string
---@field eyeL SkinEyeOverride|nil
---@field eyeR SkinEyeOverride|nil
---@field accessories SkinAccessoryDef[]

local skins = {
    -- 1. 默认（免费）
    {
        id    = "default",
        name  = "默认表情",
        desc  = "经典双眼，朴实无华",
        price = 0,
        icon  = "😐",
        eyeL  = nil,
        eyeR  = nil,
        accessories = {},
    },

    -- 2. 墨镜酷哥（贴图版）
    {
        id    = "sunglasses",
        name  = "墨镜酷哥",
        desc  = "戴上墨镜，谁都不怕",
        price = 300,
        icon  = "😎",
        eyeL  = { visible = false },
        eyeR  = { visible = false },
        accessories = {
            -- 墨镜贴图（Plane + 透明纹理）
            {
                name    = "SkinAcc_Glasses",
                pos     = { 0, 0.06, -0.52 },
                scale   = { 0.70, 0.70, 1.0 },
                rot     = nil,
                texture = "image/sunglasses.png",  -- 使用贴图
                colorFromOutline = false,
            },
        },
    },

    -- 3. 不屑脸
    {
        id    = "disdain",
        name  = "不屑脸",
        desc  = "一副看不起你的样子",
        price = 400,
        icon  = "😏",
        eyeL  = { scaleMul = 1.0, offsetY = 0.0 },
        eyeR  = { scaleMul = 0.7, offsetY = 0.05, flattenY = 0.6 },
        accessories = {
            -- 歪嘴（小斜条）
            {
                name = "SkinAcc_Smirk",
                pos  = { 0.10, -0.20, -0.50 },
                scale = { 0.14, 0.025, 0.03 },
                rot   = { -15, "FORWARD" },
                colorFromOutline = true,
            },
        },
    },

    -- 4. 萌萌脸
    {
        id    = "cute",
        name  = "萌萌脸",
        desc  = "大眼睛水汪汪",
        price = 350,
        icon  = "🥺",
        eyeL  = { scaleMul = 1.5, offsetY = -0.03 },
        eyeR  = { scaleMul = 1.5, offsetY = -0.03 },
        accessories = {
            -- 左腮红
            {
                name = "SkinAcc_BlushL",
                pos  = { -0.25, -0.10, -0.50 },
                scale = { 0.08, 0.04, 0.02 },
                rot   = nil,
                colorFromOutline = false,
            },
            -- 右腮红
            {
                name = "SkinAcc_BlushR",
                pos  = { 0.25, -0.10, -0.50 },
                scale = { 0.08, 0.04, 0.02 },
                rot   = nil,
                colorFromOutline = false,
            },
        },
    },

    -- 5. 坏笑脸
    {
        id    = "evil",
        name  = "坏笑脸",
        desc  = "倒V眉毛，满脸坏笑",
        price = 500,
        icon  = "😈",
        eyeL  = { scaleMul = 0.9, flattenY = 0.65, rotZ = 15 },
        eyeR  = { scaleMul = 0.9, flattenY = 0.65, rotZ = -15 },
        accessories = {
            -- 左尖角眉
            {
                name = "SkinAcc_BrowL",
                pos  = { -0.18, 0.22, -0.50 },
                scale = { 0.16, 0.030, 0.03 },
                rot   = { 20, "FORWARD" },
                colorFromOutline = true,
            },
            -- 右尖角眉
            {
                name = "SkinAcc_BrowR",
                pos  = { 0.18, 0.22, -0.50 },
                scale = { 0.16, 0.030, 0.03 },
                rot   = { -20, "FORWARD" },
                colorFromOutline = true,
            },
        },
    },

    -- 6. 暴怒脸
    {
        id    = "angry",
        name  = "暴怒脸",
        desc  = "气到变形，双眉紧锁",
        price = 400,
        icon  = "😡",
        eyeL  = { scaleMul = 0.85, flattenY = 0.5 },
        eyeR  = { scaleMul = 0.85, flattenY = 0.5 },
        accessories = {
            -- V形怒眉左
            {
                name = "SkinAcc_AngryBrowL",
                pos  = { -0.14, 0.22, -0.50 },
                scale = { 0.18, 0.035, 0.03 },
                rot   = { -25, "FORWARD" },
                colorFromOutline = true,
            },
            -- V形怒眉右
            {
                name = "SkinAcc_AngryBrowR",
                pos  = { 0.14, 0.22, -0.50 },
                scale = { 0.18, 0.035, 0.03 },
                rot   = { 25, "FORWARD" },
                colorFromOutline = true,
            },
        },
    },

    -- 7. 死鱼眼
    {
        id    = "dead_fish",
        name  = "死鱼眼",
        desc  = "两颗小豆豆，无精打采",
        price = 250,
        icon  = "😑",
        eyeL  = { scaleMul = 0.5 },
        eyeR  = { scaleMul = 0.5 },
        accessories = {},
    },

    -- 8. 独眼怪
    {
        id    = "cyclops",
        name  = "独眼怪",
        desc  = "一只大眼，威慑全场",
        price = 600,
        icon  = "🧿",
        eyeL  = { scaleMul = 2.0, offsetX = 0.16 },  -- 居中（原本 -0.16，+0.16 回到 0）
        eyeR  = { visible = false },
        accessories = {},
    },
}

-- 按 ID 索引
local skinById = {}
for _, s in ipairs(skins) do
    skinById[s.id] = s
end

-- NanoVG 贴图缓存（避免每帧重复加载）
local nvgImageCache = {}  -- { [path] = imageHandle }

-- ============================================================================
-- 公共 API
-- ============================================================================

---@return SkinDef[]
function FaceSkin.GetAll()
    return skins
end

---@param id string
---@return SkinDef|nil
function FaceSkin.GetById(id)
    return skinById[id]
end

---@return number
function FaceSkin.GetCount()
    return #skins
end

---@return string
function FaceSkin.GetDefaultId()
    return "default"
end

--- 获取皮肤对左右眼的参数覆盖，用于 Player.Create 存储到 p 表
---@param skinId string
---@param baseX number  眼睛基础 X（0.16）
---@param baseY number  眼睛基础 Y（0.06）
---@param baseR number  眼睛基础半径（0.22）
---@return table overrides { eyeBaseX_L, eyeBaseY_L, eyeRadius_L, eyeVisible_L, eyeFlattenY_L, eyeRotZ_L, ... R }
function FaceSkin.GetEyeOverrides(skinId, baseX, baseY, baseR)
    local def = skinById[skinId]
    local result = {
        eyeBaseX_L   = baseX,
        eyeBaseY_L   = baseY,
        eyeRadius_L  = baseR,
        eyeVisible_L = true,
        eyeFlattenY_L = 1.0,
        eyeRotZ_L    = 0,
        eyeBaseX_R   = baseX,
        eyeBaseY_R   = baseY,
        eyeRadius_R  = baseR,
        eyeVisible_R = true,
        eyeFlattenY_R = 1.0,
        eyeRotZ_R    = 0,
    }
    if not def then return result end

    -- 左眼
    if def.eyeL then
        local e = def.eyeL
        result.eyeRadius_L  = baseR * (e.scaleMul or 1.0)
        result.eyeBaseX_L   = baseX - (e.offsetX or 0)  -- 左眼X为负值,offsetX正=向右移=X绝对值减小
        result.eyeBaseY_L   = baseY + (e.offsetY or 0)
        result.eyeVisible_L = (e.visible ~= false)
        result.eyeFlattenY_L = e.flattenY or 1.0
        result.eyeRotZ_L    = e.rotZ or 0
    end
    -- 右眼
    if def.eyeR then
        local e = def.eyeR
        result.eyeRadius_R  = baseR * (e.scaleMul or 1.0)
        result.eyeBaseX_R   = baseX + (e.offsetX or 0)  -- 右眼X为正值
        result.eyeBaseY_R   = baseY + (e.offsetY or 0)
        result.eyeVisible_R = (e.visible ~= false)
        result.eyeFlattenY_R = e.flattenY or 1.0
        result.eyeRotZ_R    = e.rotZ or 0
    end

    return result
end

--- 在 visualNode 上创建皮肤配件子节点
---@param visualNode any  角色视觉节点
---@param skinId string
---@param outlineColor Color  描边颜色（用于 colorFromOutline=true 的配件）
function FaceSkin.ApplyToVisual(visualNode, skinId, outlineColor)
    if not visualNode then return end
    local def = skinById[skinId]
    if not def or #def.accessories == 0 then return end

    local boxModel = cache:GetResource("Model", "Models/Box.mdl")
    local planeModel = cache:GetResource("Model", "Models/Plane.mdl")
    local unlitTech = cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")
    local unlitAlphaTech = cache:GetResource("Technique", "Techniques/DiffUnlit.xml")

    for _, acc in ipairs(def.accessories) do
        local accNode = visualNode:CreateChild(acc.name)
        accNode.position = Vector3(acc.pos[1], acc.pos[2], acc.pos[3])
        accNode.scale = Vector3(acc.scale[1], acc.scale[2], acc.scale[3])

        if acc.rot then
            local axis = Vector3.FORWARD
            if acc.rot[2] == "RIGHT" then axis = Vector3.RIGHT
            elseif acc.rot[2] == "UP" then axis = Vector3.UP end
            accNode.rotation = Quaternion(acc.rot[1], axis)
        end

        local model = accNode:CreateComponent("StaticModel")
        model.castShadows = false

        if acc.texture then
            -- 贴图配件：用 Plane 模型 + 透明贴图
            model.model = planeModel
            -- Plane 默认朝上(Y+)，需旋转到朝前(Z-)面对相机
            local baseRot = accNode.rotation or Quaternion.IDENTITY
            accNode.rotation = baseRot * Quaternion(90, Vector3.RIGHT)
            local mat = Material:new()
            mat:SetTechnique(0, unlitAlphaTech)
            local tex = cache:GetResource("Texture2D", acc.texture)
            if tex then
                mat:SetTexture(TU_DIFFUSE, tex)
            end
            mat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
            model:SetMaterial(mat)
        else
            -- 纯色配件：用 Box 模型
            model.model = boxModel
            local mat = Material:new()
            mat:SetTechnique(0, unlitTech)
            if acc.colorFromOutline then
                mat:SetShaderParameter("MatDiffColor", Variant(outlineColor))
            else
                if string.find(acc.name, "Blush") then
                    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.95, 0.45, 0.50, 1.0)))
                else
                    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.05, 0.05, 0.05, 1.0)))
                end
            end
            model:SetMaterial(mat)
        end
    end
end

--- 移除 visualNode 上所有皮肤配件节点（以 "SkinAcc_" 开头）
---@param visualNode any
function FaceSkin.RemoveAccessories(visualNode)
    if not visualNode then return end
    -- 收集要移除的节点（不能在遍历中删除）
    local toRemove = {}
    local numCh = visualNode:GetNumChildren(false)
    for i = 0, numCh - 1 do
        local child = visualNode:GetChild(i)
        if child and child.name and string.sub(child.name, 1, 8) == "SkinAcc_" then
            toRemove[#toRemove + 1] = child
        end
    end
    for _, child in ipairs(toRemove) do
        child:Remove()
    end
end

--- NanoVG 商店预览绘制（简化 2D 版）
---@param vg number NanoVG 上下文
---@param cx number 中心 X
---@param cy number 中心 Y
---@param size number 方块边长
---@param skinId string
---@param bodyColor Color
---@param outlineColor Color
function FaceSkin.DrawPreview(vg, cx, cy, size, skinId, bodyColor, outlineColor)
    local def = skinById[skinId]
    if not def then def = skins[1] end

    local halfSize = size * 0.5
    local cornerR = math.floor(size * 0.18)

    -- 描边层
    local outPad = 3
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - halfSize - outPad, cy - halfSize - outPad,
        size + outPad * 2, size + outPad * 2, cornerR + 1)
    nvgFillColor(vg, nvgRGBA(
        math.floor(outlineColor.r * 255),
        math.floor(outlineColor.g * 255),
        math.floor(outlineColor.b * 255), 255))
    nvgFill(vg)

    -- 身体方块
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - halfSize, cy - halfSize, size, size, cornerR)
    nvgFillColor(vg, nvgRGBA(
        math.floor(bodyColor.r * 255),
        math.floor(bodyColor.g * 255),
        math.floor(bodyColor.b * 255), 255))
    nvgFill(vg)

    -- 眼睛参数（2D映射）
    local eyeGap = size * 0.20   -- 基础眼间距
    local eyeY = cy - size * 0.06
    local eyeR = size * 0.14     -- 基础眼半径

    local oR = math.floor(outlineColor.r * 255)
    local oG = math.floor(outlineColor.g * 255)
    local oB = math.floor(outlineColor.b * 255)

    -- 左眼
    local drawL = true
    local lx, ly, lr = cx - eyeGap, eyeY, eyeR
    local lFlatten = 1.0
    local lRotZ = 0
    if def.eyeL then
        lr = eyeR * (def.eyeL.scaleMul or 1.0)
        lx = lx + (def.eyeL.offsetX or 0) * size
        ly = ly - (def.eyeL.offsetY or 0) * size
        lFlatten = def.eyeL.flattenY or 1.0
        lRotZ = def.eyeL.rotZ or 0
        if def.eyeL.visible == false then drawL = false end
    end

    -- 右眼
    local drawR = true
    local rx, ry, rr = cx + eyeGap, eyeY, eyeR
    local rFlatten = 1.0
    local rRotZ = 0
    if def.eyeR then
        rr = eyeR * (def.eyeR.scaleMul or 1.0)
        rx = rx + (def.eyeR.offsetX or 0) * size
        ry = ry - (def.eyeR.offsetY or 0) * size
        rFlatten = def.eyeR.flattenY or 1.0
        rRotZ = def.eyeR.rotZ or 0
        if def.eyeR.visible == false then drawR = false end
    end

    -- 绘制眼睛
    if drawL then
        nvgSave(vg)
        nvgTranslate(vg, lx, ly)
        if lRotZ ~= 0 then nvgRotate(vg, math.rad(lRotZ)) end
        nvgBeginPath(vg)
        nvgEllipse(vg, 0, 0, lr, lr * lFlatten)
        nvgFillColor(vg, nvgRGBA(oR, oG, oB, 255))
        nvgFill(vg)
        nvgRestore(vg)
    end
    if drawR then
        nvgSave(vg)
        nvgTranslate(vg, rx, ry)
        if rRotZ ~= 0 then nvgRotate(vg, math.rad(rRotZ)) end
        nvgBeginPath(vg)
        nvgEllipse(vg, 0, 0, rr, rr * rFlatten)
        nvgFillColor(vg, nvgRGBA(oR, oG, oB, 255))
        nvgFill(vg)
        nvgRestore(vg)
    end

    -- 配件绘制（简化 2D）
    for _, acc in ipairs(def.accessories) do
        local ax = cx + acc.pos[1] * size
        local ay = cy - acc.pos[2] * size
        local aw = acc.scale[1] * size
        local ah = acc.scale[2] * size

        if acc.texture then
            -- 贴图配件：用 nvgImagePattern 绘制
            if not nvgImageCache[acc.texture] then
                nvgImageCache[acc.texture] = nvgCreateImage(vg, acc.texture, 0)
            end
            local imgHandle = nvgImageCache[acc.texture]
            if imgHandle and imgHandle ~= 0 then
                nvgSave(vg)
                nvgTranslate(vg, ax, ay)
                if acc.rot then
                    nvgRotate(vg, math.rad(-acc.rot[1]))
                end
                local paint = nvgImagePattern(vg, -aw * 0.5, -ah * 0.5, aw, ah, 0, imgHandle, 1.0)
                nvgBeginPath(vg)
                nvgRect(vg, -aw * 0.5, -ah * 0.5, aw, ah)
                nvgFillPaint(vg, paint)
                nvgFill(vg)
                nvgRestore(vg)
            end
        else
            -- 纯色配件
            local ar, ag, ab = 10, 10, 10  -- 默认黑色
            if acc.colorFromOutline then
                ar, ag, ab = oR, oG, oB
            elseif string.find(acc.name, "Blush") then
                ar, ag, ab = 240, 115, 128  -- 腮红粉色
            end

            nvgSave(vg)
            nvgTranslate(vg, ax, ay)
            if acc.rot then
                nvgRotate(vg, math.rad(-acc.rot[1]))  -- NanoVG Y轴朝下，取反
            end
            nvgBeginPath(vg)
            nvgRect(vg, -aw * 0.5, -ah * 0.5, aw, ah)
            nvgFillColor(vg, nvgRGBA(ar, ag, ab, 255))
            nvgFill(vg)
            nvgRestore(vg)
        end
    end
end

return FaceSkin
