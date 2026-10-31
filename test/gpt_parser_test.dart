import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flashallinone/services/gpt_parser.dart';

/// 构造一个合法的 GPT Header + Entries 测试数据
({Uint8List header, Uint8List entries}) buildTestGpt({
  required int sectorSize,
  required List<({String name, int firstLba, int lastLba})> partitions,
}) {
  const numEntries = 32;
  const entrySize = 128;

  final header = Uint8List(sectorSize);
  final bd = ByteData.sublistView(header);

  // 签名 "EFI PART"
  final sig = 'EFI PART'.codeUnits;
  for (var i = 0; i < 8; i++) {
    header[i] = sig[i];
  }

  bd.setUint32(8, 0x00010000, Endian.little); // revision
  bd.setUint32(12, 92, Endian.little); // header size
  bd.setUint64(24, 1, Endian.little); // current LBA
  bd.setUint64(32, 1000, Endian.little); // backup LBA
  bd.setUint64(40, 34, Endian.little); // first usable
  bd.setUint64(48, 966, Endian.little); // last usable

  // disk GUID（任意值）
  for (var i = 56; i < 72; i++) {
    header[i] = i;
  }

  bd.setUint64(72, 2, Endian.little); // partition entry LBA
  bd.setUint32(80, numEntries, Endian.little);
  bd.setUint32(84, entrySize, Endian.little);

  final entries = Uint8List(numEntries * entrySize);
  for (var i = 0; i < partitions.length; i++) {
    final off = i * entrySize;
    final eb = ByteData.sublistView(entries);
    // 类型 GUID（非零）
    for (var j = 0; j < 16; j++) {
      entries[off + j] = 0x11 + j;
    }
    // 唯一 GUID
    for (var j = 0; j < 16; j++) {
      entries[off + 16 + j] = 0x22 + j;
    }
    eb.setUint64(off + 32, partitions[i].firstLba, Endian.little);
    eb.setUint64(off + 40, partitions[i].lastLba, Endian.little);
    eb.setUint64(off + 48, 0, Endian.little);

    // 分区名 UTF-16LE
    final name = partitions[i].name;
    for (var j = 0; j < name.length && j < 36; j++) {
      final c = name.codeUnitAt(j);
      entries[off + 56 + j * 2] = c & 0xFF;
      entries[off + 56 + j * 2 + 1] = (c >> 8) & 0xFF;
    }
  }

  // 计算 header CRC（把 CRC 字段置零后算）
  bd.setUint32(16, 0, Endian.little);
  final crc = _crc32(header.sublist(0, 92));
  bd.setUint32(16, crc, Endian.little);

  return (header: header, entries: entries);
}

int _crc32(Uint8List data) {
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

void main() {
  group('GptParser', () {
    test('解析基本 GPT（4K 扇区）', () {
      final data = buildTestGpt(
        sectorSize: 4096,
        partitions: [
          (name: 'boot', firstLba: 100, lastLba: 200),
          (name: 'system', firstLba: 201, lastLba: 5000),
          (name: 'userdata', firstLba: 5001, lastLba: 9000),
        ],
      );

      final table = GptParser.parse(
        header: data.header,
        entries: data.entries,
        sectorSize: 4096,
      );

      expect(table, isNotNull);
      expect(table!.sectorSize, 4096);
      expect(table.partitions.length, 3);

      expect(table.partitions[0].name, 'boot');
      expect(table.partitions[0].firstLba, 100);
      expect(table.partitions[0].lastLba, 200);
      expect(table.partitions[0].sectors, 101);

      expect(table.partitions[1].name, 'system');
      expect(table.partitions[1].sectors, 4800);

      expect(table.partitions[2].name, 'userdata');
    });

    test('解析 512 字节扇区', () {
      final data = buildTestGpt(
        sectorSize: 512,
        partitions: [
          (name: 'misc', firstLba: 10, lastLba: 20),
        ],
      );

      final table = GptParser.parse(
        header: data.header,
        entries: data.entries,
        sectorSize: 512,
      );

      expect(table, isNotNull);
      expect(table!.partitions.length, 1);
      expect(table.partitions[0].name, 'misc');
      expect(table.partitions[0].sizeBytes(512), 11 * 512);
    });

    test('签名错误返回 null', () {
      final data = buildTestGpt(
        sectorSize: 4096,
        partitions: [(name: 'test', firstLba: 1, lastLba: 2)],
      );
      // 破坏签名
      data.header[0] = 0x00;

      final table = GptParser.parse(
        header: data.header,
        entries: data.entries,
        sectorSize: 4096,
      );
      expect(table, isNull);
    });

    test('空分区表返回空列表', () {
      final data = buildTestGpt(sectorSize: 4096, partitions: []);

      final table = GptParser.parse(
        header: data.header,
        entries: data.entries,
        sectorSize: 4096,
      );
      expect(table, isNotNull);
      expect(table!.partitions, isEmpty);
    });

    test('大小文本格式化', () {
      final data = buildTestGpt(
        sectorSize: 4096,
        partitions: [
          (name: 'small', firstLba: 0, lastLba: 0), // 1 扇区 = 4KB
          (name: 'big', firstLba: 0, lastLba: 262143), // 262144 扇区 = 1GB
        ],
      );
      final table = GptParser.parse(
        header: data.header,
        entries: data.entries,
        sectorSize: 4096,
      )!;

      expect(table.partitions[0].sizeText(4096), '4 KB');
      expect(table.partitions[1].sizeText(4096), '1.00 GB');
    });

    test('header 太短返回 null', () {
      final table = GptParser.parse(
        header: Uint8List(50),
        entries: Uint8List(128),
        sectorSize: 4096,
      );
      expect(table, isNull);
    });
  });
}
