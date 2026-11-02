import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/process_runner.dart';
import '../core/tool_extractor.dart';

/// scrcpy 启动参数
class ScrcpyOptions {
  /// 最大分辨率（长边，0 = 不限制）
  final int maxSize;

  /// 码率（Mbps）
  final int bitRateMbps;

  /// 最大帧率
  final int maxFps;

  /// 关闭音频
  final bool noAudio;

  /// 只读（不响应鼠标键盘）
  final bool readOnly;

  /// 保持常亮
  final bool stayAwake;

  /// 关闭屏幕（投屏时不点亮设备屏）
  final bool turnScreenOff;

  /// 置顶窗口
  final bool alwaysOnTop;

  /// 全屏
  final bool fullscreen;

  /// 无边框
  final bool borderless;

  /// 录制到文件
  final String? recordPath;

  /// 显示触摸点
  final bool showTouches;

  const ScrcpyOptions({
    this.maxSize = 0,
    this.bitRateMbps = 8,
    this.maxFps = 60,
    this.noAudio = true,
    this.readOnly = false,
    this.stayAwake = true,
    this.turnScreenOff = false,
    this.alwaysOnTop = false,
    this.fullscreen = false,
    this.borderless = false,
    this.recordPath,
    this.showTouches = false,
  });

  ScrcpyOptions copyWith({
    int? maxSize,
    int? bitRateMbps,
    int? maxFps,
    bool? noAudio,
    bool? readOnly,
    bool? stayAwake,
    bool? turnScreenOff,
    bool? alwaysOnTop,
    bool? fullscreen,
    bool? borderless,
    String? recordPath,
    bool? showTouches,
  }) {
    return ScrcpyOptions(
      maxSize: maxSize ?? this.maxSize,
      bitRateMbps: bitRateMbps ?? this.bitRateMbps,
      maxFps: maxFps ?? this.maxFps,
      noAudio: noAudio ?? this.noAudio,
      readOnly: readOnly ?? this.readOnly,
      stayAwake: stayAwake ?? this.stayAwake,
      turnScreenOff: turnScreenOff ?? this.turnScreenOff,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      fullscreen: fullscreen ?? this.fullscreen,
      borderless: borderless ?? this.borderless,
      recordPath: recordPath ?? this.recordPath,
      showTouches: showTouches ?? this.showTouches,
    );
  }

  /// 转成命令行参数
  List<String> toArgs(String serial) {
    final args = <String>['-s', serial];
    if (maxSize > 0) args.addAll(['--max-size', '$maxSize']);
    args.addAll(['--video-bit-rate', '${bitRateMbps}M']);
    if (maxFps > 0) args.addAll(['--max-fps', '$maxFps']);
    if (noAudio) args.add('--no-audio');
    if (readOnly) args.add('--no-control');
    if (stayAwake) args.add('--stay-awake');
    if (turnScreenOff) args.add('--turn-screen-off');
    if (alwaysOnTop) args.add('--always-on-top');
    if (fullscreen) args.add('--fullscreen');
    if (borderless) args.add('--window-borderless');
    if (showTouches) args.add('--show-touches');
    if (recordPath != null && recordPath!.isNotEmpty) {
      args.addAll(['--record', recordPath!]);
    }
    return args;
  }
}

/// scrcpy 服务
///
/// 依赖：scrcpy.exe + scrcpy-server + SDL2/FFmpeg DLL
/// 查找顺序：应用目录 tools/scrcpy/ → assets 提取 → 系统 PATH
class ScrcpyService {
  ScrcpyService._();
  static final ScrcpyService instance = ScrcpyService._();

  String? _exePath;
  String? _dir;
  bool _available = false;

  /// 内置 scrcpy 版本标记
  ///
  /// 升级 scrcpy 或 DLL 集时改这个值，
  /// 启动时会强制重新提取（避免旧文件残留导致 DLL 版本不匹配）。
  static const String _bundleVersion = 'scrcpy-5.0.1-sdl3-av63';

  /// 最近一次初始化失败的原因（供界面显示）
  String? _initError;
  String? get initError => _initError;
  Process? _running;

  bool get isAvailable => _available;
  bool get isRunning => _running != null;

