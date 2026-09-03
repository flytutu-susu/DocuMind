# DocuMind

macOS 文档智能应用（Swift + SwiftUI）：**本地 Unlimited-OCR 模型识别**、PDF 转 Word、云端大模型对话、局域网 Web 访问。

## 功能

| 功能 | 说明 |
| --- | --- |
| 文档识别 | **默认本地运行百度开源 [Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR) 3B 模型（MLX MXFP8 量化版，~3.6GB）**，完全离线免费；可在设置中一键切换 Int8 / Int4 / MXFP4 量化档位；支持 PDF（文字版自动走文本层、扫描版逐页识别）、图片、docx、xlsx。也可切换为百度智能云 OCR（标准/高精度/无限制套餐） |
| PDF 转 Word | 提取或本地识别后排版生成标准 .docx（OOXML），支持 Markdown 版面模式 |
| 局域网 Web | 内置零依赖 HTTP 服务（Network.framework），局域网设备浏览器打开 `http://<Mac的IP>:8080` 即可使用全部功能 |
| 云端 LLM | OpenAI 兼容协议（**DeepSeek、Kimi、通义千问、OpenAI 及任意兼容网关**）+ **Anthropic Messages 协议**，App 内 SSE 流式输出 |

## 环境要求

- macOS 13+，Apple Silicon（M1 16GB 可流畅运行本地 3B 4bit 模型）
- Python 3.10+（Xcode 命令行工具自带的 `/usr/bin/python3` 即可，App 会自动创建独立 venv，不污染系统环境）
- 构建需要 Xcode 15+ 或 Command Line Tools（含 Swift 5.9+）
- 首次启动本地引擎需联网下载依赖（~300MB）和模型（~2.4GB），默认走国内镜像加速

## 构建与运行

```bash
# 开发调试（直接运行）
swift run DocuMind

# 打包为 DocuMind.app
bash scripts/build-app.sh
open dist/DocuMind.app
```

也可以直接用 Xcode 打开 `Package.swift` 运行。

## 首次配置

1. **OCR（本地引擎，推荐）**：打开 App → `⌘,` → 「OCR 引擎」→ 点「安装环境并启动」。App 会自动：创建 venv → 安装 mlx-vlm → 下载模型 → 启动推理服务（仅监听 127.0.0.1）。日志面板可见下载进度，就绪后状态变绿。
   - 模型默认 [mlx-community/Unlimited-OCR-mxfp8](https://huggingface.co/mlx-community/Unlimited-OCR-mxfp8)（3.6GB，FUNSD CER 1.46%，config 原生修复版，避免旧 shim 的重复乱码问题）；设置里可切换 [sahilchachra 量化系列](https://huggingface.co/sahilchachra) 的 MXFP8 / Int8（3.7GB）/ Int4（2.3GB）/ MXFP4（2.3GB）档位
   - 输出模式：纯文本更快；**Markdown 保留版面结构，转 Word 效果更好**
2. **OCR（百度云，可选）**：引擎切换为「百度智能云 OCR」，填入[控制台](https://console.bce.baidu.com/ai-engine/ocr/overview/index)创建的 API Key / Secret Key 即可。
3. **大模型**：设置 → 大模型 → 添加预设（DeepSeek / Kimi / 千问 / OpenAI / Anthropic 已内置 Base URL 与默认模型），填入 API Key。
4. **局域网服务**：「局域网服务」页点「启动服务」，手机/其他电脑浏览器访问列表地址。

## 本地引擎架构

App 内嵌一个 Python sidecar（`MLXServerScript.swift`），全部文件在 `~/Library/Application Support/DocuMind/mlx/`：

```
App(Swift) ──HTTP 127.0.0.1:8091──> mlx_server.py (venv 内 python)
                                        └─ mlx_vlm.load("mlx-community/Unlimited-OCR-mxfp8")
POST /ocr  {image: base64, mode: text|markdown}  →  {text}
GET  /health → {status: loading|ready|failed}
```

- 推理全局串行（MLX 非线程安全）；输出自动剥离 `<|det|>` 定位标记与分词伪影
- Prompt 遵循模型卡：纯文本用 `Free OCR.`，版面模式用 `<|grounding|>Convert the document to markdown.`（MLX 路径下避免 `document parsing.`，会提前停止）
- 进程崩溃/掉线会在设置页显示故障原因与日志

## 局域网 Web API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/` | Web 前端页面 |
| GET | `/api/status` | 服务状态（含 OCR 引擎） |
| GET | `/api/llm/providers` | 已启用的 LLM 列表（不含密钥） |
| POST | `/api/ocr` | 上传文件识别（body 为文件二进制，文件名放 `X-File-Name` 头） |
| POST | `/api/pdf-to-word` | 上传 PDF，返回 .docx 文件流 |
| POST | `/api/chat` | JSON `{provider?, messages:[{role,content}]}` → `{reply}` |

## 目录结构

```
Sources/DocuMind/
├── DocuMindApp.swift           # 应用入口
├── AppState.swift              # 全局状态（任务/服务/聊天/MLX 引擎）
├── Models/                     # 设置、任务、LLM 配置模型
├── Services/
│   ├── OCREngine.swift         # OCR 引擎协议 + 工厂（本地/云端可切换）
│   ├── BaiduOCRService.swift   # 百度云 OCR（token 缓存/重试/图片压缩）
│   ├── LocalVLMOCRService.swift# 本地 MLX 推理客户端
│   ├── MLXServerManager.swift  # venv 引导/pip 安装/进程生命周期/健康检查
│   ├── MLXServerScript.swift   # 内嵌 Python 推理服务脚本
│   ├── DocumentProcessor.swift # PDF/图片/docx/xlsx 统一处理管线
│   ├── OfficeTextExtractor.swift
│   ├── DocxBuilder.swift       # 最小 OOXML docx 生成器
│   ├── PDFToWordService.swift
│   └── LLM/                    # OpenAI 兼容 + Anthropic 双协议客户端（SSE）
├── Server/                     # 局域网 HTTP 服务 + 内嵌 Web 前端
└── Views/                      # SwiftUI 界面
```

## 安全说明

- 本地 OCR 全程离线，文档不出本机；LLM 对话只把文本发给你配置的云端服务商；
- 密钥保存在 `~/Library/Application Support/DocuMind/settings.json`（明文，注意备份安全）；
- 局域网服务**无鉴权**，请勿在不可信网络开启，更不要映射到公网；
- 本地推理服务仅绑定 127.0.0.1，局域网不可直接访问模型端口。

## 参考

- 模型：[baidu/Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR)（MIT）· [论文 arXiv:2606.23050](https://arxiv.org/abs/2606.23050)
- MLX 量化（[sahilchachra 量化系列](https://huggingface.co/sahilchachra)，FUNSD 评测）：默认 MXFP8（CER 1.46%）· Int8 1.57% · Int4 2.29% · MXFP4 2.39%
- 运行时：[mlx-vlm](https://github.com/Blaizzy/mlx-vlm)（≥ 0.6.0）
