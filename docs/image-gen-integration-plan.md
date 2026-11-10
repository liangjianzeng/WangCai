# 汪柴 × Unsloth 图像生成整合方案

> 版本：v1.0 草案（2026-11-09）
> 目标评审人：产品 + 客户端
> 一句话：把 Windows 上已跑通的 Unsloth `Qwen-Image-2.1-Turbo`（Q5_K_M）出图 API 整合进汪柴聊天区，**Windows / Linux(ARM) 双端同一份代码可用**。

---

## 1. 背景与已验证事实

服务端已部署并实测通过（非设想，是现状）：

| 项 | 值 |
|---|---|
| 服务 | Unsloth Studio Desktop（后端 FastAPI，随应用自启） |
| 模型 | Qwen-Image-2.1-Turbo **GGUF Q5_K_M**（自动 8 步 / CFG=1.0，INT8-ConvRot 文本编码器） |
| 本机地址 | `http://127.0.0.1:8888/v1` |
| 局域网地址 | `http://192.168.1.211:8888/v1`（LAN 已开启 + 开机自启；防火墙需管理员放行 8888 一次） |
| 鉴权 | `Authorization: Bearer sk-unsloth-…`（已创建，存于服务端机 `E:\Unsloth\api-key.json`） |
| 实测性能 | 1024² 稳态 **17–29s**；2048² **105s**；显存峰值 10.5GB/16GB（vram-budget 已固化为 0.80） |
| OpenAI 兼容 | `POST /v1/images/generations` 实测通过（b64_json 返回，9s@512²） |
| 交互文档 | `http://<host>:8888/docs` |

**结论**：汪柴侧是纯客户端工作（HTTP + base64 + 文件落盘），**零原生依赖**，这保证了双端一致性——Linux ARM 上 OpenVINO/托盘等不支持项全部不在生图路径上。

---

## 2. 汪柴代码现状（本方案复用的地基）

| 地基 | 位置 | 事实 |
|---|---|---|
| 消息模型支持图片 | [chat_message.dart:143-155](../app/lib/models/chat_message.dart) | `imagePath` / `imagePaths`（≤10 张，多图上传在用）/ `attachments`，SQLite 序列化齐全 |
| 智能体工具体系 | [agent/builtin_tools/](../app/lib/agent/builtin_tools/) | `ToolDefinition{name, description, parameters(JSON Schema), execute, timeout}`；`builtin_tools.dart` 聚合导出，**接入层按配置过滤**；先例：weather/web_search「默认关，设置开启」、adb「设置里开一下就能用」 |
| 产物投递到 UI | [export_file_tool.dart](../app/lib/agent/builtin_tools/export_file_tool.dart) | 文件复制到公共目录 + UI 工具卡渲染「打开」按钮（`kArtifactExtensions` 已含 png/jpg） |
| 密钥安全存储 | [api_key_store.dart](../app/lib/services/api_key_store.dart) | `SecureApiKeyStore`（Win=DPAPI / Android=Keystore / Linux=libsecret），前缀 `wangcai.apikey.`，fail-open 兜底 |
| 平台网关纪律 | [inference_gateway.dart:1](../app/lib/platform/inference_gateway.dart) | "平台分支只允许出现在这里"——生图服务是纯 Dart HTTP，**不需要进网关** |
| 设置页分节先例 | [settings_screen.dart:1221](../app/lib/screens/settings_screen.dart) | `EngineManagerSection` 按平台条件渲染；新加 `ImageGenSection` 同款做法 |
| OpenAI 协议经验 | `services/openai_service.dart`、`agent/llm/openai_adapter.dart` | dio 调 OpenAI 兼容端点的既有写法可直接对齐 |

---

## 3. 总体架构

