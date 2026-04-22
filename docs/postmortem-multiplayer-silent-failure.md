# 复盘：联机模块"静默失败"排查全记录

> **项目**: 超级红温！(Super Red Hot)
> **引擎**: UrhoX (Lua)
> **日期**: 2026-04-22
> **严重程度**: P0 — 联机功能完全瘫痪
> **排查耗时**: 跨 2 个完整会话，数十轮对话

---

## 一、问题现象

玩家在主菜单点击联机功能时：

| 操作 | 预期行为 | 实际行为 |
|------|---------|---------|
| 点击"快速开始" | 进入匹配队列，显示玩家数递增 | 进入匹配画面，但"无法检测到其他玩家"，人数永远不变 |
| 点击"开房间" | 创建房间，显示房间码，进入等待页 | **点击后没有任何反应**，界面停留在朋友菜单 |

服务端显示 CONNECTED（连接已建立），但所有后续操作均无效。

---

## 二、根本原因

**Server.lua 的 `Start()` 函数在初始化过程中崩溃，导致所有网络事件监听器从未注册。**

```
Server.Start()
    ├── Server.CreateScene()           ✅ 成功
    ├── Map.Init()                     ✅ 成功
    ├── Player.Init()                  ✅ 成功
    ├── ...其他 Init...               ✅ 成功
    ├── LevelManager.Init()            💥 崩溃！
    │   ├── fileSystem:CreateDir()     ❌ ERROR: not allowed
    │   └── File()                     ❌ ERROR: not allowed
    │
    │   ↓↓↓ 以下代码全部未执行 ↓↓↓
    │
    ├── SubscribeToEvent("ClientConnected", ...)      ❌ 未注册
    ├── SubscribeToEvent("ClientDisconnected", ...)   ❌ 未注册
    ├── SubscribeToEvent(CLIENT_READY, ...)            ❌ 未注册
    ├── SubscribeToEvent(REQUEST_QUICK, ...)           ❌ 未注册
    ├── SubscribeToEvent(REQUEST_CREATE, ...)          ❌ 未注册
    ├── ...所有其他远程事件监听...                       ❌ 全部未注册
    └── print("[Server] Started, waiting...")           ❌ 未执行
```

**崩溃原因**: `LevelManager.Init()` 调用了 `fileSystem:CreateDir("levels")` 和 `File()` 构造函数。这些操作在**服务端沙箱环境**中被安全策略禁止，抛出了未捕获的错误，中断了整个 `Start()` 函数的执行。

**关键陷阱**: 引擎的网络层（TCP 连接建立、Scene 同步）是在 C++ 层自动完成的，不依赖 Lua 脚本。所以即使 Lua 层完全崩溃，**客户端仍然能成功建立 TCP 连接**——`network:GetServerConnection()` 返回有效对象，`serverConnection_ ~= nil` 为 true。这给了一个"一切正常"的假象。

---

## 三、为什么 AI 排查走了这么多弯路

### 3.1 误判方向：按钮点击问题

**第一个会话的大量时间浪费在排查 UI 点击上。**

AI 的推理链条：
```
"开房间"点击后没反应
  → 按钮没有被正确点击？
  → DrawRubberButton 返回值不对？
  → cachedPress_ 没有在正确的帧被设置？
  → CacheInput 没有被调用？
  → NanoVG 渲染帧和 Update 帧的时序问题？
```

这个方向完全错误。用户反复告知"点击没有问题"，并通过调试覆盖层证明了：
- `BtnReturnTrue` 每次点击都递增
- `LastAction` 显示正确的按钮命中信息
- `cachedPress_` 在正确的帧为 true

**教训**: 当用户明确否定一个排查方向并提供了证据时，应立即放弃该方向。

### 3.2 忽略了最关键的线索：服务端日志

在长达两个会话的排查中，**直到最后才去查看服务端日志**。

如果第一时间查看 `server_user_script.log`，会立即发现：
- 服务端日志在 `[Server] Started, waiting for connections...` 之前就结束了
- 没有任何 `HandleClientConnected` 输出
- 没有任何 `HandleRequestCreate` 输出

**一行日志就能定位问题，但 AI 选择了在客户端代码中反复翻找。**

### 3.3 被"连接成功"的假象误导

客户端日志显示：
```
[Client] Server connection established, scene assigned
[Client] CLIENT_READY sent to server
```

AI 据此判断"连接没问题，问题在后续逻辑"。但实际上：
- TCP 连接确实建立了（C++ 层）
- CLIENT_READY 确实发送了（客户端侧）
- **但服务端没有任何监听器接收这些事件**

这是一个典型的"客户端单方面成功"场景。

