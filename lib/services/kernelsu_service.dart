import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// KernelSU 模块信息
class KsuModule {
  final String name;
  final String arch;        // aarch64 / x86_64
  final String androidVer;  // android12 / android13 ...
  final String kernelVer;   // 5.10 / 5.15 ...
  final String assetPath;

  KsuModule({
    required this.name,
    required this.arch,
    required this.androidVer,
    required this.kernelVer,
    required this.assetPath,
  });

  /// 显示名
  String get displayName => '$androidVer / $kernelVer';

  /// 从文件名解析
  static KsuModule? parse(String fileName) {
    // 格式: aarch64_android12-5.10_kernelsu.ko
    final m = RegExp(r'^(\w+?)_(android\d+)-([\d.]+)_kernelsu\.ko$')
        .firstMatch(fileName);
    if (m == null) return null;
    return KsuModule(
      name: fileName,
      arch: m.group(1)!,
      androidVer: m.group(2)!,
      kernelVer: m.group(3)!,
      assetPath: 'assets/tools/kernelsu/$fileName',
    );
  }
}

/// KernelSU 操作结果
class KsuResult {
  final bool ok;
  final String message;
  final List<String> log;
  KsuResult(this.ok, this.message, [this.log = const []]);
}

/// KernelSU 服务（内核级 Root）
///
/// 技术来源：KernelSU-Next/KernelSU-Next（4671★，GPL-3.0）
///
/// 两种工作模式：
///
/// **① LKM 模式（推荐，不改 boot）**
///   · 从 release 下载对应内核版本的 .ko
///   · 推到设备 /data/local/tmp/
///   · insmod 加载
///   · 重启后失效，需配合 init 脚本持久化
///
/// **② GKI 模式（需要刷 boot）**
///   · 下载 KernelSU 内核镜像
///   · fastboot flash boot
///   · 永久生效
///
/// 优势（相比 Magisk）：
///   · 内核态 Root，隐藏性更好
///   · 不需要修补 boot.img（LKM 模式）
///   · 支持 SUSFS（更强的隐藏）
class KernelSuService {
  KernelSuService._();
  static final KernelSuService instance = KernelSuService._();

