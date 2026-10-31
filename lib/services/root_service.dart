import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// Root 方案
enum RootMethod {
  magisk('magisk', 'Magisk（官方/狐狸/Alpha）', '最通用，支持绝大多数设备'),
  kernelsu('kernelsu', 'KernelSU（内核级）', '需要内核支持，无 systemless 开销'),
  kernelsuNext('kernelsu-next', 'KernelSU Next', 'KernelSU 增强版'),
  sukisu('sukisu', 'SukiSU Ultra', 'KernelSU 分支，兼容性更好'),
  apatch('apatch', 'APatch（内核补丁）', '不需要解锁 BL，但需要内核镜像');

  final String id;
  final String label;
  final String desc;
  const RootMethod(this.id, this.label, this.desc);
}

/// Root 结果
class RootResult {
  final bool ok;
  final String message;
  final List<String> log;
  RootResult(this.ok, this.message, [this.log = const []]);
}

/// Root 服务
///
/// 技术来源：
/// · Magisk 官方 boot_patch.sh（QN 工具箱内置）
/// · KernelSU / SukiSU / APatch（各项目官方）
///
/// 核心流程（Magisk）：
///   1. adb pull boot 分区
///   2. magiskboot unpack boot.img
///   3. 检查 ramdisk 状态（stock / 已 patch / 不支持）
///   4. magiskboot cpio 注入 magiskinit + magisk.xz + stub.xz
///   5. hexpatch kernel（可选，绕过一些校验）
///   6. magiskboot repack
///   7. fastboot flash boot patched.img
class RootService {
  RootService._();
  static final RootService instance = RootService._();

  String? _magiskboot;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化：找 magiskboot
  Future<bool> init() async {
    for (final sub in ['tools/mtk', 'tools/magisk', 'tools/img', 'tools']) {
      final path = p.join(
          AppConfig.exeDir, sub, Platform.isWindows ? 'magiskboot.exe' : 'magiskboot');
      if (File(path).existsSync()) {
        _magiskboot = path;
        _available = true;
        return true;
      }
    }
    try {
      // magiskboot 在 windows/mtk/ 里打包，提取后会在 tools/ 下
      final path = await AppConfig.toolPath('magiskboot');
      if (File(path).existsSync()) {
        _magiskboot = path;
        _available = true;
        return true;
      }
    } catch (_) {}
    // 直接从 assets 提取 magiskboot + cygwin1.dll
    try {
      final dataDir = await getApplicationSupportDirectory();
      final toolsDir = Directory(p.join(dataDir.path, 'tools'));
      if (!toolsDir.existsSync()) toolsDir.createSync(recursive: true);
      final exeName = Platform.isWindows ? 'magiskboot.exe' : 'magiskboot';
      final target = File(p.join(toolsDir.path, exeName));
      if (!target.existsSync()) {
        final data = await rootBundle
            .load('assets/tools/windows/mtk/magiskboot.exe');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', target.path]);
      }
      if (target.existsSync()) {
        _magiskboot = target.path;
        _available = true;
        return true;
      }
    } catch (_) {}
    _available = false;
    return false;
  }

  Future<String> _boot() async {
    if (_magiskboot == null) await init();
    return _magiskboot ?? 'magiskboot';
  }

