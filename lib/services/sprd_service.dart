import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// 紫光展锐操作结果
class SprdResult {
  final bool ok;
  final String message;
  final List<String> log;
  SprdResult(this.ok, this.message, [this.log = const []]);
}

/// 紫光展锐（Unisoc/Spreadtrum）服务
///
/// 技术来源：ilyakurdyukov/spreadtrum_flash（232★，**Unlicense 公有领域**）
///
/// 许可证优势：Unlicense 是最宽松的许可证（等同公有领域），
/// 可以自由商用、修改、闭源分发，无任何限制。
///
/// 覆盖设备：
///   · 传音全系（Tecno / Infinix / itel）
///   · 部分三星/诺基亚/摩托罗拉低端机
///   · 其他用展锐 SoC 的设备
///
/// 工具：
///   spd_dump.exe  —— 分区读/写/擦除/重分区
///   unpac.exe     —— PAC 固件解包
///   fphelper.exe  —— 展锐指纹相关（可选）
class SprdService {
  SprdService._();
  static final SprdService instance = SprdService._();

  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    // 1. 应用目录
    for (final sub in ['tools/sprd', 'tools']) {
      final d = p.join(AppConfig.exeDir, sub);
      final exe = p.join(d, Platform.isWindows ? 'spd_dump.exe' : 'spd_dump');
      if (File(exe).existsSync()) {
        _dir = d;
        _available = true;
        return true;
      }
    }

    // 2. 从 assets 提取
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'sprd'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      const files = [
        'spd_dump.exe',
        'unpac.exe',
        'fphelper.exe',
        'fphelper_t117.exe',
        'libusb-1.0.dll',
      ];

      var extracted = 0;
      for (final f in files) {
        try {
          final target = File(p.join(dir.path, f));
          if (!target.existsSync()) {
            final data = await rootBundle.load('assets/tools/windows/sprd/$f');
            await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
          }
          extracted++;
        } catch (_) {}
      }

      if (extracted > 0) {
        _dir = dir.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  String? _exe(String name) {
    if (_dir == null) return null;
    final f = File(p.join(_dir!, '$name.exe'));
    return f.existsSync() ? f.path : null;
  }

  /// 解包 PAC 固件
  ///
  /// 用法：unpac PAC文件 输出目录
  Future<SprdResult> unpackPac({
    required String pacPath,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('unpac');
    if (exe == null) {
      return SprdResult(false, 'unpac.exe 未找到', log);
    }

    if (!File(pacPath).existsSync()) {
      return SprdResult(false, 'PAC 文件不存在', log);
    }

    Directory(outputDir).createSync(recursive: true);

    add('══ PAC 解包');
    add('  固件: ${p.basename(pacPath)}');
    add('  输出: $outputDir');
    add('');

    final code = await ProcessRunner.stream(
      exe,
      [pacPath, outputDir],
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      var count = 0;
      var totalSize = 0;
      try {
        final files =
            Directory(outputDir).listSync().whereType<File>().toList();
        count = files.length;
        for (final f in files) {
          totalSize += f.lengthSync();
        }
      } catch (_) {}

      add('');
      add('✅ 解包完成: $count 个文件，共 ${(totalSize / 1024 / 1024).toStringAsFixed(1)} MB');
      return SprdResult(true, '解包完成（$count 个文件）', log);
    }
    return SprdResult(false, '解包失败（退出码 $code）', log);
  }

  /// 读取分区
  ///
  /// 用法：spd_dump fdl fdl1.bin 0x5500 fdl fdl2.bin 0x9efffe00 read_part 分区名 0 大小
  Future<SprdResult> readPartition({
    required String fdl1Path,
    required String fdl2Path,
    required String partition,
    required String outputPath,
    String size = '8M',
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 读取分区: $partition');
    add('  大小: $size');
    add('  输出: $outputPath');
    add('');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'read_part', partition, '0', size,
      outputPath,
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 10),
    );

    if (code == 0) {
      add('');
      add('✅ 读取完成');
      return SprdResult(true, '已读取 $partition', log);
    }
    return SprdResult(false, '读取失败（退出码 $code）', log);
  }

  /// 写入分区
  Future<SprdResult> writePartition({
    required String fdl1Path,
    required String fdl2Path,
    required String partition,
    required String imagePath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 写入分区: $partition');
    add('  镜像: ${p.basename(imagePath)}');
    add('  ⚠️ 写入有变砖风险');
    add('');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'write_part', partition, imagePath,
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 20),
    );

    if (code == 0) {
      add('');
      add('✅ 写入完成');
      return SprdResult(true, '已写入 $partition', log);
    }
    return SprdResult(false, '写入失败（退出码 $code）', log);
  }

  /// 擦除分区
  Future<SprdResult> erasePartition({
    required String fdl1Path,
    required String fdl2Path,
    required String partition,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 擦除分区: $partition');
    add('  ⚠️ 不可恢复');
    add('');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'erase_part', partition,
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 5),
    );

    if (code == 0) {
      add('✅ 擦除完成');
      return SprdResult(true, '已擦除 $partition', log);
    }
    return SprdResult(false, '擦除失败（退出码 $code）', log);
  }

  /// 关机（退出展锐模式）
  Future<SprdResult> powerOff({
    required String fdl1Path,
    required String fdl2Path,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return SprdResult(false, '展锐工具未找到', log);
    }

    final exe = _exe('spd_dump');
    if (exe == null) {
      return SprdResult(false, 'spd_dump.exe 未找到', log);
    }

    add('══ 发送关机命令');

    final args = [
      'fdl', fdl1Path, '0x5500',
      'fdl', fdl2Path, '0x9efffe00',
      'power_off',
    ];

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      workingDirectory: _dir,
      timeout: const Duration(minutes: 2),
    );

    return SprdResult(code == 0, code == 0 ? '已关机' : '关机失败', log);
  }

  /// 帮助信息
  Future<String> help() async {
    if (!await init()) return '未就绪';
    final exe = _exe('spd_dump');
    if (exe == null) return 'spd_dump.exe 未找到';
    final r = await ProcessRunner.run(exe, ['--help'],
        timeout: AppConfig.shortTimeout, workingDirectory: _dir);
    return r.output;
  }
}