```
聊天区 (home_screen)
 ├── 入口①【主·P0】输入栏 🎨 chip /「/图」命令
 │      确定性直调，不经过 LLM（简单聊天模式可用、离线可用、零 token）
 │
 └── 入口②【增益·P1】智能体模式 generate_image 工具
        LLM 判断"该配图了"自主调用（与入口①共用同一实现）
                │
                ▼
   lib/services/image_gen_service.dart   ← 唯一实现（纯 Dart + dio）
        ├─ 配置: ImageGenSettings { baseUrl, model, defaultSize, enabled }
        ├─ 密钥: SecureApiKeyStore（id = "unsloth-image"）
        ├─ 调用: POST {baseUrl}/v1/images/generations  (b64_json)
        ├─ 落盘: {文档目录}/imagegen/YYYYMMDD/img-<ts>-<seed>.png
        ├─ 健康: GET {apiRoot}/api/health（设置页绿灯 / chip 置灰依据）
        └─ 产出: List<String> paths → 组 ChatMessage(imagePaths:) 入库并上屏
                │
                ▼
   Unsloth Studio（Windows, :8888）—— Q5_K_M GGUF, 8-step Turbo
```

**模式之争的裁决**（评审重点）：
- ❌ 只做智能体：依赖 LLM 工具调用质量；端侧小模型/离线时功能消失；每次多一轮推理（+3~10s）；参数（尺寸/数量）易被模型传歪。
- ❌ 只做聊天按钮：智能体写文案/讲故事时无法自动配图，组合能力缺失。
- ✅ **一个服务双入口**：入口①保下限（永远可用），入口②提上限（LLM 自主）。二者共享 `ImageGenService`，增量成本各约 100/80 行。

---

## 4. 详细设计

### 4.1 ImageGenService（新增 `app/lib/services/image_gen_service.dart`，~150 行）

```dart
class ImageGenSettings {
  bool enabled;          // 总开关（设置页）
  String baseUrl;        // 默认 Win: http://127.0.0.1:8888 / Linux: 空，需手填
  String model;          // 默认 "E:/Unsloth/models"（服务端扫描目录注册名）
  String defaultSize;    // '1024x1024'（可选 512/1024/1440/2048 档位）
  int    timeoutSecs;    // 默认 240（2048² 约 105s + 排队余量）
}

class ImageGenService {
  Future<bool> health();                       // GET {apiRoot}/api/health
  Future<List<String>> generate({              // 成功返回本地文件路径
    required String prompt, String? negative,
    int n = 1, String? size, int? seed,
  });                                          // 失败抛 ImageGenException(kind)
}

enum ImageGenErrorKind { notConfigured, unreachable, timeout, unauthorized, serverBusy, decode }
```

要点：
- 请求体：`{"model": …, "prompt": …, "n": …, "size": "WxH", "response_format": "b64_json", "seed": …}`；`Authorization: Bearer` 头。
- 落盘目录用 `path_provider` 文档目录下 `imagegen/日期/`（对齐 export_file 的 MediaStore 思路；Linux 走 XDG 自动正确）。
- **单飞队列**：服务侧单卡串行，客户端本地 `Mutex`（`package:synchronized` 或简单 `Future` 链）把并发请求排队，避免用户连点打爆服务端。
- seed 缺省时客户端生成并**随消息存进 attachments JSON**，支持"同 seed 重生成"。
- 超时按尺寸分档：512/1024→120s，2048→300s。

### 4.2 设置页（改 `settings_screen.dart`，新增 `ImageGenSection`，~80 行）

- 字段：启用开关 / baseUrl / model / 默认尺寸 / apiKey（密文输入，`SecureApiKeyStore` id=`unsloth-image`）
- **测试连接按钮**：调 `health()`，绿灯「Unsloth 已连接 · hub=Qwen-Image-2.1-Turbo」/ 红灯带错误文案（区分 unreachable / unauthorized）
- 默认值策略：Windows 首次进入预填 `http://127.0.0.1:8888`，Linux 留空 + 帮助文案「在 Windows 端打开 Unsloth 应用并开启 LAN」
- 持久化：跟随 `settings_service.dart` 的 JSON 配置模式（非密钥字段入 settings JSON，密钥入 secure storage）

### 4.3 聊天入口①：chip / 斜杠命令（改 `home_screen.dart` + 输入栏组件，~120 行）

- 输入栏加 🎨 图标 chip：点亮后该条消息按"生图请求"发送；同时支持消息文本以 `/图 ` 前缀触发（对 Linux/Windows 一致）
- 交互流：
  1. 用户输入提示词 → 上屏为普通 user 消息
  2. 立即插入 assistant 占位消息：「🎨 正在生成 1024×1024…」+ 取消按钮（仅前端排队取消）
  3. 完成 → 占位改写为带 `imagePaths` 的 assistant 消息（复用现有图片气泡渲染），文案含尺寸/seed/耗时
  4. 失败 → 占位改写为错误文案 + 「重试」按钮（同参重发）