  /// 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final r = await ProcessRunner.run(await _boot(), ['--help'],
        timeout: AppConfig.shortTimeout);
    // magiskboot 没有 --version，从 help 里提取
    final m = RegExp(r'MagiskBoot\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 解包 boot 镜像
  Future<RootResult> unpackBoot({
    required String bootImage,
    required String workDir,
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      return RootResult(false, 'magiskboot 未找到');
    }

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 解包 boot 镜像');
    add('  ${p.basename(bootImage)}');

    final code = await ProcessRunner.stream(
      await _boot(),
      ['unpack', bootImage],
      workingDirectory: workDir,
      onLine: add,
      timeout: const Duration(minutes: 2),
    );

    switch (code) {
      case 0:
        add('✅ 解包成功');
        return RootResult(true, '解包成功', log);
      case 1:
        return RootResult(false, '不支持的镜像格式', log);
      case 2:
        return RootResult(false, 'ChromeOS boot 镜像，不支持', log);
      default:
        return RootResult(false, '解包失败（退出码 $code）', log);
    }
  }

  /// 检查 ramdisk 状态
  Future<RootResult> checkRamdisk({
    required String workDir,
    void Function(String line)? onLine,
  }) async {
    final ramdisk = File(p.join(workDir, 'ramdisk.cpio'));
    if (!ramdisk.existsSync()) {
      return RootResult(true, '无 ramdisk（可能是纯内核镜像）');
    }

    final r = await ProcessRunner.run(
      await _boot(),
      ['cpio', 'ramdisk.cpio', 'test'],
      workingDirectory: workDir,
      timeout: AppConfig.normalTimeout,
    );

    // 退出码低 2 位：
    //   0 = stock（原厂）
    //   1 = 已被 Magisk 修补过
    //   2 = 被其他程序修补（不支持）
    final status = r.exitCode & 3;
    switch (status) {
      case 0:
        return RootResult(true, '原厂 boot 镜像（可安全修补）');
      case 1:
        return RootResult(true, '已被 Magisk 修补过（可重新修补）');
      case 2:
        return RootResult(false, '被其他程序修补过，请先恢复原厂镜像');
      default:
        return RootResult(false, '未知状态（退出码 $status）');
    }
  }

  /// 重打包
  Future<RootResult> repack({
    required String originalBoot,
    required String workDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 重打包 boot 镜像');
    final code = await ProcessRunner.stream(
      await _boot(),
      ['repack', originalBoot],
      workingDirectory: workDir,
      onLine: add,
      timeout: const Duration(minutes: 2),
    );

    if (code == 0) {
      final newBoot = File(p.join(workDir, 'new-boot.img'));
      if (newBoot.existsSync()) {
        add('✅ 生成: ${newBoot.path}');
        return RootResult(true, newBoot.path, log);
      }
      return RootResult(false, '重打包完成但找不到 new-boot.img', log);
    }
    return RootResult(false, '重打包失败（退出码 $code）', log);
  }

  /// 从 APK 提取 Magisk 文件（magiskinit / magisk32 / magisk64 / stub.apk）
  Future<RootResult> extractFromApk({
    required String apkPath,
    required String workDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!File(apkPath).existsSync()) {
      return RootResult(false, 'APK 不存在: $apkPath', log);
    }

    add('══ 从 APK 提取 Magisk 组件');
    add('  ${p.basename(apkPath)}');

    // APK 是 zip，用 unzip 提取
    final targets = [
      'lib/arm64-v8a/libmagiskinit.so',
      'lib/arm64-v8a/libmagisk64.so',
      'lib/arm64-v8a/libmagisk32.so',
      'lib/armeabi-v7a/libmagisk32.so',
      'assets/stub.apk',
    ];

    var extracted = 0;
    for (final t in targets) {
      final r = await ProcessRunner.run(
        'unzip',
        ['-o', '-j', apkPath, t, '-d', workDir],
        timeout: AppConfig.normalTimeout,
      );
      if (r.ok) {
        extracted++;
        add('  ✓ $t');
      }
    }

    if (extracted == 0) {
      add('⚠️ 未提取到任何文件（可能不是标准 Magisk APK）');
      return RootResult(false, '提取失败', log);
    }

    // 重命名 libmagisk*.so → magisk*
    final renames = {
      'libmagiskinit.so': 'magiskinit',
      'libmagisk64.so': 'magisk64',
      'libmagisk32.so': 'magisk32',
    };
    for (final e in renames.entries) {
      final src = File(p.join(workDir, e.key));
      if (src.existsSync()) {
        await src.rename(p.join(workDir, e.value));
        add('  → ${e.value}');
      }
    }

    add('✅ 提取完成（$extracted 个文件）');
    return RootResult(true, '提取完成', log);
  }

  /// 完整修补流程
  ///
  /// 需要：boot.img + Magisk APK + magiskboot
  Future<RootResult> patchBoot({
    required String bootImage,
    required String magiskApk,
    required String workDir,
    bool keepVerity = false,
    bool keepForceEncrypt = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return RootResult(false, 'magiskboot 未找到', log);
    }

    add('══ Magisk Boot 修补流程');
    add('  boot: ${p.basename(bootImage)}');
    add('  apk:  ${p.basename(magiskApk)}');
    add('');

    // 1. 提取 Magisk 组件
    final ex = await extractFromApk(
        apkPath: magiskApk, workDir: workDir, onLine: add);
    if (!ex.ok) return ex;
    add('');

    // 2. 解包
    final un = await unpackBoot(
        bootImage: bootImage, workDir: workDir, onLine: add);
    if (!un.ok) return un;
    add('');

    // 3. 检查 ramdisk
    final chk = await checkRamdisk(workDir: workDir, onLine: add);
    add('  状态: ${chk.message}');
    if (!chk.ok) return chk;
    add('');

    // 4. 注入 Magisk
    add('══ 注入 Magisk 到 ramdisk');
    final magiskinit = File(p.join(workDir, 'magiskinit'));
    if (!magiskinit.existsSync()) {
      add('❌ 缺少 magiskinit');
      return RootResult(false, '缺少 magiskinit', log);
    }

    // 压缩 magisk32/magisk64/stub
    for (final f in ['magisk32', 'magisk64', 'stub.apk']) {
      final src = File(p.join(workDir, f));
      if (src.existsSync()) {
        add('  压缩 $f');
        await ProcessRunner.run(
          await _boot(),
          ['compress=xz', f, '$f.xz'],
          workingDirectory: workDir,
          timeout: AppConfig.normalTimeout,
        );
      }
    }

    // 构建 cpio 命令
    final cpioArgs = <String>['cpio', 'ramdisk.cpio'];
    cpioArgs.addAll(['add', '0750', 'init', 'magiskinit']);
    cpioArgs.addAll(['mkdir', '0750', 'overlay.d']);
    cpioArgs.addAll(['mkdir', '0750', 'overlay.d/sbin']);

    if (File(p.join(workDir, 'magisk64.xz')).existsSync()) {
      cpioArgs.addAll(
          ['add', '0644', 'overlay.d/sbin/magisk64.xz', 'magisk64.xz']);
    }
    if (File(p.join(workDir, 'magisk32.xz')).existsSync()) {
      cpioArgs.addAll(
          ['add', '0644', 'overlay.d/sbin/magisk32.xz', 'magisk32.xz']);
    }
    if (File(p.join(workDir, 'stub.apk.xz')).existsSync()) {
      cpioArgs.addAll(
          ['add', '0644', 'overlay.d/sbin/stub.xz', 'stub.apk.xz']);
    }
    cpioArgs.add('patch');
    cpioArgs.addAll(['mkdir', '000', '.backup']);
    cpioArgs.addAll(['add', '000', '.backup/.magisk', 'config']);

    // 写 config
    final config = File(p.join(workDir, 'config'));
    await config.writeAsString(
      'KEEPVERITY=$keepVerity\n'
      'KEEPFORCEENCRYPT=$keepForceEncrypt\n'
      'RECOVERYMODE=false\n',
    );

    final cpioCode = await ProcessRunner.stream(
      await _boot(),
      cpioArgs,
      workingDirectory: workDir,
      onLine: add,
      timeout: const Duration(minutes: 2),
    );
    if (cpioCode != 0) {
      add('❌ cpio 注入失败');
      return RootResult(false, 'cpio 注入失败', log);
    }
    add('  ✅ 注入完成');
    add('');

    // 5. 重打包
    final rp = await repack(
        originalBoot: bootImage, workDir: workDir, onLine: add);

    return RootResult(rp.ok, rp.message, log);
  }
}
