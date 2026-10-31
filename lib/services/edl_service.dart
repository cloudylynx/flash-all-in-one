import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/process_runner.dart';
import 'gpt_parser.dart';

/// EDL (9008) 设备信息
class EdlDevice {
  final String comPort; // 如 COM3
  final String description;

  EdlDevice({required this.comPort, this.description = ''});

  @override
  String toString() => '$comPort ($description)';
}

/// 存储类型
enum EdlStorage {
  ufs('UFS'),
  emmc('EMMC');

  final String value;
  const EdlStorage(this.value);
}

/// 9008 (EDL) 刷机服务
///
/// 基于高通 QSaharaServer + fh_loader 工具链。
/// 流程：
///   1. QSaharaServer 把 firehose ELF 加载到设备内存
///   2. fh_loader 按 rawprogram.xml 刷写分区
class EdlService {
  EdlService._();
  static final EdlService instance = EdlService._();

  static const String _qsaharaAsset = 'assets/tools/QSaharaServer.exe';
  static const String _fhLoaderAsset = 'assets/tools/fh_loader.exe';
  static const String _devconAsset = 'assets/tools/devcon.exe';

  String? _toolsDir;

  /// 提取内置工具到应用数据目录
  Future<String> _ensureTools() async {
    if (_toolsDir != null) return _toolsDir!;

    final dataDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(dataDir.path, 'edl'));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    for (final entry in {
      _qsaharaAsset: 'QSaharaServer.exe',
      _fhLoaderAsset: 'fh_loader.exe',
      _devconAsset: 'devcon.exe',
    }.entries) {
      final target = File(p.join(dir.path, entry.value));
      if (!target.existsSync()) {
        final data = await rootBundle.load(entry.key);
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
    }

    _toolsDir = dir.path;
    return dir.path;
  }

  /// 检查工具是否可用（仅 Windows 支持）
  bool get isSupported => Platform.isWindows;

  /// 扫描 9008 设备
  ///
  /// 用 devcon 列出 USB 设备，找 QDLoader 或 Qualcomm 9008
  Future<List<EdlDevice>> scanDevices() async {
    if (!isSupported) return [];

    final tools = await _ensureTools();
    final devcon = p.join(tools, 'devcon.exe');

    final r = await ProcessRunner.run(devcon, ['find', 'usb*'],
        timeout: const Duration(seconds: 15));

    final devices = <EdlDevice>[];
    for (final line in r.output.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      // 典型输出：
      // USB\VID_05C6&PID_9008\5&2A3B4C5D&0&1: Qualcomm HS-USB QDLoader 9008 (COM3)
      if (t.contains('9008') || t.contains('QDLoader') || t.contains('EDL')) {
        final m = RegExp(r'\(COM(\d+)\)').firstMatch(t);
        if (m != null) {
          devices.add(EdlDevice(
            comPort: 'COM${m.group(1)}',
            description: t.split(':').last.trim(),
          ));
        }
      }
    }
    return devices;
  }


