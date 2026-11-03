// LP 元数据（super.img）解析测试
//
// 格式来自 AOSP metadata_format.h。
// 布局： [0,4096) 保留 | [4096,8192) 几何 | [8192,12288) 几何备份 | [12288,...) 元数据

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flashallinone/services/lp_metadata_service.dart';

void main() {
  final svc = LpMetadataService.instance;

  group('常量正确性', () {
    test('布局常量符合 AOSP 定义', () {
      expect(LpMetadataService.reservedBytes, 4096);
      expect(LpMetadataService.geometryOffset, 4096);
      expect(LpMetadataService.geometrySize, 4096);
      // 元数据 = 保留 + 两份几何 = 12288
      expect(LpMetadataService.metadataOffset, 12288);
    });

    test('magic 值正确', () {
      expect(LpGeometry.magic, 0x616C4467); // "gDla"
      expect(LpMetadataService.headerMagic, 0x414C5030); // "PLA\0"
    });

    test('扇区大小', () {
      expect(LpMetadataService.sectorSize, 512);
    });
  });

  group('buildEmptyMetadata', () {
    test('生成的镜像能被自己解析', () async {
      final bytes = svc.buildEmptyMetadata(
        blockDeviceSize: 8 * 1024 * 1024 * 1024, // 8 GB
      );

      // 大小 = 4096*3 + 65536*2*2 = 12288 + 262144 = 274432
      expect(bytes.length, 274432);

      final tmp = File(
          '${Directory.systemTemp.path}/lp_empty_test_${DateTime.now().microsecondsSinceEpoch}.img');
      await tmp.writeAsBytes(bytes);

      try {
        expect(await svc.isSuperImage(tmp.path), isTrue);

        final meta = await svc.parseFile(tmp.path);
        expect(meta, isNotNull);
        expect(meta!.majorVersion, 10);
        expect(meta.partitions, isEmpty); // 空镜像没有分区
        expect(meta.blockDevices.length, 1);
        expect(meta.blockDevices.first.partitionName, 'super');
        expect(meta.blockDevices.first.size, 8 * 1024 * 1024 * 1024);
        expect(meta.geometry, isNotNull);
        expect(meta.geometry!.logicalBlockSize, 4096);
        expect(meta.geometry!.metadataSlotCount, 2);
        expect(meta.geometry!.metadataMaxSize, 65536);
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });

    test('不同设备大小', () async {
      for (final gb in [2, 4, 8, 16]) {
        final bytes = svc.buildEmptyMetadata(
          blockDeviceSize: gb * 1024 * 1024 * 1024,
        );
        final tmp = File(
            '${Directory.systemTemp.path}/lp_size_${gb}.img');
        await tmp.writeAsBytes(bytes);
        try {
          final meta = await svc.parseFile(tmp.path);
          expect(meta, isNotNull, reason: '${gb}GB');
          expect(meta!.blockDevices.first.size, gb * 1024 * 1024 * 1024,
              reason: '${gb}GB');
        } finally {
          if (tmp.existsSync()) tmp.deleteSync();
        }
      }
    });
  });

  group('isSuperImage — 错误输入', () {
    test('不存在的文件返回 false', () async {
      expect(await svc.isSuperImage('/nonexistent/xxx.img'), isFalse);
    });

    test('太小的文件返回 false', () async {
      final tmp = File('${Directory.systemTemp.path}/tiny.img');
      await tmp.writeAsBytes(List.filled(100, 0));
      try {
        expect(await svc.isSuperImage(tmp.path), isFalse);
      } finally {
        tmp.deleteSync();
      }
    });

    test('随机数据返回 false', () async {
      final tmp = File('${Directory.systemTemp.path}/random.img');
      await tmp.writeAsBytes(List.filled(20000, 0xAB));
      try {
        expect(await svc.isSuperImage(tmp.path), isFalse);
      } finally {
        tmp.deleteSync();
      }
    });

    test('parseFile 对无效文件返回 null', () async {
      final tmp = File('${Directory.systemTemp.path}/notsuper.img');
      await tmp.writeAsBytes(List.filled(20000, 0));
      try {
        expect(await svc.parseFile(tmp.path), isNull);
      } finally {
        tmp.deleteSync();
      }
    });
  });

  group('LpPartition 计算', () {
    test('sizeBytes = extents 扇区数 × 512', () {
      final p = LpPartition(
        name: 'system',
        attributes: 0,
        firstExtentIndex: 0,
        numExtents: 2,
        groupIndex: 0,
        extents: [
          LpExtent(
              numSectors: 2048, targetType: 0, targetData: 0, targetSource: 0),
          LpExtent(
              numSectors: 1024, targetType: 0, targetData: 2048, targetSource: 0),
        ],
      );
      // (2048 + 1024) * 512 = 1572864 = 1.5 MB
      expect(p.sizeBytes, 1572864);
      expect(p.sizeText, '1.5 MB');
    });

    test('readonly 标志', () {
      final ro = LpPartition(
        name: 'a',
        attributes: LpPartition.attrReadonly,
        firstExtentIndex: 0,
        numExtents: 0,
        groupIndex: 0,
      );
      expect(ro.isReadonly, isTrue);

      final rw = LpPartition(
        name: 'b',
        attributes: 0,
        firstExtentIndex: 0,
        numExtents: 0,
        groupIndex: 0,
      );
      expect(rw.isReadonly, isFalse);
    });

    test('大小文本格式化', () {
      LpPartition make(int sectors) => LpPartition(
            name: 'x',
            attributes: 0,
            firstExtentIndex: 0,
            numExtents: 1,
            groupIndex: 0,
            extents: [
              LpExtent(
                  numSectors: sectors,
                  targetType: 0,
                  targetData: 0,
                  targetSource: 0),
            ],
          );

      // 512 扇区 = 256 KB
      expect(make(512).sizeText, '256 KB');
      // 2048 扇区 = 1 MB
      expect(make(2048).sizeText, '1.0 MB');
      // 2*1024*2048 扇区 = 2 GB
      expect(make(2 * 1024 * 2048).sizeText, '2.00 GB');
    });
  });

  group('LpExtent', () {
    test('LINEAR vs ZERO', () {
      final linear = LpExtent(
          numSectors: 100, targetType: 0, targetData: 0, targetSource: 0);
      expect(linear.isZero, isFalse);

      final zero = LpExtent(
          numSectors: 100, targetType: 1, targetData: 0, targetSource: 0);
      expect(zero.isZero, isTrue);
    });
  });

  group('LpPartitionGroup', () {
    test('无限制时文本正确', () {
      final g =
          LpPartitionGroup(name: 'default', flags: 0, maximumSize: 0);
      expect(g.maxSizeText, '无限制');
    });

    test('有上限时文本正确', () {
      final g = LpPartitionGroup(
          name: 'group_a', flags: 0, maximumSize: 8 * 1024 * 1024 * 1024);
      expect(g.maxSizeText, '8.00 GB');
    });
  });

  group('LpMetadata 汇总', () {
    test('totalSizeBytes 累加所有分区', () {
      LpPartition make(String name, int sectors) => LpPartition(
            name: name,
            attributes: 0,
            firstExtentIndex: 0,
            numExtents: 1,
            groupIndex: 0,
            extents: [
              LpExtent(
                  numSectors: sectors,
                  targetType: 0,
                  targetData: 0,
                  targetSource: 0),
            ],
          );

      final meta = LpMetadata(
        majorVersion: 10,
        minorVersion: 0,
        partitions: [
          make('system', 2048), // 1 MB
          make('vendor', 1024), // 512 KB
        ],
        groups: const [],
        blockDevices: const [],
      );
      expect(meta.totalSizeBytes, (2048 + 1024) * 512);
    });
  });

  group('真实 super.img（如果存在）', () {
    test('解析 lpmake 生成的镜像', () async {
      const path = '/tmp/lptest/super.img';
      if (!File(path).existsSync()) {
        // 没测试文件就跳过（不算失败）
        return;
      }
      final meta = await svc.parseFile(path);
      expect(meta, isNotNull);
      expect(meta!.partitions.length, 3);

      final names = meta.partitions.map((p) => p.name).toList()..sort();
      expect(names, ['product', 'system', 'vendor']);

      // 大小校验
      final sys = meta.partitions.firstWhere((p) => p.name == 'system');
      expect(sys.sizeBytes, 8 * 1024 * 1024);
    });
  });
}
