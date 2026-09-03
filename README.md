# DocuMind

macOS 文档智能平台（Swift + SwiftUI）：**本地 Unlimited-OCR 结构化识别**、**版面保持的 PDF 转 Word**、任务队列、SQLite 文档库、云端大模型对话、局域网 Web 访问。

## 功能

| 功能 | 说明 |
| --- | --- |
| 文档识别 | **默认本地运行百度开源 [Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR) 3B 模型（MLX MXFP8 量化版）**，grounding 模式输出**结构化块（标题/正文/表格/图片 + bbox 坐标）**，完全离线免费；可切换 Int8/Int4/MXFP4 档位；支持 PDF（文字版自动走文本层）、图片、docx、xlsx。也可切换为百度智能云 OCR（标准/高精度/无限制套餐） |
| PDF 转 Word（版面保持） | **`PDFToWordService` 统一入口：所有引擎走 blocks → layout → docx**。文字版 PDF 文本层直出；扫描件由本地 Unlimited-OCR 产出语义块（title/text/table/image+bbox），百度云自动切含位置版产出行级块（LayoutAnalyzer 按行距/对齐合并成段落）。Swift Layout Engine（`Services/Layout/`）：Heading 大纲样式、真表格 w:tbl、插图 bbox 裁剪内联嵌入、逐页分页 |
| 任务队列 | **Worker Pool 调度**：OCR（推理）/ Convert（转换）/ Parse（本地解析）三条独立流水线并行分发，任务持久化 SQLite（pending/running/success/failed），Web/App 提交即返回 task_id；长 PDF 转换不阻塞图片识别入队 |
| 文档库 | 所有处理文件自动入库：`documents` / `document_versions` / `ocr_results` / `tasks` 四表，文件存于 `~/Library/Application Support/DocuMind/library/`，App 与 Web 均可检索、查看、导出 |
| 局域网 Web | 内置零依赖 HTTP 服务（Network.framework），局域网设备浏览器打开 `http://<Mac的IP>:8080` 即可使用全部功能 |
| 云端 LLM | OpenAI 兼容协议（**DeepSeek、Kimi、通义千问、OpenAI 及任意兼容网关**）+ **Anthropic Messages 协议**，App 内 SSE 流式输出 |

## 环境要求

- macOS 13+，Apple Silicon（M1 16GB 可流畅运行本地 3B 模型）
- Python 3.10+（Xcode 命令行工具自带的 `/usr/bin/python3` 即可，App 会自动创建独立 venv，不污染系统环境）
- 构建需要 Xcode 15+ 或 Command Line Tools（含 Swift 5.9+）
- 首次启动本地引擎需联网下载依赖（mlx-vlm，~300MB）和模型（~3.6GB），默认走国内镜像加速

## 构建与运行

```bash
# 开发调试（直接运行）
swift run DocuMind

# 打包为 DocuMind.app
bash scripts/build-app.sh
open dist/DocuMind.app
```

也可以直接用 Xcode 打开 `Package.swift` 运行。每次 push 到 main，GitHub Actions（macos-14）自动编译、测试、打 tag 并发布 Release。

## 首次配置