  /// 解析 rawprogram.xml
  ///
  /// 格式示例：
  /// ```xml
  /// <program SECTOR_SIZE_IN_BYTES="4096" file_sector_offset="0"
  ///          filename="boot.img" label="boot"
  ///          num_partition_sectors="16384" physical_partition_number="0"
  ///          start_sector="131072"/>
  /// ```
  Future<EdlFlashPlan?> parseRawprogramXml(String xmlPath) async {
    final file = File(xmlPath);
    if (!file.existsSync()) return null;

    final content = await file.readAsString();
    final entries = <EdlFlashEntry>[];

    // 匹配所有 <program .../> 或 <program ...></program>
    final programRegex = RegExp(r'<program\s([^>]+?)/?>', multiLine: true);
    for (final m in programRegex.allMatches(content)) {
      final attrs = _parseAttrs(m.group(1)!);
      final label = attrs['label'] ?? '';
      if (label.isEmpty) continue;

      final filename = attrs['filename'];
      entries.add(EdlFlashEntry(
        label: label,
        filename: (filename == null || filename.isEmpty) ? null : filename,
        startSector: int.tryParse(attrs['start_sector'] ?? ''),
        numSectors: int.tryParse(attrs['num_partition_sectors'] ?? ''),
        physicalPartition:
            int.tryParse(attrs['physical_partition_number'] ?? ''),
      ));
    }

    // 找同目录下的 patch xml
    final dir = p.dirname(xmlPath);
    String? patchPath;
    for (final candidate in [
      'patch0.xml',
      'patch1.xml',
      'patch2.xml',
      'patch3.xml',
      'patch4.xml',
    ]) {
      final f = File(p.join(dir, candidate));
      if (f.existsSync()) {
        patchPath = f.path;
        break;
      }
    }

    return EdlFlashPlan(
      entries: entries,
      xmlPath: xmlPath,
      patchXmlPath: patchPath,
    );
  }

  /// 解析 XML 属性（key="value" 形式）
  Map<String, String> _parseAttrs(String attrStr) {
    final result = <String, String>{};
    final regex = RegExp(r'(\w+)\s*=\s*"([^"]*)"');
    for (final m in regex.allMatches(attrStr)) {
      result[m.group(1)!] = m.group(2)!;
    }
    return result;
  }

  /// 只刷选中的分区
  ///
  /// 生成临时 XML，只包含选中的 label，然后交给 fh_loader。
  Future<String> buildFilteredXml(
    String originalXmlPath,
    Set<String> selectedLabels,
  ) async {
    final content = await File(originalXmlPath).readAsString();
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" ?>');
    buf.writeln('<data>');

    final programRegex = RegExp(r'<program\s[^>]+?/?>', multiLine: true);
    for (final m in programRegex.allMatches(content)) {
      final tag = m.group(0)!;
      final attrs = _parseAttrs(tag);
      final label = attrs['label'] ?? '';
      if (selectedLabels.contains(label)) {
        buf.writeln(tag);
      }
    }
    buf.writeln('</data>');

    final tmp = File(p.join(
      p.dirname(originalXmlPath),
      'rawprogram_filtered_${DateTime.now().millisecondsSinceEpoch}.xml',
    ));
    await tmp.writeAsString(buf.toString());
    return tmp.path;
  }


  // ═══════════════════════════════════════════════════════
  // 实时读取设备 GPT（优先方案）
  // ═══════════════════════════════════════════════════════

  /// 用 fh_loader 读设备 GPT 分区表
  ///
  /// 步骤：
  /// 1. fh_loader --read 读 LBA 0-33（保护 MBR + GPT Header + 分区条目）
  /// 2. GptParser 解析
  ///
  /// 返回 null 表示失败（调用方应降级到 rawprogram.xml）
  Future<GptTable?> readDeviceGpt({
    required String comPort,
    required String workDir,
    int sectorSize = 4096,
    void Function(String line)? onLine,
  }) async {
    if (!isSupported) return null;

    final tools = await _ensureTools();
    final fhLoader = p.join(tools, 'fh_loader.exe');

    // 读 34 个扇区（LBA 0-33）：保护 MBR + GPT Header + 32 个条目扇区
    final outFile = p.join(workDir, 'gpt_dump.bin');
    try {
      if (File(outFile).existsSync()) File(outFile).deleteSync();
    } catch (_) {}

    onLine?.call('══ 读取设备 GPT（LBA 0-33）');
    onLine?.call('  扇区大小: $sectorSize');

    final args = [
      '--port=\\.\$comPort',
      '--convertprogram2read',
      '--lun=0',
      '--start_sector=0',
      '--num_sectors=34',
      '--sectorsizeinbytes=$sectorSize',
      '--mainoutputdir=$workDir',
      '--noprompt',
    ];

    final code = await ProcessRunner.stream(
      fhLoader,
      args,
      onLine: onLine ?? (_) {},
      timeout: const Duration(seconds: 60),
    );

    if (code != 0 || !File(outFile).existsSync()) {
      onLine?.call('  ✗ 读取失败（退出码 $code）');
      return null;
    }

    final bytes = await File(outFile).readAsBytes();
    onLine?.call('  ✓ 读取 ${bytes.length} 字节');

    // 解析：LBA 1 = header，LBA 2+ = entries
    if (bytes.length < sectorSize * 3) {
      onLine?.call('  ✗ 数据太短');
      return null;
    }

    final header = bytes.sublist(sectorSize, sectorSize * 2);
    final entriesStart = sectorSize * 2;
    final entriesEnd = bytes.length < sectorSize * 34 ? bytes.length : sectorSize * 34;
    final entries = bytes.sublist(entriesStart, entriesEnd);

    final table = GptParser.parse(
      header: header,
      entries: entries,
      sectorSize: sectorSize,
    );

    if (table == null) {
      onLine?.call('  ✗ GPT 解析失败（签名或结构不符）');
      return null;
    }

    onLine?.call('  ✓ 解析到 ${table.partitions.length} 个分区');
    return table;
  }

