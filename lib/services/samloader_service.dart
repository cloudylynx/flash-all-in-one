import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// samloader 结果
class SamResult {
  final bool ok;
  final String message;
  final List<String> log;
  SamResult(this.ok, this.message, [this.log = const []]);
}

/// 三星固件下载与刷写服务（samloader-rs）
///
/// 技术来源：topjohnwu/samloader-rs（397★，Apache-2.0）
/// 作者是 Magisk 的 topjohnwu
///
/// **比 Heimdall 更全**：
///   · download        下载官方固件（Heimdall 做不到）
///   · check-update    查询可用版本
///   · detect          检测下载模式设备
///   · dump-pit        导出 PIT 分区表
///   · flash           刷机
///   · verify-md5      校验 .tar.md5
///   · reboot-download 重启到下载模式
///
/// 用法：
///   samloader check-update -m SM-G998B -r DBT
///   samloader download -m SM-G998B -r DBT -f G998BXXU3AUJ1/G998BOXM3AUJ1/G998BXXU3AUJ1
///   samloader flash --BOOT boot.img --RECOVERY recovery.img
class SamloaderService {
  SamloaderService._();
  static final SamloaderService instance = SamloaderService._();

  String? _exePath;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    // 1. 应用目录
    for (final sub in ['tools/samloader', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe = p.join(dir, Platform.isWindows ? 'samloader.exe' : 'samloader');
      if (File(exe).existsSync()) {
        _exePath = exe;
        _available = true;
        return true;
      }
    }

    // 2. 从 assets 提取
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'samloader'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final isWin = Platform.isWindows;
      final fname = isWin ? 'samloader.exe' : 'samloader';
      final assetBase = isWin ? 'windows' : 'linux';
      final target = File(p.join(dir.path, fname));

      if (!target.existsSync()) {
        final data =
            await rootBundle.load('assets/tools/$assetBase/samloader/$fname');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }

      if (!isWin) {
        await Process.run('chmod', ['+x', target.path]);
      }

      if (target.existsSync()) {
        _exePath = target.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    // 3. PATH
    try {
      final r = await ProcessRunner.run('samloader', ['--version'],
          timeout: AppConfig.shortTimeout);
      if (r.output.contains('samloader') || r.ok) {
        _exePath = 'samloader';
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  Future<String> _bin() async {
    if (_exePath == null) await init();
    return _exePath ?? 'samloader';
  }

  /// 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final r = await ProcessRunner.run(await _bin(), ['--version'],
        timeout: AppConfig.shortTimeout);
    // 用 stdout（output 会合并 stderr 干扰解析）
    final text = r.stdout.trim().isNotEmpty ? r.stdout : r.output;
    final m = RegExp(r'samloader\s+([\d.]+)').firstMatch(text) ??
        RegExp(r'(\d+\.\d+\.\d+)').firstMatch(text);
    return m?.group(1);
  }

  /// 查询可用固件版本
  Future<SamResult> checkUpdate({
    required String model,
    required String region,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SamResult(false, 'samloader 未就绪', log);
    }

    add('══ 查询三星固件');
    add('  型号: $model');
    add('  区域: $region');
    add('');

    final r = await ProcessRunner.run(
      await _bin(),
      ['check-update', '-m', model, '-r', region],
      timeout: AppConfig.longTimeout,
    );

    if (r.ok) {
      add('  最新版本:');
      for (final line in r.output.trim().split('\n')) {
        if (line.trim().isNotEmpty) add('    $line');
      }
      return SamResult(true, '查询成功', log);
    }

    add('❌ 查询失败: ${r.output.trim()}');
    add('');
    add('📌 常见问题：');
    add('  · 型号格式：SM-G998B（带 SM- 前缀）');
    add('  · 区域代码：DBT（德国）/ XAA（美国）/ CHC（中国）');
    return SamResult(false, '查询失败', log);
  }

  /// 下载固件
  Future<SamResult> download({
    required String model,
    required String region,
    required String firmware,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SamResult(false, 'samloader 未就绪', log);
    }

    Directory(outputDir).createSync(recursive: true);

    add('══ 下载三星固件');
    add('  型号: $model');
    add('  区域: $region');
    add('  版本: $firmware');
    add('  输出: $outputDir');
    add('');

    final code = await ProcessRunner.stream(
      await _bin(),
      ['download', '-m', model, '-r', region, '-f', firmware, '-o', outputDir],
      onLine: add,
      timeout: const Duration(minutes: 60),
    );

    if (code == 0) {
      // 统计
      var count = 0;
      var total = 0;
      try {
        final files = Directory(outputDir)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.zip') || f.path.endsWith('.tar.md5'))
            .toList();
        count = files.length;
        for (final f in files) {
          total += f.lengthSync();
        }
      } catch (_) {}

      add('');
      add('✅ 下载完成: $count 个文件，共 ${(total / 1024 / 1024).toStringAsFixed(1)} MB');
      return SamResult(true, '下载完成', log);
    }

    add('❌ 下载失败（退出码 $code）');
    return SamResult(false, '下载失败', log);
  }

  /// 检测下载模式设备
  Future<SamResult> detect({void Function(String line)? onLine}) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SamResult(false, 'samloader 未就绪', log);
    }

    add('══ 检测三星下载模式设备');
    final r = await ProcessRunner.run(await _bin(), ['detect'],
        timeout: AppConfig.normalTimeout);

    if (r.ok) {
      add('✅ ${r.output.trim()}');
      return SamResult(true, r.output.trim(), log);
    }
    add('❌ 未检测到设备（需进入下载模式：音量下+Home+电源）');
    return SamResult(false, '未检测到设备', log);
  }