- **服务不可用降级**：`enabled=false` 或 health 失败 → chip 置灰 + tooltip「图像服务未连接（设置 → 图像生成）」——落实"不支持就提示不支持"
- n>1（一次最多 4）用长按 chip 弹选项，简单模式默认 1

### 4.4 智能体入口②：generate_image 工具（新增 `agent/builtin_tools/generate_image_tool.dart`，~80 行）

```dart
ToolDefinition createGenerateImageTool() => ToolDefinition(
  name: 'generate_image',
  description: '调用本地 Qwen-Image-2.1-Turbo 生成图片。当用户要求"画/配图/生成图片/海报/插画"，'
               '或你的回答需要一张插图时调用。返回本地 PNG 路径，图片会自动出现在聊天区。'
               '一次最多 4 张；海报/大图用 size=2048x2048（耗时约 2 分钟）。',
  parameters: { /* prompt(必填), size(枚举), n(1-4), negative_prompt, seed */ },
  timeout: const Duration(minutes: 6),
  isConcurrencySafe: (_) => false,   // 单卡串行，独占执行（同 export_file）
  execute: (args) => ImageGenService.instance.generateFromTool(args),
);
```

- 注册：`builtin_tools.dart` 加 export + 聚合列表；**接入层按 `ImageGenSettings.enabled && lastHealthOk` 过滤**（照 weather/web_search 的"设置开启才注册"先例）→ LLM 在关闭/断连时根本看不到该工具，不会幻觉调用
- 工具返回文本 + 路径；工具卡按 export_file 先例渲染缩略图与「打开」
- 智能体生成的图片同样以 `imagePaths` 消息落库（保证重进会话可回看）

### 4.5 数据与消息流约定

- 一条生图 assistant 消息 = `ChatMessage(role: assistant, text: '（描述+参数）', imagePaths: [...])`
- `attachments` JSON 追加 `{"gen": {"seed":…, "size":…, "ms":…, "model":"qwen-image-2.1-turbo-Q5K_M"}}` 便于溯源/复现
- 图片文件生命周期：跟随会话清理策略（P2 再谈，先只增不删）

---

## 5. 平台差异矩阵

| 能力 | Windows（本机） | Linux ARM（局域网） |
|---|---|---|
| 聊天 chip 生图 | ✅ baseUrl=127.0.0.1 | ✅ baseUrl=192.168.1.211 |
| 智能体工具 | ✅ | ✅（同一实现） |
| 健康检查/置灰提示 | ✅ | ✅ |
| 密钥存储 | DPAPI | libsecret（gnome-keyring；无则 fail-open 明文兜底，同现有口径） |
| 图片打开（工具卡） | 系统查看器 | `xdg-open` |
| 依赖前提 | Unsloth 应用开着 | 同左 + 防火墙 8888 放行 |

无任何编译期平台分支需要写——纯 Dart。Linux 其余"不支持项"（OpenVINO/托盘/截图/选图）与本功能无关，各自按既有守卫降级。

---

## 6. 分期与验收标准

### P0（主链路，1 天）
`image_gen_service.dart` + 设置节 + 聊天 chip/斜杠命令
- [ ] Win 端：输入 `/图 一只戴围巾的柴犬` → 30s 内图片出现在聊天气泡，带 seed 文案
- [ ] Linux(ARM) 端：同一构建配置 LAN 地址后重复上述通过
- [ ] 断连场景：关掉 Unsloth → chip 置灰带原因；已排队请求报「服务不可达」+ 可重试
- [ ] 429/排队：连发 3 条，串行完成，无服务端崩溃
- [ ] 单测：mock dio 覆盖 成功/b64 解码/超时/401/队列 5 条

### P1（智能体工具，半天）
`generate_image_tool.dart` + 条件注册 + 工具卡缩略图
- [ ] 智能体模式："帮我写一段产品文案并配一张图" → LLM 自主调用，图进聊天区
- [ ] 设置关闭后，工具不出现在注册表（断言工具列表）
- [ ] 长任务（2048², ~105s）工具卡显示进行中，不阻塞其他工具

