---
name: cloud-save
description: "WASM \u5e73\u53f0\u6301\u4e45\u5316\u5b58\u6863\u65b9\u6848\uff0c\u4f7f\u7528 clientCloud \u4e91\u53d8\u91cf\u66ff\u4ee3\u672c\u5730 File API\uff08\u5237\u65b0\u5373\u4e22\u5931\uff09\u3002Use when users need to (1) \u4fdd\u5b58\u6e38\u620f\u6570\u636e\u8de8\u5237\u65b0\u6301\u4e45\u5316, (2) \u7f16\u8f91\u5668/\u5de5\u5177\u6570\u636e\u6301\u4e45\u4fdd\u5b58, (3) \u672c\u5730 File \u5199\u5165\u5237\u65b0\u540e\u4e22\u5931, (4) WASM \u5e73\u53f0\u5b58\u6863, (5) \u7528\u6237\u53cd\u9988\u201c\u4fdd\u5b58\u540e\u5237\u65b0\u6570\u636e\u4e22\u4e86\u201d."
---

# Cloud Save \u2014 WASM \u6301\u4e45\u5316\u5b58\u6863

## \u95ee\u9898

WASM \u5e73\u53f0\u4e0b `File("x.json", FILE_WRITE)` \u5199\u5165\u7684\u662f\u5185\u5b58\u6587\u4ef6\u7cfb\u7edf\uff0c**\u5237\u65b0\u9875\u9762\u5373\u4e22\u5931**\u3002
\u9700\u8981 `clientCloud` \u4e91\u53d8\u91cf\u5b9e\u73b0\u8de8\u4f1a\u8bdd\u6301\u4e45\u5316\u3002

## \u6838\u5fc3\u6a21\u5f0f\uff1a\u4e09\u5c42\u5b58\u50a8

```
assets/x.json          \u2190 \u521d\u59cb\u9ed8\u8ba4\u6570\u636e\uff08\u53ea\u8bfb\uff0c\u6784\u5efa\u65f6\u6253\u5305\uff09
\u6c99\u76d2 File("x.json")    \u2190 \u4f1a\u8bdd\u5185\u5373\u65f6\u8bfb\u5199\uff08\u5237\u65b0\u4e22\u5931\uff09
clientCloud:Set(key)   \u2190 \u8de8\u4f1a\u8bdd\u6301\u4e45\u5316\uff08\u670d\u52a1\u7aef\u5b58\u50a8\uff09
```

**\u52a0\u8f7d\u4f18\u5148\u7ea7**\uff1a`clientCloud` > \u6c99\u76d2 `File` > `cache:GetFile(assets)`
**\u4fdd\u5b58\u7b56\u7565**\uff1a\u540c\u65f6\u5199\u6c99\u76d2\uff08\u5373\u65f6\uff09+ \u4e91\u7aef\uff08\u6301\u4e45\uff09

## \u5b9e\u73b0

### 1. \u4fdd\u5b58\uff1a\u6c99\u76d2 + \u4e91\u7aef\u53cc\u5199

```lua
-- \u672c\u5730\u6c99\u76d2\uff08\u5373\u65f6\u751f\u6548\uff09
local f = File("mydata.json", FILE_WRITE)
if f:IsOpen() then f:WriteString(cjson.encode(data)); f:Close() end

-- \u4e91\u7aef\u6301\u4e45\u5316\uff08\u5e26\u9632\u6296\uff09
CloudSave("mydata", data)
```

### 2. \u9632\u6296\u4e91\u5199\u5165\uff08\u907f\u514d\u9891\u7e41\u64cd\u4f5c\u8d85\u9650\uff09

`clientCloud` \u6709\u9891\u7387\u9650\u5236\uff08300 \u6b21/\u5206\u949f\uff09\uff0c\u9ad8\u9891\u4fdd\u5b58\u573a\u666f\uff08\u62d6\u62fd\u3001\u6ed1\u5757\uff09\u987b\u9632\u6296\uff1a

```lua
local cloudSaveTimer_ = {}

function CloudSave(key, data)
    cloudSaveTimer_[key] = { data = data, delay = 0.5 }
end

function FlushCloudSaves(dt)
    for key, info in pairs(cloudSaveTimer_) do
        info.delay = info.delay - dt
        if info.delay <= 0 then
            clientCloud:Set("save_" .. key, cjson.encode(info.data), {
                ok = function() print("[cloud] saved " .. key) end,
                error = function(code, reason)
                    print("[cloud] save failed " .. key .. ": " .. tostring(reason))
                end
            })
            cloudSaveTimer_[key] = nil
        end
    end
end

-- HandleUpdate \u4e2d\u6bcf\u5e27\u8c03\u7528
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    FlushCloudSaves(dt)
end
```

### 3. \u52a0\u8f7d\uff1a\u4e91\u7aef\u4f18\u5148 > \u6c99\u76d2 > assets \u5154\u5e95