  /// 打印 PIT
  Future<SamResult> printPit({void Function(String line)? onLine}) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SamResult(false, 'samloader 未就绪', log);
    }

    add('══ 读取 PIT 分区表');
    final r = await ProcessRunner.run(await _bin(), ['print-pit'],
        timeout: AppConfig.longTimeout);

    if (r.ok) {
      for (final line in r.output.split('\n').take(100)) {
        if (line.trim().isNotEmpty) add(line);
      }
      return SamResult(true, '已读取 PIT', log);
    }
    add('❌ 读取失败');
    return SamResult(false, '读取失败', log);
  }

  /// 刷机
  Future<SamResult> flash({
    required Map<String, String> partitions,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SamResult(false, 'samloader 未就绪', log);
    }
    if (partitions.isEmpty) {
      return SamResult(false, '没有选择文件', log);
    }

    add('══ 三星刷机');
    final args = <String>['flash'];
    for (final e in partitions.entries) {
      if (!File(e.value).existsSync()) {
        add('⚠️ 跳过 ${e.key}（文件不存在）');
        continue;
      }
      args.addAll(['--${e.key}', e.value]);
      add('  ${e.key} ← ${p.basename(e.value)}');
    }
    add('');

    if (args.length <= 1) {
      return SamResult(false, '没有可刷的文件', log);
    }

    final code = await ProcessRunner.stream(
      await _bin(),
      args,
      onLine: add,
      timeout: const Duration(minutes: 30),
    );

    if (code == 0) {
      add('');
      add('✅ 刷机完成');
      return SamResult(true, '刷机完成', log);
    }
    return SamResult(false, '刷机失败（退出码 $code）', log);
  }

  /// 重启到下载模式
  Future<SamResult> rebootDownload({void Function(String line)? onLine}) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SamResult(false, 'samloader 未就绪', log);
    }

    add('══ 重启到下载模式');
    final r = await ProcessRunner.run(await _bin(), ['reboot-download'],
        timeout: AppConfig.normalTimeout);

    add(r.ok ? '✅ ${r.output.trim()}' : '❌ 失败: ${r.output.trim()}');
    return SamResult(r.ok, r.ok ? '已重启到下载模式' : '失败', log);
  }

  /// 校验 .tar.md5
  Future<SamResult> verifyMd5({
    required List<String> files,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SamResult(false, 'samloader 未就绪', log);
    }
    if (files.isEmpty) {
      return SamResult(false, '没有文件', log);
    }

    add('══ 校验 MD5（${files.length} 个文件）');
    final code = await ProcessRunner.stream(
      await _bin(),
      ['verify-md5', ...files],
      onLine: add,
      timeout: const Duration(minutes: 20),
    );

    return SamResult(code == 0, code == 0 ? '校验通过' : '校验失败', log);
  }
}