  /// 带重试和降级的 GPT 读取
  ///
  /// 依次尝试：
  /// 1. 扇区 4096（UFS 常见）
  /// 2. 扇区 512（eMMC 常见）
  /// 3. 都失败 → 返回 null，调用方降级到 rawprogram.xml
  Future<GptTable?> readDeviceGptWithFallback({
    required String comPort,
    required String workDir,
    int maxAttempts = 2,
    void Function(String line)? onLine,
  }) async {
    final sectorSizes = [4096, 512];

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      for (final ss in sectorSizes) {
        onLine?.call('── 尝试 $ss 字节扇区（第 ${attempt + 1} 次）');
        final table = await readDeviceGpt(
          comPort: comPort,
          workDir: workDir,
          sectorSize: ss,
          onLine: onLine,
        );
        if (table != null && table.partitions.isNotEmpty) {
          onLine?.call('✅ GPT 读取成功（扇区 $ss）');
          return table;
        }
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }

    onLine?.call('⚠️ GPT 实时读取失败，将降级使用 rawprogram.xml');
    return null;
  }

  /// 步骤 1：加载 firehose ELF（QSaharaServer）
  ///
  /// 返回退出码。日志通过 [onLine] 流式回调。
  Future<int> loadFirehose({
    required String comPort,
    required String elfPath,
    void Function(String line)? onLine,
  }) async {
    if (!isSupported) {
      onLine?.call('[错误] 9008 刷机仅支持 Windows');
      return -1;
    }

    final tools = await _ensureTools();
    final qsahara = p.join(tools, 'QSaharaServer.exe');

    onLine?.call('══ QSaharaServer 加载 firehose ══');
    onLine?.call('串口: \\\\.\\$comPort');
    onLine?.call('ELF:  $elfPath');

    final code = await ProcessRunner.stream(
      qsahara,
      ['-p', '\\\\.\\$comPort', '-s', '13:$elfPath'],
      onLine: onLine ?? (_) {},
      timeout: const Duration(seconds: 90),
    );

    return code;
  }

  /// 步骤 2：按 XML 刷写分区（fh_loader）
  Future<int> flashPartitions({
    required String comPort,
    required String elfDir,
    required String xmlPath,
    required EdlStorage storage,
    bool resetAfter = true,
    void Function(String line)? onLine,
  }) async {
    if (!isSupported) {
      onLine?.call('[错误] 9008 刷机仅支持 Windows');
      return -1;
    }

    final tools = await _ensureTools();
    final fhLoader = p.join(tools, 'fh_loader.exe');

    onLine?.call('══ fh_loader 刷写分区 ══');
    onLine?.call('存储类型: ${storage.value}');
    onLine?.call('XML: $xmlPath');

    final args = [
      '--port=\\\\.\\$comPort',
      '--search_path=$elfDir',
      '--memoryname=${storage.value}',
      '--noprompt',
      '--sendxml=$xmlPath',
      '--zlpawarehost=1',
      if (resetAfter) '--reset',
    ];

    final code = await ProcessRunner.stream(
      fhLoader,
      args,
      onLine: onLine ?? (_) {},
      timeout: const Duration(minutes: 10),
    );

    return code;
  }

