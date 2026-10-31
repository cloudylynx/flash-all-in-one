import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';

/// Heimdall 操作结果
class HeimdallResult {
  final bool ok;
  final String message;
  final List<String> log;
  HeimdallResult(this.ok, this.message, [this.log = const []]);
}

/// Heimdall 服务（三星 Odin 替代）
///
/// 技术来源：Benjamin-Dobell/Heimdall（3129★，MIT）
///
/// 用途：给三星设备刷机（替代 Windows 专属的 Odin）
/// 跨平台：Linux / macOS / Windows
///
/// 常用命令：
///   heimdall detect                         检测设备
///   heimdall print-pit                      打印 PIT 分区表
///   heimdall flash --<分区> <文件>          刷入分区
///   heimdall flash --RECOVERY recovery.img  刷 recovery
///   heimdall close-pc-screen                关闭下载模式
class HeimdallService {
  HeimdallService._();
  static final HeimdallService instance = HeimdallService._();

  String? _exe;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    // 1. 应用目录
    for (final sub in ['tools/heimdall', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe = p.join(dir, Platform.isWindows ? 'heimdall.exe' : 'heimdall');
      if (File(exe).existsSync()) {
        _exe = exe;
        _available = true;
        return true;
      }
    }

    // 2. 系统 PATH
    try {
      final r = await ProcessRunner.run('heimdall', ['version'],
          timeout: const Duration(seconds: 5));
      if (r.output.toLowerCase().contains('heimdall')) {
        _exe = 'heimdall';
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  Future<String> _bin() async {
    if (_exe == null) await init();
    return _exe ?? 'heimdall';
  }

  /// 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final r = await ProcessRunner.run(await _bin(), ['version'],
        timeout: AppConfig.shortTimeout);
    final m = RegExp(r'Heimdall v?([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }

  /// 检测设备
  Future<HeimdallResult> detect() async {
    if (!await init()) {
      return HeimdallResult(false, 'heimdall 未找到');
    }
    final r = await ProcessRunner.run(await _bin(), ['detect'],
        timeout: AppConfig.normalTimeout);
    if (r.ok && !r.output.toLowerCase().contains('failed')) {
      return HeimdallResult(true, r.output.trim());
    }
    return HeimdallResult(false, '未检测到三星设备（需下载模式）');
  }

  /// 打印 PIT 分区表
  Future<HeimdallResult> printPit() async {
    if (!await init()) {
      return HeimdallResult(false, 'heimdall 未找到');
    }
    final r = await ProcessRunner.run(await _bin(), ['print-pit'],
        timeout: AppConfig.normalTimeout);
    return HeimdallResult(r.ok, r.output);
  }

  /// 刷入单个分区
  Future<HeimdallResult> flashPartition({
    required String partition,
    required String filePath,
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      return HeimdallResult(false, 'heimdall 未找到');
    }
    if (!File(filePath).existsSync()) {
      return HeimdallResult(false, '文件不存在: $filePath');
    }

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ Heimdall 刷入');
    add('  分区: $partition');
    add('  文件: ${p.basename(filePath)}');

    final code = await ProcessRunner.stream(
      await _bin(),
      ['flash', '--$partition', filePath],
      onLine: add,
      timeout: const Duration(minutes: 15),
    );

    if (code == 0) {
      add('✅ 刷入成功');
      return HeimdallResult(true, '已刷入 $partition', log);
    }
    return HeimdallResult(false, '刷入失败（退出码 $code）', log);
  }

  /// 批量刷入（多个分区）
  Future<HeimdallResult> flashMultiple({
    required Map<String, String> partitions,
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      return HeimdallResult(false, 'heimdall 未找到');
    }

    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ Heimdall 批量刷入（${partitions.length} 个分区）');

    final args = <String>['flash'];
    for (final e in partitions.entries) {
      if (!File(e.value).existsSync()) {
        add('⚠️ 跳过 ${e.key}（文件不存在）');
        continue;
      }
      args.addAll(['--${e.key}', e.value]);
      add('  ${e.key} ← ${p.basename(e.value)}');
    }

    if (args.length <= 1) {
      return HeimdallResult(false, '没有可刷的文件', log);
    }

    final code = await ProcessRunner.stream(
      await _bin(),
      args,
      onLine: add,
      timeout: const Duration(minutes: 30),
    );

    if (code == 0) {
      add('✅ 批量刷入完成');
      return HeimdallResult(true, '刷入完成', log);
    }
    return HeimdallResult(false, '刷入失败（退出码 $code）', log);
  }

  /// 关闭下载模式（重启设备）
  Future<HeimdallResult> closePcScreen() async {
    if (!await init()) {
      return HeimdallResult(false, 'heimdall 未找到');
    }
    final r = await ProcessRunner.run(await _bin(), ['close-pc-screen'],
        timeout: AppConfig.normalTimeout);
    return HeimdallResult(r.ok, r.output);
  }

  /// 从 tar.md5 固件包里提取（三星官方固件格式）
  ///
  /// tar.md5 就是 tar + 末尾 MD5 校验
  Future<HeimdallResult> extractFirmware({
    required String tarPath,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!File(tarPath).existsSync()) {
      return HeimdallResult(false, '文件不存在', log);
    }

    Directory(outputDir).createSync(recursive: true);
    add('══ 解包三星固件');
    add('  ${p.basename(tarPath)}');

    // 用系统 tar
    final code = await ProcessRunner.stream(
      'tar',
      ['-xf', tarPath, '-C', outputDir],
      onLine: add,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      final files = Directory(outputDir)
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toList();
      add('✅ 解出 ${files.length} 个文件:');
      for (final f in files.take(15)) {
        add('  $f');
      }
      return HeimdallResult(true, '解包完成', log);
    }
    return HeimdallResult(false, '解包失败', log);
  }
}
