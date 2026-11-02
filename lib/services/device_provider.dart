import 'dart:io';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/config.dart';
import '../models/android_device.dart';
import '../services/adb_service.dart';
import '../services/fastboot_service.dart';

/// 设备状态管理
///
/// 负责：
/// - 定时轮询设备列表
/// - 维护当前选中设备
/// - 加载设备详细信息
class DeviceProvider extends ChangeNotifier {
  final AdbService _adb = AdbService.instance;

  List<AndroidDevice> _devices = [];
  String? _selectedSerial;
  bool _adbReady = false;
  String? _adbVersion;
  String? _error;
  Timer? _pollTimer;
  bool _autoRefresh = true;
  int _refreshSeconds = 3;
  bool _loadingDetails = false;

  List<AndroidDevice> get devices => _devices;
  bool get adbReady => _adbReady;
  String? get adbVersion => _adbVersion;
  String? get error => _error;
  bool get loadingDetails => _loadingDetails;

  /// 当前选中设备
  AndroidDevice? get selectedDevice {
    if (_selectedSerial == null) return null;
    try {
      return _devices.firstWhere((d) => d.serial == _selectedSerial);
    } catch (_) {
      return null;
    }
  }

  String? get selectedSerial => _selectedSerial;

  /// 初始化：检查 adb、首次拉设备、启动轮询
  Future<void> init() async {
    await _checkAdb();
    await refresh();
    _startPolling();
  }

  Future<void> _checkAdb() async {
    _adbReady = false;
    _error = null;

    try {
      final path = await AppConfig.adbPath();
      final available = await _adb.isAvailable();

      if (available) {
        _adbReady = true;
        _adbVersion = await _adb.version();
        await _adb.startServer();
      } else {
        // 给出可诊断的详细原因
        final detail = await _adb.diagnose(path);
        _error = 'adb 不可用\n\n'
            '路径: $path\n'
            '存在: ${File(path).existsSync()}\n'
            '$detail';
      }
    } catch (e) {
      _error = 'adb 检测异常: $e';
    }

    notifyListeners();
  }

  /// 手动刷新设备列表
  Future<void> refresh() async {
    final list = await _adb.listDevices();

    // 测试用：GAOJI_MOCK_FASTBOOT=1 模拟一个 fastboot 设备
    if (Platform.environment['GAOJI_MOCK_FASTBOOT'] == '1') {
      list.add(AndroidDevice(
        serial: 'MOCK_FASTBOOT_DEVICE',
        state: 'fastboot',
        connectionType: 'usb',
      ));
    }

    // 同时查 fastboot 设备（fastboot 模式下 adb 看不到）
    try {
      final fbDevices = await FastbootService.instance.listDevices();
      for (final fb in fbDevices) {
        // 避免和 adb 设备重复
        if (list.any((d) => d.serial == fb.serial)) continue;
        list.add(AndroidDevice(
          serial: fb.serial,
          state: 'fastboot',
          connectionType: 'usb',
        ));
      }
    } catch (_) {}

    // 保留已加载的详细信息（避免每次轮询都重新查 getprop）
    final merged = <AndroidDevice>[];
    for (final d in list) {
      final old = _devices.where((o) => o.serial == d.serial).firstOrNull;
      if (old != null && old.model != null) {
        merged.add(old.copyWith(state: d.state));
      } else {
        merged.add(d);
      }
    }

    _devices = merged;

    // 选中设备被拔掉时清空选择
    if (_selectedSerial != null &&
        !_devices.any((d) => d.serial == _selectedSerial)) {
      _selectedSerial = null;
    }

      // 优先选 fastboot 设备（fastboot 模式下 adb 看不到，但设备确实连着）
      if (_selectedSerial == null) {
        final fb = _devices.where((d) => d.isFastboot).firstOrNull;
        if (fb != null) {
          _selectedSerial = fb.serial;
        }
      }

      // 只有一个可操作设备时自动选中（含 fastboot）
      if (_selectedSerial == null) {
        final operable = _devices.where((d) => d.isOperable).toList();
        if (operable.length == 1) {
          _selectedSerial = operable.first.serial;
          if (operable.first.isReady) {
            unawaited(loadDeviceDetails(operable.first.serial));
          }
        }
      }



      // 测试用：GAOJI_AUTO_SELECT=1 自动选第一台可操作设备
      if (Platform.environment['GAOJI_AUTO_SELECT'] == '1' &&
          _selectedSerial == null) {
        final operable = _devices.where((d) => d.isOperable).toList();
        if (operable.isNotEmpty) {
          _selectedSerial = operable.first.serial;
          if (operable.first.isReady) {
            unawaited(loadDeviceDetails(operable.first.serial));
          }
        }
      }

    notifyListeners();
  }

  /// 选中设备
  Future<void> selectDevice(String serial) async {
    _selectedSerial = serial;
    notifyListeners();
    await loadDeviceDetails(serial);
  }

  /// 加载设备详细信息
  Future<void> loadDeviceDetails(String serial) async {
    final idx = _devices.indexWhere((d) => d.serial == serial);
    if (idx < 0) return;
    if (!_devices[idx].isReady) return;

    _loadingDetails = true;
    notifyListeners();

    try {
      final filled = await _adb.fillDeviceInfo(_devices[idx]);
      filled.isRooted = await _adb.checkRoot(serial);
      _devices[idx] = filled;
    } catch (e) {
      _error = '加载设备信息失败：$e';
    }

    _loadingDetails = false;
    notifyListeners();
  }

  /// 重新扫描 adb（用户手动点刷新时用）
  Future<void> restartAdb() async {
    await _adb.killServer();
    await Future.delayed(const Duration(milliseconds: 500));
    await _adb.startServer();
    await Future.delayed(const Duration(milliseconds: 500));
    await refresh();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    if (!_autoRefresh) return;
    _pollTimer = Timer.periodic(Duration(seconds: _refreshSeconds), (_) {
      unawaited(refresh());
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// 设置自动刷新
  void setAutoRefresh(bool enabled) {
    _autoRefresh = enabled;
    if (enabled) {
      _startPolling();
    } else {
      _stopPolling();
    }
    notifyListeners();
  }

  /// 设置刷新间隔（秒）
  void setRefreshInterval(int seconds) {
    _refreshSeconds = seconds;
    if (_autoRefresh) {
      _stopPolling();
      _startPolling();
    }
    notifyListeners();
  }

}
