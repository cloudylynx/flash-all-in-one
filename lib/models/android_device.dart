/// Android 设备模型
class AndroidDevice {
  /// 序列号（如 emulator-5554、ABCD1234）
  final String serial;

  /// 状态：device / offline / unauthorized / bootloader / recovery / unknown
  final String state;

  /// 连接方式：usb / emulator / tcp
  final String connectionType;

  // ---- 以下为详细信息，通过 getprop 填充 ----
  String? model;        // ro.product.model
  String? brand;        // ro.product.brand
  String? manufacturer; // ro.product.manufacturer
  String? androidVersion; // ro.build.version.release
  String? sdkVersion;   // ro.build.version.sdk
  String? abi;          // ro.product.cpu.abi
  String? productName;  // ro.product.name
  String? buildId;      // ro.build.id
  String? securityPatch; // ro.build.version.security_patch

  /// 是否已 root
  bool? isRooted;

  /// 屏幕分辨率（如 1080x2340）
  String? screenResolution;

  /// 屏幕密度（dpi）
  String? screenDensity;

  AndroidDevice({
    required this.serial,
    required this.state,
    required this.connectionType,
  });

  /// 是否可用（已授权且在线）
  ///
  /// fastboot 模式也算可用——虽然 adb 命令不可用，
  /// 但能读 getvar、刷机、重启，功能上是"可操作"的。
  bool get isReady => state == 'device';

  /// 是否可操作（系统模式或 fastboot 模式）
  bool get isOperable => isReady || isFastboot || isRecovery;

  /// 是否是模拟器
  bool get isEmulator =>
      serial.startsWith('emulator-') || connectionType == 'emulator';

  /// 是否在 fastboot 模式
  bool get isFastboot =>
      state == 'bootloader' || state == 'fastboot' || state == 'fastbootd';

  /// 是否在 recovery 模式（可以通过 adb sideload 操作）
  bool get isRecovery => state == 'recovery';

  /// 显示名：优先 model，其次 serial
  String get displayName {
    if (model != null && model!.isNotEmpty) return model!;
    return serial;
  }

  /// 副标题：品牌 + 系统版本
  String get subtitle {
    final parts = <String>[];
    if (brand != null && brand!.isNotEmpty) {
      parts.add(brand![0].toUpperCase() + brand!.substring(1));
    }
    if (androidVersion != null) parts.add('Android $androidVersion');
    if (sdkVersion != null) parts.add('API $sdkVersion');
    return parts.join(' · ');
  }

  AndroidDevice copyWith({String? state}) {
    final d = AndroidDevice(
      serial: serial,
      state: state ?? this.state,
      connectionType: connectionType,
    )
      ..model = model
      ..brand = brand
      ..manufacturer = manufacturer
      ..androidVersion = androidVersion
      ..sdkVersion = sdkVersion
      ..abi = abi
      ..productName = productName
      ..buildId = buildId
      ..securityPatch = securityPatch
      ..isRooted = isRooted
      ..screenResolution = screenResolution
      ..screenDensity = screenDensity;
    return d;
  }

  @override
  String toString() => 'AndroidDevice($serial, $state)';

  @override
  bool operator ==(Object other) =>
      other is AndroidDevice && other.serial == serial;

  @override
  int get hashCode => serial.hashCode;
}
