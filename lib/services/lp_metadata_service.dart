import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Android 逻辑分区（Logical Partition）元数据
///
/// 从 Android 10 开始，system/vendor/product 等分区不再直接写进 GPT，
/// 而是打包进一个 `super` 分区，内部用 LP 元数据描述。
///
/// 格式定义来自 AOSP：
///   platform/system/core/fs_mgr/liblp/include/liblp/metadata_format.h
///
/// 布局：
///   [几何信息 4096B] [元数据槽 1] [元数据槽 2] ... [分区数据...]
class LpGeometry {
  static const int magic = 0x616c4467; // "gDla"
  static const int structSize = 4096;

  final int metadataMaxSize;
  final int metadataSlotCount;
  final int logicalBlockSize;
  final Uint8List checksum;

  LpGeometry({
    required this.metadataMaxSize,
    required this.metadataSlotCount,
    required this.logicalBlockSize,
    required this.checksum,
  });

  static LpGeometry? parse(Uint8List data) {
    if (data.length < 52) return null;
    final bd = ByteData.sublistView(data);
    if (bd.getUint32(0, Endian.little) != magic) return null;
    return LpGeometry(
      metadataMaxSize: bd.getUint32(40, Endian.little),
      metadataSlotCount: bd.getUint32(44, Endian.little),
      logicalBlockSize: bd.getUint32(48, Endian.little),
      checksum: data.sublist(8, 40),
    );
  }
}

/// 一个逻辑分区
class LpPartition {
  static const int attrReadonly = 1 << 0;

  final String name;
  final int attributes;
  final int firstExtentIndex;
  final int numExtents;
  final int groupIndex;

  /// 填充的区段（解析后关联）
  final List<LpExtent> extents;

  LpPartition({
    required this.name,
    required this.attributes,
    required this.firstExtentIndex,
    required this.numExtents,
    required this.groupIndex,
    this.extents = const [],
  });

  bool get isReadonly => (attributes & attrReadonly) != 0;

  /// 总字节数（按 512 字节扇区算）
  int get sizeBytes =>
      extents.fold(0, (sum, e) => sum + e.numSectors * 512);

  String get sizeText {
    final b = sizeBytes;
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (b >= 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / 1024).toStringAsFixed(0)} KB';
  }

  static LpPartition? parse(Uint8List data, int offset) {
    if (offset + 52 > data.length) return null;
    final bd = ByteData.sublistView(data);
    // name[36] ASCII
    final nameBytes = data.sublist(offset, offset + 36);
    final nul = nameBytes.indexOf(0);
    final name = String.fromCharCodes(
      nul >= 0 ? nameBytes.sublist(0, nul) : nameBytes,
    );
    return LpPartition(
      name: name,
      attributes: bd.getUint32(offset + 36, Endian.little),
      firstExtentIndex: bd.getUint32(offset + 40, Endian.little),
      numExtents: bd.getUint32(offset + 44, Endian.little),
      groupIndex: bd.getUint32(offset + 48, Endian.little),
    );
  }

  @override
  String toString() => 'LpPartition($name, $sizeText)';
}

/// 一个区段（分区数据在 super 里的位置）
class LpExtent {
  /// 0 = 线性映射（ZERO/LINEAR），1 = ZERO
  static const int typeZero = 1;
  static const int typeLinear = 0;

  final int numSectors;
  final int targetType;

  /// targetType=0 时是 super 内的起始扇区；type=1（ZERO）时无意义
  final int targetData;
  final int targetSource;

  LpExtent({
    required this.numSectors,
    required this.targetType,
    required this.targetData,
    required this.targetSource,
  });

  bool get isZero => targetType == typeZero;

  static LpExtent? parse(Uint8List data, int offset) {
    if (offset + 24 > data.length) return null;
    final bd = ByteData.sublistView(data);
    return LpExtent(
      numSectors: bd.getUint64(offset, Endian.little),
      targetType: bd.getUint32(offset + 8, Endian.little),
      targetData: bd.getUint64(offset + 12, Endian.little),
      targetSource: bd.getUint32(offset + 20, Endian.little),
    );
  }
}

