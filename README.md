<div align="center">

<img src="docs/images/banner.png" alt="Flash All In One" width="100%">

# Flash All In One

**全宇宙中功能最全的刷机工具箱**

[![Flutter](https://img.shields.io/badge/Flutter-3.47-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux-blue)]()
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Version](https://img.shields.io/badge/Version-1.0.0-orange)]()

刷机，从未如此简单

</div>

---

## 这是什么

一个用 Flutter 写的跨平台安卓刷机工具箱，把散落在各个命令行工具里的刷机、解锁、Root、救砖能力整合到一个图形界面里。

**目标**：让刷机从「背命令 + 找工具 + 查文档」变成「点几下」。

**设计原则**：
- **内置工具**：不用自己下载 adb、fastboot、各种刷机工具，全都打包好了
- **危险操作折叠**：解锁、分区读写、EDL 等高风险功能默认隐藏，需确认用户协议才能进入
- **不重复造轮子**：直接集成业界成熟的开源工具，做好界面和流程编排

---

## 功能

### 设备管理

| 功能 | 说明 |
|---|---|
| 设备总览 | 型号、系统、CPU、电池、内存、存储，**支持 fastboot 模式** |
| 屏幕控制 | 截图、点击模拟、14 个常用按键 |
| 实时投屏 | 基于 scrcpy，码率/帧率可调 |
| Shell 终端 | 交互式命令执行，支持历史记录 |
| 无线 ADB | Wi-Fi 配对连接 |
| 一键诊断 | 4 组检查，自动给出修复建议 |
| 日志查看 | 实时 logcat，级别/缓冲区/内容过滤 |
| 性能追踪 | 基于 Perfetto，5 种采集预设 |

### 应用与文件

| 功能 | 说明 |
|---|---|
| 应用管理 | 安装、卸载、冻结、清数据 |
| 系统精简 | 基于 UAD-ng，1500+ 包风险分级，支持批量禁用/卸载 |
| APK 工具 | 反编译、重打包、签名、合并 split APK |
| 文件管理 | 浏览、上传、下载、删除、新建，**中文路径正常** |
| 批量操作 | 多应用批量处理 |
| 脚本录制 | 命令序列保存/回放 |

### 刷机

| 功能 | 说明 |
|---|---|
| Fastboot 刷机 | 分区刷入、擦除、A/B 切换 |
| MTK 刷机 | 基于 mtkclient，BROM 模式 |
| 厂商专用 | 三星（Heimdall + samloader 固件下载）、紫光展锐、OTA payload、cust 分区 |
| 一键 Root | Magisk / KernelSU / APatch 等 5 种方案 |

### 高级功能（需协议确认）

| 功能 | 说明 |
|---|---|
| Bootloader 解锁 | **9 种方式**：fastboot oem / MTK seccfg / 华为 NVME / MTK LK 补丁 / LK 分析 / RPMB 扫描 / Val Protocol / 骁龙小米 |
| EDL 深度刷机 | 高通 9008，支持 qdl（跨平台）和 fh_loader |
| 镜像工具 | vbmeta 校验开关、EROFS/F2FS 解包打包、sparse 转换 |
| 分区读写 | 导出、刷入、擦除任意分区 |

---

## iOS 与开发板

### iOS 设备管理

基于 libimobiledevice（8300★）+ idevicerestore（2001★）：

- 读设备信息 / IPSW 刷写（升级或全新）/ 进恢复模式
- 备份 / 系统日志 / 截图 / 诊断

### iOS 越狱

**palera1n 2.4**（6613★，MIT）—— checkm8 漏洞

| 芯片 | 机型 | 支持 |
|---|---|---|
| A11 | iPhone 8 / 8 Plus / X | ✅ |
| A10 | iPhone 7 / 7 Plus | ✅ |
| A9 | iPhone 6s / 6s Plus / SE 1 | ✅ |
| A8 | iPhone 6 / 6 Plus | ✅ |
| A12+ | iPhone XS 及以后 | ❌ |

**Dopamine 3.0.12**（7147★，MIT）—— iOS 15-26，A12-A16

**Windows 原生**：gaster（pwned DFU）+ openra1n（PongoOS）

### 智能穿戴 / 开发板

8 个 Tab，覆盖 12 类平台：

| Tab | 工具 | 用途 |
|---|---|---|
| ESP32 | esptool 5.6.0 | 15 种芯片，ESP8266/ESP32 全系 |
| Pico | picotool 2.3.1 | RP2040 / RP2350 |
| STM32 | stlink 1.9.0 | 81 个芯片型号 |
| nRF52 | nrfutil 6.1.7 | DFU 刷写（串口/BLE/Thread/Zigbee/ANT） |
| JTAG | openocd 0.12.0 | 49 接口 × 309 芯片，最后的救砖手段 |
| 树莓派 | rpiboot | USB Boot 模式 |
| Arduino | arduino-cli 1.5.1 | 编译上传 |
| 小米穿戴 | AstroBox-NG | Vela 系统（外链） |

### TTL / 串口

**tio 3.9**（3210★）—— 自动重连、时间戳、hex 模式、DTR/RTS 时序

---

## 插件系统

主程序 382 MB，主要体积是内置工具。**新功能走插件**，主程序不再膨胀。

### 怎么用

```
插件 → 点「+」→ 选择 .zip → 自动出现在左侧列表
```

### 插件能做什么

插件是**声明式**的：用 `plugin.json` 描述 UI 和命令，由主程序解释执行。
不加载任何外部代码，安全可控。

```json
{
  "id": "picotool",
  "name": "树莓派 Pico",
  "version": "2.3.1",
  "tools": [{"name": "picotool", "path": "tools/picotool", "platform": "linux"}],
  "ui": {
    "inputs": [{"id": "firmware", "type": "file", "label": "固件"}],
    "cards": [{
      "title": "操作",
      "actions": [
        {"label": "刷入", "tool": "picotool",
         "args": ["load", "{input:firmware}", "-x"],
         "confirm": "确认刷入？", "danger": true}
      ]
    }]
  }
}
```

### 开发插件

看 [PLUGIN_AGENTS.md](PLUGIN_AGENTS.md) —— 完整的插件开发规范，
包括如何把任意开源刷机工具转换成插件。

---

## 内置工具

全部内置，无需额外下载：

| 工具 | 用途 | 许可证 |
|---|---|---|
| adb / fastboot | 设备通信 | Apache-2.0 |
| qdl | 高通 EDL 刷机（跨平台） | BSD-3-Clause |
| samloader | 三星固件下载与刷写 | Apache-2.0 |
| Heimdall | 三星 Odin 替代 | MIT |
| spreadtrum_flash | 紫光展锐刷机 | **Unlicense** |
| mtkclient | MTK BROM 刷机 | GPL-3.0 |
| scrcpy | 投屏 | Apache-2.0 |
| GhostLock | 临时 Root（CVE-2026-43499） | Apache-2.0 |
| KernelSU | 内核级 Root（16 个 .ko） | GPL-3.0 |
| UAD-ng | 系统精简 | GPL-3.0 |
| apktool / jadx / APKEditor | APK 处理 | Apache-2.0 |
| payload-dumper-go | OTA 提取 | Apache-2.0 |
| EROFS / F2FS / ext4 工具链 | 镜像处理 | 多种开源许可 |

---

## 快速开始

### 下载

从 [Releases](https://github.com/cloudylynx/flash-all-in-one/releases) 下载最新版：

- **Windows**：`FlashAllInOne-v1.0.0-win64.zip`，解压后运行 `flashallinone.exe`
- **Linux**：`FlashAllInOne-v1.7.0-linux-x64.tar.gz`（382.6 MB，含全部内置工具）

> **v1.7.0 更新**：新增 iOS 设备管理 + 越狱（palera1n / Dopamine）、
> TTL 串口、nRF52、JTAG，智能穿戴/开发板扩到 8 个 Tab

**Linux 包分卷说明**（因单文件过大，Release 里拆成 4 个分卷）：

```bash
# 下载全部 4 个分卷后合并
cat FlashAllInOne-v1.7.0-linux-x64.tar.gz.part0 \
    FlashAllInOne-v1.7.0-linux-x64.tar.gz.p1_0 \
    FlashAllInOne-v1.7.0-linux-x64.tar.gz.p1_1 \
    FlashAllInOne-v1.7.0-linux-x64.tar.gz.part2 \
    > FlashAllInOne-v1.7.0-linux-x64.tar.gz

tar xzf FlashAllInOne-v1.7.0-linux-x64.tar.gz
./flashallinone
```

### 从源码构建

```bash
# 需要 Flutter 3.47+
git clone https://github.com/cloudylynx/flash-all-in-one.git
cd flash-all-in-one
flutter pub get

# Windows
flutter build windows --release

# Linux
flutter build linux --release
```

### 使用前准备

1. 手机开启「开发者选项」→「USB 调试」
2. 用数据线连接电脑
3. 手机上点「允许 USB 调试」

---

## 关于 scrcpy

内置 scrcpy v5.0.1（Windows 版）。**Linux/macOS 请用系统包管理器安装**：

```bash
# Ubuntu / Debian
sudo apt install scrcpy

# macOS
brew install scrcpy
```

---

## 安全说明

**刷机有风险。** 本工具集成了一些高风险功能：

- Bootloader 解锁会**清空所有数据**
- 分区读写操作错误会**导致变砖**
- EDL 模式操作不当可能**永久损坏设备**

高级功能首次进入需完整阅读并输入确认短语。**请确保你知道自己在做什么。**

作者不对任何设备损坏或数据丢失负责。

---

## 技术栈

- **Flutter 3.47** + Dart 3.13
- **Provider** 状态管理
- 25,000+ 行 Dart 代码，24 个页面，29 个服务

---

## 致谢

本项目的刷机能力建立在众多开源项目之上：

[bkerler/mtkclient](https://github.com/bkerler/mtkclient) ·
[linux-msm/qdl](https://github.com/linux-msm/qdl) ·
[topjohnwu/samloader-rs](https://github.com/topjohnwu/samloader-rs) ·
[Benjamin-Dobell/Heimdall](https://github.com/Benjamin-Dobell/Heimdall) ·
[ilyakurdyukov/spreadtrum_flash](https://github.com/ilyakurdyukov/spreadtrum_flash) ·
[tiann/KernelSU](https://github.com/tiann/KernelSU) ·
[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) ·
[YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app) ·
[Universal-Debloater-Alliance](https://github.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation) ·
[Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) ·
[iBotPeaches/Apktool](https://github.com/iBotPeaches/Apktool) ·
[ssut/payload-dumper-go](https://github.com/ssut/payload-dumper-go)

特别感谢 [Linuxoid-cn/Mi8G3-Unlocker](https://github.com/Linuxoid-cn/Mi8G3-Unlocker) 提供的骁龙小米解锁技术路线。

---

## 许可证

[MIT License](LICENSE)

第三方工具的许可证见各自项目。

---

<div align="center">

**让刷机更简单 · 让玩机更自由**

</div>