1. **OCR（本地引擎，推荐）**：打开 App → `⌘,` → 「OCR 引擎」→ 点「安装环境并启动」。App 会自动：创建 venv → 安装依赖 → 下载模型 → 启动推理服务（仅监听 127.0.0.1）。日志面板可见下载进度，就绪后状态变绿。
   - 模型默认 [mlx-community/Unlimited-OCR-mxfp8](https://huggingface.co/mlx-community/Unlimited-OCR-mxfp8)（config 原生修复版）；可切换 [sahilchachra 量化系列](https://huggingface.co/sahilchachra) 的 MXFP8 / Int8 / Int4 / MXFP4
2. **OCR（百度云，可选）**：引擎切换为「百度智能云 OCR」，填入[控制台](https://console.bce.baidu.com/ai-engine/ocr/overview/index)创建的 API Key / Secret Key 即可。PDF 转 Word 时自动升级使用含位置版接口，按行级坐标重建段落版面（无表格/图片语义，完整语义版面请用本地引擎）。
3. **大模型**：设置 → 大模型 → 添加预设（DeepSeek / Kimi / 千问 / OpenAI / Anthropic 已内置 Base URL 与默认模型），填入 API Key。
4. **局域网服务**：「局域网服务」页点「启动服务」，手机/其他电脑浏览器访问列表地址。

## 核心管线：PDF → Word（PDFToWordService 统一入口）

```
PDFToWordService.convert()
   │
   ├─ 文字版 PDF → PDFKit 文本层直出 → DocxBuilder（简单排版，零误差秒级）
   │
   └─ 扫描版 PDF → blocks → layout → docx：
        │
        ▼ 结构化块来源（按引擎）
        ├─ 本地 Unlimited-OCR：grounding 语义块 {title/text/table/image, bbox, page}
        └─ 百度云（自动升级含位置版）：行级 location 合成 blocks
        │
        ▼  Services/Layout/LayoutAnalyzer.swift
        类别映射 · 标题级别按 bbox 高度推断 · markdown 表格解析 · 行级块按行距合并成段落
        │
        ▼  Services/Layout/DocxLayoutBuilder.swift（OOXML）
        Heading1-3 大纲样式 / 真 w:tbl 表格 / w:drawing 插图（bbox 裁剪，宽度自适应）/ 分页符
        │
        ▼
   output.docx
```

## 本地引擎架构

App 内嵌一个 Python sidecar（`MLXServerScript.swift`），全部文件在 `~/Library/Application Support/DocuMind/mlx/`：

```
App(Swift) ──HTTP 127.0.0.1:8091──> mlx_server.py (venv 内 python)
                                        └─ mlx_vlm.load("mlx-community/Unlimited-OCR-mxfp8")
POST /ocr     {image: base64, mode: text|markdown} → {text, blocks:[{category,bbox,content,page}]}
GET  /health  → {status, model, error}
```

- 推理全局串行（MLX 非线程安全）；输出自动剥离 `<|det|>` 定位标记与分词伪影
- Prompt 遵循模型卡：纯文本用 `Free OCR.`，版面模式用 `<|grounding|>Convert the document to markdown.`
- 进程崩溃/掉线会在设置页显示故障原因与日志

## 数据模型（SQLite）

`~/Library/Application Support/DocuMind/library/documind.db`：

| 表 | 说明 |
| --- | --- |
| `documents` | 文档主表（id/name/kind/created_at） |
| `document_versions` | 版本表（文件物理路径、大小、版本号） |
| `ocr_results` | 识别结果（全文 + blocks_json 结构化块 + 引擎 + 页数） |
| `tasks` | 任务队列表（类型/状态/进度/引擎/产物路径/错误） |

## 局域网 Web API

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/` | Web 前端页面（识别/转换/任务队列/文档库/对话） |
| GET | `/api/status` | 服务状态（含引擎运行状态） |
| POST | `/api/ocr` | 上传文件识别（body 为文件二进制 + `X-File-Name` 头）→ `{task_id}` |
| POST | `/api/pdf-to-word` | 上传 PDF → `{task_id}` |
| GET | `/api/tasks` | 任务列表 |
| GET | `/api/tasks/{id}` | 任务详情（OCR 成功时含 text） |
| GET | `/api/tasks/{id}/download` | 下载产物（docx / txt） |
| GET | `/api/documents` | 文档库列表 |
| GET | `/api/documents/{id}` | 文档详情（版本 + 最新识别文本） |
| GET | `/api/llm/providers` | 已启用的 LLM 列表（不含密钥） |
| POST | `/api/chat` | JSON `{provider?, messages:[{role,content}]}` → `{reply}` |

## 目录结构

```
Sources/DocuMind/
├── DocuMindApp.swift           # 应用入口
├── AppState.swift              # 全局状态（队列/文档库/服务/聊天/MLX 引擎）
├── Models/                     # 设置、文档类型、LLM 配置
├── Storage/
│   ├── Database.swift          # libsqlite3 极简封装（串行队列，零依赖）
│   ├── Records.swift           # 数据记录 + OCRBlock 结构化块
│   └── DocumentStore.swift     # 四表 CRUD + 文件入库
├── Services/
│   ├── TaskQueue.swift         # Worker Pool 调度（OCR/Convert/Parse 三流水线，持久化）
│   ├── OCREngine.swift         # OCR 引擎协议 + 工厂（本地/云端可切换）
│   ├── BaiduOCRService.swift   # 百度云 OCR（token 缓存/重试/图片压缩）
│   ├── LocalVLMOCRService.swift# 本地 MLX 推理客户端（blocks 解析）
│   ├── MLXServerManager.swift  # venv 引导/pip 安装/进程生命周期/健康检查
│   ├── MLXServerScript.swift   # 内嵌 Python sidecar（纯推理）
│   ├── Layout/                 # ★ 版面引擎（纯 Swift，可测试）
│   │   ├── Block.swift         #   LayoutElement 版面元素模型
│   │   ├── LayoutAnalyzer.swift#   OCRBlock → 版面元素（类别映射/表格解析/标题级别）
│   │   ├── DocxLayoutBuilder.swift # 版面元素 → OOXML docx（样式/表格/插图/分页）
│   │   └── LayoutPDFConverter.swift# 转换编排（逐页渲染→识别→裁剪→构建，内存受控）
│   ├── DocumentProcessor.swift # PDF/图片/docx/xlsx 统一处理管线
│   ├── OfficeTextExtractor.swift
│   ├── DocxBuilder.swift       # 最小 OOXML docx 生成器（文本层直出快路径）
│   ├── PDFToWordService.swift  # ★ PDF→Word 统一入口（文本层快路径 / blocks→layout→docx）
│   └── LLM/                    # OpenAI 兼容 + Anthropic 双协议客户端（SSE）
├── Server/                     # 局域网 HTTP 服务 + 内嵌 Web 前端
└── Views/                      # SwiftUI 界面（识别/转换/文档库/对话/服务/设置）
```

## 安全说明

- 本地 OCR 全程离线，文档不出本机；LLM 对话只把文本发给你配置的云端服务商；
- 密钥保存在 `~/Library/Application Support/DocuMind/settings.json`（明文，注意备份安全）；
- 局域网服务**无鉴权**，请勿在不可信网络开启，更不要映射到公网；
- 本地推理服务仅绑定 127.0.0.1，局域网不可直接访问模型端口。

## 参考

- 模型：[baidu/Unlimited-OCR](https://huggingface.co/baidu/Unlimited-OCR)（MIT）· [论文 arXiv:2606.23050](https://arxiv.org/abs/2606.23050)
- MLX 量化（[sahilchachra 量化系列](https://huggingface.co/sahilchachra)，FUNSD 评测）：MXFP8（CER 1.46%）· Int8 1.57% · Int4 2.29% · MXFP4 2.39%
- 运行时：[mlx-vlm](https://github.com/Blaizzy/mlx-vlm)（≥ 0.6.0）