/// 分区组（用于动态分区大小限制）
class LpPartitionGroup {
  final String name;
  final int flags;
  final int maximumSize;

  LpPartitionGroup({
    required this.name,
    required this.flags,
    required this.maximumSize,
  });

  String get maxSizeText {
    if (maximumSize == 0) return '无限制';
    if (maximumSize >= 1024 * 1024 * 1024) {
      return '${(maximumSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(maximumSize / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  static LpPartitionGroup? parse(Uint8List data, int offset) {
    if (offset + 48 > data.length) return null;
    final bd = ByteData.sublistView(data);
    final nameBytes = data.sublist(offset, offset + 36);
    final nul = nameBytes.indexOf(0);
    final name = String.fromCharCodes(
      nul >= 0 ? nameBytes.sublist(0, nul) : nameBytes,
    );
    return LpPartitionGroup(
      name: name,
      flags: bd.getUint32(offset + 36, Endian.little),
      maximumSize: bd.getUint64(offset + 40, Endian.little),
    );
  }
}

/// 块设备信息
class LpBlockDevice {
  final int firstLogicalSector;
  final int alignment;
  final int alignmentOffset;
  final int size;
  final String partitionName;

  LpBlockDevice({
    required this.firstLogicalSector,
    required this.alignment,
    required this.alignmentOffset,
    required this.size,
    required this.partitionName,
  });

