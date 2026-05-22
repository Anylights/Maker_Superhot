-- ============================================================================
-- Economy.lua - 货币与职业持久化（云存档）
-- 存储：金币（iscores）、已拥有职业列表 + 当前选中职业 + 皮肤（values）
-- ============================================================================

local CharacterClass = require("CharacterClass")
local FaceSkin = require("FaceSkin")

local Economy = {}

-- 本地缓存
local coins_      = 0             -- 当前金币
local ownedIds_   = { 1 }         -- 已拥有的职业 ID 列表（默认拥有 1）
local selectedId_ = 1             -- 当前选中职业 ID
local loaded_     = false         -- 是否已从云端加载
local loading_    = false         -- 正在加载中

-- 皮肤缓存
local ownedSkinIds_   = { "default" }  -- 已拥有的皮肤 ID 列表
local selectedSkinId_ = "default"      -- 当前选中皮肤 ID

-- 教程缓存
local tutorialDone_   = false          -- 是否已完成新手教程

-- ============================================================================
-- 内部工具
-- ============================================================================

--- 检查是否拥有某职业
---@param id number
---@return boolean
local function hasClass(id)
    for _, v in ipairs(ownedIds_) do
        if v == id then return true end
    end
    return false
end

--- 将 owned 列表序列化为逗号分隔字符串（云端存储）
---@return string
local function serializeOwned()
    local parts = {}
    for _, id in ipairs(ownedIds_) do
        parts[#parts + 1] = tostring(id)
    end
    return table.concat(parts, ",")
end

--- 从逗号分隔字符串反序列化 owned 列表
---@param str string
---@return number[]
local function deserializeOwned(str)
    if not str or str == "" then return { 1 } end
    local result = {}
    for s in string.gmatch(str, "([^,]+)") do
        local n = tonumber(s)
        if n then result[#result + 1] = n end
    end
    -- 确保默认职业始终存在
    local has1 = false
    for _, v in ipairs(result) do
        if v == 1 then has1 = true; break end
    end
    if not has1 then table.insert(result, 1, 1) end
    return result
end

--- 检查是否拥有某皮肤
---@param id string
---@return boolean
local function hasSkin(id)
    for _, v in ipairs(ownedSkinIds_) do
        if v == id then return true end
    end
    return false
end

--- 将皮肤 owned 列表序列化
---@return string
local function serializeOwnedSkins()
    return table.concat(ownedSkinIds_, ",")
end

--- 从逗号分隔字符串反序列化皮肤 owned 列表
---@param str string
---@return string[]
local function deserializeOwnedSkins(str)
    if not str or str == "" then return { "default" } end
    local result = {}
    for s in string.gmatch(str, "([^,]+)") do
        result[#result + 1] = s
    end
    -- 确保 default 始终存在
    local hasDefault = false
    for _, v in ipairs(result) do
        if v == "default" then hasDefault = true; break end
    end
    if not hasDefault then table.insert(result, 1, "default") end
    return result
end

-- ============================================================================
-- 云端读写
-- ============================================================================

--- 从云端加载经济数据
---@param onLoaded? fun() 加载完成回调（可选）
function Economy.Load(onLoaded)
    if not clientCloud then
        print("[Economy] clientCloud not available, using defaults")
        loaded_ = true
        if onLoaded then onLoaded() end
        return
    end
    if loading_ then return end
    loading_ = true

    -- 使用 BatchGet 同时读取所有 key
    clientCloud:BatchGet()
        :Key("coins")
        :Key("owned_classes")
        :Key("selected_class")
        :Key("owned_skins")
        :Key("selected_skin")
        :Key("tutorial_done")
        :Fetch({
            ok = function(values, iscores)
                coins_ = iscores.coins or 0
                -- 一次性修正：之前的 bug 导致金币异常膨胀，超过 10 万则重置为 0 并回写云端
                local needFixSave = false
                if coins_ > 100000 then
                    print("[Economy] Coin overflow detected (" .. coins_ .. "), resetting to 0")
                    coins_ = 0
                    needFixSave = true
                end
                -- owned_classes 和 selected_class 存在 values 里
                if values.owned_classes then
                    ownedIds_ = deserializeOwned(tostring(values.owned_classes))
                end
                if values.selected_class then
                    local sel = tonumber(values.selected_class)
                    if sel and CharacterClass.GetById(sel) and hasClass(sel) then
                        selectedId_ = sel
                    else
                        selectedId_ = 1
                    end
                end
                -- 皮肤数据
                if values.owned_skins then
                    ownedSkinIds_ = deserializeOwnedSkins(tostring(values.owned_skins))
                end
                if values.selected_skin then
                    local skinStr = tostring(values.selected_skin)
                    if FaceSkin.GetById(skinStr) and hasSkin(skinStr) then
                        selectedSkinId_ = skinStr
                    else
                        selectedSkinId_ = "default"
                    end
                end
                -- 教程完成标记
                if values.tutorial_done then
                    tutorialDone_ = (tostring(values.tutorial_done) == "1")
                end
                loaded_ = true
                loading_ = false
                print("[Economy] Loaded: coins=" .. coins_ .. " owned=" .. serializeOwned() .. " selected=" .. selectedId_ .. " skin=" .. selectedSkinId_)
                if needFixSave then
                    Economy.Save()
                end
                if onLoaded then onLoaded() end
            end,
            error = function(code, reason)
                print("[Economy] Load error: " .. tostring(reason) .. " (code=" .. tostring(code) .. ")")
                loaded_ = true
                loading_ = false
                if onLoaded then onLoaded() end
            end,
        })
end

--- 保存当前经济数据到云端
---@param callback? fun() 保存成功回调
function Economy.Save(callback)
    if not clientCloud then
        if callback then callback() end
        return
    end

    clientCloud:BatchSet()
        :SetInt("coins", coins_)
        :Set("owned_classes", serializeOwned())
        :Set("selected_class", tostring(selectedId_))
        :Set("owned_skins", serializeOwnedSkins())
        :Set("selected_skin", selectedSkinId_)
        :Set("tutorial_done", tutorialDone_ and "1" or "0")
        :Save("Economy save", {
            ok = function()
                print("[Economy] Saved: coins=" .. coins_ .. " owned=" .. serializeOwned() .. " selected=" .. selectedId_ .. " skin=" .. selectedSkinId_)
                if callback then callback() end
            end,
            error = function(code, reason)
                print("[Economy] Save error: " .. tostring(reason))
                if callback then callback() end
            end,
        })
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--- 是否已加载完成
---@return boolean
function Economy.IsLoaded()
    return loaded_
end

--- 获取当前金币
---@return number
function Economy.GetCoins()
    return coins_
end

--- 增加金币（比赛结束时奖励）
---@param amount number
function Economy.AddCoins(amount)
    coins_ = coins_ + amount
end

--- 获取当前选中职业 ID
---@return number
function Economy.GetSelectedClassId()
    return selectedId_
end

--- 设置选中职业（必须已拥有）
---@param id number
---@return boolean 是否设置成功
function Economy.SelectClass(id)
    if not hasClass(id) then return false end
    selectedId_ = id
    Economy.Save()
    return true
end

--- 是否拥有某职业
---@param id number
---@return boolean
function Economy.OwnsClass(id)
    return hasClass(id)
end

--- 获取所有已拥有的职业 ID 列表
---@return number[]
function Economy.GetOwnedIds()
    return ownedIds_
end

--- 购买职业
---@param id number
---@return boolean success
---@return string? errorMsg
function Economy.BuyClass(id)
    if hasClass(id) then
        return false, "already_owned"
    end
    local def = CharacterClass.GetById(id)
    if not def then
        return false, "invalid_class"
    end
    if coins_ < def.price then
        return false, "not_enough_coins"
    end

    coins_ = coins_ - def.price
    ownedIds_[#ownedIds_ + 1] = id
    -- 购买后自动选中
    selectedId_ = id
    Economy.Save()
    print("[Economy] Bought class " .. def.name .. " for " .. def.price .. " coins, remaining=" .. coins_)
    return true, nil
end

--- 比赛结算奖励金币（基于分数）
---@param score number 本局得分
---@return number reward 获得的金币数
function Economy.RewardFromScore(score)
    -- 简单公式：每 100 分 = 10 金币，最低 5 金币
    local reward = math.max(5, math.floor(score / 10))
    Economy.AddCoins(reward)
    Economy.Save()
    return reward
end

-- ============================================================================
-- 皮肤 API
-- ============================================================================

--- 获取当前选中皮肤 ID
---@return string
function Economy.GetSelectedSkinId()
    return selectedSkinId_
end

--- 设置选中皮肤（必须已拥有）
---@param id string
---@return boolean
function Economy.SelectSkin(id)
    if not hasSkin(id) then return false end
    selectedSkinId_ = id
    Economy.Save()
    return true
end

--- 是否拥有某皮肤
---@param id string
---@return boolean
function Economy.OwnsSkin(id)
    return hasSkin(id)
end

--- 获取所有已拥有的皮肤 ID 列表
---@return string[]
function Economy.GetOwnedSkinIds()
    return ownedSkinIds_
end

--- 购买皮肤
---@param id string
---@return boolean success
---@return string? errorMsg
function Economy.BuySkin(id)
    if hasSkin(id) then
        return false, "already_owned"
    end
    local def = FaceSkin.GetById(id)
    if not def then
        return false, "invalid_skin"
    end
    if coins_ < def.price then
        return false, "not_enough_coins"
    end

    coins_ = coins_ - def.price
    ownedSkinIds_[#ownedSkinIds_ + 1] = id
    selectedSkinId_ = id
    Economy.Save()
    print("[Economy] Bought skin " .. def.name .. " for " .. def.price .. " coins, remaining=" .. coins_)
    return true, nil
end

-- ============================================================================
-- 教程 API
-- ============================================================================

--- 是否已完成新手教程
---@return boolean
function Economy.IsTutorialDone()
    return tutorialDone_
end

--- 标记教程已完成并保存云端
function Economy.SetTutorialDone()
    if tutorialDone_ then return end
    tutorialDone_ = true
    Economy.Save()
    print("[Economy] Tutorial marked as done")
end

return Economy
