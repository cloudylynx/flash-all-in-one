import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// splash.img / logo.img 处理结果
class SplashResult {
  final bool ok;
  final String message;
  final List<String> log;
  SplashResult(this.ok, this.message, this.log);
}

/// 一张 splash 图片的元数据
class SplashImage {
  /// 在包里从 0 开始的序号
  final int index;
  final int width;
  final int height;

  /// 0 = raw RGB, 1 = RLE 压缩
  final int type;

  /// 数据字节数（已从块数换算）
  final int size;

  /// 相对 512 字节块起点的偏移
  final int offset;

  SplashImage({
    required this.index,
    required this.width,
    required this.height,
    required this.type,
    required this.size,
    required this.offset,
  });

  String get typeName => type == 1 ? 'RLE 压缩' : '原始 RGB';
}

/// 高通 splash.img / logo.img 读写
///
/// 格式（小端）：
/// ```
/// 偏移 0    "SPLASH!!"  (8 字节 magic)
/// 偏移 8    count       (uint32)  图片数量
/// 偏移 12   count × 16 字节头：
///             width    (uint32)
///             height   (uint32)
///             type     (uint32)  0=raw 1=RLE
///             size     (uint32)  × 512 = 数据字节数
///             offset   (uint32)  相对文件头 512 块的偏移
/// 偏移 512  数据区（按 512 字节对齐的块）
/// ```
///
/// 部分 MTK 机型用 logo.bin，格式类似但不带 SPLASH!! magic，
/// 这里只处理高通 splash.img；logo.bin 会明确报不支持。
class SplashService {
  SplashService._();
  static final SplashService instance = SplashService._();

  static const String _magic = 'SPLASH!!';
  static const int _blockSize = 512;

  /// 解析 splash.img 头，列出所有图片
  Future<(List<SplashImage>, SplashResult)> list(String splashPath) async {
    final log = <String>[];
    void add(String s) => log.add(s);

    final f = File(splashPath);
    if (!f.existsSync()) {
      return (<SplashImage>[], SplashResult(false, '文件不存在', log));
    }

    final bytes = await f.readAsBytes();
    if (bytes.length < _blockSize) {
      add('❌ 文件太小（${bytes.length} 字节），不是有效 splash.img');
      return (<SplashImage>[], SplashResult(false, '文件太小', log));
    }

    final magic = String.fromCharCodes(bytes.sublist(0, 8));
    if (magic != _magic) {
      add('❌ Magic 不匹配');
      add('   期望: $_magic');
      add('   实际: $magic');
      if (magic.contains('LOGO') || magic.contains('logo')) {
        add('   这像是 MTK 的 logo.bin，本工具暂不支持');
      }
      return (<SplashImage>[], SplashResult(false, '不是高通 splash.img', log));
    }

    final bd = ByteData.sublistView(bytes);
    final count = bd.getUint32(8, Endian.little);
    add('══ 解析 splash.img');
    add('  文件大小: ${_mb(bytes.length)}');
    add('  图片数量: $count');

    if (count == 0 || count > 1000) {
      add('❌ 图片数量异常: $count');
      return (<SplashImage>[], SplashResult(false, '头信息损坏', log));
    }

    final images = <SplashImage>[];
    var cursor = 12;
    for (var i = 0; i < count; i++) {
      if (cursor + 20 > _blockSize) {
        add('⚠️ 第 $i 张图头信息越过 512 字节边界，停止解析');
        break;
      }
      final w = bd.getUint32(cursor, Endian.little);
      final h = bd.getUint32(cursor + 4, Endian.little);
      final t = bd.getUint32(cursor + 8, Endian.little);
      final blocks = bd.getUint32(cursor + 12, Endian.little);
      final off = bd.getUint32(cursor + 16, Endian.little);
      cursor += 20;

      images.add(SplashImage(
        index: i,
        width: w,
        height: h,
        type: t,
        size: blocks * _blockSize,
        offset: off - _blockSize, // 头里存的是绝对偏移，减掉头块
      ));
    }

    add('');
    for (final im in images) {
      add('  [${im.index}] ${im.width}×${im.height}  ${im.typeName}  '
          '${_kb(im.size)}  偏移 0x${im.offset.toRadixString(16)}');
    }
    add('');
    add('✅ 解析完成，共 ${images.length} 张');

    return (images, SplashResult(true, '解析完成', log));
  }

