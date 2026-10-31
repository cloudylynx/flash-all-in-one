import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// F2FS 操作结果
class F2fsResult {
  final bool ok;
  final String message;
  final List<String> log;
  F2fsResult(this.ok, this.message, [this.log = const []]);
}

/// F2FS 镜像处理服务
///
/// 技术来源：Sushrut1101/f2fs-extractor（Go，单文件，9 平台）
///
/// F2FS 是 Flash-Friendly File System，现代 Android 的 /data 分区
/// 以及部分厂商的 /system 使用它。
///
/// 为什么需要它：
///   现有的 EROFS / ext4 工具链完全无法处理 F2FS，
///   而提取 /data 或修改 F2FS 格式的 system 是常见需求。
class F2fsService {
  F2fsService._();
  static final F2fsService instance = F2fsService._();

  String? _exePath;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化
  Future<bool> init() async {
    if (_available) return true;

    // 1. 应用目录
    for (final sub in ['tools/f2fs', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe =
          p.join(dir, Platform.isWindows ? 'f2fs-extractor.exe' : 'f2fs-extractor');
      if (File(exe).existsSync()) {
        _exePath = exe;
        _available = true;
        return true;
      }
    }

    // 2. 从 assets 提取
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'f2fs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final target = File(p.join(dir.path, 'f2fs-extractor.exe'));
      if (!target.existsSync()) {
        final data = await rootBundle
            .load('assets/tools/windows/f2fs/f2fs-extractor.exe');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      if (target.existsSync()) {
        _exePath = target.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    // 3. PATH
    try {
      final r = await ProcessRunner.run('f2fs-extractor', ['--help'],
          timeout: AppConfig.shortTimeout);
      if (r.output.contains('f2fs') || r.output.contains('Usage')) {
        _exePath = 'f2fs-extractor';
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  Future<String> _bin() async {
    if (_exePath == null) await init();
    return _exePath ?? 'f2fs-extractor';
  }

  /// 检测镜像是否是 F2FS
  ///
  /// F2FS 的 magic 是 0xF2F52010，位于 offset 1024（小端）
  Future<bool> isF2fs(String imagePath) async {
    final f = File(imagePath);
    if (!f.existsSync()) return false;

    final raf = await f.open();
    await raf.setPosition(1024);
    final magic = await raf.read(4);
    await raf.close();

    if (magic.length < 4) return false;
    // F2FS_SUPER_MAGIC = 0xF2F52010（小端存储为 10 20 F5 F2）
    return magic[0] == 0x10 &&
        magic[1] == 0x20 &&
        magic[2] == 0xF5 &&
        magic[3] == 0xF2;
  }

  /// 解包 F2FS 镜像
  Future<F2fsResult> extract({
    required String imagePath,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return F2fsResult(false, 'f2fs-extractor 未找到', log);
    }

    if (!File(imagePath).existsSync()) {
      return F2fsResult(false, '镜像不存在: $imagePath', log);
    }

    final isF2 = await isF2fs(imagePath);
    add('══ F2FS 解包');
    add('  镜像: ${p.basename(imagePath)}');
    add('  检测: ${isF2 ? "✅ 是 F2FS 格式" : "⚠️ magic 不匹配，尝试强制解包"}');
    add('  输出: $outputDir');
    add('');

    Directory(outputDir).createSync(recursive: true);

    final code = await ProcessRunner.stream(
      await _bin(),
      [imagePath, outputDir],
      onLine: add,
      timeout: const Duration(minutes: 15),
    );

    if (code == 0) {
      // 统计解出多少文件
      var count = 0;
      try {
        count = Directory(outputDir)
            .listSync(recursive: true)
            .whereType<File>()
            .length;
      } catch (_) {}

      add('');
      add('✅ 解包完成，共 $count 个文件');
      return F2fsResult(true, '解包完成（$count 个文件）', log);
    }
    return F2fsResult(false, '解包失败（退出码 $code）', log);
  }

  /// 显示帮助
  Future<String> help() async {
    if (!await init()) return '未就绪';
    final r = await ProcessRunner.run(await _bin(), ['--help'],
        timeout: AppConfig.shortTimeout);
    return r.output;
  }
}