```lua
function LoadData()
    -- \u540c\u6b65\u52a0\u8f7d\uff1a\u6c99\u76d2 > assets\uff08\u4fdd\u8bc1\u542f\u52a8\u4e0d\u963b\u585e\uff09
    local loaded = false
    if fileSystem:FileExists("mydata.json") then
        local f = File("mydata.json", FILE_READ)
        if f:IsOpen() then
            local ok, d = pcall(cjson.decode, f:ReadString()); f:Close()
            if ok and d then myData_ = d; loaded = true end
        end
    end
    if not loaded then
        local f = cache:GetFile("mydata.json")
        if f then myData_ = cjson.decode(f:ReadString()); f:Close() end
    end
end

function CloudLoad()
    -- \u5f02\u6b65\u52a0\u8f7d\uff1a\u4e91\u7aef\u6570\u636e\u8986\u76d6\u672c\u5730\uff08\u542f\u52a8\u540e\u8c03\u7528\uff09
    clientCloud:Get("save_mydata", {
        ok = function(values, iscores)
            if values.save_mydata then
                local ok, d = pcall(cjson.decode, values.save_mydata)
                if ok and d then
                    myData_ = d
                    -- \u56de\u5199\u6c99\u76d2\u4f9b\u672c\u6b21\u4f1a\u8bdd\u4f7f\u7528
                    local f = File("mydata.json", FILE_WRITE)
                    if f:IsOpen() then f:WriteString(values.save_mydata); f:Close() end
                    OnDataRestored()  -- \u5237\u65b0 UI / \u91cd\u8f7d\u573a\u666f
                end
            end
        end,
        error = function(code, reason)
            print("[cloud] load failed, using local data")
        end
    })
end

function Start()
    LoadData()     -- \u5148\u540c\u6b65\u52a0\u8f7d\u672c\u5730\u5154\u5e95
    CloudLoad()    -- \u518d\u5f02\u6b65\u4e91\u7aef\u8986\u76d6
end
```

### 4. \u6279\u91cf\u8bfb\u5199\uff08\u591a\u4e2a\u6570\u636e\u6587\u4ef6\uff09

```lua
-- \u6279\u91cf\u4fdd\u5b58
clientCloud:BatchSet()
    :Set("save_scenes", cjson.encode(scenesData))
    :Set("save_meta", cjson.encode(metaData))
    :Save("editor save")

-- \u6279\u91cf\u52a0\u8f7d
clientCloud:BatchGet()
    :Key("save_scenes")
    :Key("save_meta")
    :Fetch({
        ok = function(values, iscores)
            if values.save_scenes then ... end
            if values.save_meta then ... end
        end
    })
```

## \u5173\u952e\u6ce8\u610f\u4e8b\u9879

| \u4e8b\u9879 | \u8bf4\u660e |
|------|------|
| **key \u547d\u540d** | \u52a0\u7edf\u4e00\u524d\u7f00\u5982 `save_`\u3001`editor_`\uff0c\u907f\u514d\u4e0e\u6e38\u620f\u903b\u8f91\u4e91\u53d8\u91cf\u51b2\u7a81 |
| **\u6570\u636e\u4e3a string** | \u5927\u578b JSON \u5efa\u8bae `cjson.encode` \u4e3a\u5b57\u7b26\u4e32\u5b58\u50a8\uff0c\u907f\u514d\u5d4c\u5957\u5e8f\u5217\u5316\u95ee\u9898 |
| **\u9632\u6296\u5fc5\u987b** | \u62d6\u62fd/\u6ed1\u5757\u7b49\u9ad8\u9891\u64cd\u4f5c\u6bcf\u5e27\u90fd\u4f1a\u89e6\u53d1\u4fdd\u5b58\uff0c\u4e0d\u9632\u6296\u4f1a\u89e6\u53d1 429 \u9650\u6d41 |
| **\u5f02\u6b65\u8986\u76d6** | \u4e91\u7aef\u52a0\u8f7d\u662f\u5f02\u6b65\u7684\uff0c\u6570\u636e\u5230\u8fbe\u524d\u7528\u6237\u770b\u5230\u7684\u662f\u672c\u5730/assets \u5154\u5e95\u6570\u636e\uff0c\u5230\u8fbe\u540e\u81ea\u52a8\u5237\u65b0 |
| **\u56de\u5199\u6c99\u76d2** | \u4e91\u7aef\u6570\u636e\u6062\u590d\u540e\u5199\u56de\u6c99\u76d2 File\uff0c\u540e\u7eed\u672c\u6b21\u4f1a\u8bdd\u5185\u8bfb\u53d6\u8d70\u6c99\u76d2\u5373\u53ef\uff0c\u65e0\u9700\u53cd\u590d\u8bf7\u6c42\u4e91\u7aef |
| **\u4ec5\u5ba2\u6237\u7aef** | `clientCloud` \u4ec5\u9650 Standalone/Client \u6a21\u5f0f\uff0cServer \u6a21\u5f0f\u4e0d\u53ef\u7528 |
