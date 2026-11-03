<div align="center">

# Flash All In One

**全宇宙中功能最全的刷机工具箱**

Flutter 跨平台 · Windows / Linux · 135 项能力 · 44 个服务模块

[下载](#下载) · [功能](#功能矩阵) · [插件](#插件系统) · [构建](#从源码构建) · [文档](docs/用户手册.docx)

</div>

---

## 这是什么

一个把「刷机、救砖、系统改造、开发板烧录」全都装进一个界面的工具箱。

前身是 Windows 上的《搞机助手》，用 Flutter 重写后：

- **跨平台**：Windows / Linux 同一套代码
- **功能密度**：35 个页面、44 个服务、46,588 行 Dart
- **插件化**：功能可以按需安装，不装就是干净的核心
- **不联网**：所有操作本地完成，不上传任何数据

> ⚠️ **免责声明**：刷机有风险，操作前请务必备份。作者不对设备损坏负责。

---

## 功能矩阵

### 设备管理

| 功能 | 说明 |
|---|---|
| 设备总览 | 型号、系统、内核、分辨率、Root 状态、连接方式 |
| 屏幕镜像 | scrcpy 集成，支持有线/无线、画质调节、按键映射 |
| Shell 终端 | 内置 adb shell，支持命令历史、常用命令快捷 |
| 无线 ADB | 一键切换 WiFi 调试，支持配对码连接 |
| 一键诊断 | 20+ 项设备健康检查（分区、SELinux、电量、温度…） |
| 性能追踪 | perfetto 集成，CPU/内存/帧率实时曲线 |
| 日志查看 | logcat 实时过滤，按 tag/优先级/进程筛选 |
| 脚本录制 | 录制 ADB 操作序列，生成可复用脚本 |

### 应用与文件

| 功能 | 说明 |
|---|---|
| 应用管理 | 安装/卸载/冻结/清除数据，显示包名、版本、大小 |
| 安装 APK | 拖拽安装，支持多文件队列、降级安装 |
| APK 工具 | 反编译（apktool）、签名（uber-apk-signer）、查看 manifest |
| 系统精简 | 预置 100+ 可卸载系统应用，按厂商分类，支持恢复 |
| 批量操作 | 批量安装/卸载/导出，支持正则筛选 |
| 文件管理 | 双栏文件管理器，支持推送/拉取/压缩/解压 |

### 刷机

| 功能 | 说明 |
|---|---|
| Fastboot 刷机 | 分区列表、批量刷写、A/B 槽切换、临时启动 |
| ADB Sideload | 侧载 OTA 包，显示进度和速度 |
| MTK 刷机 | MTK BROM 模式，支持 scatter 文件解析 |
| 厂商专用 | 三星（Odin 协议）、小米（MiFlash）、OPPO/vivo |
| EDL 深度刷机 | 高通 9008，支持 rawprogram.xml 解析、分区表读取、**loader 自动匹配** |
| OTA 造包 | payload.bin 解包/重打包、AVB 重签（avbroot） |
| 镜像工具 | sparse 转换、vbmeta 解析/改 flags、**super.img 动态分区解析**、**内核补丁检测** |
| 数据恢复 | 分区扫描、误删文件恢复（testdisk/photorec） |

### 系统改造

| 功能 | 说明 |
|---|---|
| 一键 Root | Magisk / KernelSU / APatch，支持 boot.img 修补 |
| 开机 Logo | `splash.img` 读写，支持多图替换、RLE 压缩 |
| 分区扩容 | userdata 扩容、分区表调整（sgdisk） |
| 多系统工具箱 | 字库备份、分区表备份、基带备份、**合成大容量 Boot** |
| 分区读写 | 任意分区读取/写入/擦除，支持 dd 直读 |
| BL 解锁 | 各厂商解锁流程引导 + 状态检测 |

### 进阶

| 功能 | 说明 |
|---|---|
| BL 解锁助手 | 小米/一加/OPPO/vivo/三星/华为 解锁状态查询 |
| EDL 深度刷机 | 高通 Firehose 协议，支持 lint 模式（只读） |
| OTA 造包 | 增量 OTA 生成、payload 签名 |
| 数据恢复 | 分区级恢复、GPT 修复 |
| 单板电脑 | ARM 开发板烧录（RK / 全志 / 树莓派） |

### iOS

| 功能 | 说明 |
|---|---|
| 设备管理 | info/backup/restore（libimobiledevice） |
| 刷 IPSW | idevicerestore，支持保留数据 |
| 越狱 | palera1n / checkra1n（checkm8，A5~A11） |
| DFU 模式 | 进入/退出，pwn DFU（gaster / openra1n） |

### 扩展

| 功能 | 说明 |
|---|---|
| 插件管理 | 安装/卸载/执行，支持参数化 |
| TTL / 串口 | 串口终端，支持波特率/数据位/流控 |
| 开发板 | Arduino / ESP32 / STM32 / Pico / nRF / RP2040 |

---

## 插件系统

核心功能之外，所有扩展能力都以插件形式提供。

### 已发布的插件

| 插件 | 大小 | 内容 |
|---|---|---|
| **edl-loader-pack** | 154 MB | 878 个高通 Firehose loader，覆盖 48 个厂商 |
| **super-tools** | 7.9 MB | lpmake / lpunpack / lpadd / lpflash + sparse 工具 |
| **ios-toolkit** | 7.1 MB | libimobiledevice 全套（iproxy / imagemounter / provision…） |
| **all-plugins-collection** | 383 MB | 27 个插件合集 |

### 插件能做什么

插件可以：

- 提供可执行工具（Windows `.exe` / Linux 二进制）
- 声明 UI（输入框、选择器、按钮）
- 用占位符传参：`{input:file}` / `{pluginDir}` / `{toolDir}`

装了就出现在侧栏，不装就完全不可见 —— 不污染核心界面。

### 自己写插件

最小插件只需要两个文件：

```
my-plugin/
├── plugin.json
└── tools/windows/mytool.exe
```

`plugin.json`：

```json
{
  "id": "my-plugin",
  "name": "我的工具",
  "version": "1.0.0",
  "description": "演示插件",
  "author": "你的名字",
  "icon": "build",
  "category": "工具",
  "tools": [
    {
      "name": "mytool",
      "path": "tools/windows/mytool.exe",
      "platform": "windows",
      "executable": true
    }
  ],
  "ui": {
    "inputs": [
      { "id": "file", "type": "file", "label": "输入文件" }
    ],
    "cards": [
      {
        "title": "操作",
        "actions": [
          {
            "label": "执行",
            "tool": "mytool",
            "args": ["--input", "{input:file}"],
            "timeout": 300
          }
        ]
      }
    ]
  }
}
```

打包成 zip 后从「插件管理」页面导入即可。

**完整开发指南见** [`docs/插件开发指南.md`](docs/插件开发指南.md)

---

## 内置工具

| 类别 | 工具 |
|---|---|
| Android | adb 37.0.1、fastboot、scrcpy、sgdisk、e2fsprogs |
| 镜像 | lpmake、simg2img、img2simg、mkfs.erofs、extract.erofs、dump.erofs |
| 高通 | QSaharaServer、fh_loader、qdl、devcon |
| MTK | mtk.exe（Mindows 打包）、magiskboot |
| 签名 | uber-apk-signer、apksigner、avbroot、otasigner |
| iOS | idevicerestore、libimobiledevice 全套、palera1n、gaster、openra1n |
| 系统 | ResourceHacker（去水印）、7z、testdisk |

总计 **384 MB** 工具资源，全部随包分发，不需要额外下载。

---

## 安全设计

### 命令注入防护

所有用户输入在拼进 shell 命令前都经过白名单校验：

```dart
// 拦截 /dev/block/sda; rm -rf / 这类载荷
if (!InputSanitizer.isValidDevicePath(path)) {
  throw ArgumentError(InputSanitizer.explainDevicePath(path));
}
```

覆盖的字段：设备路径、分区名、卷标、串口、挂载点、host:port。

**24 个安全测试**覆盖各种注入手法（分号、管道、与号、反引号、`$()`、重定向、换行）。

### 不联网

- 没有遥测、没有崩溃上报、没有自动更新
- 唯一的网络访问是插件下载（用户主动触发）
- 所有设备操作走本地 adb/fastboot

### 权限

- Windows：不需要管理员权限（除驱动安装）
- Linux：把当前用户加入 `plugdev` 组即可

---

## 下载

### Windows

```
https://github.com/cloudylynx/flash-all-in-one/releases/latest
```

### 插件

```
edl-loader-pack.zip          154 MB   878 个 EDL loader
super-tools.zip              7.9 MB   动态分区工具
ios-toolkit.zip              7.1 MB   iOS 工具链
all-plugins-collection.zip   383 MB   27 个插件合集
```

### 使用前准备

1. **安装 adb 驱动**（Windows）：小米/一加等厂商驱动，或通用 ADB 驱动
2. **开启 USB 调试**：设置 → 关于手机 → 连点版本号 7 次 → 开发者选项
3. **授权调试**：首次连接手机弹窗点「允许」

---

## 从源码构建

### 依赖

- Flutter 3.47+
- Windows: Visual Studio 2022（C++ 桌面开发）
- Linux: `clang cmake ninja-build libgtk-3-dev`

### 命令

```bash
flutter pub get

# Windows
flutter build windows --release

# Linux
flutter build linux --release
```

### 在 Linux 上交叉编译 Windows 版

需要 wine + mingw-w64，完整步骤见 [`docs/BUILD-WINDOWS-ON-LINUX.md`](docs/BUILD-WINDOWS-ON-LINUX.md)。

### 跑测试

```bash
flutter test
```

当前 **86 个测试**，覆盖：
- 输入清洗（24 个）
- GPT 解析（6 个）
- vbmeta（4 个）
- LP 元数据（17 个）
- 内核检测（16 个）
- 插件参数（16 个）
- 应用冒烟（3 个）

---

## 技术栈

| 层 | 技术 |
|---|---|
| UI | Flutter 3.47 + Material 3 |
| 状态 | provider |
| 平台 | Windows / Linux |
| 打包 | MSIX（Windows） / AppImage（Linux） |
| 测试 | flutter_test |

### 项目结构

```
lib/
├── core/          工具函数（输入清洗、进程执行、配置）
├── services/      44 个业务服务
└── ui/
    ├── pages/     35 个页面
    ├── widgets/   通用组件
    └── theme/     主题定义
```

---

## 许可

MIT License

第三方工具遵循各自许可证（见 `assets/tools/**/licenses/`）。

---

## 致谢

本项目的很多技术方案学习自这些开源项目：

- [bkerler/edl](https://github.com/bkerler/edl) — 高通 EDL 协议
- [bkerler/Loaders](https://github.com/bkerler/Loaders) — 878 个 Firehose loader
- [bkerler/mtkclient](https://github.com/bkerler/mtkclient) — MTK BROM
- [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) — iOS 通信
- [palera1n](https://github.com/palera1n/palera1n) — checkm8 越狱
- [avbroot](https://github.com/chenxiaolong/avbroot) — AVB 重签
- [AOSP partition_tools](https://android.googlesource.com/platform/system/core/) — LP 元数据
- [Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) — 屏幕镜像

以及 Mindows、UotanToolboxNT、VioletToolBox、ios-sweet-wip 等项目的思路启发。
