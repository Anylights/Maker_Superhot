---
name: llm-server-http
description: |
  通过服务端 HTTP 在 UrhoX 多人游戏中接入大语言模型（LLM）。
  Use when:
  (1) 用户要在游戏里接入大模型/LLM/AI对话/智能NPC,
  (2) 用户提到豆包/通义千问/百炼/火山引擎/Doubao/Qwen等国内大模型API,
  (3) 用户需要服务端调用外部 HTTP API 并把结果发回客户端,
  (4) 用户想做 AI 聊天/对话/问答功能。
---

# 服务端 HTTP 接入大模型（LLM）

## 架构概览

```
客户端                    服务端                      LLM API
  │                        │                           │
  │─── RemoteEvent ───────>│                           │
  │   (用户消息)            │─── HTTP POST ────────────>│
  │                        │                           │
  │                        │<── JSON Response ─────────│
  │<── RemoteEvent ────────│                           │
  │   (LLM回复)            │                           │
```

**核心约束**：客户端 HTTP 完全被封禁，所有外部请求必须走服务端。

## 接入前：向用户收集信息

开始编码前，必须向用户确认以下信息（**禁止将这些值硬编码到 Skill 或提交到版本控制**）：

| 信息 | 说明 | 示例 |
|------|------|------|
| **LLM 服务商** | 使用哪家 API | 火山引擎(豆包)、百炼(通义千问) |
| **API 完整 URL** | 包含路径的完整请求地址 | `https://ark.cn-beijing.volces.com/api/v3/chat/completions` |
| **API Key** | 鉴权密钥 | 用户从服务商控制台获取 |
| **模型标识** | 模型名或 Endpoint ID | `doubao-seed-1-8-251228` 或 `ep-m-xxxx` |
| **System Prompt** | LLM 角色设定 | "你是游戏里的智能NPC..." |

### 常见服务商 URL 参考

向用户确认时可参考（以实际控制台为准）：

- **火山引擎（豆包）**：`https://ark.cn-beijing.volces.com/api/v3/chat/completions`
- **百炼（通义千问）**：`https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`

两者均兼容 OpenAI Chat Completions 格式。

## 项目结构

多人游戏模式（persistent world 常驻服），三文件结构：

```
scripts/
├── main.lua              # 入口：检测 server/client 加载对应模块
└── network/
    ├── Shared.lua         # 共享事件名定义 + RegisterRemoteEvent
    ├── Server.lua         # 接收消息 → HTTP 调 LLM → 发回回复
    └── Client.lua         # 聊天 UI + 收发消息展示
```

### 构建配置

首次构建时必须传 multiplayer 参数：

```
multiplayer: { enabled: true, persistent_world: { enabled: true }, max_players: 2 }
```

## 关键实现要点

### 1. cjson 是全局变量

```lua
-- ✅ 正确：直接使用
local body = cjson.encode({ model = MODEL, messages = msgs })
local data = cjson.decode(response.dataAsString)

-- ❌ 错误：会报 Module not found
local cjson = require("cjson")
```

### 2. HTTP 请求写法（服务端）

```lua
http:Create()
    :SetUrl(API_URL)
    :SetMethod(HTTP_POST)
    :SetContentType("application/json")
    :AddHeader("Authorization", "Bearer " .. API_KEY)
    :SetBody(requestBody)
    :OnSuccess(function(client, response)
        if response.success then
            local ok, data = pcall(cjson.decode, response.dataAsString)
            -- 处理 data.choices[1].message.content
        end
    end)
    :OnError(function(client, statusCode, error)
        -- 处理网络错误
    end)
    :Send()
```

### 3. 远程事件注册

接收方必须调用 `network:RegisterRemoteEvent(eventName)`，否则日志会报 `Discarding not allowed remote event`。

- 服务端接收客户端事件 → **服务端**注册
- 客户端接收服务端事件 → **客户端**注册

### 4. ClientReady 握手

客户端必须先设置 `connection.scene`，再发 `ClientReady`；服务端收到后才设置 `connection.scene`。顺序不能反。

### 5. 请求/响应数据格式（OpenAI 兼容）

```lua
-- 请求体
{
    model = "模型标识",
    messages = {
        { role = "system", content = "系统提示" },
        { role = "user",   content = "用户消息" },
    },
    max_tokens = 256,
}

-- 响应体（取回复文本）
data.choices[1].message.content
```

## 验证 Demo 说明

可为用户搭建一个最小验证 Demo，功能如下：

- **客户端**：聊天界面（输入框 + 发送按钮 + 消息气泡 + 底部调试日志面板），发消息时通过 RemoteEvent 发给服务端，收到回复后显示 AI 气泡
- **服务端**：监听聊天事件，收到消息后用 `http:Create()` 调用 LLM API，解析 JSON 响应，通过 RemoteEvent 把回复文本发回客户端
- **调试面板**：在客户端底部显示黑底日志区，实时输出连接状态、消息收发、错误信息，方便排查问题

### UI 气泡注意事项

使用 `urhox-libs/UI` 构建聊天 UI 时，Label 的 `whiteSpace = "normal"` 需要父容器有**确定宽度**（`width`），`maxWidth` 不算确定宽度，会导致 Label 宽度为 0 文字不显示。对于气泡场景，建议不设 `whiteSpace` 用默认单行，或确保父容器链路上有确定的 `width`。

## 排查清单

| 现象 | 原因 | 解决 |
|------|------|------|
| 服务端 `Module not found: cjson` | `require("cjson")` | 去掉 require，cjson 是全局变量 |
| `Discarding not allowed remote event` | 接收方未注册事件 | 在接收方调用 `RegisterRemoteEvent` |
| 一直"思考中"无回复 | 服务端启动失败或 HTTP 失败 | 查服务端日志 `server_engine.log` |
| 气泡显示但文字为空 | Label 在 maxWidth 容器中宽度为 0 | 去掉 `whiteSpace = "normal"` 或给父容器确定 width |
