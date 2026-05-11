-- ============================================================================
-- LevelManager.lua - 关卡文件管理
-- 负责关卡的扫描、读写、删除
-- 数据源：LevelsData.lua（内置/持久化）+ levels/ 目录（运行时补充）
-- ============================================================================

local Config = require("Config")
local MapData = require("MapData")
local LevelsData = require("LevelsData")
---@diagnostic disable-next-line: undefined-global
local cjson = cjson

local LevelManager = {}

local SAVE_DIR = "levels"

-- 运行时缓存：合并内置 + 文件系统关卡
-- key = filename (不含 .json), value = { name, width, height, blocks }
local runtimeCache_ = {}

-- ============================================================================
-- 初始化
-- ============================================================================

function LevelManager.Init()
    fileSystem:CreateDir(SAVE_DIR)

    -- 将内置关卡加载到运行时缓存
    for key, data in pairs(LevelsData.levels) do
        runtimeCache_[key] = data
        LevelManager.WriteToFileSystem(key, data)
    end

    print("[LevelManager] Initialized, built-in levels: " .. LevelManager.CountTable(LevelsData.levels))
end

--- 统计 table 元素数量
---@param t table
---@return number
function LevelManager.CountTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- ============================================================================
-- 文件列表
-- ============================================================================

--- 返回所有可用关卡列表（合并内置 + 运行时）
---@return table[] -- { filename, name }
function LevelManager.List()
    local result = {}
    local seen = {}

    -- 优先从缓存读取（包含内置关卡）
    for key, data in pairs(runtimeCache_) do
        local fn = key .. ".json"
        seen[fn] = true
        table.insert(result, { filename = fn, name = data.name or key })
    end

    -- 补充文件系统中可能有的但缓存中没有的关卡
    local files = fileSystem:ScanDir(SAVE_DIR .. "/", "*.json", SCAN_FILES, false)
    for _, filename in ipairs(files) do
        if not seen[filename] then
            local name = LevelManager.ReadNameFromFile(filename)
            table.insert(result, { filename = filename, name = name })
        end
    end

    -- 按文件名排序
    table.sort(result, function(a, b)
        return a.filename < b.filename
    end)
    return result
end

--- 获取已保存关卡数量
---@return number
function LevelManager.GetCount()
    return #LevelManager.List()
end

-- ============================================================================
-- 读写
-- ============================================================================

--- 从文件系统读取关卡名称（快速读取，不解析 grid）
---@param filename string 文件名（含 .json）
---@return string
function LevelManager.ReadNameFromFile(filename)
    local path = SAVE_DIR .. "/" .. filename
    if not fileSystem:FileExists(path) then
        return filename
    end
    local file = File(path, FILE_READ)
    if not file:IsOpen() then
        return filename
    end
    local jsonStr = file:ReadString()
    file:Close()
    local ok, data = pcall(cjson.decode, jsonStr)
    if ok and type(data) == "table" and data.name then
        return data.name
    end
    return filename
end

--- 加载关卡，返回 grid 数据和名称
---@param filename string 文件名（含 .json）
---@return table|nil grid -- grid[y][x] 格式
---@return string|nil name
function LevelManager.Load(filename)
    local key = filename:gsub("%.json$", "")

    -- 优先从缓存读取
    local cached = runtimeCache_[key]
    if cached then
        local w = cached.width or MapData.Width
        local h = cached.height or MapData.Height
        MapData.SetDimensions(w, h)
        local grid = LevelManager.BlocksToGrid(cached.blocks, w, h)
        print("[LevelManager] Loaded from cache: " .. filename .. " (" .. w .. "x" .. h .. ")")
        return grid, cached.name
    end

    -- 回退到文件系统
    return LevelManager.LoadFromFileSystem(filename)
end

