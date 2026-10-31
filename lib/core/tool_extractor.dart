import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 统一工具提取器
///
/// 解决各服务重复写提取逻辑的问题：
///   · 统一的错误处理
///   · 统一的 chmod
///   · 统一的缓存检查
///   · 统一的日志
class ToolExtractor {
  ToolExtractor._();

  static String? _baseDir;

  /// 获取工具根目录（{appSupport}/tools/）
  static Future<String?> baseDir() async {
    if (_baseDir != null) return _baseDir;
    try {
      final dataDir = await getApplicationSupportDirectory();
      final dir = Directory(p.join(dataDir.path, 'tools'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _baseDir = dir.path;
      return _baseDir;
    } catch (_) {
      return null;
    }
  }

  /// 提取单个文件
  ///
  /// [assetPath] 完整 asset 路径，如 'assets/tools/windows/qdl/qdl.exe'
  /// [subDir] 子目录名，如 'qdl'
  /// [fileName] 目标文件名（默认从 assetPath 取）
  /// [executable] 是否 chmod +x（非 Windows）
  ///
  /// 返回本地文件路径，失败返回 null
  static Future<String?> extractFile({
    required String assetPath,
    required String subDir,
    String? fileName,
    bool executable = false,
  }) async {
    final base = await baseDir();
    if (base == null) return null;

    try {
      final dir = Directory(p.join(base, subDir));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final name = fileName ?? p.basename(assetPath);
      final target = File(p.join(dir.path, name));

      // 已存在且大小 > 0 就复用
      if (target.existsSync() && target.lengthSync() > 0) {
        return target.path;
      }

      final data = await rootBundle.load(assetPath);
      if (data.lengthInBytes == 0) return null;

      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);

      if (executable && !Platform.isWindows) {
        await Process.run('chmod', ['+x', target.path]);
      }

      return target.path;
    } catch (e) {
      return null;
    }
  }


  /// 提取单个文件（返回详细错误信息）
  ///
  /// 与 extractFile 的区别：失败时返回具体原因，便于诊断
  static Future<({String? path, String? error})> extractFileVerbose({
    required String assetPath,
    required String subDir,
    String? fileName,
    bool executable = false,
  }) async {
    final base = await baseDir();
    if (base == null) {
      return (path: null, error: '无法获取应用数据目录');
    }

    try {
      final dir = Directory(p.join(base, subDir));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final name = fileName ?? p.basename(assetPath);
      final target = File(p.join(dir.path, name));

      if (target.existsSync() && target.lengthSync() > 0) {
        return (path: target.path, error: null);
      }

      final data = await rootBundle.load(assetPath);
      if (data.lengthInBytes == 0) {
        return (path: null, error: '$assetPath 是空文件');
      }

      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);

      if (executable && !Platform.isWindows) {
        await Process.run('chmod', ['+x', target.path]);
      }

      return (path: target.path, error: null);
    } catch (e) {
      return (path: null, error: '$assetPath: $e');
    }
  }

  /// 批量提取
  ///
  /// 返回成功数量
  static Future<int> extractBatch({
    required List<String> assetPaths,
    required String subDir,
    bool executable = false,
  }) async {
    var count = 0;
    for (final asset in assetPaths) {
      final r = await extractFile(
        assetPath: asset,
        subDir: subDir,
        executable: executable,
      );
      if (r != null) count++;
    }
    return count;
  }

  /// 找可执行文件（先查应用目录，再查 PATH）
  ///
  /// [name] 文件名（不含扩展名），如 'qdl'
  /// [subDir] 应用目录下的子目录，如 'qdl'
  static Future<String?> findExecutable({
    required String name,
    required String subDir,
    String? assetPath,
    List<String>? companionFiles,
  }) async {
    final exeName = Platform.isWindows ? '$name.exe' : name;

    // 1. 应用目录
    final base = await baseDir();
    if (base != null) {
      final direct = File(p.join(base, subDir, exeName));
      if (direct.existsSync()) return direct.path;

      final flat = File(p.join(base, exeName));
      if (flat.existsSync()) return flat.path;
    }

    // 2. 从 assets 提取
    if (assetPath != null) {
      final extracted = await extractFile(
        assetPath: assetPath,
        subDir: subDir,
        fileName: exeName,
        executable: true,
      );
      if (extracted != null) {
        // 提取配套文件（DLL 等）
        if (companionFiles != null) {
          for (final comp in companionFiles) {
            final dir = p.dirname(assetPath);
            await extractFile(
              assetPath: '$dir/$comp',
              subDir: subDir,
              fileName: comp,
            );
          }
        }
        return extracted;
      }
    }

    // 3. PATH
    try {
      final r = await Process.run(
          Platform.isWindows ? 'where' : 'which', [name]);
      if (r.exitCode == 0) {
        final path = (r.stdout as String).trim().split('\n').first.trim();
        if (path.isNotEmpty) return path;
      }
    } catch (_) {}

    return null;
  }

  /// 清理缓存（删除整个 tools 目录）
  static Future<bool> clearCache() async {
    final base = await baseDir();
    if (base == null) return false;
    try {
      final dir = Directory(base);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        _baseDir = null;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 工具是否已提取
  static Future<bool> isExtracted(String subDir, String fileName) async {
    final base = await baseDir();
    if (base == null) return false;
    final f = File(p.join(base, subDir, fileName));
    return f.existsSync() && f.lengthSync() > 0;
  }
}
