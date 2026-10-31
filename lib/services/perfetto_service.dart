import 'dart:io';

import '../core/config.dart';
import '../core/process_runner.dart';

/// Perfetto 采集结果
class PerfettoResult {
  final bool ok;
  final String message;
  final String? tracePath;
  final List<String> log;
  PerfettoResult(this.ok, this.message, {this.tracePath, this.log = const []});
}

/// Perfetto 性能追踪服务
///
/// 技术来源：google/perfetto（6722★，Apache-2.0）
///
/// **零安装成本**：Android 10（API 29）及以上设备自带 perfetto 命令，
/// 不需要往设备推任何二进制。
///
/// 采集流程：
///   1. adb shell perfetto -t <时长> -b <缓冲区> -o <设备路径> <类别...>
///   2. adb pull <设备路径> <本地路径>
///   3. adb shell rm <设备路径>
///
/// 常用采集类别：
///   sched   —— CPU 调度（看掉帧、卡顿）
///   gfx     —— 图形（GPU 渲染）
///   view    —— View 系统（UI 绘制）
///   wm      —— Window Manager
///   am      —— Activity Manager（启动耗时）
///   input   —— 输入事件
///   freq    —— CPU 频率
///   idle    —— 电源管理
///   binder_driver —— Binder 通信
class PerfettoService {
  PerfettoService._();
  static final PerfettoService instance = PerfettoService._();

  /// 采集预设
  static const presets = <String, PerfettoPreset>{
    'quick': PerfettoPreset(
      id: 'quick',
      name: '快速诊断（10 秒）',
      description: 'CPU + 图形 + 输入，适合快速看卡顿',
      duration: 10,
      bufferSize: 32,
      categories: ['sched', 'gfx', 'input', 'view'],
    ),
    'startup': PerfettoPreset(
      id: 'startup',
      name: '应用启动分析（15 秒）',
      description: 'Activity 启动 + Binder + CPU',
      duration: 15,
      bufferSize: 64,
      categories: ['sched', 'am', 'binder_driver', 'freq'],
    ),
    'jank': PerfettoPreset(
      id: 'jank',
      name: '掉帧分析（20 秒）',
      description: '图形 + View + 调度，定位掉帧原因',
      duration: 20,
      bufferSize: 64,
      categories: ['sched', 'gfx', 'view', 'wm'],
    ),
    'battery': PerfettoPreset(
      id: 'battery',
      name: '耗电分析（30 秒）',
      description: '电源 + CPU 频率 + 空闲状态',
      duration: 30,
      bufferSize: 64,
      categories: ['power', 'freq', 'idle', 'sched'],
    ),
    'full': PerfettoPreset(
      id: 'full',
      name: '完整采集（30 秒）',
      description: '所有常用类别，数据量大',
      duration: 30,
      bufferSize: 128,
      categories: [
        'sched', 'gfx', 'view', 'wm', 'am', 'input',
        'freq', 'idle', 'power', 'binder_driver',
      ],
    ),
  };

  /// 检查设备是否支持 perfetto
  Future<(bool, String)> checkSupport(String serial) async {
    final adb = await AppConfig.adbPath();

    // 1. 检查 perfetto 命令是否存在
    final r = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'which', 'perfetto'],
      timeout: AppConfig.shortTimeout,
    );

    if (!r.ok || r.output.contains('not found') || r.output.trim().isEmpty) {
      return (false, '设备没有 perfetto 命令（需要 Android 10+）');
    }

    // 2. 检查 API 版本
    final sdk = await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'getprop', 'ro.build.version.sdk'],
      timeout: AppConfig.shortTimeout,
    );
    final sdkVer = int.tryParse(sdk.output.trim()) ?? 0;

    if (sdkVer < 29) {
      return (false, 'API $sdkVer < 29，需要 Android 10+（或手动推 tracebox）');
    }

    return (true, 'API $sdkVer，perfetto 可用');
  }

  /// 采集 trace
  Future<PerfettoResult> capture({
    required String serial,
    required PerfettoPreset preset,
    required String outputPath,
    void Function(String line)? onLine,
  }) async {
    final log = <String>[];
    void add(String s) {
      log.add(s);
      onLine?.call(s);
    }

    final adb = await AppConfig.adbPath();

    // 1. 检查支持
    add('══ Perfetto 性能采集');
    final (supported, msg) = await checkSupport(serial);
    add('  $msg');
    if (!supported) {
      return PerfettoResult(false, msg, log: log);
    }
    add('');

    // 2. 设备端路径
    final devicePath =
        '/data/misc/perfetto-traces/faio_${DateTime.now().millisecondsSinceEpoch}.pftrace';

    add('── 采集配置');
    add('  时长: ${preset.duration} 秒');
    add('  缓冲: ${preset.bufferSize} MB');
    add('  类别: ${preset.categories.join(", ")}');
    add('');

    // 3. 执行采集
    add('── 开始采集（${preset.duration} 秒）');
    final args = [
      '-s', serial, 'shell', 'perfetto',
      '-t', '${preset.duration}s',
      '-b', '${preset.bufferSize}mb',
      '-o', devicePath,
      ...preset.categories,
    ];

    final captureResult = await ProcessRunner.run(
      adb,
      args,
      timeout: Duration(seconds: preset.duration + 30),
    );

    if (!captureResult.ok) {
      add('❌ 采集失败: ${captureResult.output}');
      return PerfettoResult(false, '采集失败', log: log);
    }
    add('  ✅ 采集完成');

    // 4. 拉取
    add('── 拉取 trace');
    final pullResult = await ProcessRunner.run(
      adb,
      ['-s', serial, 'pull', devicePath, outputPath],
      timeout: AppConfig.longTimeout,
    );

    if (!pullResult.ok) {
      add('❌ 拉取失败: ${pullResult.output}');
      return PerfettoResult(false, '拉取失败', log: log);
    }

    // 5. 清理设备端
    await ProcessRunner.run(
      adb,
      ['-s', serial, 'shell', 'rm', '-f', devicePath],
      timeout: AppConfig.shortTimeout,
    );

    // 6. 检查文件大小
    final f = File(outputPath);
    if (f.existsSync()) {
      final size = f.lengthSync();
      add('  ✅ 已保存: $outputPath');
      add('     大小: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
      add('');
      add('📌 分析方式：');
      add('  · 用 Perfetto UI（ui.perfetto.dev）打开');
      add('  · 或用 trace_processor 命令行查询');
      return PerfettoResult(
        true,
        '采集完成（${(size / 1024 / 1024).toStringAsFixed(2)} MB）',
        tracePath: outputPath,
        log: log,
      );
    }

    add('❌ 文件未生成');
    return PerfettoResult(false, '文件未生成', log: log);
  }

  /// 快捷采集：只抓 CPU 调度（最快）
  Future<PerfettoResult> quickCapture({
    required String serial,
    required String outputPath,
    int seconds = 10,
    void Function(String line)? onLine,
  }) async {
    return capture(
      serial: serial,
      preset: PerfettoPreset(
        id: 'custom',
        name: '自定义',
        description: '',
        duration: seconds,
        bufferSize: 32,
        categories: ['sched', 'gfx', 'input'],
      ),
      outputPath: outputPath,
      onLine: onLine,
    );
  }
}

/// 采集预设
class PerfettoPreset {
  final String id;
  final String name;
  final String description;
  final int duration;
  final int bufferSize;
  final List<String> categories;

  const PerfettoPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.duration,
    required this.bufferSize,
    required this.categories,
  });
}
