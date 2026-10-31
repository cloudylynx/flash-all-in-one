import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// GhostLock 执行结果
class GhostResult {
  final bool ok;
  final String message;
  final List<String> log;
  GhostResult(this.ok, this.message, [this.log = const []]);
}

/// GhostLock 临时 Root 服务（CVE-2026-43499）
///
/// 技术来源：YuKongA/ghostlock-app（2440★，Apache-2.0）
///
/// **核心优势：纯 ADB 执行，不需要 Shizuku**
///
/// 官方 App 需要 Shizuku 是因为它要绕过 seccomp，
/// 但通过 `adb shell` 执行时 **shell 用户本来就没有 seccomp 过滤**，
/// 所以直接跳过 W3 阶段，不需要任何额外权限。
///
/// 完整流程（纯 ADB）：
///   1. adb push ghostlock /data/local/tmp/
///   2. adb push profile.bin /data/local/tmp/
///   3. adb shell chmod 755 /data/local/tmp/ghostlock
///   4. adb shell /data/local/tmp/ghostlock --load-prebuilt-profile /data/local/tmp/profile.bin
///
/// 限制：
///   · 内核版本必须精确匹配 `uname -r`
///   · 临时 Root，重启失效
///   · 部分机型需要 profile 里的特定 offset
class GhostLockService {
  GhostLockService._();
  static final GhostLockService instance = GhostLockService._();

  String? _extractDir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化：提取二进制
  Future<bool> init() async {
    if (_available) return true;

    final base = await ToolExtractor.baseDir();
    if (base == null) return false;

    _extractDir = p.join(base, 'ghostlock');

    // 用统一提取器
    final bin = await ToolExtractor.extractFile(
      assetPath: 'assets/tools/ghostlock/ghostlock',
      subDir: 'ghostlock',
      executable: true,
    );

    if (bin == null) {
      _available = false;
      return false;
    }

    _available = true;
    return true;
  }

  /// 获取所有可用 profile 的内核版本列表
  Future<List<String>> listProfiles() async {
    // 直接从 assets 目录读（编译时已打包）
    try {
      final dir = Directory(p.join(_extractDir ?? '', 'profiles'));
      if (dir.existsSync()) {
        final files = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.conf'))
            .map((f) => p.basenameWithoutExtension(f.path))
            .where((n) => !n.contains('template') && !n.startsWith('kernelsnitch'))
            .toList()
          ..sort();
        if (files.isNotEmpty) return files;
      }
    } catch (_) {}

    // 回退：用已知列表
    return List<String>.from(_knownKernels)..sort();
  }

  /// 已知的 profile 内核版本（从 assets 目录编译时确定）
  ///
  /// Flutter 3.x 只有 AssetManifest.bin，没有 .json，
  /// 所以不能用 manifest 动态枚举，改为硬编码列表。
  static const _knownKernels = <String>[
    // 5.10
    '5.10.236-android12-9-00014-gb97c62c4e7d1',
    // 5.15
    '5.15.41-android13-8-g8dc4c75ab7d8-ab1673212412',
    '5.15.119-android13-8-g6ff5097ee32a-ab1764665171',
    '5.15.167-android13-8-00017-gb1f32b310a30-ab12826353',
    '5.15.178-android13-8-00025-g7feb0b0b7cd8-ab14134651',
    '5.15.189-android13-8-00016-g51bba4309aac-ab14546557',
    '5.15.206-android13-8-00056-g3f87b8704e9e-ab15683575',
    // 6.1
    '6.1.25-android14-11-maybe-dirty',
    '6.1.78-android14-11-gb6577b760481-ab12075023',
    '6.1.115-android14-11-ga2521ca27699-ab13294383',
    '6.1.118-android14-11-ga3b9c44908dd-ab13320413',
    '6.1.118-android14-11-gca0ef6d17716-ab13624819',
    '6.1.134-android14-11-maybe-dirty',
    '6.1.138-android14-11-g0c3d559bcd85-ab14529422',
    '6.1.138-android14-11-g6ab8c9a86a33-ab14396278',
    '6.1.138-android14-11-g44bda9e8f6e9-ab13792638',
    // 6.6
    '6.6.77-android15-8-g4a507830d890-ab13636293-4k',
    '6.6.82-android15-8-g076ac12bde16-ab13715361-4k',
    '6.6.89-android15-8-g5a0ffb447c1d-ab13771415-4k',
    '6.6.118-android15-8-g2e6b9c3812c5-ab15114928-4k',
    '6.6.118-android15-8-gbf8cd367de7a-ab15314822-4k',
    // 6.12
    '6.12.30-android16-5-g6e872b4863d6-ab13847919-4k',
  ];

  /// 提取全部 profile 到本地（首次调用时）
  Future<int> extractAllProfiles() async {
    if (!await init()) return 0;
    final dir = Directory(p.join(_extractDir!, 'profiles'));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    var count = 0;
    for (final kernel in _knownKernels) {
      final target = File(p.join(dir.path, '$kernel.conf'));
      if (target.existsSync()) continue;
      try {
        final data = await rootBundle
            .load('assets/tools/ghostlock/profiles/$kernel.conf');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
        count++;
      } catch (_) {}
    }
    return count;
  }

