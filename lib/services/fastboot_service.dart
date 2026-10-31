import 'dart:async';

import '../core/config.dart';
import '../core/process_runner.dart';

/// Fastboot 设备信息
class FastbootDevice {
  final String serial;
  final String mode; // fastboot / fastbootd

  FastbootDevice({required this.serial, this.mode = 'fastboot'});

  @override
  String toString() => '$serial ($mode)';
}

/// Fastboot 服务
///
/// 封装 fastboot 命令：刷机、解锁、分区操作。
class FastbootService {
  FastbootService._();
  static final FastbootService instance = FastbootService._();

  String? _fbPathCache;

  Future<String> _getFb() async {
    _fbPathCache ??= await AppConfig.fastbootPath();
    return _fbPathCache!;
  }

  /// 检查 fastboot 是否可用
  Future<bool> isAvailable() async {
    final r = await ProcessRunner.run(await _getFb(), ['--version'],
        timeout: AppConfig.shortTimeout);
    return r.ok || r.output.contains('fastboot');
  }

  /// 列出 fastboot 设备
  ///
  /// 输出格式：`ABCD1234	fastboot`
  Future<List<FastbootDevice>> listDevices() async {
    final r = await ProcessRunner.run(await _getFb(), ['devices'],
        timeout: AppConfig.shortTimeout);
    if (!r.ok) return [];

    final devices = <FastbootDevice>[];
    for (final line in r.stdout.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        devices.add(FastbootDevice(serial: parts[0], mode: parts[1]));
      } else if (parts.length == 1 && parts[0].isNotEmpty) {
        devices.add(FastbootDevice(serial: parts[0]));
      }
    }
    return devices;
  }

  /// 获取设备变量
  Future<Map<String, String>> getVars(String serial) async {
    final r = await ProcessRunner.run(await _getFb(),
      ['-s', serial, 'getvar', 'all'],
      timeout: AppConfig.normalTimeout,
    );
    final vars = <String, String>{};
    // 输出到 stderr：(bootloader) product: xxx
    for (final line in r.output.split('\n')) {
      final m = RegExp(r'\(bootloader\)\s+(\S+):\s*(.*)').firstMatch(line);
      if (m != null) vars[m.group(1)!] = m.group(2)!.trim();
    }
    return vars;
  }

  /// 刷入分区
  Future<int> flash(
    String serial,
    String partition,
    String imagePath, {
    void Function(String line)? onLine,
    bool slot = false,
  }) async {
    final args = ['-s', serial, 'flash'];
    if (slot) args.add('--slot=all');
    args.addAll([partition, imagePath]);

    return ProcessRunner.stream(await _getFb(),
      args,
      onLine: onLine ?? (_) {},
      timeout: AppConfig.longTimeout,
    );
  }

  /// 擦除分区
  Future<ExecResult> erase(String serial, String partition) async {
    return ProcessRunner.run(await _getFb(),
      ['-s', serial, 'erase', partition],
      timeout: AppConfig.normalTimeout,
    );
  }

  /// 临时启动镜像（不刷入）
  Future<ExecResult> boot(String serial, String imagePath) async {
    return ProcessRunner.run(await _getFb(),
      ['-s', serial, 'boot', imagePath],
      timeout: AppConfig.longTimeout,
    );
  }

  /// 解锁 bootloader
  Future<ExecResult> oemUnlock(String serial) async {
    return ProcessRunner.run(await _getFb(),
      ['-s', serial, 'oem', 'unlock'],
      timeout: AppConfig.normalTimeout,
    );
  }

  /// 上锁 bootloader
  Future<ExecResult> oemLock(String serial) async {
    return ProcessRunner.run(await _getFb(),
      ['-s', serial, 'oem', 'lock'],
      timeout: AppConfig.normalTimeout,
    );
  }

  /// 重启到系统
  Future<ExecResult> reboot(String serial, {String? target}) async {
    final args = ['-s', serial, 'reboot'];
    if (target != null) args.add(target);
    return ProcessRunner.run(await _getFb(), args, timeout: AppConfig.shortTimeout);
  }

  /// 重启到 fastbootd（用户空间 fastboot）
  Future<ExecResult> rebootFastbootd(String serial) async {
    return ProcessRunner.run(await _getFb(),
      ['-s', serial, 'reboot', 'fastboot'],
      timeout: AppConfig.normalTimeout,
    );
  }

  /// 从 fastboot 重启到 recovery
  Future<ExecResult> rebootRecovery(String serial) async {
    return ProcessRunner.run(await _getFb(),
      ['-s', serial, 'reboot', 'recovery'],
      timeout: AppConfig.shortTimeout,
    );
  }

  /// 设置活动槽位（AB 分区设备）
  Future<ExecResult> setActiveSlot(String serial, String slot) async {
    return ProcessRunner.run(await _getFb(),
      ['-s', serial, '--set-active=$slot'],
      timeout: AppConfig.normalTimeout,
    );
  }

  /// 查询当前槽位
  Future<String?> currentSlot(String serial) async {
    final vars = await getVars(serial);
    return vars['current-slot'];
  }

  /// 获取分区列表
  Future<List<String>> listPartitions(String serial) async {
    final vars = await getVars(serial);
    final partitions = <String>[];
    for (final key in vars.keys) {
      if (key.startsWith('partition-type:')) {
        partitions.add(key.substring('partition-type:'.length));
      }
    }
    return partitions;
  }
}