  String get sizeText {
    if (size >= 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  static LpBlockDevice? parse(Uint8List data, int offset) {
    if (offset + 64 > data.length) return null;
    final bd = ByteData.sublistView(data);
    final nameBytes = data.sublist(offset + 24, offset + 60);
    final nul = nameBytes.indexOf(0);
    final name = String.fromCharCodes(
      nul >= 0 ? nameBytes.sublist(0, nul) : nameBytes,
    );
    return LpBlockDevice(
      firstLogicalSector: bd.getUint64(offset, Endian.little),
      alignment: bd.getUint32(offset + 8, Endian.little),
      alignmentOffset: bd.getUint32(offset + 12, Endian.little),
      size: bd.getUint64(offset + 16, Endian.little),
      partitionName: name.isEmpty ? 'super' : name,
    );
  }
}

/// 解析结果
class LpMetadata {
  final int majorVersion;
  final int minorVersion;
  final List<LpPartition> partitions;
  final List<LpPartitionGroup> groups;
  final List<LpBlockDevice> blockDevices;
  final LpGeometry? geometry;

  LpMetadata({
    required this.majorVersion,
    required this.minorVersion,
    required this.partitions,
    required this.groups,
    required this.blockDevices,
    this.geometry,
  });

  /// 所有分区的总大小（未压缩）
  int get totalSizeBytes =>
      partitions.fold(0, (s, part) => s + part.sizeBytes);

  String get totalSizeText {
    final b = totalSizeBytes;
    if (b >= 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// LP 元数据读写服务
///
/// 用途：
///   · 解析 super.img（列出所有逻辑分区）
///   · 检查分区大小是否超限
///   · 为重建 super.img 做准备
class LpMetadataService {
  LpMetadataService._();
  static final LpMetadataService instance = LpMetadataService._();

  static const int headerMagic = 0x414C5030;
  static const int sectorSize = 512;

  /// 布局常量（来自 AOSP metadata_format.h）
  ///
  /// [0, 4096)      保留区（LP_PARTITION_RESERVED_BYTES，防误判为引导扇区）
  /// [4096, 8192)   几何信息副本 1
  /// [8192, 12288)  几何信息副本 2（备份）
  /// [12288, ...)   元数据头 + 表
  static const int reservedBytes = 4096;
  static const int geometryOffset = 4096;
  static const int geometrySize = 4096;
  static const int metadataOffset = reservedBytes + geometrySize * 2; // 12288

  /// 解析 super.img 文件
  ///
  /// 只读文件头和元数据，不读全部数据（几 GB 的镜像也能秒解析）
  Future<LpMetadata?> parseFile(String path) async {
    final f = File(path);
    if (!f.existsSync()) return null;

    final raf = await f.open();
    try {
      final len = await f.length();

      // ① 读几何信息（偏移 4096，大小 4096）
      Uint8List? geometryBytes;
      if (len >= geometryOffset + geometrySize) {
        await raf.setPosition(geometryOffset);
        geometryBytes = await raf.read(geometrySize);
      }
      final geo = geometryBytes == null || geometryBytes.isEmpty
          ? null
          : LpGeometry.parse(geometryBytes);

      // ② 元数据从 12288 开始
      if (len < metadataOffset + 128) return null;
      await raf.setPosition(metadataOffset);
      final headerBytes = await raf.read(256);
      if (headerBytes.length < 128) return null;

      final hbd = ByteData.sublistView(headerBytes);
      if (hbd.getUint32(0, Endian.little) != headerMagic) {
        // 可能整个文件本身就是空的 super_empty.img
        return null;
      }

      final major = hbd.getUint16(4, Endian.little);
      final minor = hbd.getUint16(6, Endian.little);
      final headerSize = hbd.getUint32(8, Endian.little);
      final tablesSize = hbd.getUint32(44, Endian.little);

      // ③ 读全部表
      final tableStart = metadataOffset + headerSize;
      if (len < tableStart + tablesSize) return null;
      await raf.setPosition(tableStart);
      final tables = await raf.read(tablesSize);

      return _parseTables(tables, major, minor, geo, headerBytes);
    } finally {
      await raf.close();
    }
  }

  LpMetadata? _parseTables(
    Uint8List tables,
    int major,
    int minor,
    LpGeometry? geo,
    Uint8List header,
  ) {
    // 分区表描述符（在 header 里）
    final hbd = ByteData.sublistView(header);
    // LpMetadataTableDescriptor: offset(4) num_entries(4) entry_size(4)
    //
    // header 布局（V1.0，128 字节）：
    //   0   magic
    //   4   major_version (u16)
    //   6   minor_version (u16)
    //   8   header_size
    //   12  header_checksum[32]
    //   44  tables_size
    //   48  tables_checksum[32]   → 占用 48..80
    //   80  partitions 描述符（12 字节）
    //   92  extents 描述符
    //   104 groups 描述符
    //   116 block_devices 描述符
    const descBase = 80;
    int descOffset(int idx) {
      final base = descBase + idx * 12;
      if (base + 12 > header.length) return 0;
      return hbd.getUint32(base, Endian.little);
    }

    int descCount(int idx) {
      final base = descBase + idx * 12 + 4;
      if (base + 4 > header.length) return 0;
      return hbd.getUint32(base, Endian.little);
    }

    // 表顺序：partitions(0), extents(1), groups(2), block_devices(3)
    final partOff = descOffset(0), partCnt = descCount(0);
    final extOff = descOffset(1);
    final grpOff = descOffset(2), grpCnt = descCount(2);
    final blkOff = descOffset(3), blkCnt = descCount(3);

    // 解析 extents
    final extents = <LpExtent>[];
    var eo = extOff;
    while (eo + 24 <= tables.length) {
      final e = LpExtent.parse(tables, eo);
      if (e == null) break;
      extents.add(e);
      eo += 24;
      if (extents.length > 3000) break; // 防死循环
    }

    // 解析分区
    final partitions = <LpPartition>[];
    var po = partOff;
    for (var i = 0; i < partCnt; i++) {
      if (po + 52 > tables.length) break;
      final part = LpPartition.parse(tables, po);
      if (part == null) break;
      // 关联 extents
      final myExtents = <LpExtent>[];
      for (var k = 0; k < part.numExtents; k++) {
        final idx = part.firstExtentIndex + k;
        if (idx < extents.length) myExtents.add(extents[idx]);
      }
      partitions.add(LpPartition(
        name: part.name,
        attributes: part.attributes,
        firstExtentIndex: part.firstExtentIndex,
        numExtents: part.numExtents,
        groupIndex: part.groupIndex,
        extents: myExtents,
      ));
      po += 52;
    }

    // 解析组
    final groups = <LpPartitionGroup>[];
    var go = grpOff;
    for (var i = 0; i < grpCnt; i++) {
      if (go + 48 > tables.length) break;
      final g = LpPartitionGroup.parse(tables, go);
      if (g == null) break;
      groups.add(g);
      go += 48;
    }

    // 解析块设备
    final blocks = <LpBlockDevice>[];
    var bo = blkOff;
    for (var i = 0; i < blkCnt; i++) {
      if (bo + 64 > tables.length) break;
      final b = LpBlockDevice.parse(tables, bo);
      if (b == null) break;
      blocks.add(b);
      bo += 64;
    }

    return LpMetadata(
      majorVersion: major,
      minorVersion: minor,
      partitions: partitions,
      groups: groups,
      blockDevices: blocks,
      geometry: geo,
    );
  }

  /// 快速检查一个文件是不是 super 镜像
  Future<bool> isSuperImage(String path) async {
    final f = File(path);
    if (!f.existsSync()) return false;
    if (await f.length() < metadataOffset + 128) return false;
    final raf = await f.open();
    try {
      await raf.setPosition(metadataOffset);
      final b = await raf.read(4);
      if (b.length < 4) return false;
      return ByteData.sublistView(b).getUint32(0, Endian.little) ==
          headerMagic;
    } catch (_) {
      return false;
    } finally {
      await raf.close();
    }
  }

  /// 生成 super_empty.img（空的分区表模板）
  ///
  /// 用途：创建全新的 super 分区结构
  Uint8List buildEmptyMetadata({
    required int blockDeviceSize,
    int logicalBlockSize = 4096,
    int metadataMaxSize = 65536,
    int metadataSlotCount = 2,
  }) {
    // 几何信息 4096 字节
    final geo = Uint8List(LpGeometry.structSize);
    final gbd = ByteData.sublistView(geo);
    gbd.setUint32(0, LpGeometry.magic, Endian.little);
    gbd.setUint32(4, 52, Endian.little);
    gbd.setUint32(40, metadataMaxSize, Endian.little);
    gbd.setUint32(44, metadataSlotCount, Endian.little);
    gbd.setUint32(48, logicalBlockSize, Endian.little);
    // 算 checksum（把 checksum 字段清零后算）
    final geoCopy = Uint8List.fromList(geo);
    for (var i = 8; i < 40; i++) {
      geoCopy[i] = 0;
    }
    final geoHash = sha256.convert(geoCopy.sublist(0, 52)).bytes;
    for (var i = 0; i < 32; i++) {
      geo[i + 8] = geoHash[i];
    }

    // 头部 128 字节（V1.0 基础大小）
    const headerSize = 128;
    final header = Uint8List(headerSize);
    final hbd = ByteData.sublistView(header);
    hbd.setUint32(0, headerMagic, Endian.little);
    hbd.setUint16(4, 10, Endian.little); // major
    hbd.setUint16(6, 2, Endian.little); // minor
    hbd.setUint32(8, headerSize, Endian.little);

    // 表描述符：partitions(0), extents(1), groups(2), block_devices(3)
    // 每组 12 字节：offset, num_entries, entry_size
    // 空镜像：只有 1 个 block device，0 个分区
    const descBase = 80;
    const tablesOffset = 0;
    // partitions: 空
    hbd.setUint32(descBase + 0, tablesOffset, Endian.little);
    hbd.setUint32(descBase + 4, 0, Endian.little);
    hbd.setUint32(descBase + 8, 52, Endian.little);
    // extents: 空
    hbd.setUint32(descBase + 12, tablesOffset, Endian.little);
    hbd.setUint32(descBase + 16, 0, Endian.little);
    hbd.setUint32(descBase + 20, 24, Endian.little);
    // groups: 空
    hbd.setUint32(descBase + 24, tablesOffset, Endian.little);
    hbd.setUint32(descBase + 28, 0, Endian.little);
    hbd.setUint32(descBase + 32, 48, Endian.little);
    // block_devices: 1 个
    hbd.setUint32(descBase + 36, tablesOffset, Endian.little);
    hbd.setUint32(descBase + 40, 1, Endian.little);
    hbd.setUint32(descBase + 44, 64, Endian.little);

    // 表：1 个 block device（64 字节）
    final tables = Uint8List(64);
    final tbd = ByteData.sublistView(tables);
    // first_logical_sector: 元数据之后
    final metaSectors =
        (reservedBytes + geometrySize * 2 + metadataMaxSize * metadataSlotCount * 2) ~/
            sectorSize;
    tbd.setUint64(0, metaSectors, Endian.little);
    tbd.setUint32(8, logicalBlockSize, Endian.little);
    tbd.setUint32(12, 0, Endian.little);
    tbd.setUint64(16, blockDeviceSize, Endian.little);
    final nameBytes = Uint8List.fromList(utf8.encode('super'));
    for (var i = 0; i < nameBytes.length && i < 36; i++) {
      tables[24 + i] = nameBytes[i];
    }

    // tables_size + tables_checksum
    hbd.setUint32(44, tables.length, Endian.little);
    final tHash = sha256.convert(tables).bytes;
    for (var i = 0; i < 32; i++) {
      header[48 + i] = tHash[i];
    }

    // header checksum
    final hCopy = Uint8List.fromList(header);
    for (var i = 12; i < 44; i++) {
      hCopy[i] = 0;
    }
    final hHash = sha256.convert(hCopy).bytes;
    for (var i = 0; i < 32; i++) {
      header[12 + i] = hHash[i];
    }

    // 拼装：[4096 保留] [geo 4096] [geo 备份 4096] [header+tables × 槽数 × 2]
    final out = Uint8List(
        reservedBytes + geometrySize * 2 + metadataMaxSize * metadataSlotCount * 2);
    out.setAll(geometryOffset, geo);
    out.setAll(geometryOffset + geometrySize, geo);
    out.setAll(metadataOffset, header);
    out.setAll(metadataOffset + headerSize, tables);

    return out;
  }

  /// 导出成人类可读的报告
  String formatReport(LpMetadata m) {
    final sb = StringBuffer();
    sb.writeln('══ super.img 分析');
    sb.writeln('');
    sb.writeln('  元数据版本: ${m.majorVersion}.${m.minorVersion}');
    if (m.geometry != null) {
      sb.writeln('  逻辑块大小: ${m.geometry!.logicalBlockSize} 字节');
      sb.writeln('  元数据槽数: ${m.geometry!.metadataSlotCount}');
      sb.writeln('  元数据上限: ${m.geometry!.metadataMaxSize} 字节');
    }
    sb.writeln('');

    sb.writeln('  块设备:');
    for (final b in m.blockDevices) {
      sb.writeln('    ${b.partitionName}  ${b.sizeText}'
          '  (起始扇区 ${b.firstLogicalSector}, 对齐 ${b.alignment})');
    }
    sb.writeln('');

    sb.writeln('  分区组:');
    for (final g in m.groups) {
      sb.writeln('    ${g.name.isEmpty ? "(默认)" : g.name}'
          '  上限 ${g.maxSizeText}');
    }
    sb.writeln('');

    sb.writeln('  逻辑分区 (${m.partitions.length} 个，共 ${m.totalSizeText}):');
    final sorted = [...m.partitions]
      ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    for (final part in sorted) {
      final ro = part.isReadonly ? ' [只读]' : '';
      sb.writeln('    ${part.name.padRight(24)} ${part.sizeText.padLeft(10)}'
          '  ${part.extents.length} 段$ro');
    }

    return sb.toString();
  }
}