### P2（打磨，择期）
- 「同 seed 微调重生成」快捷按钮；历史会话图片清理策略；LAN 自动发现（mDNS 扫 `_unsloth._tcp`）；失败图自动降级尺寸（2048 OOM → 1440 重试）；图片长按菜单（设为头像/导出到下载目录，复用 device_files_service）

---

## 7. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 单卡串行，多人/多端并发排队 | Linux 端长等待 | 客户端单飞队列 + 排队中状态；timeout 分档；docs 明示"2048 约 2 分钟" |
| Windows 端 Unsloth 未启动 | 全部生图失败 | chip 置灰 + 设置页红灯 + 错误文案指明「请在 Windows 打开 Unsloth 并开启 LAN」 |
| 防火墙未放行 | Linux 全挂，Win 正常 | 设置页「测试连接」直接报 unreachable，帮助文档含 `netsh advfirewall` 一条命令 |
| 服务端显存策略回退（升级应用后 vram-budget 重置） | 生图卡死（历史已踩） | 设置页 health 检查附带读取 `/api/settings/vram-budget`，fraction>0.9 时黄灯提醒「显存预算过高」 |
| key 泄漏（LAN 明文 HTTP） | 局域网内可被蹭 | 文档注明仅受信内网使用；长期上 `--secure` Cloudflare 或 TLS；key 可服务端随时吊销重发 |
| b64 大图内存尖峰（2048² ≈ 13MB×4 张） | 低端 ARM OOM | n 上限 4；解码即落盘、字节流不落 String（dio `ResponseType.bytes`，本地解析 JSON 中 b64 段） |
| 模型未载入时首请求含加载 | 首图慢 1 分钟 | 客户端把「load 阶段」归入 timeout 预算并在占位气泡提示「首次加载模型约 1 分钟」 |

---

## 8. 附录

### 8.1 API 契约（实测）

```http
POST /v1/images/generations
Authorization: Bearer ***
Content-Type: application/json

{ "model": "E:/Unsloth/models", "prompt": "...", "n": 1,
  "size": "1024x1024", "response_format": "b64_json", "seed": 42 }

200 OK  { "data": [ { "b64_json": "<base64 PNG>" } ] }
```

- 原生高级接口（P2 备用）：`POST /api/inference/images/generate`（hires/lora/图生图），需桌面会话鉴权，暂不依赖。
- 健康：`GET /api/health` → `{"status":"healthy","hub_source":"modelscope",...}`（免鉴权）
- 模型清单：`GET /v1/models`（需 Bearer）

### 8.2 测试脚本（联调用）

```bash
# Windows 本机 / Linux 远程同一条命令（换 IP）
curl -s http://192.168.1.211:8888/v1/images/generations \
  -H "Authorization: Bearer $IMG_KEY" -H "Content-Type: application/json" \
  -d '{"model":"E:/Unsloth/models","prompt":"test","size":"512x512","response_format":"b64_json"}' \
  | jq -r '.data[0].b64_json' | base64 -d > /tmp/out.png
```

### 8.3 服务端一次性配置备忘（已完成项打勾）

- [x] 模型目录 `E:\Unsloth\models`（Q5_K_M + 编码器 + VAE，sha256 校验）
- [x] LAN access 开启 + 自启（`/api/settings/lan-access`）
- [x] vram-budget = 0.80（防溢出固化项）
- [x] API key `sk-unsloth-…`（服务端 `E:\Unsloth\api-key.json`）
- [ ] 防火墙 8888 入站规则（**需管理员**，一次性：`netsh advfirewall firewall add rule name="Unsloth API" dir=in action=allow protocol=TCP localport=8888`）

---

## 9. 评审需拍板的 4 个问题

1. 入口①形态：**chip 开关** vs **仅斜杠命令** vs 两者都要？（建议：chip + `/图` 双开，成本+20 行）
2. n>1 是否 P0 就放出来？（建议 P0 只放 n=1，队列压力小）
3. 生图是否计入会话导出/分享（share_service）？
4. Linux 端 baseUrl 要不要做「局域网自动发现」提前到 P1？（建议留 P2，先手填）
