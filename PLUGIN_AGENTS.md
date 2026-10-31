# Flash All In One 插件开发规范

> 这份文档给 AI Agent 或人类开发者看：**如何把任意开源刷机工具转换成 Flash All In One 插件**。

---

## 为什么用插件

主程序已经 382 MB，主要体积是内置工具。**新功能走插件**可以：

- 主程序不膨胀
- 用户按需安装
- 插件独立更新
- 失败不影响主程序

---

## 核心约束：声明式，不是代码

**Flutter 不能动态加载 Dart 代码。** 所以插件必须是**声明式**的：

```
plugin.json  →  描述 UI 和命令  →  主程序解释执行
tools/       →  实际的二进制文件
```

**不能做的事**：
- ❌ 插件里写 Dart / JavaScript 代码
- ❌ 插件动态链接进主程序
- ❌ 插件访问主程序内部 API

**能做的事**：
- ✅ 声明输入项（文本框 / 文件选择 / 下拉框 / 开关）
- ✅ 声明操作（调用插件自带的二进制，传参数）
- ✅ 用 `{input:xxx}` 占位符引用输入值

---

## 插件包结构

```
my-plugin.zip
├── plugin.json          ← 必需，清单文件
├── tools/               ← 二进制工具（可选）
│   ├── mytool           ← Linux
│   └── mytool.exe       ← Windows
├── assets/              ← 数据文件（可选）
│   └── profiles/
└── README.md            ← 说明（可选）
```

**解压后目录**：
```
Linux:   ~/.local/share/io.github.flashallinone/plugins/<id>/
Windows: %APPDATA%\Flash All In One\Flash All In One\plugins\<id>\
```

---

## plugin.json 完整规范

```json
{
  "id": "unique-plugin-id",
  "name": "插件显示名",
  "version": "1.0.0",
  "description": "一句话说明这个插件做什么",
  "author": "作者名",
  "homepage": "https://github.com/you/repo",
  "license": "MIT",
  "icon": "extension",
  "category": "flashing",
  "tools": [
    {
      "name": "mytool",
      "path": "tools/mytool",
      "platform": "any",
      "executable": true
    }
  ],
  "ui": {
    "inputs": [...],
    "cards": [...]
  }
}
```

### 顶层字段

| 字段 | 必需 | 说明 |
|---|---|---|
| `id` | ✅ | 唯一标识，只能用小写字母、数字、连字符。**解压后的目录名** |
| `name` | ✅ | 显示名 |
| `version` | ✅ | 语义化版本 |
| `description` | ✅ | 一句话说明 |
| `author` | ✅ | 作者 |
| `homepage` | ❌ | 项目主页 |
| `license` | ❌ | SPDX 许可证标识 |
| `icon` | ❌ | Material 图标名，默认 `extension` |
| `category` | ❌ | 分类：`flashing` / `debug` / `root` / `tools` / `other` |
| `tools` | ✅ | 二进制列表（可为空数组） |
| `ui` | ✅ | 界面定义 |

### tools 字段

| 字段 | 说明 |
|---|---|
| `name` | 工具名，UI 里用这个引用 |
| `path` | 相对插件目录的路径 |
| `platform` | `linux` / `windows` / `macos` / `any` |
| `executable` | 是否可执行（Linux 会自动 chmod +x） |

### ui.inputs —— 输入项

支持 5 种类型：

```json
{
  "id": "target",
  "type": "text",
  "label": "目标设备",
  "hint": "例如 /dev/ttyUSB0",
  "default": ""
}
```

| type | 说明 | 额外字段 |
|---|---|---|
| `text` | 文本框 | `hint`, `default` |
| `file` | 文件选择 | `hint` |
| `dir` | 目录选择 | `hint` |
| `select` | 下拉框 | `options: [{value, label}]` |
| `bool` | 开关 | `default: "true"/"false"` |

### ui.cards —— 操作卡片

