import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// qdl 操作结果
class QdlResult {
  final bool ok;
  final String message;
  final List<String> log;
  QdlResult(this.ok, this.message, [this.log = const []]);
}

/// qdl 后端
enum QdlBackend {
  /// Windows：走官方 QDLoader COM 口（不需要 Zadig 换驱动）
  qud('qud', 'QDLoader COM（推荐，不换驱动）'),
  /// libusb：需要 Zadig 装 WinUSB 驱动
  usb('usb', 'libusb（需 Zadig 换驱动）'),
  /// 自动
  auto('auto', '自动选择');

  final String id;
  final String label;
  const QdlBackend(this.id, this.label);
}

/// qdl 服务（高通 EDL 刷机引擎）
///
/// 技术来源：linux-msm/qdl（449★，BSD-3-Clause）
///
/// 优势（相比 QSaharaServer + fh_loader）：
///   · BSD 许可，可自由分发
///   · 跨平台预编译（Windows/Linux/macOS）
///   · `qud` 后端走官方 QDLoader COM 口，不用 Zadig 换驱动
///   · 输出结构化，便于解析进度
///
/// 用法：
///   qdl [--backend=qud] prog_firehose_ddr.elf rawprogram*.xml patch*.xml
class QdlService {
  QdlService._();
  static final QdlService instance = QdlService._();

  String? _exePath;
  String? _dir;
  bool _available = false;

  bool get isAvailable => _available;

  /// 初始化：从 assets 提取
  Future<bool> init() async {
    if (_available) return true;

    // 1. 应用目录
    for (final sub in ['tools/qdl', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe = p.join(dir, Platform.isWindows ? 'qdl.exe' : 'qdl');
      // Linux 的 qdl 在 tools/linux/qdl/
      if (File(exe).existsSync()) {
        _exePath = exe;
        _dir = dir;
        _available = true;
        return true;
      }
    }

    // 2. 从 assets 提取
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'qdl'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final isWin = Platform.isWindows;
      final files = isWin
          ? [
              'qdl.exe',
              'libusb-1.0.dll',
              'libxml2-16.dll',
              'libzip.dll',
              'zlib1.dll',
              'liblzma-5.dll',
              'libbz2-1.dll',
              'libzstd.dll',
              'libiconv-2.dll',
            ]
          : ['qdl']; // Linux 版是单文件

      var extracted = 0;
      final assetBase = isWin ? 'windows' : 'linux';
      for (final f in files) {
        try {
          final target = File(p.join(dir.path, f));
          if (!target.existsSync()) {
            final data =
                await rootBundle.load('assets/tools/$assetBase/qdl/$f');
            await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
          }
          if (!isWin) {
            await Process.run('chmod', ['+x', target.path]);
          }
          extracted++;
        } catch (_) {}
      }

      if (extracted > 0) {
        _exePath = p.join(dir.path, 'qdl.exe');
        _dir = dir.path;
        _available = true;
        return true;
      }
    } catch (_) {}

    // 3. 系统 PATH
    try {
      final r = await ProcessRunner.run('qdl', ['--help'],
          timeout: AppConfig.shortTimeout);
      if (r.output.toLowerCase().contains('qdl') ||
          r.output.contains('Usage')) {
        _exePath = 'qdl';
        _dir = null;
        _available = true;
        return true;
      }
    } catch (_) {}

    _available = false;
    return false;
  }

  Future<String> _bin() async {
    if (_exePath == null) await init();
    return _exePath ?? 'qdl';
  }

