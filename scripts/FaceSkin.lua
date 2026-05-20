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
---@field pos table              相对位置 {x, y, z}
---@field scale table            缩放 {x, y, z}
---@field rot table|nil          旋转 {angle, axis} 或 nil
---@field colorFromOutline boolean 是否使用描边色（true=描边色, false=自定义黑色）
---@field followEyes boolean|nil   是否跟随眼睛偏移（默认true）。设为false则嘴/眼罩等不跟随移动偏移
---@field modelType string|nil   模型类型: "box"(默认)/"sphere"/"star"/"plane"
---@field isHighlight boolean|nil 是否白色高光

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
            {
                name    = "SkinAcc_Glasses",
                pos     = { 0, 0.06, -0.52 },
                scale   = { 0.95, 0.95, 1.0 },
                rot     = nil,
                texture = "image/sunglasses.png",
                colorFromOutline = false,
                followEyes = true,
            },
        },
    },

    -- 3. 不屑脸（外八字线眼 + 小嘴）
    --    参考图：两条横线微微外八字倾斜 + 下方一个小矩形嘴
    {
        id    = "bored",
        name  = "不屑冷漠",
        desc  = "一脸不屑，看什么都无聊",
        price = 200,
        icon  = "😑",
        eyeL  = { visible = false },
        eyeR  = { visible = false },
        accessories = {
            -- 左眼：扁矩形，左高右低约8度倾斜
            {
                name = "SkinAcc_EyeLineL", modelType = "box",
                pos = { -0.16, 0.08, -0.52 }, scale = { 0.22, 0.055, 0.02 },
                rot = { 8, "FORWARD" }, colorFromOutline = true, followEyes = true,
            },
            -- 右眼：扁矩形，右高左低约-8度倾斜
            {
                name = "SkinAcc_EyeLineR", modelType = "box",
                pos = { 0.16, 0.08, -0.52 }, scale = { 0.22, 0.055, 0.02 },
                rot = { -8, "FORWARD" }, colorFromOutline = true, followEyes = true,
            },
            -- 小嘴巴 - 不跟随偏移
            {
                name = "SkinAcc_Mouth", modelType = "box",
                pos = { 0, -0.16, -0.52 }, scale = { 0.12, 0.045, 0.02 },
                rot = nil, colorFromOutline = true, followEyes = false,
            },
        },
    },

    -- 4. 呆萌脸（2大黑球 + 2小白球高光）
    --    参考图：两个大圆黑眼 + 每个眼睛右上角一个小白圆高光点
    {
        id    = "cute",
        name  = "呆萌大眼",
        desc  = "水汪汪的大眼睛，谁能拒绝",
        price = 250,
        icon  = "🥺",
        eyeL  = { visible = false },
        eyeR  = { visible = false },
        accessories = {
            -- 左大球（眼睛）— 描边色
            {
                name = "SkinAcc_EyeBigL", modelType = "sphere",
                pos = { -0.16, 0.06, -0.52 }, scale = { 0.30, 0.30, 0.06 },
                rot = nil, colorFromOutline = true, followEyes = true,
            },
            -- 右大球（眼睛）— 描边色
            {
                name = "SkinAcc_EyeBigR", modelType = "sphere",
                pos = { 0.16, 0.06, -0.52 }, scale = { 0.30, 0.30, 0.06 },
                rot = nil, colorFromOutline = true, followEyes = true,
            },
            -- 左眼高光（小白球，在左眼右上角偏移）
            {
                name = "SkinAcc_HighlightL", modelType = "sphere",
                pos = { -0.08, 0.14, -0.57 }, scale = { 0.085, 0.085, 0.02 },
                rot = nil, colorFromOutline = false, followEyes = true, isHighlight = true,
            },
            -- 右眼高光（小白球，在右眼右上角偏移）
            {
                name = "SkinAcc_HighlightR", modelType = "sphere",
                pos = { 0.24, 0.14, -0.57 }, scale = { 0.085, 0.085, 0.02 },
                rot = nil, colorFromOutline = false, followEyes = true, isHighlight = true,
            },
        },
    },

    -- 5. 海盗眼罩（1大黑球眼罩 + 1黑色斜矩形带 + 1小白球露出的眼睛）
    --    参考图：大黑圆覆盖左眼区域 + 一条斜向深色矩形带穿过 + 右上方一个小白点
    {
        id    = "eyepatch",
        name  = "独眼海盗",
        desc  = "一只眼睛就够用了",
        price = 350,
        icon  = "🏴‍☠️",
        eyeL  = { visible = false },
        eyeR  = { visible = false },
        accessories = {
            -- 斜带矩形（穿过眼罩大球，黑色）- 不跟随
            {
                name = "SkinAcc_Strip", modelType = "box",
                pos = { -0.14, 0.06, -0.51 }, scale = { 1.0, 0.10, 0.02 },
                rot = { 45, "FORWARD" }, colorFromOutline = false, followEyes = false,
            },
            -- 大球（眼罩主体，偏左，更大）- 不跟随
            {
                name = "SkinAcc_PatchBall", modelType = "sphere",
                pos = { -0.14, 0.06, -0.52 }, scale = { 0.40, 0.40, 0.06 },
                rot = nil, colorFromOutline = false, followEyes = false,
            },
            -- 小球（露出的右眼）- 描边色，和默认眼睛一样大
            {
                name = "SkinAcc_SmallEye", modelType = "sphere",
                pos = { 0.22, 0.06, -0.53 }, scale = { 0.14, 0.14, 0.04 },
                rot = nil, colorFromOutline = true, followEyes = true,
            },
        },
    },

    -- 6. 星星眼（2大黑球 + 2个五角星，用CustomGeometry）
    --    参考图：两个大圆黑底 + 每个里面一个五角星
    {
        id    = "stareyes",
        name  = "追星达人",
        desc  = "眼里全是星星，闪闪发光",
        price = 400,
        icon  = "⭐",
        eyeL  = { visible = false },
        eyeR  = { visible = false },
        accessories = {
            -- 左大球（底色）— 描边色
            {
                name = "SkinAcc_StarBgL", modelType = "sphere",
                pos = { -0.16, 0.06, -0.52 }, scale = { 0.32, 0.32, 0.06 },
                rot = nil, colorFromOutline = true, followEyes = true,
            },
            -- 右大球（底色）— 描边色
            {
                name = "SkinAcc_StarBgR", modelType = "sphere",
                pos = { 0.16, 0.06, -0.52 }, scale = { 0.32, 0.32, 0.06 },
                rot = nil, colorFromOutline = true, followEyes = true,
            },
            -- 左星星（CustomGeometry五角星）— 角色主体色，五角尖端到大球边缘
            {
                name = "SkinAcc_StarL", modelType = "star",
                pos = { -0.16, 0.06, -0.58 }, scale = { 0.32, 0.32, 0.01 },
                rot = nil, colorFromBody = true, followEyes = true,
            },
            -- 右星星（CustomGeometry五角星）— 角色主体色，五角尖端到大球边缘
            {
                name = "SkinAcc_StarR", modelType = "star",
                pos = { 0.16, 0.06, -0.58 }, scale = { 0.32, 0.32, 0.01 },
                rot = nil, colorFromBody = true, followEyes = true,
            },
        },
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

--- 生成五角星的三角形顶点列表（用于 CustomGeometry）
--- 返回三角形列表，每3个顶点为一个三角形
---@param cx number 中心X
---@param cy number 中心Y
---@param outerR number 外径
---@param innerR number 内径
---@return table 顶点列表 {{x,y}, ...}
local function generateStarVertices(cx, cy, outerR, innerR)
    local verts = {}
    local pts = {}  -- 10个顶点：交替外/内
    for i = 0, 9 do
        local angle = math.rad(-90 + i * 36)  -- 从顶部开始
        local r = (i % 2 == 0) and outerR or innerR
        pts[#pts + 1] = { x = cx + r * math.cos(angle), y = cy + r * math.sin(angle) }
    end
    -- 用扇形三角剖分（中心点 + 相邻两个顶点）
    for i = 1, 10 do
        local j = (i % 10) + 1
        verts[#verts + 1] = { x = cx, y = cy }
        verts[#verts + 1] = pts[i]
        verts[#verts + 1] = pts[j]
    end
    return verts
end

--- 在 visualNode 上创建皮肤配件子节点
---@param visualNode any  角色视觉节点
---@param skinId string
---@param outlineColor Color  描边颜色（用于 colorFromOutline=true 的配件）
---@param bodyColor Color|nil  身体颜色（用于 colorFromBody=true 的配件）
function FaceSkin.ApplyToVisual(visualNode, skinId, outlineColor, bodyColor)
    if not visualNode then return end
    local def = skinById[skinId]
    if not def or #def.accessories == 0 then return end

    local boxModel = cache:GetResource("Model", "Models/Box.mdl")
    local sphereModel = cache:GetResource("Model", "Models/Sphere.mdl")
    local planeModel = cache:GetResource("Model", "Models/Plane.mdl")
    local unlitTech = cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")
    local unlitAlphaTech = cache:GetResource("Technique", "Techniques/DiffAlpha.xml")

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

        -- 决定颜色
        local matColor
        if acc.colorFromBody and bodyColor then
            matColor = bodyColor
        elseif acc.colorFromOutline then
            matColor = outlineColor
        elseif acc.isHighlight then
            matColor = Color(0.95, 0.95, 0.95, 1.0)
        elseif string.find(acc.name, "Blush") then
            matColor = Color(0.95, 0.45, 0.50, 1.0)
        else
            matColor = Color(0.05, 0.05, 0.05, 1.0)
        end

        local mtype = acc.modelType or "box"

        if mtype == "star" then
            -- 五角星用 CustomGeometry
            local geom = accNode:CreateComponent("CustomGeometry")
            geom:BeginGeometry(0, TRIANGLE_LIST)
            local starVerts = generateStarVertices(0, 0, 0.5, 0.2)
            for _, v in ipairs(starVerts) do
                geom:DefineVertex(Vector3(v.x, v.y, 0))
                geom:DefineNormal(Vector3(0, 0, -1))  -- 面向相机
                geom:DefineTexCoord(Vector2(0, 0))
            end
            geom:Commit()
            local mat = Material:new()
            mat:SetTechnique(0, unlitTech)
            mat:SetShaderParameter("MatDiffColor", Variant(matColor))
            mat.cullMode = CULL_NONE
            geom:SetMaterial(mat)
        elseif acc.texture then
            -- 贴图配件：用 Plane 模型 + 透明贴图
            local model = accNode:CreateComponent("StaticModel")
            model.castShadows = false
            model.model = planeModel
            local baseRot = accNode.rotation or Quaternion.IDENTITY
            accNode.rotation = baseRot * Quaternion(-90, Vector3.RIGHT)
            local mat = Material:new()
            mat:SetTechnique(0, unlitAlphaTech)
            mat.cullMode = CULL_NONE
            local tex = cache:GetResource("Texture2D", acc.texture)
            if tex then
                mat:SetTexture(TU_DIFFUSE, tex)
            end
            mat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
            model:SetMaterial(mat)
        else
            -- box 或 sphere
            local model = accNode:CreateComponent("StaticModel")
            model.castShadows = false
            if mtype == "sphere" then
                model.model = sphereModel
            else
                model.model = boxModel
            end
            local mat = Material:new()
            mat:SetTechnique(0, unlitTech)
            mat:SetShaderParameter("MatDiffColor", Variant(matColor))
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

        -- 决定颜色
        local ar, ag, ab = 10, 10, 10  -- 默认黑色
        if acc.colorFromBody and bodyColor then
            ar = math.floor(bodyColor.r * 255)
            ag = math.floor(bodyColor.g * 255)
            ab = math.floor(bodyColor.b * 255)
        elseif acc.colorFromOutline then
            ar, ag, ab = oR, oG, oB
        elseif acc.isHighlight then
            ar, ag, ab = 240, 240, 240  -- 白色高光
        elseif string.find(acc.name, "Blush") then
            ar, ag, ab = 240, 115, 128  -- 腮红粉色
        end

        local mtype = acc.modelType or "box"

        if mtype == "sphere" then
            -- 圆形
            nvgBeginPath(vg)
            nvgEllipse(vg, ax, ay, aw * 0.5, ah * 0.5)
            nvgFillColor(vg, nvgRGBA(ar, ag, ab, 255))
            nvgFill(vg)
        elseif mtype == "star" then
            -- 五角星
            local starR = math.min(aw, ah) * 0.5
            local innerR = starR * 0.4
            nvgSave(vg)
            nvgTranslate(vg, ax, ay)
            nvgBeginPath(vg)
            for i = 0, 9 do
                local angle = math.rad(-90 + i * 36)
                local r = (i % 2 == 0) and starR or innerR
                local px = r * math.cos(angle)
                local py = r * math.sin(angle)
                if i == 0 then
                    nvgMoveTo(vg, px, py)
                else
                    nvgLineTo(vg, px, py)
                end
            end
            nvgClosePath(vg)
            nvgFillColor(vg, nvgRGBA(ar, ag, ab, 255))
            nvgFill(vg)
            nvgRestore(vg)
        elseif acc.texture then
            -- 贴图配件
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
            -- box 矩形
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

--- 获取指定皮肤每个配件是否跟随眼睛偏移
---@param skinId string
---@return table<string, boolean>  { ["SkinAcc_xxx"] = true/false }
function FaceSkin.GetAccessoryFollowFlags(skinId)
    local flags = {}
    local def = skinById[skinId]
    if not def then return flags end
    for _, acc in ipairs(def.accessories) do
        -- 默认 followEyes = true（眼镜等跟随），设为 false 则不跟随（嘴、眼罩）
        flags[acc.name] = (acc.followEyes ~= false)
    end
    return flags
end

return FaceSkin