  /// 完整刷机流程（两步合一）
  Future<bool> flashFull({
    required String comPort,
    required String elfPath,
    required String xmlPath,
    required EdlStorage storage,
    bool resetAfter = true,
    void Function(String line)? onLine,
  }) async {
    final log = onLine ?? (_) {};

    // 步骤 1
    final c1 = await loadFirehose(
      comPort: comPort,
      elfPath: elfPath,
      onLine: log,
    );
    if (c1 != 0) {
      log('❌ Sahara 加载失败（退出码 $c1）');
      return false;
    }
    log('✅ Sahara 加载成功');

    // 稍等设备切换模式
    await Future.delayed(const Duration(seconds: 2));

    // 步骤 2
    final elfDir = p.dirname(elfPath);
    final c2 = await flashPartitions(
      comPort: comPort,
      elfDir: elfDir,
      xmlPath: xmlPath,
      storage: storage,
      resetAfter: resetAfter,
      onLine: log,
    );

    if (c2 != 0) {
      log('❌ 分区刷写失败（退出码 $c2）');
      return false;
    }

    log('✅ 刷机完成${resetAfter ? "，设备将重启" : ""}');
    return true;
  }

  /// 让设备重启到 EDL（需要 adb 或 fastboot 权限）
  Future<bool> rebootToEdl({String? adbPath, String? fastbootPath}) async {
    // 先试 adb
    if (adbPath != null) {
      final r = await ProcessRunner.run(adbPath, ['reboot', 'edl'],
          timeout: const Duration(seconds: 10));
      if (r.ok) return true;
    }
    // 再试 fastboot
    if (fastbootPath != null) {
      final r = await ProcessRunner.run(fastbootPath, ['oem', 'edl'],
          timeout: const Duration(seconds: 10));
      if (r.ok) return true;
    }
    return false;
  }
}


/// rawprogram.xml 里的一个刷机项
class EdlFlashEntry {
  /// 分区名（label）
  final String label;

  /// 镜像文件名（filename，可能为空表示只 patch 不刷）
  final String? filename;

  /// 起始扇区
  final int? startSector;

  /// 扇区数
  final int? numSectors;

  /// 物理分区号
  final int? physicalPartition;

  /// 是否只 patch（无 filename）
  bool get isPatchOnly => filename == null || filename!.isEmpty;

  EdlFlashEntry({
    required this.label,
    this.filename,
    this.startSector,
    this.numSectors,
    this.physicalPartition,
  });

  /// 大小估算
  String get sizeText {
    if (numSectors == null) return '—';
    final bytes = numSectors! * 4096; // 假设 4K 扇区
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  String toString() => 'EdlFlashEntry($label, ${filename ?? "patch"})';
}

/// rawprogram.xml 解析结果
class EdlFlashPlan {
  final List<EdlFlashEntry> entries;
  final String xmlPath;
  final String? patchXmlPath;

  EdlFlashPlan({
    required this.entries,
    required this.xmlPath,
    this.patchXmlPath,
  });

  /// 实际要刷的分区（有 filename 的）
  List<EdlFlashEntry> get flashable =>
      entries.where((e) => !e.isPatchOnly).toList();

  /// 只 patch 的条目
  List<EdlFlashEntry> get patchOnly =>
      entries.where((e) => e.isPatchOnly).toList();
}
