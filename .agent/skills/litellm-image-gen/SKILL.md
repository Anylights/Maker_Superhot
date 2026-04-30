# LiteLLM Image Generation Skill

## 概述

通过公司 LiteLLM Proxy 调用 `gpt-image-1.5` 模型生成/编辑游戏场景图片。
本 Skill 用于处理编辑器中的 `[AI_REQUEST]` 图片生成请求。

## 配置

| 项目 | 值 |
|------|------|
| Proxy Base URL | `https://llm-proxy.tapsvc.com` |
| API Key | `sk-xnHLHg2WjosJ7zx3aCVFPQ` |
| Model | `gpt-image-1.5` |
| HTTP Proxy | `http://127.0.0.1:1080`（沙箱网络策略要求） |

## 触发条件

当用户说以下任意内容时触发：
- "处理生成请求"
- "生成图片"
- "处理 AI 请求"
- 或编辑器日志中出现 `[AI_REQUEST]...[/AI_REQUEST]`

## 工作流程

### 1. 读取请求队列

```bash
cat /workspace/assets/editor_requests.json
```

找到所有 `status: "pending"` 且 `type: "image"` 的请求。

### 2. 调用 LiteLLM 生成图片

对每个待处理请求，使用 curl 调用 API：

```bash
curl -x http://127.0.0.1:1080 \
  -X POST "https://llm-proxy.tapsvc.com/v1/images/generations" \
  -H "Authorization: Bearer sk-xnHLHg2WjosJ7zx3aCVFPQ" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-image-1.5",
    "prompt": "<场景描述提示词>",
    "n": 1,
    "size": "1536x1024",
    "quality": "high"
  }'
```

**尺寸说明**：场景图使用横版 `1536x1024`（16:10 比例，适合游戏场景）。

### 3. 含参考图片的请求（img2img）

当请求包含 `referenceImages` 字段时，需要在 prompt 中描述风格一致性：

```
请求示例:
{
  "type": "image",
  "sceneId": "balcony",
  "prompt": "阴暗的阳台，锈蚀的栏杆，远处是灰色的湖面",
  "referenceImages": [
    {"id": "room", "path": "scenes/room.png", "source": "connected"},
    {"id": "hallway", "path": "scenes/hallway.png", "source": "manual"}
  ]
}
```

处理方式：
1. 读取参考图片文件，转为 base64
2. 使用 `images/edits` 端点（如果 API 支持 image 输入），或在 prompt 中强调风格一致性
3. 对于 `source: "connected"` 的参考图，在 prompt 前加 "保持与相邻场景一致的风格、色调和光照。"
4. 对于 `source: "manual"` 的参考图，在 prompt 前加 "参考以下场景的视觉风格。"

### 4. 下载并保存图片

API 返回 base64 数据或 URL。将图片保存到 `/workspace/assets/<targetPath>`：

```bash
# 如果返回 base64
echo "<base64_data>" | base64 -d > /workspace/assets/scenes/room.png

# 如果返回 URL
curl -x http://127.0.0.1:1080 -o /workspace/assets/scenes/room.png "<url>"
```

### 5. 更新请求状态

修改 `/workspace/assets/editor_requests.json`，将已处理请求的 `status` 改为 `"done"`：

```json
{
  "requests": [
    {
      "type": "image",
      "status": "done",
      "sceneId": "room",
      "prompt": "...",
      "targetPath": "scenes/room.png",
      "timestamp": 1234567890
    }
  ]
}
```

编辑器会每 3 秒轮询此文件，检测到 `done` 后自动刷新缩略图。

### 6. 处理动画请求（type: "animation"）

动画请求暂不通过此 API 处理（需要视频生成能力）。可以：
- 使用 `create_video_task` MCP 工具
- 或标记为需要手动处理

## 错误处理

- API 返回 4xx/5xx → 在请求中设置 `status: "error"`，添加 `errorMsg` 字段
- 网络超时 → 重试最多 2 次
- 图片保存失败 → 检查目录是否存在，必要时 `mkdir -p`

## 注意事项

1. **务必使用 HTTP Proxy**：沙箱环境网络隔离，必须通过 `http://127.0.0.1:1080` 访问外部服务
2. **文件路径**：图片保存到 `/workspace/assets/` 下，编辑器通过 `cache:GetResource()` 读取
3. **并发**：建议串行处理请求，避免 API 限流
4. **图片格式**：保存为 PNG 格式
