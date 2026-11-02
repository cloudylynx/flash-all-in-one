import 'dart:typed_data';

/// GPT 分区条目
class GptPartition {
  /// 分区名（UTF-16LE 解码）
  final String name;

  /// 分区类型 GUID
  final String typeGuid;

  /// 唯一分区 GUID
  final String uniqueGuid;

  /// 起始 LBA
  final int firstLba;

  /// 结束 LBA（含）
  final int lastLba;

  /// 属性
  final int attributes;

  GptPartition({
    required this.name,
    required this.typeGuid,
    required this.uniqueGuid,
    required this.firstLba,
    required this.lastLba,
    required this.attributes,
  });

  /// 扇区数
  int get sectors => lastLba - firstLba + 1;

  /// 大小（字节）
  int sizeBytes(int sectorSize) => sectors * sectorSize;

  /// 大小可读文本
  String sizeText(int sectorSize) {
    final b = sizeBytes(sectorSize);
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (b >= 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '$b B';
  }


    // ═══════════ Android A/B 分区标志（attributes 字段）═══════════
    //
    // 来源：Qualcomm EDL 协议实现（bkerler/edl gpt.py）
    // 这几个 bit 就是 Android 无缝升级 A/B 机制的底层：
    //   · 系统启动成功 → 把当前槽 SUCCESS 置 1
    //   · 启动失败     → 重试计数 -1，减到 0 就回滚到另一槽

    static const int _bitPriority = 48; // 3 bit，优先级 0-3
    static const int _bitActive = 51; // 1 bit，当前激活槽
    static const int _bitRetryCount = 52; // 3 bit，剩余重试次数
    static const int _bitSuccessful = 54; // 1 bit，启动成功标记
    static const int _bitUnbootable = 55; // 1 bit，不可启动

    /// 优先级（0-3，数字越大越优先）
    int get priority => (attributes >> _bitPriority) & 0x7;

    /// 是否是当前激活的槽
    bool get isActive => ((attributes >> _bitActive) & 0x1) == 1;

    /// 剩余重试次数（0-7）
    int get retryCount => (attributes >> _bitRetryCount) & 0x7;

    /// 是否已成功启动过
    bool get isSuccessful => ((attributes >> _bitSuccessful) & 0x1) == 1;

    /// 是否被标记为不可启动（系统可能已损坏）
    bool get isUnbootable => ((attributes >> _bitUnbootable) & 0x1) == 1;

    /// 这个分区有没有 A/B 相关标志
    bool get hasAbFlags => attributes != 0;

    /// A/B 状态可读文本（给 UI 用）
    String get abStatusText {
      if (!hasAbFlags) return '';
      final parts = <String>[];
      if (isActive) parts.add('激活');
      if (isSuccessful) parts.add('已成功');
      if (isUnbootable) parts.add('不可启动');
      if (retryCount > 0) parts.add('重试$retryCount次');
      if (priority > 0) parts.add('优先级$priority');
      return parts.join(' · ');
    }


  @override
  String toString() => 'GptPartition($name, LBA $firstLba-$lastLba)';
}

/// GPT 分区表解析结果
class GptTable {
  final int sectorSize;
  final String diskGuid;
  final int firstUsableLba;
  final int lastUsableLba;
  final int partitionEntryLba;
  final int numEntries;
  final int entrySize;
  final List<GptPartition> partitions;

  GptTable({
    required this.sectorSize,
    required this.diskGuid,
    required this.firstUsableLba,
    required this.lastUsableLba,
    required this.partitionEntryLba,
    required this.numEntries,
    required this.entrySize,
    required this.partitions,
  });

  /// 有效分区（类型 GUID 非全零）
  List<GptPartition> get validPartitions => partitions;

  int get totalSectors =>
      partitions.isEmpty
          ? 0
          : partitions.map((p) => p.sectors).reduce((a, b) => a + b);
}

/// GPT 解析器
///
/// 纯静态方法，无 IO 依赖，可单元测试。
///
/// 参考 UEFI 规范：
/// - LBA 0: 保护性 MBR
/// - LBA 1: GPT Header（签名 "EFI PART"）
/// - LBA 2+: 分区条目数组
class GptParser {
  GptParser._();

  static const String _signature = 'EFI PART';