```json
{
  "title": "操作",
  "actions": [
    {
      "label": "刷入固件",
      "description": "把固件写入设备",
      "tool": "mytool",
      "args": ["--flash", "{input:firmware}"],
      "confirm": "确认刷入？写错会导致设备无法启动。",
      "danger": true,
      "icon": "flash_on"
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `label` | 按钮文字 |
| `description` | 副标题说明 |
| `tool` | 引用 `tools[].name` |
| `args` | 参数数组，支持占位符 |
| `confirm` | 确认弹窗文字（可选） |
| `danger` | 是否危险操作（红色） |
| `icon` | Material 图标名 |
| `workDir` | 工作目录（相对插件目录） |

### 占位符

| 占位符 | 替换成 |
|---|---|
| `{input:xxx}` | 输入项 xxx 的值 |
| `{pluginDir}` | 插件根目录绝对路径 |
| `{toolDir}` | `<插件目录>/tools` |

---

## 可用图标名

```
extension  build      flash_on   memory     usb
cable      phone_iphone  developer_board    watch
play_arrow download   upload     delete     settings
info       error      lock_open  security   storage
folder
```

---

## 转换流程：开源工具 → 插件

### 第 1 步：确认工具能用 CLI 调用

**必须**：
- ✅ 有命令行接口（`--help` / `-h` 有输出）
- ✅ 能独立运行（不依赖 GUI）
- ✅ 许可证允许分发

**不行**：
- ❌ 纯 GUI 应用（如 AstroBox）
- ❌ 需要常驻服务
- ❌ 无许可证或禁止分发

### 第 2 步：获取二进制

**优先级**：
1. 官方 release 里的预编译二进制
2. 自己编译（记录编译命令）
3. 交叉编译（Windows 版）

**检查依赖**：
```bash
ldd ./mytool              # Linux 依赖
objdump -p mytool.exe | grep "DLL Name"  # Windows 依赖
```

如果依赖系统库，**必须一起打包**（放 `tools/lib/` 并在 args 里用 `LD_LIBRARY_PATH`）。

### 第 3 步：读 --help 确定命令

```bash
./mytool --help
```

找出：
- 必需参数
- 可选参数
- 危险操作（会改设备 / 清数据）

### 第 4 步：写 plugin.json

**模板**：
```json
{
  "id": "tool-name",
  "name": "工具显示名",
  "version": "1.0.0",
  "description": "从 README 摘一句",
  "author": "原项目作者",
  "homepage": "https://github.com/owner/repo",
  "license": "SPDX-ID",
  "icon": "build",
  "category": "flashing",
  "tools": [
    {"name": "mytool", "path": "tools/mytool", "platform": "any", "executable": true}
  ],
  "ui": {
    "inputs": [
      {"id": "device", "type": "text", "label": "设备", "hint": "/dev/ttyUSB0"}
    ],
    "cards": [
      {
        "title": "操作",
        "actions": [
          {"label": "检测", "tool": "mytool", "args": ["--detect"]},
          {"label": "刷入", "tool": "mytool", "args": ["--flash", "{input:device}"], "confirm": "确认刷入？", "danger": true}
        ]
      }
    ]
  }
}
```

### 第 5 步：打包

```bash
cd my-plugin/
zip -r ../my-plugin.zip plugin.json tools/ assets/ README.md
```

**注意**：`plugin.json` 必须在 ZIP 根目录（或在某个子目录里，程序会自动识别）。

### 第 6 步：测试

1. 主程序 → 插件 → 点「+」导入
2. 检查插件出现在左侧列表
3. 填参数，点操作
4. 看右侧日志

---

## 实际案例

### 案例 1：把 picotool 做成插件

**原始工具**：`raspberrypi/picotool`（1014★，BSD-3-Clause）

```json
{
  "id": "picotool",
  "name": "树莓派 Pico",
  "version": "2.3.1",
  "description": "RP2040/RP2350 固件刷写与调试",
  "author": "Raspberry Pi Foundation",
  "homepage": "https://github.com/raspberrypi/picotool",
  "license": "BSD-3-Clause",
  "icon": "developer_board",
  "category": "flashing",
  "tools": [
    {"name": "picotool", "path": "tools/picotool", "platform": "linux", "executable": true}
  ],
  "ui": {
    "inputs": [
      {"id": "firmware", "type": "file", "label": "固件", "hint": ".uf2 / .elf / .bin"}
    ],
    "cards": [
      {
        "title": "设备",
        "actions": [
          {"label": "列出设备", "tool": "picotool", "args": ["info"], "icon": "usb"},
          {"label": "读固件信息", "tool": "picotool", "args": ["info", "{input:firmware}"], "icon": "info"}
        ]
      },
      {
        "title": "刷写",
        "actions": [
          {
            "label": "刷入固件",
            "tool": "picotool",
            "args": ["load", "{input:firmware}", "-x"],
            "confirm": "将刷入固件并重启设备。",
            "danger": true,
            "icon": "flash_on"
          }
        ]
      }
    ]
  }
}
```

### 案例 2：带依赖库的工具

如果工具依赖 `libfoo.so`：

```
my-plugin/
├── plugin.json
└── tools/
    ├── mytool
    └── lib/
        └── libfoo.so.1