### 3.4 过度关注客户端，忽略服务端

排查的绝大部分时间都花在：
- 分析 Client.lua 的事件发送逻辑
- 分析 HUD.lua 的按钮渲染和点击检测
- 分析 NanoVG 渲染帧 vs Update 帧的时序
- 添加客户端调试覆盖层

而服务端只是"读了一遍代码"，没有：
- 查看服务端运行时日志
- 验证 Server.Start() 是否完整执行
- 检查服务端引擎错误日志

---

## 四、修复方案

### 4.1 核心修复：pcall 保护 LevelManager.Init()

```lua
-- Server.lua - 修复前
LevelManager.Init()  -- 💥 崩溃，后续代码全部不执行

-- Server.lua - 修复后
local ok, err = pcall(function()
    LevelManager.Init()
end)
if not ok then
    print("[Server] WARNING: LevelManager.Init() failed: " .. tostring(err))
    print("[Server] Continuing without level manager file operations...")
end

-- 事件监听器注册（现在保证能执行到）
SubscribeToEvent("ClientConnected", "HandleClientConnected")
SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
-- ...
```

### 4.2 附带修复：按钮重复触发

排查过程中还发现了一个次要问题——"开房间"按钮在渲染帧中每帧触发，导致 `REQUEST_CREATE` 被发送了 38 次：

```lua
-- 修复前
function Client.RequestCreateRoom()
    -- 没有任何防重复机制
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_CREATE, true)
end

-- 修复后
function Client.RequestCreateRoom()
    if clientState_ == "roomWaiting" or clientState_ == "creatingRoom" then
        return  -- 已经发送过，不重复
    end
    clientState_ = "creatingRoom"  -- 设置临时状态防止重复
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_CREATE, true)
end
```

---

## 五、最终定位问题的方法

### 5.1 网络事件日志系统 (NetLog)

在 Client.lua 中添加了一个运行时事件日志，记录每个 SEND/RECV 事件：

```lua
local netLog_ = {}
local function NetLog(msg, r, g, b)
    table.insert(netLog_, { time = os.clock(), msg = msg, r=r, g=g, b=b })
    print("[NetLog] " .. msg)
end

-- 在每个关键点调用：
NetLog("SEND: REQUEST_CREATE", 255, 255, 100)   -- 黄色=发送
NetLog("RECV: ROOM_CREATED", 100, 255, 100)     -- 绿色=接收
NetLog("SEND FAIL: no connection!", 255, 100, 100) -- 红色=错误
```

### 5.2 HUD 调试覆盖层

在屏幕左上角实时显示 NetLog 内容，让用户直观看到事件流：
- 全是 `SEND` 没有 `RECV` → 服务端没响应
- 有 `SEND FAIL` → 连接断开
- 有 `RECV` → 事件链正常

### 5.3 服务端日志（真正的突破口）

查看 `/opt/log/dev/server_user_script.log` 发现：
- 日志在 `LevelManager.Init()` 处截断
- 没有 `[Server] Started, waiting for connections...`
- 没有任何客户端事件处理的输出

查看 `/opt/log/dev/server_engine.log` 确认了错误：
```
ERROR: FileSystem:CreateDir is not allowed
ERROR: Execute Lua function failed: attempt to index a nil value (local 'file')
```

**结论**: 查看日志文件用了 1 分钟，定位了花费数小时未能找到的根因。

---

## 六、联机游戏开发防错清单

### 6.1 服务端初始化必须防崩溃

```lua
-- ❌ 危险：任何 Init 失败都会阻断后续事件注册
ModuleA.Init()
ModuleB.Init()  -- 如果这里崩溃...
SubscribeToEvent(...)  -- ...这里永远不会执行

-- ✅ 安全：每个可能失败的模块用 pcall 保护
local ok, err = pcall(ModuleA.Init)
if not ok then print("ModuleA failed: " .. err) end

local ok2, err2 = pcall(ModuleB.Init)
if not ok2 then print("ModuleB failed: " .. err2) end

-- 事件注册保证执行
SubscribeToEvent(...)
```

**核心原则**: `SubscribeToEvent` 必须放在所有可能失败的初始化之后，或者用 pcall 保护前面的初始化代码。一个都不能漏。

### 6.2 服务端沙箱限制清单

服务端运行在受限沙箱中，以下操作会被拒绝：

| 操作 | 状态 | 替代方案 |
|------|------|---------|
| `fileSystem:CreateDir()` | 禁止 | 使用云变量存储 |
| `File()` 构造函数 | 禁止 | 使用云变量存储 |
| `io.*` 库 | 不存在 | 使用云变量存储 |
| `graphics` 相关 | 不存在 | 使用 mock 对象 |
| 网络监听/事件注册 | 允许 | — |
| `print()` 日志 | 允许 | — |
| 游戏逻辑计算 | 允许 | — |