  /// 初始化：定位 scrcpy 可执行文件
  ///
  /// 查找顺序：
  ///   1. 应用目录 tools/scrcpy/（已提取）
  ///   2. 从 assets 提取（含全部依赖 DLL）
  ///   3. 系统 PATH（用绝对路径验证，不靠 output.contains 误判）
  Future<bool> init() async {
    if (_available) return true;

    final exeName = Platform.isWindows ? 'scrcpy.exe' : 'scrcpy';

    // 1. 应用目录（先查已提取的）
    final base = await ToolExtractor.baseDir();
    if (base != null) {
      final direct = File(p.join(base, 'scrcpy', exeName));
      if (direct.existsSync()) {
        _exePath = direct.path;
        _dir = direct.parent.path;
        _available = true;
        return true;
      }
    }

    // 2. exe 同目录（打包后 tools/ 平铺）
    for (final sub in ['tools/scrcpy', 'tools']) {
      final dir = p.join(AppConfig.exeDir, sub);
      final exe = p.join(dir, exeName);
      if (File(exe).existsSync()) {
        _exePath = exe;
        _dir = dir;
        _available = true;
        return true;
      }
    }

    // 3. 从 assets 提取（scrcpy 需要 6 个文件一起）
    if (Platform.isWindows) {
      // scrcpy v5.0.1 官方依赖（注意是 SDL3 + avcodec-63，不是 SDL2 + avcodec-61）
      const files = [
        'scrcpy.exe',
        'scrcpy-server',
        'scrcpy.png',
        'SDL3.dll',
        'avcodec-63.dll',
        'avformat-63.dll',
        'avutil-61.dll',
        'swresample-7.dll',
        'libusb-1.0.dll',
        'AdbWinApi.dll',
        'AdbWinUsbApi.dll',
      ];

        var ok = 0;
        final errors = <String>[];

        // 提取所有文件，记录每个结果
        for (final f in files) {
          final r = await ToolExtractor.extractFileVerbose(
            assetPath: 'assets/tools/windows/scrcpy/$f',
            subDir: 'scrcpy',
            executable: f == 'scrcpy.exe',
          );
          if (r.path != null) {
            ok++;
          } else {
            errors.add('$f: ${r.error ?? "未知"}');
          }
        }

        // ═══ libusb 专项保证：这是唯一经常提取失败的文件 ═══
        if (base != null) {
          final scrcpyDir = p.join(base, 'scrcpy');
          final libusbTarget = File(p.join(scrcpyDir, 'libusb-1.0.dll'));
          final needLibusb =
              !libusbTarget.existsSync() || libusbTarget.lengthSync() == 0;

          if (needLibusb) {
            // 方案 1：从 qdl 目录借（同一份官方文件）
            for (final sub in ['qdl', 'sprd']) {
              final src = File(p.join(base, sub, 'libusb-1.0.dll'));
              if (src.existsSync() && src.lengthSync() > 0) {
                try {
                  await src.copy(libusbTarget.path);
                  if (libusbTarget.lengthSync() > 0) {
                    errors.add('libusb 已从 $sub 复制');
                    ok++;
                    break;
                  }
                } catch (_) {}
              }
            }

            // 方案 2：直接读 assets 字节写入（绕过 ToolExtractor）
            if (!libusbTarget.existsSync() || libusbTarget.lengthSync() == 0) {
              try {
                final data = await rootBundle
                    .load('assets/tools/windows/scrcpy/libusb-1.0.dll');
                await libusbTarget
                    .writeAsBytes(data.buffer.asUint8List(), flush: true);
                if (libusbTarget.lengthSync() > 0) {
                  errors.add('libusb 已直接写入');
                  ok++;
                }
              } catch (e) {
                errors.add('libusb 直接写入失败: $e');
              }
            }
          }
        }

        // 写提取日志（Windows 可查）
        try {
          if (base != null) {
            final logFile = File(p.join(base, 'scrcpy-extract.log'));
            final listing = <String>[];
            final d = Directory(p.join(base, 'scrcpy'));
            if (d.existsSync()) {
              for (final f in d.listSync().whereType<File>()) {
                listing.add('  ${p.basename(f.path)}  ${f.lengthSync()} B');
              }
            }
            logFile.writeAsStringSync(
              '=== scrcpy 提取 ${DateTime.now()} ===\n'
              'bundle: $_bundleVersion\n'
              'ok: $ok/${files.length}\n\n'
              '=== 目录内容 ===\n${listing.join("\n")}\n\n'
              '=== 备注 ===\n${errors.join("\n")}\n',
            );
          }
        } catch (_) {}

        // 关键文件完整性校验（不要求全部成功，但必须齐这 8 个）
        var criticalOk = true;
        if (base != null) {
          const critical = [
            'scrcpy.exe', 'scrcpy-server', 'SDL3.dll',
            'avcodec-63.dll', 'avformat-63.dll', 'avutil-61.dll',
            'swresample-7.dll', 'libusb-1.0.dll',
          ];
          for (final f in critical) {
            final file = File(p.join(base, 'scrcpy', f));
            if (!file.existsSync() || file.lengthSync() == 0) {
              criticalOk = false;
              errors.add('缺失关键文件: $f');
            }
          }
        }

        if (criticalOk && base != null) {
        // 写版本标记，下次启动就不用重新提取
        try {
          File(p.join(base, 'scrcpy', '.bundle-version'))
              .writeAsStringSync(_bundleVersion);
        } catch (_) {}

        _exePath = p.join(base, 'scrcpy', 'scrcpy.exe');
        _dir = p.join(base, 'scrcpy');
        _available = true;
        return true;
      }
    }

    // 4. 系统 PATH —— 用绝对路径验证，绝不用 output.contains
    try {
      final which = Platform.isWindows ? 'where' : 'which';
      final r = await ProcessRunner.run(which, ['scrcpy'],
          timeout: AppConfig.shortTimeout);
      if (r.exitCode == 0 && r.stdout.trim().isNotEmpty) {
        final path = r.stdout.trim().split('\n').first.trim();
        // 必须是真实存在的文件
        if (path.isNotEmpty && File(path).existsSync()) {
          _exePath = path;
          _dir = File(path).parent.path;
          _available = true;
          return true;
        }
      }
    } catch (_) {}

    _available = false;
    if (_initError == null) {
      if (!Platform.isWindows) {
        _initError = '当前平台不支持 scrcpy 投屏\n'
            '平台: ${Platform.operatingSystem}\n'
            '内置 scrcpy 是 Windows 版本，仅 Windows 可用\n'
            'Linux/macOS 请用系统包管理器安装 scrcpy';
      } else {
        _initError = 'scrcpy 提取失败\n'
            '应用目录: ${base ?? "无法获取"}\n'
            '检查是否被杀毒软件拦截，或手动删除该目录后重启';
      }
    }
    return false;
  }

