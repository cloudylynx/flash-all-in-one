import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../core/process_runner.dart';

/// payload 分区条目
class PayloadPartition {
  final String name;
  final int size;
  final int offset;
  final String? sha256Hash;

  PayloadPartition({
    required this.name,
    required this.size,
    required this.offset,
    this.sha256Hash,
  });

  String get sizeText {
    if (size >= 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (size >= 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }
}

/// payload 处理结果
class PayloadResult {
  final bool ok;
  final String message;
  final List<String> log;
  PayloadResult(this.ok, this.message, [this.log = const []]);
}

/// Android OTA payload.bin 提取服务
///
/// 技术来源：ssut/payload-dumper-go（3582★）
///
/// payload.bin 是 A/B OTA 的容器格式（Chromium Omaha 协议）。
///
/// 文件结构：
///   0x00  magic         "CrAU"
///   0x04  version       uint64（通常是 2）
///   0x0C  manifest_size uint64
///   0x14  metadata_sig_size uint32（version 2+ 才有）
///   0x18  manifest      protobuf
///   之后  data blobs（按 operation 的 offset/size 切分）
///
/// manifest 是 protobuf 格式，包含：
///   · partitions[]  —— 分区名、新分区信息
///   · operations[]  —— REPLACE / REPLACE_BZ / REPLACE_XZ / ZERO / DISCARD
class PayloadService {
  PayloadService._();
  static final PayloadService instance = PayloadService._();

  static const _magic = 'CrAU';

  /// 解析 payload.bin 头部
  Future<Map<String, dynamic>?> parseHeader(String payloadPath) async {
    final f = File(payloadPath);
    if (!f.existsSync()) return null;

    final raf = await f.open();
    final header = await raf.read(24);
    await raf.close();

    if (header.length < 20) return null;
    final magic = String.fromCharCodes(header.sublist(0, 4));
    if (magic != _magic) return null;

    final bd = ByteData.sublistView(header);
    final version = bd.getUint64(4, Endian.big);
    final manifestSize = bd.getUint64(12, Endian.big);

    var metaSigSize = 0;
    if (version >= 2 && header.length >= 24) {
      metaSigSize = bd.getUint32(20, Endian.big);
    }

    return {
      'version': version,
      'manifestSize': manifestSize,
      'metaSigSize': metaSigSize,
      'dataOffset': 24 + metaSigSize + manifestSize,
    };
  }

  /// 从 manifest 里提取分区名（简化 protobuf 解析）
  ///
  /// 不做完整 protobuf 解码，而是扫描字符串提取分区名。
  /// 完整实现需要 protobuf 库，这里用启发式。
  Future<List<String>> extractPartitionNames(String payloadPath) async {
    final header = await parseHeader(payloadPath);
    if (header == null) return [];

    final f = File(payloadPath);
    final raf = await f.open();
    await raf.setPosition(24 + (header['metaSigSize'] as int));
    final manifest =
        await raf.read(header['manifestSize'] as int);
    await raf.close();

    // 扫描常见的分区名（protobuf 里 field 1 是 partition_name）
    const knownPartitions = [
      'boot', 'init_boot', 'system', 'system_ext', 'vendor', 'product',
      'odm', 'vbmeta', 'vbmeta_system', 'vbmeta_vendor', 'dtbo', 'recovery',
      'cust', 'modem', 'dsp', 'xbl', 'abl', 'tz', 'hyp', 'keymaster',
      'cmnlib', 'cmnlib64', 'devcfg', 'featenabler', 'qupfw', 'uefisecapp',
      'vm-bootsys', 'super', 'userdata', 'metadata', 'misc', 'persist',
    ];

    final found = <String>[];
    final manifestStr = String.fromCharCodes(manifest);

    for (final name in knownPartitions) {
      // 分区名前通常有长度字节，后跟 0x0A 之类的 protobuf tag
      if (manifestStr.contains(name)) {
        found.add(name);
      }
    }

    return found;
  }

  /// 提取指定分区
  ///
  /// 注意：完整提取需要解析 protobuf 的 operations 列表。
  /// 这里做的是「按分区名扫描 manifest 找 offset/size」的简化实现。
  /// 生产环境建议用 payload-dumper-go 二进制。
  Future<PayloadResult> extractPartition({
    required String payloadPath,
    required String partitionName,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final header = await parseHeader(payloadPath);
    if (header == null) {
      return PayloadResult(false, '不是有效的 payload.bin', log);
    }

    add('══ payload.bin 解析');
    add('  版本: ${header['version']}');
    add('  manifest: ${header['manifestSize']} B');
    add('  数据起始: ${header['dataOffset']}');

    final partitions = await extractPartitionNames(payloadPath);
    add('  发现分区: ${partitions.join(", ")}');

    if (!partitions.contains(partitionName)) {
      return PayloadResult(
          false, '分区 $partitionName 不在 payload 里', log);
    }

    // 简化实现：提示用户用外部工具
    add('');
    add('⚠️ 完整提取需要 protobuf 解析');
    add('  建议方案：');
    add('    · 用 payload-dumper-go（Go 二进制，已内置）');
    add('    · 或 payload_dumper（Python）');
    add('');
    add('  本软件已支持检测分区列表，');
    add('  提取请用「payload-dumper-go」命令行：');
    add('    payload-dumper-go -o <输出目录> <payload.bin>');

    return PayloadResult(false, '需要外部工具完成提取', log);
  }

  /// 检查内置的 payload-dumper-go 是否可用
  Future<bool> hasDumperGo() async {
    for (final name in ['payload-dumper-go', 'payload-dumper-go.exe']) {
      final candidates = [
        p.join(Directory.current.path, name),
        p.join(Directory.current.path, 'tools', name),
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return true;
      }
    }
    // 检查 PATH
    try {
      final r = await Process.run(
          Platform.isWindows ? 'where' : 'which', ['payload-dumper-go']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }


  /// 用 payload-dumper-go 提取（真正的实现）
  ///
  /// payload-dumper-go 支持：
  ///   -o 输出目录
  ///   -p 只提取指定分区
  ///   -c 并发数
  Future<PayloadResult> extractWithDumperGo({
    required String payloadPath,
    required String outputDir,
    List<String>? partitions,
    int concurrency = 4,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final exe = await _dumperGoPath();
    if (exe == null) {
      add('❌ payload-dumper-go 未找到');
      add('  应从 assets 自动提取，或手动放到 tools/payload/ 下');
      return PayloadResult(false, 'payload-dumper-go 未找到', log);
    }

    final header = await parseHeader(payloadPath);
    if (header == null) {
      return PayloadResult(false, '不是有效的 payload.bin', log);
    }

    add('══ payload-dumper-go 提取');
    add('  payload: ${p.basename(payloadPath)}');
    add('  版本: ${header['version']}');
    add('  输出: $outputDir');
    if (partitions != null && partitions.isNotEmpty) {
      add('  分区: ${partitions.join(", ")}');
    }
    add('  并发: $concurrency');
    add('');

    Directory(outputDir).createSync(recursive: true);

    final args = <String>['-o', outputDir, '-c', '$concurrency'];
    if (partitions != null && partitions.isNotEmpty) {
      for (final part in partitions) {
        args.addAll(['-p', part]);
      }
    }
    args.add(payloadPath);

    final code = await ProcessRunner.stream(
      exe,
      args,
      onLine: add,
      timeout: const Duration(minutes: 30),
    );

    if (code == 0) {
      var count = 0;
      var totalSize = 0;
      try {
        final files = Directory(outputDir)
            .listSync()
            .whereType<File>()
            .toList();
        count = files.length;
        for (final f in files) {
          totalSize += f.lengthSync();
        }
      } catch (_) {}

      add('');
      add('✅ 提取完成: $count 个文件，共 ${(totalSize / 1024 / 1024).toStringAsFixed(1)} MB');
      return PayloadResult(true, '提取完成（$count 个文件）', log);
    }
    return PayloadResult(false, '提取失败（退出码 $code）', log);
  }

  /// 找 payload-dumper-go
  Future<String?> _dumperGoPath() async {
    // 1. 应用目录
    for (final sub in ['tools/payload', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe = p.join(
          dir, Platform.isWindows ? 'payload-dumper-go.exe' : 'payload-dumper-go');
      if (File(exe).existsSync()) return exe;
    }

    // 2. 从 assets 提取
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools', 'payload'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final target = File(p.join(dir.path, 'payload-dumper-go.exe'));
      if (!target.existsSync()) {
        final data = await rootBundle
            .load('assets/tools/windows/payload/payload-dumper-go.exe');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      if (target.existsSync()) return target.path;
    } catch (_) {}

    // 3. PATH
    try {
      final r = await ProcessRunner.run('payload-dumper-go', ['-h'],
          timeout: AppConfig.shortTimeout);
      if (r.output.contains('payload') || r.output.contains('Usage')) {
        return 'payload-dumper-go';
      }
    } catch (_) {}

    return null;
  }

  /// 用 payload-dumper-go 提取全部
  Future<PayloadResult> extractAll({
    required String payloadPath,
    required String outputDir,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    add('══ 提取 payload.bin 全部分区');

    // 先解析头部验证
    final header = await parseHeader(payloadPath);
    if (header == null) {
      return PayloadResult(false, '不是有效的 payload.bin', log);
    }
    add('  ✅ 格式有效（版本 ${header['version']}）');

    // 尝试调外部工具
    final hasTool = await hasDumperGo();
    if (!hasTool) {
      add('');
      add('⚠️ 未找到 payload-dumper-go');
      add('  下载: https://github.com/ssut/payload-dumper-go/releases');
      add('  放到应用目录 tools/ 下即可');
      return PayloadResult(false, '缺少 payload-dumper-go', log);
    }

    add('  调用 payload-dumper-go…');
    final r = await Process.start('payload-dumper-go',
        ['-o', outputDir, payloadPath]);
    r.stdout.transform(const SystemEncoding().decoder).listen(add);
    r.stderr.transform(const SystemEncoding().decoder).listen(add);
    final code = await r.exitCode;

    if (code == 0) {
      add('✅ 提取完成: $outputDir');
      return PayloadResult(true, '提取完成', log);
    }
    return PayloadResult(false, '提取失败（退出码 $code）', log);
  }
}
