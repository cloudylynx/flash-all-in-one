/// 输入校验
///
/// 所有要拼进 shell 命令的参数都必须先经过校验，
/// 防止命令注入（例：用户输入 `/dev/block/sda; rm -rf /`）。
///
/// 注意：这类漏洞在 root shell 里执行 = 设备完全失控。
class InputSanitizer {
  InputSanitizer._();

  /// 校验设备磁盘路径
  ///
  /// 允许：
  ///   /dev/block/sda
  ///   /dev/block/mmcblk0
  ///   /dev/block/nvme0n1
  ///   /dev/block/sda25      （分区）
  ///   /dev/block/mmcblk0p1  （分区）
  ///   /dev/block/by-name/userdata
  ///
  /// 拒绝：含空格、分号、管道、重定向、反引号、$() 等
  static bool isValidDevicePath(String input) {
    if (input.isEmpty || input.length > 128) return false;
    // 只允许：/dev/block/ 开头 + 安全字符
    return RegExp(r'^/dev/block/[a-zA-Z0-9_./:\-]+$').hasMatch(input);
  }

  /// 校验分区名（如 userdata / system / sda25）
  static bool isValidPartitionName(String input) {
    if (input.isEmpty || input.length > 64) return false;
    return RegExp(r'^[a-zA-Z0-9_\-]+$').hasMatch(input);
  }

  /// 校验卷标（文件系统 label）
  ///
  /// NTFS/FAT32 卷标限制较多，这里只放行字母数字和少量符号
  static bool isValidVolumeLabel(String input) {
    if (input.isEmpty) return true; // 空表示不设置
    if (input.length > 32) return false;
    // 允许中文/日文/韩文等 Unicode 字母，但排除 shell 元字符
    if (RegExp(r'[;&|$`()<>\n\r/\\:*?"]').hasMatch(input)) return false;
    // 只允许字母（含 Unicode）、数字、下划线、连字符、空格
    return RegExp(r'^[\w\- \u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]+$')
        .hasMatch(input);
  }

  /// 校验串口路径
  static bool isValidSerialPort(String input) {
    if (input.isEmpty || input.length > 128) return false;
    // Linux: /dev/ttyUSB0 /dev/ttyACM0   Windows: COM1
    return RegExp(r'^(/dev/tty(S|USB|ACM|AMA)[0-9]+|COM[0-9]+)$')
        .hasMatch(input);
  }

  /// 校验挂载点路径
  static bool isValidMountPoint(String input) {
    if (input.isEmpty || input.length > 128) return false;
    return RegExp(r'^/[a-zA-Z0-9_./\-]*$').hasMatch(input);
  }

  /// 校验 IP:端口（无线 ADB）
  static bool isValidHostPort(String input) {
    if (input.isEmpty || input.length > 64) return false;
    return RegExp(r'^[0-9a-zA-Z.\-]+(:[0-9]{1,5})?$').hasMatch(input);
  }

  /// 通用：拒绝明显危险的字符
  ///
  /// 用于没有专门校验器但对安全性有要求的场景
  static bool hasShellMetaChars(String input) {
    // ; | & $ ` ( ) < > \n \r 都不允许
    return RegExp(r'[;&|$`()<>\n\r]').hasMatch(input);
  }

  /// 返回校验失败的原因（给用户看）
  static String? explainDevicePath(String input) {
    if (input.isEmpty) return '不能为空';
    if (input.length > 128) return '路径过长';
    if (!input.startsWith('/dev/block/')) return '必须以 /dev/block/ 开头';
    if (RegExp(r'[;&|$`()<>\s]').hasMatch(input)) {
      return '包含非法字符（空格、分号、管道等）';
    }
    if (!RegExp(r'^/dev/block/[a-zA-Z0-9_./:\-]+$').hasMatch(input)) {
      return '包含不支持的字符';
    }
    return null;
  }
}