  /// 检查设备内核是否受支持
  Future<(bool, String, String?)> checkKernel(String serial) async {
    final adb = await AppConfig.adbPath();

    final r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'uname', '-r'],
      timeout: AppConfig.shortTimeout,
    );
    final kernel = r.output.trim();

    if (kernel.isEmpty) {
      return (false, '无法读取内核版本', null);
    }

    // 精确匹配 profile 文件名
    final profilePath = await _findProfile(kernel);
    if (profilePath == null) {
      return (false, '内核 $kernel 不在支持列表内', kernel);
    }

    return (true, '内核 $kernel 已支持', kernel);
  }

  /// 找匹配的 profile 文件
  Future<String?> _findProfile(String kernelVersion) async {
    if (!await init()) return null;

    final dir = Directory(p.join(_extractDir!, 'profiles'));
    if (!dir.existsSync()) {
      // 从 assets 提取所有 profile
      dir.createSync(recursive: true);
      // 注意：这里只提取需要的，避免首次启动慢
    }

    final target = File(p.join(dir.path, '$kernelVersion.conf'));
    if (target.existsSync()) return target.path;

    // 从 assets 提取这个 profile
    try {
      final data = await rootBundle
          .load('assets/tools/ghostlock/profiles/$kernelVersion.conf');
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  /// 执行临时 Root（纯 ADB，不需要 Shizuku）
  Future<GhostResult> execute({
    required String serial,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return GhostResult(false, 'GhostLock 未就绪', log);
    }

    final adb = await AppConfig.adbPath();

    add('══ GhostLock 临时 Root');
    add('  CVE-2026-43499');
    add('  纯 ADB 执行（无需 Shizuku）');
    add('');

    // 1. 检查内核
    add('── 检查内核');
    final (supported, msg, kernel) = await checkKernel(serial);
    add('  $msg');
    if (!supported) {
      add('');
      add('📌 内核版本必须精确匹配');
      add('  当前: ${kernel ?? "未知"}');
      add('');
      add('  支持的内核（部分）：');
      for (final k in (await listProfiles()).take(8)) {
        add('    · $k');
      }
      add('  …共 85 个 profile');
      return GhostResult(false, msg, log);
    }
    add('');

    // 2. 提取并推送二进制
    add('── 推送 ghostlock');
    final binPath = p.join(_extractDir!, 'ghostlock');
    const remoteBin = '/data/local/tmp/ghostlock';

    var r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'push', binPath, remoteBin],
      timeout: AppConfig.longTimeout,
    );
    if (!r.ok) {
      return GhostResult(false, '推送二进制失败: ${r.output}', log);
    }
    add('  ✅ $remoteBin');

    // 3. 推送 profile
    add('── 推送 profile');
    final profilePath = await _findProfile(kernel!);
    if (profilePath == null) {
      return GhostResult(false, '找不到匹配的 profile', log);
    }
    const remoteProfile = '/data/local/tmp/ghostlock_profile.conf';

    r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'push', profilePath, remoteProfile],
      timeout: AppConfig.normalTimeout,
    );
    if (!r.ok) {
      return GhostResult(false, '推送 profile 失败', log);
    }
    add('  ✅ $remoteProfile');
    add('');

    // 4. chmod
    add('── 设置权限');
    r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'chmod', '755', remoteBin],
      timeout: AppConfig.shortTimeout,
    );
    add(r.ok ? '  ✅ chmod 755' : '  ⚠️ chmod 失败');
    add('');

    // 5. 执行
    add('── 执行 exploit');
    add('  ⚠️ 这可能需要 10-60 秒');
    add('');

    final code = await ProcessRunner.stream(
      adb,
      [
        '-s', serial, 'shell',
        remoteBin, '--load-prebuilt-profile', remoteProfile,
      ],
      onLine: add,
      timeout: const Duration(minutes: 3),
    );

    add('');
    if (code == 0) {
      add('✅ 执行完成');
      add('');
      add('📌 验证方法：');
      add('  adb shell su -c id');
      add('  应该看到 uid=0(root)');
      add('');
      add('⚠️ 临时 Root，重启后失效');
      return GhostResult(true, 'GhostLock 执行完成', log);
    }

    add('❌ 执行失败（退出码 $code）');
    add('');
    add('可能原因：');
    add('  · 内核版本不精确匹配');
    add('  · 设备已修补该 CVE');
    add('  · 需要更多内存或特定条件');
    return GhostResult(false, '执行失败', log);
  }

  /// 验证 Root 是否成功
  Future<bool> verifyRoot(String serial) async {
    final adb = await AppConfig.adbPath();
    final r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'su', '-c', 'id'],
      timeout: AppConfig.normalTimeout,
    );
    return r.output.contains('uid=0');
  }

  /// 清理设备端文件
  Future<void> cleanup(String serial) async {
    final adb = await AppConfig.adbPath();
    await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'rm', '-f',
       '/data/local/tmp/ghostlock',
       '/data/local/tmp/ghostlock_profile.conf'],
      timeout: AppConfig.shortTimeout,
    );
  }
}