  /// 版本
  Future<String?> version() async {
    if (!await init()) return null;
    final r = await ProcessRunner.run(_exePath!, ['--version'],
        timeout: AppConfig.shortTimeout);
    final m = RegExp(r'scrcpy\s+([\d.]+)').firstMatch(r.output);
    return m?.group(1);
  }


  /// 诊断 scrcpy 启动失败原因
  ///
  /// 退出码：
  ///   0xC0000135 (-1073741515) = 找不到 DLL（或 DLL 版本不匹配）
  ///   0xC000007B (-1073741701) = 架构不匹配
  ///   2 = 找不到 adb
  Future<Map<String, dynamic>> diagnose() async {
    final result = <String, dynamic>{};

    if (!await init()) {
      result['error'] = 'scrcpy 未找到';
      result['diagnosis'] = 'scrcpy 未就绪';
      return result;
    }

    result['exePath'] = _exePath;
    result['dir'] = _dir;
    result['bundleVersion'] = _bundleVersion;

    // 1. 检查必需文件是否齐全
    const required = [
      'scrcpy.exe', 'scrcpy-server',
      'SDL3.dll', 'avcodec-63.dll', 'avformat-63.dll',
      'avutil-61.dll', 'swresample-7.dll', 'libusb-1.0.dll',
    ];

    final missing = <String>[];
    final present = <String, int>{};

    if (_dir != null) {
      for (final f in required) {
        final file = File(p.join(_dir!, f));
        if (!file.existsSync() || file.lengthSync() == 0) {
          missing.add(f);
        } else {
          present[f] = file.lengthSync();
        }
      }
      result['files'] = present;
      result['missing'] = missing;
    }

    // 2. 尝试 --version（不依赖设备）
    final verRun = await ProcessRunner.run(
      _exePath!,
      ['--version'],
      timeout: const Duration(seconds: 10),
      workingDirectory: _dir,
    );
    result['versionExitCode'] = verRun.exitCode;
    result['versionOutput'] = verRun.output;

    // 3. 诊断
    final code = verRun.exitCode;
    if (missing.isNotEmpty) {
      result['diagnosis'] = '缺少文件：${missing.join(", ")}\n'
          '请删除 ${_dir ?? ""} 目录后重启应用重新提取';
    } else if (code == -1073741515 || code == 3221225781) {
      result['diagnosis'] = 'DLL 加载失败（0xC0000135）\n'
          '文件都在但加载不了，可能是：\n'
          '  · 残留旧版 DLL（SDL2 vs SDL3）\n'
          '  · 系统缺 VC++ 运行库\n'
          '请删除 ${_dir ?? ""} 目录后重启应用';
    } else if (code == -1073741701 || code == 3221225595) {
      result['diagnosis'] = '架构不匹配（0xC000007B）';
    } else if (code == 0) {
      result['diagnosis'] = 'scrcpy 可独立运行（版本 ${verRun.output.split("\n").first}）\n'
          '问题在设备连接或 adb';
    } else {
      result['diagnosis'] = '退出码 $code\n${verRun.output}';
    }

    return result;
  }