**规则**: 服务端代码不能有任何文件系统操作。所有需要持久化的数据走云变量（serverCloud）。

### 6.3 调试联机问题的正确顺序

```
发现联机功能异常
  │
  ├─ 第1步：查服务端日志（1分钟）
  │   └─ server_user_script.log — Server.Start() 是否完整执行？
  │   └─ server_engine.log — 有没有 ERROR？
  │
  ├─ 第2步：查客户端日志（1分钟）
  │   └─ user_script.log — 连接是否建立？事件是否发送？
  │
  ├─ 第3步：对比 SEND vs RECV
  │   └─ 客户端发了什么？服务端收到了什么？
  │   └─ 如果客户端 SEND 了但服务端日志里没有 → 服务端事件监听未注册
  │   └─ 如果服务端收到了但没响应 → FindConnection 失败或 early return
  │
  └─ 第4步：才开始看代码逻辑
      └─ 此时已经知道断裂点在哪，针对性排查
```

**绝对不要**: 跳过第 1-3 步直接看代码。

### 6.4 联机游戏必备的调试工具

开发联机游戏时，从第一天起就应该内置：

1. **服务端启动确认日志**
   ```lua
   -- Server.Start() 的最后一行
   print("[Server] ✅ All event handlers registered, server fully ready")
   ```
   如果日志中没有这行，说明初始化中途崩溃了。

2. **客户端网络事件日志 (NetLog)**
   - 记录每个 SEND 和 RECV
   - 在屏幕上实时显示
   - 颜色区分类型（发送/接收/错误）

3. **服务端连接表 Dump**
   ```lua
   -- 定期或在关键事件时打印
   local function DumpConnections(label)
       for k, v in pairs(connections_) do
           print("[Server] " .. label .. ": " .. k ..
                 " ready=" .. tostring(v.ready))
       end
   end
   ```

4. **服务端 Handler 入口日志**
   ```lua
   function HandleRequestCreate(eventType, eventData)
       print("[Server] >>> HandleRequestCreate ENTERED")
       -- ...
   end
   ```
   如果这行日志从未出现，说明事件监听器没注册。

### 6.5 客户端请求必须防重复

在渲染帧（NanoVGRender）中触发的操作，按钮可能每帧返回 true：

```lua
-- ❌ 危险：渲染帧中可能每帧触发
if DrawRubberButton("开房间", ...) then
    Client.RequestCreateRoom()  -- 可能被调用 30+ 次
end

-- ✅ 安全：请求函数内部防重复
function Client.RequestCreateRoom()
    if clientState_ == "creatingRoom" or clientState_ == "roomWaiting" then
        return  -- 已经在处理中
    end
    clientState_ = "creatingRoom"
    serverConnection_:SendRemoteEvent(EVENTS.REQUEST_CREATE, true)
end
```

---

## 七、时间线回顾

| 阶段 | 做了什么 | 结果 | 耗时 |
|------|---------|------|------|
| 会话1-前半 | 排查按钮点击、CacheInput 时序、NanoVG 渲染帧 | 无效 | 大量 |
| 会话1-后半 | 添加屏幕调试覆盖层（鼠标坐标、按钮命中、cachedPress） | 证明点击没问题 | 中等 |
| 会话2-前半 | 添加 NetLog 系统到 Client.lua + HUD 显示 | 发现只有 SEND 没有 RECV | 中等 |
| 会话2-中间 | 添加详细日志到 Server.lua 所有 Handler | 准备工作 | 少量 |
| 会话2-转折 | **查看服务端日志** `server_engine.log` | **1分钟定位根因** | 极少 |
| 会话2-修复 | pcall 保护 LevelManager.Init() + 防重复发送 | 问题解决 | 少量 |

**最大教训**: 如果一开始就查服务端日志，整个问题可能在 5 分钟内解决。

---

## 八、总结

这个 bug 的本质是：**一个非网络模块的初始化错误，通过异常传播，静默地摧毁了整个网络层。**

它之所以难以发现，是因为：
1. TCP 连接在 C++ 层正常建立，Lua 层看起来"已连接"
2. 服务端没有 `[Server] Started` 日志，但没人去看
3. 客户端发送事件不会报错（即使服务端没有监听器）
4. 排查者（AI）被"按钮是否被点击"这个表层问题吸引，在错误的方向上花费了大量时间

**一句话总结**: 联机出问题，先看服务端日志。