--- 从文件系统加载
---@param filename string
---@return table|nil, string|nil
function LevelManager.LoadFromFileSystem(filename)
    local path = SAVE_DIR .. "/" .. filename
    if not fileSystem:FileExists(path) then
        print("[LevelManager] File not found: " .. path)
        return nil, nil
    end
    local file = File(path, FILE_READ)
    if not file:IsOpen() then
        print("[LevelManager] Cannot open: " .. path)
        return nil, nil
    end
    local jsonStr = file:ReadString()
    file:Close()

    local ok, saveData = pcall(cjson.decode, jsonStr)
    if not ok or type(saveData) ~= "table" then
        print("[LevelManager] Invalid JSON in: " .. path)
        return nil, nil
    end

    local w = saveData.width or MapData.Width
    local h = saveData.height or MapData.Height
    MapData.SetDimensions(w, h)
    local grid = LevelManager.BlocksToGrid(saveData.blocks, w, h)
    local name = saveData.name or filename
    print("[LevelManager] Loaded from file: " .. filename .. " (" .. w .. "x" .. h .. ", " .. (saveData.blocks and #saveData.blocks or 0) .. " blocks)")
    return grid, name
end

--- blocks 数组 → grid[y][x] 表
---@param blocks table
---@param w number
---@param h number
---@return table
function LevelManager.BlocksToGrid(blocks, w, h)
    local grid = {}
    for y = 1, h do
        grid[y] = {}
        for x = 1, w do
            grid[y][x] = Config.BLOCK_EMPTY
        end
    end
    if blocks then
        for _, b in ipairs(blocks) do
            if b.x >= 1 and b.x <= w and b.y >= 1 and b.y <= h then
                grid[b.y][b.x] = b.t
            end
        end
    end
    return grid
end

--- 保存关卡（同时写入内置数据 + 文件系统）
---@param filename string 文件名（含 .json）
---@param name string 关卡名称
---@param grid table grid[y][x] 格式
---@return boolean success
function LevelManager.Save(filename, name, grid)
    -- 压缩存储：只保存非空格子
    local blocks = {}
    local h = MapData.Height
    local w = MapData.Width
    for y = 1, h do
        for x = 1, w do
            if grid[y] and grid[y][x] and grid[y][x] ~= Config.BLOCK_EMPTY then
                table.insert(blocks, { x = x, y = y, t = grid[y][x] })
            end
        end
    end

    local saveData = {
        version = 1,
        name = name,
        width = w,
        height = h,
        blocks = blocks,
    }

    local key = filename:gsub("%.json$", "")

    -- 1. 写入内置数据（运行时持久化）
    LevelsData.levels[key] = saveData
    print("[LevelManager] Saved to LevelsData: " .. key .. " (" .. #blocks .. " blocks)")

    -- 输出关卡数据到日志，便于持久化到源文件
    print("[LEVEL_DATA_BEGIN:" .. key .. "]")
    print(cjson.encode(saveData))
    print("[LEVEL_DATA_END:" .. key .. "]")

    -- 2. 写入运行时缓存
    runtimeCache_[key] = saveData

    -- 3. 写入文件系统（当前会话可用）
    LevelManager.WriteToFileSystem(key, saveData)

    return true
end

--- 写入文件系统
---@param key string 不含 .json
---@param saveData table
function LevelManager.WriteToFileSystem(key, saveData)
    fileSystem:CreateDir(SAVE_DIR)
    local path = SAVE_DIR .. "/" .. key .. ".json"
    local jsonStr = cjson.encode(saveData)
    local file = File(path, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString(jsonStr)
        file:Close()
    end
end

--- 删除关卡
---@param filename string 文件名（含 .json）
---@return boolean success
function LevelManager.Delete(filename)
    local key = filename:gsub("%.json$", "")

    -- 1. 从内置数据移除
    LevelsData.levels[key] = nil

    -- 2. 从运行时缓存移除
    runtimeCache_[key] = nil

    -- 3. 从文件系统移除
    local path = SAVE_DIR .. "/" .. filename
    if fileSystem:FileExists(path) then
        fileSystem:Delete(path)
    end

    print("[LevelManager] Deleted: " .. filename)
    return true
end

-- ============================================================================
-- 随机选取
-- ============================================================================

--- 随机选取一个关卡，返回 grid 数据
---@param excludeFilename string|nil 要排除的文件名（避免连续出现同一张图）
---@return table|nil grid
---@return string|nil filename
function LevelManager.GetRandom(excludeFilename)
    local list = LevelManager.List()
    if #list == 0 then
        return nil, nil
    end

    -- 收集候选（排除指定文件）
    local candidates = {}
    for _, entry in ipairs(list) do
        if entry.filename ~= excludeFilename then
            table.insert(candidates, entry)
        end
    end
    if #candidates == 0 then candidates = list end

    math.randomseed(os.time() * 1000 + math.floor((os.clock() % 1) * 100000))
    local idx = math.random(1, #candidates)
    local entry = candidates[idx]
    local grid, _ = LevelManager.Load(entry.filename)
    return grid, entry.filename
end

-- ============================================================================
-- 导出持久化（输出到日志，供 AI 提取写入源文件）
-- ============================================================================

--- 将所有关卡数据导出到日志，供持久化到 LevelsData.lua
---@return number 导出的关卡数量
function LevelManager.ExportToLog()
    local allData = {}
    local count = 0

    -- 收集所有关卡数据（缓存中的）
    for key, data in pairs(runtimeCache_) do
        allData[key] = data
        count = count + 1
    end

    if count == 0 then
        print("[LevelManager] No levels to export")
        return 0
    end

    -- 输出为一个完整 JSON，用特殊标记包裹便于提取
    local jsonStr = cjson.encode(allData)
    print("[PERSIST_LEVELS_BEGIN]")
    print(jsonStr)
    print("[PERSIST_LEVELS_END]")
    print("[LevelManager] Exported " .. count .. " levels to log for persistence")
    return count
end

-- ============================================================================
-- 直接写入 LevelsData.lua 源文件（自动化持久化）
-- ============================================================================

--- 将所有关卡数据直接写入 scripts/LevelsData.lua 源文件
--- 支持多次覆盖，每次调用都会重新生成完整文件
---@return number count 写入的关卡数量
---@return string|nil error 错误信息
function LevelManager.SaveToSourceFile()
    local count = 0
    local sortedKeys = {}

    for key, _ in pairs(runtimeCache_) do
        count = count + 1
        table.insert(sortedKeys, key)
    end

    if count == 0 then
        return 0, "没有关卡数据"
    end

    -- 按 key 排序，确保输出稳定
    table.sort(sortedKeys)

    -- 构建 LevelsData.lua 源代码
    local lines = {}
    table.insert(lines, '-- ============================================================================')
    table.insert(lines, '-- LevelsData.lua - 内置关卡数据（持久化存储）')
    table.insert(lines, '-- 此文件由关卡编辑器自动生成，请勿手动编辑')
    table.insert(lines, '-- 生成时间: ' .. os.date("%Y-%m-%d %H:%M:%S"))
    table.insert(lines, '-- ============================================================================')
    table.insert(lines, '')
    table.insert(lines, 'local LevelsData = {}')
    table.insert(lines, 'LevelsData.levels = {}')
    table.insert(lines, '')

    for _, key in ipairs(sortedKeys) do
        local data = runtimeCache_[key]
        table.insert(lines, '-- ' .. (data.name or key))
        table.insert(lines, 'LevelsData.levels["' .. key .. '"] = {')
        table.insert(lines, '    version = ' .. (data.version or 1) .. ',')
        table.insert(lines, '    name = "' .. (data.name or key) .. '",')
        table.insert(lines, '    width = ' .. (data.width or 30) .. ',')
        table.insert(lines, '    height = ' .. (data.height or 24) .. ',')
        table.insert(lines, '    blocks = {')

        if data.blocks then
            for _, b in ipairs(data.blocks) do
                table.insert(lines, '        { x = ' .. b.x .. ', y = ' .. b.y .. ', t = ' .. b.t .. ' },')
            end
        end

        table.insert(lines, '    },')
        table.insert(lines, '}')
        table.insert(lines, '')
    end

    table.insert(lines, 'return LevelsData')
    table.insert(lines, '')

    local content = table.concat(lines, '\n')

    -- 写入文件
    local path = "LevelsData.lua"  -- scripts/ 是资源根目录，相对路径即可
    local file = File(path, FILE_WRITE)
    if not file:IsOpen() then
        print("[LevelManager] ERROR: Cannot open LevelsData.lua for writing")
        return 0, "无法写入文件"
    end
    file:WriteString(content)
    file:Close()

    print("[LevelManager] Saved " .. count .. " levels to LevelsData.lua source file")
    return count, nil
end

-- ============================================================================
-- 文件名生成
-- ============================================================================

--- 生成下一个可用文件名
---@return string filename -- 如 "level_001.json"
---@return string name -- 如 "关卡 1"
function LevelManager.NextFilename()
    -- 查找最大编号（从缓存 + 文件系统）
    local maxNum = 0

    for key, _ in pairs(runtimeCache_) do
        local num = tonumber(key:match("level_(%d+)"))
        if num and num > maxNum then
            maxNum = num
        end
    end

    local files = fileSystem:ScanDir(SAVE_DIR .. "/", "*.json", SCAN_FILES, false)
    for _, f in ipairs(files) do
        local num = tonumber(f:match("level_(%d+)%.json"))
        if num and num > maxNum then
            maxNum = num
        end
    end

    local nextNum = maxNum + 1
    local filename = string.format("level_%03d.json", nextNum)
    local name = "关卡 " .. nextNum
    return filename, name
end

return LevelManager