  /// 解包所有图片到目录
  Future<SplashResult> unpack(String splashPath, String outputDir) async {
    final (images, r) = await list(splashPath);
    final log = [...r.log];
    if (!r.ok) return SplashResult(false, r.message, log);

    void add(String s) => log.add(s);

    final bytes = await File(splashPath).readAsBytes();
    final dir = Directory(outputDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    add('');
    add('══ 解包到 $outputDir');

    var ok = 0;
    for (final im in images) {
      final start = _blockSize + im.offset;
      final end = start + im.size;
      if (start < 0 || end > bytes.length) {
        add('  ❌ [${im.index}] 数据越界（$start..$end / 共 ${bytes.length}）');
        continue;
      }
      final data = bytes.sublist(start, end);

      img.Image? decoded;
      try {
        decoded = im.type == 1
            ? _decodeRle(data, im.width, im.height)
            : _decodeRaw(data, im.width, im.height);
      } catch (e) {
        add('  ❌ [${im.index}] 解码失败: $e');
        continue;
      }

      if (decoded == null) {
        add('  ❌ [${im.index}] 解码返回空');
        continue;
      }

      final outPath = p.join(outputDir, 'splash_${im.index}.png');
      await File(outPath).writeAsBytes(img.encodePng(decoded));
      add('  ✅ [${im.index}] ${im.width}×${im.height} → '
          '${p.basename(outPath)}');
      ok++;
    }

    add('');
    add(ok == images.length
        ? '✅ 全部解出（$ok 张）'
        : '⚠️ 解出 $ok / ${images.length} 张');
    return SplashResult(ok > 0, '解出 $ok 张', log);
  }

  /// 打包：从目录里的 PNG 重新生成 splash.img
  ///
  /// 目录里文件名按字典序排序，对应图片顺序。
  Future<SplashResult> repack({
    required String imageDir,
    required String outputPath,
    bool compress = true,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final dir = Directory(imageDir);
    if (!dir.existsSync()) {
      return SplashResult(false, '目录不存在', log);
    }

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final ext = p.extension(f.path).toLowerCase();
          return ext == '.png' || ext == '.jpg' || ext == '.jpeg' ||
              ext == '.bmp' || ext == '.webp';
        })
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    if (files.isEmpty) {
      add('❌ 目录里没有图片（支持 png/jpg/bmp/webp）');
      return SplashResult(false, '没有可用图片', log);
    }

    add('══ 打包 splash.img');
    add('  图片数量: ${files.length}');
    add('  压缩: ${compress ? "RLE" : "原始 RGB"}');
    add('');

    final payloads = <Uint8List>[];
    final metas = <(int, int, int)>[]; // (w, h, type)

    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      add('  [$i] ${p.basename(f.path)}');
      final bytes = await f.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        add('    ❌ 无法解码，跳过');
        continue;
      }