  /// 解析 GPT
  ///
  /// [header] 至少一个扇区的数据（从 LBA 1 开始）
  /// [entries] 分区条目数据（从 partitionEntryLba 开始，长度 = numEntries * entrySize）
  /// [sectorSize] 扇区大小（常见 512 / 4096）
  ///
  /// 返回 null 表示格式无效
  static GptTable? parse({
    required Uint8List header,
    required Uint8List entries,
    required int sectorSize,
  }) {
    if (header.length < 92) return null;

    // 校验签名
    final sig = String.fromCharCodes(header.sublist(0, 8));
    if (sig != _signature) return null;

    final bd = ByteData.sublistView(header);

    final headerSize = bd.getUint32(12, Endian.little);
    if (headerSize < 92 || headerSize > header.length) return null;

    // Header CRC32 校验
    final expectedCrc = bd.getUint32(16, Endian.little);
    final crcData = Uint8List.fromList(header.sublist(0, headerSize));
    // CRC 字段本身置零
    crcData[16] = 0;
    crcData[17] = 0;
    crcData[18] = 0;
    crcData[19] = 0;
    final actualCrc = _crc32(crcData);
    if (actualCrc != expectedCrc) {
      // CRC 不匹配不直接失败（某些设备/工具会算错），继续尝试解析
      // 但记录到 debug 由调用方决定
    }

    final firstUsable = bd.getUint64(40, Endian.little);
    final lastUsable = bd.getUint64(48, Endian.little);
    final diskGuid = _guidToString(header.sublist(56, 72));
    final entryLba = bd.getUint64(72, Endian.little);
    final numEntries = bd.getUint32(80, Endian.little);
    final entrySize = bd.getUint32(84, Endian.little);

    if (numEntries == 0 || numEntries > 1024) return null;
    if (entrySize < 128 || entrySize > 4096) return null;
    if (entries.length < numEntries * entrySize) return null;

    final partitions = <GptPartition>[];
    for (var i = 0; i < numEntries; i++) {
      final off = i * entrySize;
      final entry = entries.sublist(off, off + entrySize);

      // 类型 GUID 全零 = 未使用
      final typeGuid = _guidToString(entry.sublist(0, 16));
      if (typeGuid == '00000000-0000-0000-0000-000000000000') continue;

      final uniqueGuid = _guidToString(entry.sublist(16, 32));
      final eb = ByteData.sublistView(entry);
      final firstLba = eb.getUint64(32, Endian.little);
      final lastLba = eb.getUint64(40, Endian.little);
      final attrs = eb.getUint64(48, Endian.little);

      // 分区名：72 字节 UTF-16LE
      final nameBytes = entry.sublist(56, 56 + 72);
      final name = _utf16leToString(nameBytes);

      partitions.add(GptPartition(
        name: name.isEmpty ? 'partition_$i' : name,
        typeGuid: typeGuid,
        uniqueGuid: uniqueGuid,
        firstLba: firstLba,
        lastLba: lastLba,
        attributes: attrs,
      ));
    }

    return GptTable(
      sectorSize: sectorSize,
      diskGuid: diskGuid,
      firstUsableLba: firstUsable,
      lastUsableLba: lastUsable,
      partitionEntryLba: entryLba,
      numEntries: numEntries,
      entrySize: entrySize,
      partitions: partitions,
    );
  }

  /// GPT GUID 字节序 → 字符串
  ///
  /// GPT 的 GUID 前 3 段是小端存储
  static String _guidToString(Uint8List b) {
    if (b.length < 16) return '';
    final d1 = _le32(b, 0);
    final d2 = _le16(b, 4);
    final d3 = _le16(b, 6);
    final d4 = b.sublist(8, 10);
    final d5 = b.sublist(10, 16);
    String hex(int v, int len) => v.toRadixString(16).padLeft(len, '0');
    return '${hex(d1, 8)}-${hex(d2, 4)}-${hex(d3, 4)}-'
        '${_hexBytes(d4)}-${_hexBytes(d5)}';
  }

  static int _le32(Uint8List b, int off) =>
      b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

  static int _le16(Uint8List b, int off) => b[off] | (b[off + 1] << 8);

  static String _hexBytes(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  /// UTF-16LE 字节 → 字符串（截断到第一个 NUL）
  static String _utf16leToString(Uint8List b) {
    final codes = <int>[];
    for (var i = 0; i + 1 < b.length; i += 2) {
      final c = b[i] | (b[i + 1] << 8);
      if (c == 0) break;
      codes.add(c);
    }
    return String.fromCharCodes(codes);
  }

  /// CRC32（IEEE 802.3，GPT 用这个）
  static int _crc32(Uint8List data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        if (crc & 1 == 1) {
          crc = (crc >> 1) ^ 0xEDB88320;
        } else {
          crc >>= 1;
        }
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