  /// 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final r = await ProcessRunner.run(await _bin(), ['-v'],
        timeout: AppConfig.shortTimeout,
        workingDirectory: _dir);
    final m = RegExp(r'qdl\s+v?([\d.]+)').firstMatch(r.output);
    return m?.group(1) ?? (r.ok ? '就绪' : null);
  }

  /// 列出 EDL 设备
  Future<List<String>> listDevices() async {
    if (!await init()) return [];
    final r = await ProcessRunner.run(await _bin(), ['list'],
        timeout: AppConfig.normalTimeout,
        workingDirectory: _dir);
    final devices = <String>[];
    for (final line in r.output.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      // qdl list 输出格式待确认，先收集所有行
      devices.add(t);
    }
    return devices;
  }

  /// 读取芯片信息
  Future<QdlResult> chipinfo() async {
    if (!await init()) {
      return QdlResult(false, 'qdl 未找到');
    }
    final log = <String>[];
    final code = await ProcessRunner.stream(
      await _bin(),
      ['chipinfo'],
      onLine: log.add,
      workingDirectory: _dir,
      timeout: AppConfig.normalTimeout,
    );
    return QdlResult(code == 0, log.join('\n'), log);
  }

  /// 列出可用后端
  Future<List<String>> listBackends() async {
    if (!await init()) return [];
    final r = await ProcessRunner.run(await _bin(), ['--help'],
        timeout: AppConfig.shortTimeout,
        workingDirectory: _dir);
    final backends = <String>[];
    for (final m in RegExp(r'--backend[=\s]+(\w+)').allMatches(r.output)) {
      backends.add(m.group(1)!);
    }
    return backends;
  }

  /// 刷机（按 rawprogram.xml）
  ///
  /// [loaderPath] prog_firehose_ddr.elf
  /// [xmlPaths] rawprogram*.xml + patch*.xml
  /// [imageDir] 镜像所在目录（qdl 会从 xml 里的路径找）
  Future<QdlResult> flash({
    required String loaderPath,
    required List<String> xmlPaths,
    String? imageDir,
    QdlBackend backend = QdlBackend.qud,
    bool dryRun = false,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    if (!await init()) {
      return QdlResult(false, 'qdl 未找到', log);
    }

    if (!File(loaderPath).existsSync()) {
      return QdlResult(false, 'loader 不存在: $loaderPath', log);
    }
    for (final x in xmlPaths) {
      if (!File(x).existsSync()) {
        return QdlResult(false, 'XML 不存在: $x', log);
      }
    }

    add('══ qdl 刷机');
    add('  loader: ${p.basename(loaderPath)}');
    add('  XML: ${xmlPaths.map(p.basename).join(", ")}');
    add('  后端: ${backend.label}');
    add('');

    final args = <String>[];
    if (backend != QdlBackend.auto) {
      args.add('--backend=${backend.id}');
    }
    args.add(loaderPath);
    args.addAll(xmlPaths);

    add('命令: qdl ${args.join(" ")}');
    add('');

    final code = await ProcessRunner.stream(
      await _bin(),
      args,
      onLine: add,
      workingDirectory: imageDir ?? _dir,
      timeout: const Duration(minutes: 30),
    );

    if (code == 0) {
      add('');
      add('✅ 刷机完成');
      return QdlResult(true, '刷机完成', log);
    }
    return QdlResult(false, '刷机失败（退出码 $code）', log);
  }

  /// 只读：显示分区表（qdl 没有此功能，用 edl-ng 或 mtk 替代）
  ///
  /// 这里用 qdl 的 dry-run 模式预览
  Future<QdlResult> preview({
    required String loaderPath,
    required List<String> xmlPaths,
    QdlBackend backend = QdlBackend.qud,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ qdl 预览（不实际写入）');
    add('  注意：qdl 没有 dry-run 参数，这是直接执行');
    add('  如需预览，请用 edl-ng 的 dump-rawprogram');

    return QdlResult(false, 'qdl 不支持 dry-run', log);
  }

  /// 找同目录下的 loader 和 xml
  Future<List<String>> autoDiscover(String dir) async {
    final d = Directory(dir);
    if (!d.existsSync()) return [];

    final found = <String>[];
    for (final f in d.listSync().whereType<File>()) {
      final name = p.basename(f.path).toLowerCase();
      if (name.startsWith('prog_firehose') && name.endsWith('.elf')) {
        found.add(f.path);
      }
    }
    return found;
  }

  /// 找同目录下的 XML 文件
  Future<List<String>> findXmls(String dir) async {
    final d = Directory(dir);
    if (!d.existsSync()) return [];

    final found = <String>[];
    for (final f in d.listSync().whereType<File>()) {
      final name = p.basename(f.path).toLowerCase();
      if (name.endsWith('.xml') &&
          (name.startsWith('rawprogram') || name.startsWith('patch'))) {
        found.add(f.path);
      }
    }
    found.sort();
    return found;
  }
}
