import 'dart:async';
import 'dart:io';


import '../core/config.dart';
import '../core/process_runner.dart';

/// MTK 设备信息
class MtkDevice {
  final String port;      // COM3 / /dev/ttyACM0
  final String mode;      // BROM / Preloader / DA
  final String? chipset;  // MT6765 等

  MtkDevice({required this.port, required this.mode, this.chipset});

  @override
  String toString() => '$port ($mode)';
}

/// MTK 分区信息（scatter 解析结果）
class MtkPartition {
  final String name;
  final String? file;
  final int? startAddr;
  final int? size;
  final bool isDownload;

  MtkPartition({
    required this.name,
    this.file,
    this.startAddr,
    this.size,
    this.isDownload = true,
  });

  /// 大小可读化
  String get sizeText {
    if (size == null) return '?';
    if (size! >= 1024 * 1024 * 1024) {
      return '${(size! / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (size! >= 1024 * 1024) {
      return '${(size! / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (size! >= 1024) return '${(size! / 1024).toStringAsFixed(0)} KB';
    return '$size B';
  }

  @override
  String toString() => 'MtkPartition($name, $sizeText)';
}

/// MTK 刷机服务
///
/// 基于 penumbra (antumbra CLI)。
/// 支持：刷机、读回、擦除、bootloader 解锁、RPMB 操作。
class MtkService {
  MtkService._();
  static final MtkService instance = MtkService._();

  String? _binPath;
  bool _available = false;

  /// 工具是否可用
  bool get isAvailable => _available;

  /// 初始化：定位或提取 antumbra 二进制
  Future<bool> init() async {
    try {
      final path = await AppConfig.antumbraPath();
      final r = await ProcessRunner.run(path, ['--version'],
          timeout: const Duration(seconds: 10));
      if (r.ok || r.output.contains('antumbra')) {
        _binPath = path;
        _available = true;
        return true;
      }
    } catch (_) {}
    _available = false;
    return false;
  }

  Future<String> _bin() async {
    if (_binPath == null) await init();
    return _binPath ?? 'antumbra';
  }

  /// 版本
  Future<String?> version() async {
    final r = await ProcessRunner.run(await _bin(), ['--version'],
        timeout: const Duration(seconds: 10));
    return r.ok ? r.output.trim() : null;
  }

  /// 扫描 MTK 设备
  Future<List<MtkDevice>> scanDevices() async {
    if (!_available) return [];

    // antumbra 没有 devices 命令，用 pgpt 探测是否连上设备
    final r = await ProcessRunner.run(await _bin(), ['pgpt'],
        timeout: const Duration(seconds: 20));
    if (!r.ok) return [];

    final devices = <MtkDevice>[];
    for (final line in r.output.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      // 尝试解析端口
      final portMatch = RegExp(r'(COM\d+|/dev/tty\w+)').firstMatch(t);
      if (portMatch != null) {
        final mode = t.contains('BROM')
            ? 'BROM'
            : (t.contains('Preloader') ? 'Preloader' : 'DA');
        devices.add(MtkDevice(port: portMatch.group(1)!, mode: mode));
      }
    }
    return devices;
  }

  /// 解析 scatter 文件
  ///
  /// MTK scatter 是文本格式，形如：
  /// ```
  /// - partition_name: boot
  ///   file_name: boot.img
  ///   is_download: true
  ///   partition_size: 0x2000000
  /// ```
  Future<List<MtkPartition>> parseScatter(String scatterPath) async {
    final file = File(scatterPath);
    if (!file.existsSync()) return [];

    final content = await file.readAsString();
    final partitions = <MtkPartition>[];

    String? name;
    String? fileName;
    bool isDownload = true;
    int? size;
    int? addr;

    void flush() {
      if (name != null && name!.isNotEmpty) {
        partitions.add(MtkPartition(
          name: name!,
          file: fileName,
          startAddr: addr,
          size: size,
          isDownload: isDownload,
        ));
      }
      name = null;
      fileName = null;
      isDownload = true;
      size = null;
      addr = null;
    }

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.startsWith('- partition_name:')) {
        flush();
        name = line.split(':').last.trim();
      } else if (line.startsWith('file_name:')) {
        final v = line.split(':').last.trim();
        fileName = (v.isEmpty || v == 'NONE') ? null : v;
      } else if (line.startsWith('is_download:')) {
        isDownload = line.split(':').last.trim().toLowerCase() == 'true';
      } else if (line.startsWith('partition_size:')) {
        final v = line.split(':').last.trim();
        size = _parseHex(v);
      } else if (line.startsWith('physical_start_addr:')) {
        final v = line.split(':').last.trim();
        addr = _parseHex(v);
      }
    }
    flush();

    return partitions;
  }

  int? _parseHex(String s) {
    try {
      if (s.startsWith('0x') || s.startsWith('0X')) {
        return int.parse(s.substring(2), radix: 16);
      }
      return int.parse(s);
    } catch (_) {
      return null;
    }
  }

  /// 刷入分区
  Future<int> flashPartition({
    required String partitionName,
    required String imagePath,
    void Function(String line)? onLine,
  }) async {
    return ProcessRunner.stream(
      await _bin(),
      ['download', partitionName, imagePath],
      onLine: onLine ?? (_) {},
      timeout: const Duration(minutes: 10),
    );
  }

  /// 按 scatter 全量刷机
  Future<int> flashScatter({
    required String scatterPath,
    required String imageDir,
    void Function(String line)? onLine,
  }) async {
    return ProcessRunner.stream(
      await _bin(),
      ['scatter', scatterPath],
      onLine: onLine ?? (_) {},
      timeout: const Duration(minutes: 30),
    );
  }

  /// 读回分区
  Future<int> readback({
    required String partitionName,
    required String outPath,
    void Function(String line)? onLine,
  }) async {
    return ProcessRunner.stream(
      await _bin(),
      ['upload', partitionName, outPath],
      onLine: onLine ?? (_) {},
      timeout: const Duration(minutes: 15),
    );
  }

  /// 擦除分区
  Future<int> erase({
    required String partitionName,
    void Function(String line)? onLine,
  }) async {
    return ProcessRunner.stream(
      await _bin(),
      ['erase', partitionName],
      onLine: onLine ?? (_) {},
      timeout: const Duration(minutes: 5),
    );
  }

  /// 解锁 bootloader（仅漏洞设备）
  Future<int> unlockBootloader({void Function(String line)? onLine}) async {
    return ProcessRunner.stream(
      await _bin(),
      ['seccfg', 'unlock'],
      onLine: onLine ?? (_) {},
      timeout: const Duration(minutes: 5),
    );
  }

  /// 上锁 bootloader
  Future<int> lockBootloader({void Function(String line)? onLine}) async {
    return ProcessRunner.stream(
      await _bin(),
      ['seccfg', 'lock'],
      onLine: onLine ?? (_) {},
      timeout: const Duration(minutes: 5),
    );
  }
}