  /// 确保 scrcpy 目录下有 adb.exe
  ///
  /// scrcpy.exe 会从自己的目录找 adb.exe（或 PATH），
  /// 找不到就报 "CreateProcessW() error 2 / Command not found: [adb]"
  Future<void> _ensureAdbInScrcpyDir() async {
    if (!Platform.isWindows || _dir == null) return;

    // 关键：不能只看 adb.exe 存在就跳过。
    // adb.exe 依赖 AdbWinApi.dll + AdbWinUsbApi.dll，
    // 缺任一 DLL 会报 "CreateProcessW() error 5"（拒绝访问）
    const required = ['adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll'];
    final missing = required
        .where((f) => !File(p.join(_dir!, f)).existsSync())
        .toList();
    if (missing.isEmpty) return;

    // 从 AppConfig 的 adb 目录复制
    try {
      final adbPath = await AppConfig.adbPath();
      final src = File(adbPath);
      if (src.existsSync()) {
        for (final name in missing) {
          final source =
              name == 'adb.exe' ? src : File(p.join(src.parent.path, name));
          if (source.existsSync()) {
            await source.copy(p.join(_dir!, name));
          }
        }
      }
    } catch (_) {}

    // 兜底：从 assets 直接提取（src.parent 可能不含 DLL）
    for (final name in required) {
      final target = File(p.join(_dir!, name));
      if (target.existsSync()) continue;
      try {
        final data = await rootBundle.load('assets/tools/windows/$name');
        await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      } catch (_) {}
    }
  }

  /// 启动投屏
  ///
  /// 返回 null 表示启动成功，否则返回错误信息。
  Future<String?> start({
    required String serial,
    ScrcpyOptions options = const ScrcpyOptions(),
    void Function(String line)? onLine,
  }) async {
    if (!await init()) {
      return 'scrcpy 未找到（需要 scrcpy.exe + scrcpy-server + DLL）';
    }
    if (_running != null) {
      return '已有投屏在运行';
    }

    // 确保 scrcpy 目录有 adb.exe（否则报 CreateProcessW error 2）
    await _ensureAdbInScrcpyDir();

    try {
      _running = await Process.start(
        _exePath!,
        options.toArgs(serial),
        workingDirectory: _dir,
        runInShell: false,
      );

      // 监听输出
      _running!.stdout
          .transform(const SystemEncoding().decoder)
          .listen((s) => onLine?.call(s.trimRight()));
      _running!.stderr
          .transform(const SystemEncoding().decoder)
          .listen((s) => onLine?.call(s.trimRight()));

      // 进程退出时清理
      unawaited(_running!.exitCode.then((code) {
        _running = null;
        onLine?.call('── scrcpy 已退出（$code）');
      }));

      return null;
    } catch (e) {
      _running = null;
      return '启动失败: $e';
    }
  }

  /// 停止投屏
  Future<void> stop() async {
    final proc = _running;
    _running = null;
    if (proc != null) {
      try {
        proc.kill();
      } catch (_) {}
    }
  }

  /// 检查 scrcpy-server 是否就位（启动必需）
  bool get hasServer {
    if (_dir == null) return true; // 系统 PATH 模式，无法检查
    return File(p.join(_dir!, 'scrcpy-server')).existsSync();
  }
}