      final payload = compress
          ? _encodeRle(decoded)
          : _encodeRaw(decoded);
      payloads.add(payload);
      metas.add((decoded.width, decoded.height, compress ? 1 : 0));
      add('    ${decoded.width}×${decoded.height} → '
          '${_kb(payload.length)}');
    }

    if (payloads.isEmpty) {
      return SplashResult(false, '没有成功编码的图片', log);
    }

    // 组装文件
    final header = ByteData(_blockSize);
    final magicBytes = _magic.codeUnits;
    for (var i = 0; i < magicBytes.length; i++) {
      header.setUint8(i, magicBytes[i]);
    }
    header.setUint32(8, payloads.length, Endian.little);

    var cursor = 12;
    var dataOffset = 0;
    for (var i = 0; i < payloads.length; i++) {
      final (w, h, t) = metas[i];
      final blocks = (payloads[i].length + _blockSize - 1) ~/ _blockSize;

      header.setUint32(cursor, w, Endian.little);
      header.setUint32(cursor + 4, h, Endian.little);
      header.setUint32(cursor + 8, t, Endian.little);
      header.setUint32(cursor + 12, blocks, Endian.little);
      header.setUint32(
          cursor + 16, dataOffset + _blockSize, Endian.little);
      cursor += 20;
      dataOffset += blocks * _blockSize;
    }

    // 数据区
    final total = _blockSize + dataOffset;
    final out = Uint8List(total);
    out.setRange(0, _blockSize, header.buffer.asUint8List());

    var pos = _blockSize;
    for (final pl in payloads) {
      out.setRange(pos, pos + pl.length, pl);
      pos += (pl.length + _blockSize - 1) ~/ _blockSize * _blockSize;
    }

    await File(outputPath).writeAsBytes(out);
    add('');
    add('✅ 已生成 ${p.basename(outputPath)}（${_mb(out.length)}）');
    add('   ${payloads.length} 张图，${compress ? "RLE 压缩" : "原始 RGB"}');
    return SplashResult(true, '打包完成', log);
  }

  /// 替换 splash.img 里的某一张图片
  Future<SplashResult> replaceOne({
    required String splashPath,
    required String newImagePath,
    required int targetIndex,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final (images, r) = await list(splashPath);
    log.addAll(r.log);
    if (!r.ok) return SplashResult(false, r.message, log);

    if (targetIndex < 0 || targetIndex >= images.length) {
      add('❌ 序号越界（共 ${images.length} 张，要替换 $targetIndex）');
      return SplashResult(false, '序号越界', log);
    }

    final srcBytes = await File(splashPath).readAsBytes();
    final newBytes = await File(newImagePath).readAsBytes();
    final newImg = img.decodeImage(newBytes);
    if (newImg == null) {
      add('❌ 无法解码新图片');
      return SplashResult(false, '新图片无效', log);
    }

    final target = images[targetIndex];
    add('══ 替换第 $targetIndex 张');
    add('  原尺寸: ${target.width}×${target.height}');
    add('  新尺寸: ${newImg.width}×${newImg.height}');
    if (target.width != newImg.width || target.height != newImg.height) {
      add('  ⚠️ 尺寸不一致，部分机型可能显示异常');
    }

    // 编码新图（保持原类型）
    final payload = target.type == 1
        ? _encodeRle(newImg)
        : _encodeRaw(newImg);

    // 重建：其余图原样拷贝
    final payloads = <Uint8List>[];
    final metas = <(int, int, int)>[];
    for (final im in images) {
      if (im.index == targetIndex) {
        payloads.add(payload);
        metas.add((newImg.width, newImg.height, im.type));
      } else {
        final s = _blockSize + im.offset;
        payloads.add(srcBytes.sublist(s, s + im.size));
        metas.add((im.width, im.height, im.type));
      }
    }

    // 组装
    final header = ByteData(_blockSize);
    final magicBytes = _magic.codeUnits;
    for (var i = 0; i < magicBytes.length; i++) {
      header.setUint8(i, magicBytes[i]);
    }
    header.setUint32(8, payloads.length, Endian.little);

    var cursor = 12;
    var dataOffset = 0;
    for (var i = 0; i < payloads.length; i++) {
      final (w, h, t) = metas[i];
      final blocks = (payloads[i].length + _blockSize - 1) ~/ _blockSize;
      header.setUint32(cursor, w, Endian.little);
      header.setUint32(cursor + 4, h, Endian.little);
      header.setUint32(cursor + 8, t, Endian.little);
      header.setUint32(cursor + 12, blocks, Endian.little);
      header.setUint32(cursor + 16, dataOffset + _blockSize, Endian.little);
      cursor += 20;
      dataOffset += blocks * _blockSize;
    }

    final out = Uint8List(_blockSize + dataOffset);
    out.setRange(0, _blockSize, header.buffer.asUint8List());
    var pos = _blockSize;
    for (final pl in payloads) {
      out.setRange(pos, pos + pl.length, pl);
      pos += (pl.length + _blockSize - 1) ~/ _blockSize * _blockSize;
    }

    await File(outputPath).writeAsBytes(out);
    add('');
    add('✅ 已生成 ${p.basename(outputPath)}（${_mb(out.length)}）');
    return SplashResult(true, '替换完成', log);
  }

  // ────────────────────── 编解码 ──────────────────────

  /// 解码 RLE 压缩数据
  img.Image? _decodeRle(Uint8List data, int w, int h) {
    final out = img.Image(width: w, height: h);
    final total = w * h;
    var area = 0;
    var pos = 0;
    var x = 0;
    var y = 0;

    while (area < total && pos < data.length) {
      final flag = data[pos];
      pos++;
      final repeat = (flag & 0x80) != 0;
      final count = (flag & 0x7f) + 1;

      if (pos + 3 > data.length) break;
      final b = data[pos];
      final g = data[pos + 1];
      final r = data[pos + 2];
      if (!repeat) pos += 3;

      for (var i = 0; i < count && area < total; i++) {
        out.setPixelRgb(x, y, r, g, b);
        area++;
        x++;
        if (x >= w) {
          x = 0;
          y++;
        }
      }
      if (repeat) pos += 3;
    }
    return out;
  }

  /// 解码原始 RGB（BGR 顺序，无 RLE）
  img.Image? _decodeRaw(Uint8List data, int w, int h) {
    final out = img.Image(width: w, height: h);
    final total = w * h;
    var area = 0;
    var x = 0;
    var y = 0;
    while (area < total && (area * 3 + 2) < data.length) {
      final b = data[area * 3];
      final g = data[area * 3 + 1];
      final r = data[area * 3 + 2];
      out.setPixelRgb(x, y, r, g, b);
      area++;
      x++;
      if (x >= w) {
        x = 0;
        y++;
      }
    }
    return out;
  }

  /// RLE 编码
  Uint8List _encodeRle(img.Image im) {
    final pixels = <int>[]; // BGR 三元组
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final px = im.getPixel(x, y);
        pixels.add(px.b.toInt());
        pixels.add(px.g.toInt());
        pixels.add(px.r.toInt());
      }
    }

    final out = <int>[];
    var i = 0;
    while (i < pixels.length ~/ 3) {
      // 数一数连续相同像素
      final base = i * 3;
      var run = 1;
      while (run < 128 &&
          (i + run) < pixels.length ~/ 3 &&
          pixels[(i + run) * 3] == pixels[base] &&
          pixels[(i + run) * 3 + 1] == pixels[base + 1] &&
          pixels[(i + run) * 3 + 2] == pixels[base + 2]) {
        run++;
      }

      if (run > 1) {
        // 重复段：bit7 = 1
        out.add(0x80 | (run - 1));
        out.add(pixels[base]);
        out.add(pixels[base + 1]);
        out.add(pixels[base + 2]);
        i += run;
      } else {
        // 找一段不重复的（最多 128 个）
        var seq = 1;
        while (seq < 128 && (i + seq) < pixels.length ~/ 3) {
          final nb = (i + seq) * 3;
          // 下一个像素必须和当前不同，否则该走重复分支
          if (pixels[nb] == pixels[nb - 3] &&
              pixels[nb + 1] == pixels[nb - 2] &&
              pixels[nb + 2] == pixels[nb - 1]) {
            break;
          }
          seq++;
        }
        if (seq == 1) {
          // 只有 1 个，用重复段长度 1 表示
          out.add(0x80 | 0);
          out.add(pixels[base]);
          out.add(pixels[base + 1]);
          out.add(pixels[base + 2]);
          i += 1;
        } else {
          out.add(seq - 1);
          for (var k = 0; k < seq; k++) {
            final nb = (i + k) * 3;
            out.add(pixels[nb]);
            out.add(pixels[nb + 1]);
            out.add(pixels[nb + 2]);
          }
          i += seq;
        }
      }
    }
    return Uint8List.fromList(out);
  }

  /// 原始 RGB 编码（BGR 顺序）
  Uint8List _encodeRaw(img.Image im) {
    final out = Uint8List(im.width * im.height * 3);
    var i = 0;
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final px = im.getPixel(x, y);
        out[i++] = px.b.toInt();
        out[i++] = px.g.toInt();
        out[i++] = px.r.toInt();
      }
    }
    return out;
  }

  String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';
}
