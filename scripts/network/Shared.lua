-- ============================================================================
-- Shared.lua - 双端共享的场景创建和远程事件注册
-- Server.lua 和 Client.lua 共同调用
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local NetConfig = require("NetConfig")

local Shared = {}

--- 创建场景（双端公用）
---@param isServer boolean
---@return Scene
function Shared.CreateScene(isServer)
    local scene = Scene()
    scene:CreateComponent("Octree")

    if not isServer then
        scene:CreateComponent("DebugRenderer")
    end

    -- 3D 物理世界
    local physicsWorld = scene:CreateComponent("PhysicsWorld")
    physicsWorld:SetGravity(Vector3(0, -28.0, 0))

    -- 客户端：光照
    if not isServer then
        local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Daytime.xml")
        if lightGroupFile then
            local lightGroup = scene:CreateChild("LightGroup")
            lightGroup:LoadXML(lightGroupFile:GetRoot())
            local zoneComp = lightGroup:GetComponent("Zone")
            if not zoneComp then
                for i = 0, lightGroup.numChildren - 1 do
                    local child = lightGroup:GetChild(i)
                    zoneComp = child:GetComponent("Zone")
                    if zoneComp then break end
                end
            end
            if zoneComp then
                zoneComp.fogColor = Color(0.95, 0.82, 0.68)
            end
        else
            Shared.CreateFallbackLighting(scene)
        end
    end

    -- 死亡区域（双端都需要，服务端用于碰撞检测）
    local deathZone = scene:CreateChild("DeathZone")
    deathZone.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
    deathZone.scale = Vector3(MapData.Width + 20, 2, 10)
    local dzBody = deathZone:CreateComponent("RigidBody")
    dzBody.trigger = true
    dzBody.collisionLayer = 4
    dzBody.collisionMask = 2
    local dzShape = deathZone:CreateComponent("CollisionShape")
    dzShape:SetBox(Vector3(1, 1, 1))

    print("[Shared] Scene created (isServer=" .. tostring(isServer) .. ")")
    return scene
end

--- 备用光照（客户端）
---@param scene Scene
function Shared.CreateFallbackLighting(scene)
    local zoneNode = scene:CreateChild("Zone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(-200.0, 200.0)
    zone.ambientColor = Color(0.40, 0.35, 0.30)
    zone.fogColor = Color(0.95, 0.82, 0.68)
    zone.fogStart = 80.0
    zone.fogEnd = 150.0

    local lightNode = scene:CreateChild("DirectionalLight")
    lightNode.direction = Vector3(0.5, -1.0, 0.3)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL
    light.color = Color(1.0, 0.95, 0.9)
    light.castShadows = true
    light.shadowBias = BiasParameters(0.00025, 0.5)
    light.shadowCascade = CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
end

--- 更新死亡区域（适配当前地图尺寸）
---@param scene Scene
function Shared.UpdateDeathZone(scene)
    local dz = scene:GetChild("DeathZone", false)
    if dz then
        dz.position = Vector3(MapData.Width * 0.5, Config.DeathY, 0)
        dz.scale = Vector3(MapData.Width + 20, 2, 10)
    end
end

--- 创建渐变背景平面（仅客户端）
---@param scene Scene
function Shared.CreateBackgroundPlane(scene)
    local topColor = Config.BgColorTop
    local botColor = Config.BgColorBot
    local size = 200
    local strips = 8
    local bgNode = scene:CreateChild("BackgroundGradient")
    bgNode.position = Vector3(0, 0, 5)

    local pbrTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

    for i = 0, strips - 1 do
        local t0 = i / strips
        local t1 = (i + 1) / strips
        local r0 = topColor[1] + (botColor[1] - topColor[1]) * t0
        local g0 = topColor[2] + (botColor[2] - topColor[2]) * t0
        local b0 = topColor[3] + (botColor[3] - topColor[3]) * t0
        local r1 = topColor[1] + (botColor[1] - topColor[1]) * t1
        local g1 = topColor[2] + (botColor[2] - topColor[2]) * t1
        local b1 = topColor[3] + (botColor[3] - topColor[3]) * t1
        local midR = (r0 + r1) * 0.5
        local midG = (g0 + g1) * 0.5
        local midB = (b0 + b1) * 0.5

        local stripNode = bgNode:CreateChild("Strip" .. i)
        local yTop = size * (1 - t0 * 2)
        local yBot = size * (1 - t1 * 2)
        stripNode.position = Vector3(0, (yTop + yBot) * 0.5, 0)
        stripNode.scale = Vector3(size * 2, yTop - yBot, 0.1)

        local model = stripNode:CreateComponent("StaticModel")
        model.model = cache:GetResource("Model", "Models/Box.mdl")
        model.castShadows = false

        local mat = Material:new()
        mat:SetTechnique(0, pbrTech)
        mat:SetShaderParameter("MatDiffColor", Variant(Color(midR, midG, midB, 1.0)))
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(midR * 0.3, midG * 0.3, midB * 0.3)))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(1.0))
        model:SetMaterial(mat)
    end
end

--- 注册所有远程事件（双端必须调用）
function Shared.RegisterEvents()
    NetConfig.RegisterEvents()
    print("[Shared] Remote events registered")
end

return Shared