  String? _extractDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 所有可用模块（16 个）
  static final List<KsuModule> allModules = [
    'aarch64_android12-5.10_kernelsu.ko',
    'aarch64_android13-5.10_kernelsu.ko',
    'aarch64_android13-5.15_kernelsu.ko',
    'aarch64_android14-5.15_kernelsu.ko',
    'aarch64_android14-6.1_kernelsu.ko',
    'aarch64_android15-6.6_kernelsu.ko',
    'aarch64_android16-6.12_kernelsu.ko',
    'aarch64_android17-6.18_kernelsu.ko',
    'x86_64_android12-5.10_kernelsu.ko',
    'x86_64_android13-5.10_kernelsu.ko',
    'x86_64_android13-5.15_kernelsu.ko',
    'x86_64_android14-5.15_kernelsu.ko',
    'x86_64_android14-6.1_kernelsu.ko',
    'x86_64_android15-6.6_kernelsu.ko',
    'x86_64_android16-6.12_kernelsu.ko',
    'x86_64_android17-6.18_kernelsu.ko',
  ].map((n) => KsuModule.parse(n)).whereType<KsuModule>().toList();

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'kernelsu'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _extractDir = dir.path;
      _available = true;
      return true;
    } catch (_) {
      _available = false;
      return false;
    }
  }

  /// 提取指定模块到本地
  Future<String?> extractModule(KsuModule module) async {
    if (!await init()) return null;
    final target = File(p.join(_extractDir!, module.name));
    if (target.existsSync()) return target.path;

    try {
      final data = await rootBundle.load(module.assetPath);
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  /// 检测设备信息（内核版本 + 架构 + Android 版本）
  Future<DeviceKernelInfo?> detectDevice(String serial) async {
    final adb = await AppConfig.adbPath();

    final kernel = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'uname', '-r'],
        timeout: AppConfig.shortTimeout);
    final kernelVer = kernel.output.trim();

    final arch = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'uname', '-m'],
        timeout: AppConfig.shortTimeout);
    final archStr = arch.output.trim();

    final sdk = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'getprop', 'ro.build.version.sdk'],
        timeout: AppConfig.shortTimeout);
    final sdkVer = int.tryParse(sdk.output.trim()) ?? 0;

    // SDK → Android 版本名
    final androidName = switch (sdkVer) {
      31 => 'android12',
      32 => 'android12',
      33 => 'android13',
      34 => 'android14',
      35 => 'android15',
      36 => 'android16',
      >= 37 => 'android17',
      _ => null,
    };

    // 内核主版本（5.10.198 → 5.10）
    final km = RegExp(r'^(\d+\.\d+)').firstMatch(kernelVer);
    final kernelMajor = km?.group(1);

    if (androidName == null || kernelMajor == null) return null;

    return DeviceKernelInfo(
      serial: serial,
      kernelVersion: kernelVer,
      kernelMajor: kernelMajor,
      arch: archStr.contains('aarch64') || archStr.contains('arm64')
          ? 'aarch64'
          : 'x86_64',
      sdkVersion: sdkVer,
      androidName: androidName,
    );
  }

  /// 自动匹配模块
  KsuModule? matchModule(DeviceKernelInfo info) {
    for (final m in allModules) {
      if (m.arch == info.arch &&
          m.androidVer == info.androidName &&
          m.kernelVer == info.kernelMajor) {
        return m;
      }
    }
    // 退化：只按架构 + Android 版本匹配
    for (final m in allModules) {
      if (m.arch == info.arch && m.androidVer == info.androidName) {
        return m;
      }
    }
    return null;
  }

  /// LKM 模式加载（不改 boot）
  Future<KsuResult> loadLkm({
    required String serial,
    required KsuModule module,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final adb = await AppConfig.adbPath();

    add('══ KernelSU LKM 加载');
    add('  模块: ${module.displayName}');
    add('  (${module.arch})');
    add('');

    // 1. 提取模块
    add('── 提取模块');
    final localPath = await extractModule(module);
    if (localPath == null) {
      return KsuResult(false, '提取模块失败', log);
    }
    add('  ✅ $localPath');
    add('');

    // 2. 推送
    add('── 推送到设备');
    const remotePath = '/data/local/tmp/kernelsu.ko';
    var r = await ProcessRunner.run(
        adb, ['-s', serial, 'push', localPath, remotePath],
        timeout: AppConfig.longTimeout);
    if (!r.ok) {
      return KsuResult(false, '推送失败: ${r.output}', log);
    }
    add('  ✅ $remotePath');
    add('');

    // 3. 检查设备是否支持
    add('── 检查加载条件');
    r = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'ls', '/data/local/tmp/kernelsu.ko'],
        timeout: AppConfig.shortTimeout);
    if (!r.ok) {
      return KsuResult(false, '文件推送后不可见', log);
    }

    // 4. 尝试加载（需要 root）
    add('── 加载内核模块');
    r = await ProcessRunner.run(
        adb,
        ['-s', serial, 'shell',
         'su -c "insmod $remotePath"'],
        timeout: AppConfig.normalTimeout);

    if (r.ok && !r.output.contains('failed')) {
      add('  ✅ insmod 成功');
    } else {
      add('  ⚠️ insmod 失败: ${r.output.trim()}');
      add('');
      add('📌 LKM 模式需要满足：');
      add('  · 设备已解锁 BL');
      add('  · 已有临时 root（或用 Magisk 提权）');
      add('  · 内核版本完全匹配');
      add('');
      add('  更可靠的方式：用 KernelSU 管理器 App 加载');
      add('  或改用 GKI 模式（刷 boot 镜像）');
      return KsuResult(false, 'insmod 失败', log);
    }

    // 5. 验证
    add('── 验证');
    r = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'lsmod'],
        timeout: AppConfig.shortTimeout);
    if (r.output.contains('kernelsu')) {
      add('  ✅ 模块已加载');
      add('');
      add('📌 下一步：');
      add('  安装 KernelSU 管理器 APK 管理授权');
      return KsuResult(true, 'KernelSU 已加载（临时，重启失效）', log);
    }

    return KsuResult(false, '未检测到模块', log);
  }

  /// 检查设备是否已装 KernelSU
  Future<KsuResult> checkInstalled(String serial) async {
    final adb = await AppConfig.adbPath();
    final log = <String>[];

    // 1. 检查管理器
    final mgr = await ProcessRunner.run(
        adb,
        ['-s', serial, 'shell', 'pm', 'list', 'packages', 'me.weishu.kernelsu'],
        timeout: AppConfig.normalTimeout);
    final hasMgr = mgr.output.contains('me.weishu.kernelsu');
    log.add('管理器: ${hasMgr ? "✅ 已安装" : "❌ 未安装"}');

    // 2. 检查内核模块
    final lsmod = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'lsmod'],
        timeout: AppConfig.shortTimeout);
    final hasModule = lsmod.output.toLowerCase().contains('kernelsu');
    log.add('内核模块: ${hasModule ? "✅ 已加载" : "❌ 未加载"}');

    // 3. 检查 su
    final su = await ProcessRunner.run(
        adb, ['-s', serial, 'shell', 'which', 'su'],
        timeout: AppConfig.shortTimeout);
    final hasSu = su.output.contains('su');
    log.add('su 命令: ${hasSu ? "✅ 存在（${su.output.trim()}）" : "❌ 不存在"}');

    return KsuResult(hasMgr || hasModule, hasModule ? 'KernelSU 已激活' : '未激活', log);
  }
}

/// 设备内核信息
class DeviceKernelInfo {
  final String serial;
  final String kernelVersion;
  final String kernelMajor;
  final String arch;
  final int sdkVersion;
  final String androidName;

  DeviceKernelInfo({
    required this.serial,
    required this.kernelVersion,
    required this.kernelMajor,
    required this.arch,
    required this.sdkVersion,
    required this.androidName,
  });

  @override
  String toString() =>
      '$androidName / kernel $kernelVersion / $arch (SDK $sdkVersion)';
}