```

`plugin.json` 里：
```json
"tools": [
  {"name": "mytool", "path": "tools/mytool", "platform": "linux", "executable": true},
  {"name": "libfoo", "path": "tools/lib/libfoo.so.1", "platform": "linux", "executable": false}
]
```

**问题**：当前插件引擎不直接支持 `LD_LIBRARY_PATH`。

**临时方案**：写一个 shell 脚本包装：
```bash
#!/bin/sh
export LD_LIBRARY_PATH="$(dirname "$0")/lib:$LD_LIBRARY_PATH"
exec "$(dirname "$0")/mytool" "$@"
```
然后 `tools.mytool.path` 指向这个脚本。

---

## 安全要求

### 必须做

- ✅ 危险操作加 `confirm` 提示
- ✅ 破坏性操作加 `danger: true`
- ✅ 在 `description` 里说清风险

### 禁止做

- ❌ 插件里内置挖矿 / 后门 / 遥测
- ❌ 未经用户确认就修改设备
- ❌ 分发无许可证的二进制
- ❌ 使用 `pkill -f` 这类宽泛杀进程命令

---

## 当前限制

| 限制 | 说明 |
|---|---|
| 无 `LD_LIBRARY_PATH` 支持 | 需用包装脚本 |
| 无环境变量注入 | 同上 |
| 无长驻进程 | 每个操作独立执行 |
| 无插件间通信 | 各自独立 |
| 无 Dart/JS 脚本 | 只能调用外部二进制 |

---

## 未来可能的扩展

如果要突破上述限制，可以考虑：

1. **加 `env` 字段**：允许插件声明环境变量
2. **加 `requires` 字段**：插件依赖检查
3. **加 `scripts` 字段**：允许简单的 shell 脚本片段
4. **WASM 插件**：用 WebAssembly 跑真正的代码（复杂但强大）

---

## 检查清单

打包前逐项确认：

- [ ] `plugin.json` 在 ZIP 根目录
- [ ] `id` 唯一、小写、无空格
- [ ] 所有 `tools[].path` 指向的文件存在
- [ ] Linux 二进制有执行权限（打包前 `chmod +x`）
- [ ] 依赖库已打包（或用了包装脚本）
- [ ] 危险操作有 `confirm`
- [ ] `license` 字段正确
- [ ] `homepage` 指向真实项目
- [ ] 在干净环境测试过导入

---

**最后**：插件系统的目的是**让主程序保持轻量，功能无限扩展**。

每加一个新工具前先问：**这个能不能做成插件？** 如果能，就不要塞进主程序。
