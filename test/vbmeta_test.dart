import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// 独立的 vbmeta 解析测试（不走服务，直接验证字节逻辑）
void main() {
  group('vbmeta 真实镜像测试', () {
    test('解析模拟器 vbmeta', () async {
      final f = File('/tmp/vbmeta-test.img');
      if (!f.existsSync()) {
        // 跳过（CI 无此文件）
        return;
      }

      final bytes = await f.readAsBytes();

      // 1. magic
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'AVB0');

      final bd = ByteData.sublistView(bytes);
      final major = bd.getUint32(0x04, Endian.big);
      final minor = bd.getUint32(0x08, Endian.big);
      final algType = bd.getUint32(0x14, Endian.big);
      final flags = bd.getUint32(0x48, Endian.big);

      print('版本: $major.$minor');
      print('算法: $algType');
      print('flags: 0x${flags.toRadixString(16)}');
      print('大小: ${bytes.length} B');

      expect(major, greaterThan(0));
      expect(flags, isNot(equals(0xFFFFFFFF)));
    });

    test('禁用校验并验证 flags 变化', () async {
      final f = File('/tmp/vbmeta-test.img');
      if (!f.existsSync()) return;

      final bytes = Uint8List.fromList(await f.readAsBytes());
      final bd = ByteData.sublistView(bytes);
      final oldFlags = bd.getUint32(0x48, Endian.big);

      // 修改
      bd.setUint32(0x48, oldFlags | 0x03, Endian.big);

      // 验证
      final bd2 = ByteData.sublistView(bytes);
      final newFlags = bd2.getUint32(0x48, Endian.big);
      expect(newFlags & 0x03, 0x03);
      expect(newFlags != oldFlags, isTrue);
      print('原 flags: 0x${oldFlags.toRadixString(16)} → 新 flags: 0x${newFlags.toRadixString(16)}');
    });

    test('恢复校验（flags 清零）', () async {
      final bytes = Uint8List(256);
      final bd = ByteData.sublistView(bytes);
      bd.setUint32(0x48, 0x03, Endian.big);

      bd.setUint32(0x48, 0, Endian.big);
      expect(bd.getUint32(0x48, Endian.big), 0);
    });

    test('magic 校验拒绝错误文件', () async {
      final bytes = Uint8List(1024);
      bytes[0] = 0x41; // 'A'
      bytes[1] = 0x42; // 'B'
      bytes[2] = 0x43; // 'C'
      bytes[3] = 0x44; // 'D'

      final magic = String.fromCharCodes(bytes.sublist(0, 4));
      expect(magic == 'AVB0', isFalse);
    });
  });
}
