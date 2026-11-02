import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 应用全局配置
class AppConfig {
  AppConfig._();

  static const String appName = 'Flash All In One';
    /// 版本号（从 pubspec.yaml 自动读取，不再手写）
    ///
    /// 之前是硬编码 '0.1.0'，和 pubspec 完全脱节，界面一直显示旧版本号。
    static String _appVersion = '';

    /// 版本号（如 2.0.0+12）；未初始化时返回占位
    static String get appVersion => _appVersion.isEmpty ? '…' : _appVersion;

    /// 启动时调用一次，从 pubspec 加载版本
    static Future<void> loadVersion() async {
      try {
        final info = await PackageInfo.fromPlatform();
        _appVersion = info.buildNumber.isEmpty
            ? info.version
            : '${info.version}+${info.buildNumber}';
      } catch (_) {
        _appVersion = '未知';
      }
    }

  static final Map<String, String> _cache = {};
  static String? _toolsDir;

  /// 当前平台资源子目录
  static String get _platformDir => Platform.isWindows ? 'windows' : 'linux';

  /// 应用可执行文件所在目录
  static String get exeDir => p.dirname(Platform.resolvedExecutable);

  /// 工具依赖的伴随文件
  ///
  /// adb.exe 在 Windows 上必须同时有这两个 DLL 才能运行
  static const Map<String, List<String>> _companionFiles = {
    'adb': [
      'AdbWinApi.dll',
      'AdbWinUsbApi.dll',
    ],
    'magiskboot': [
      'cygwin1.dll',
    ],
  };

  /// 获取工具目录（首次调用时创建并提取所有工具）
  static Future<String> _ensureToolsDir() async {
    if (_toolsDir != null) return _toolsDir!;

    final dataDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(dataDir.path, 'tools'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _toolsDir = dir.path;
    return dir.path;
  }

  /// 从 assets 提取单个文件
  static Future<bool> _extractAsset(String assetKey, String targetPath) async {
    try {
      final target = File(targetPath);
      if (target.existsSync() && target.lengthSync() > 0) return true;
      final data = await rootBundle.load(assetKey);
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 获取工具路径
  ///
  /// 查找顺序：
  /// 1. 应用目录 `tools/<name>`（用户手动放置）
  /// 2. 从 `assets/tools/<platform>/` 提取到数据目录（含伴随 DLL）
  /// 3. 从 `assets/tools/` 提取（通用 exe）
  /// 4. 系统 PATH
  static Future<String> toolPath(String name) async {
    final exeName = Platform.isWindows && !name.contains('.')
        ? '$name.exe'
        : name;

    if (_cache.containsKey(exeName)) return _cache[exeName]!;

    // 1. 应用目录 tools/
    final beside = p.join(exeDir, 'tools', exeName);
    if (File(beside).existsSync()) {
      _cache[exeName] = beside;
      return beside;
    }

    // 2 & 3. 从 assets 提取
    final toolsDir = await _ensureToolsDir();
    final targetPath = p.join(toolsDir, exeName);

    for (final assetBase in ['assets/tools/$_platformDir', 'assets/tools']) {
      final ok = await _extractAsset('$assetBase/$exeName', targetPath);
      if (!ok) continue;

      // 提取伴随文件（DLL 等）
      final companions = _companionFiles[name] ?? const <String>[];
      for (final comp in companions) {
        await _extractAsset(
            '$assetBase/$comp', p.join(toolsDir, comp));
      }

      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', targetPath]);
      }

      if (File(targetPath).existsSync()) {
        _cache[exeName] = targetPath;
        return targetPath;
      }
    }

    // 4. 系统 PATH
    _cache[exeName] = name;
    return name;
  }

  static Future<String> adbPath() => toolPath('adb');
  static Future<String> fastbootPath() => toolPath('fastboot');
  static Future<String> antumbraPath() => toolPath('antumbra');

  /// 命令超时
  static const Duration shortTimeout = Duration(seconds: 10);
  static const Duration normalTimeout = Duration(seconds: 30);
  static const Duration longTimeout = Duration(seconds: 120);

  /// 窗口默认尺寸
  static const double windowWidth = 1180;
  static const double windowHeight = 760;
  static const double windowMinWidth = 900;
  static const double windowMinHeight = 600;
}
