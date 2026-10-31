/// 已安装应用信息
class AppInfo {
  final String packageName;
  String? label;         // 应用名（需额外查询，可能为 null）
  String? versionName;   // 版本名，如 1.2.3
  int? versionCode;      // 版本号
  int? uid;
  bool isSystemApp;      // 是否系统应用
  bool isEnabled;        // 是否启用
  bool isStopped;        // 是否被强制停止

  AppInfo({
    required this.packageName,
    this.label,
    this.versionName,
    this.versionCode,
    this.uid,
    this.isSystemApp = false,
    this.isEnabled = true,
    this.isStopped = false,
  });

  /// 显示名
  String get displayName => label ?? packageName;

  /// 包名最后一段（通常是应用短名）
  String get shortName {
    final parts = packageName.split('.');
    return parts.length > 1 ? parts.last : packageName;
  }

  @override
  String toString() => 'AppInfo($packageName, ${versionName ?? "?"})';

  @override
  bool operator ==(Object other) =>
      other is AppInfo && other.packageName == packageName;

  @override
  int get hashCode => packageName.hashCode;
}
