// 输入清洗测试
//
// 这是安全关键代码：防止 UI 输入被拼进 shell 命令造成命令注入。
// 之前发现过 /dev/block/sda; rm -rf / 这类攻击载荷能通过。

import 'package:flutter_test/flutter_test.dart';
import 'package:flashallinone/core/input_sanitizer.dart';

void main() {
  // ─────────────────────────────────────────────────
  group('isValidDevicePath', () {
    test('标准块设备路径通过', () {
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda'), isTrue);
      expect(InputSanitizer.isValidDevicePath('/dev/block/mmcblk0p1'), isTrue);
      expect(InputSanitizer.isValidDevicePath('/dev/block/by-name/system'),
          isTrue);
      expect(InputSanitizer.isValidDevicePath('/dev/block/vold/179:1'), isTrue);
      expect(InputSanitizer.isValidDevicePath('/dev/block/dm-0'), isTrue);
    });

    test('分号注入被拒', () {
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda; rm -rf /'),
          isFalse);
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda;reboot'), isFalse);
    });

    test('管道注入被拒', () {
      expect(
          InputSanitizer.isValidDevicePath('/dev/block/sda | cat /etc/passwd'),
          isFalse);
    });

    test('与号注入被拒', () {
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda && reboot'),
          isFalse);
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda & reboot'),
          isFalse);
    });

    test('反引号和 \$() 注入被拒', () {
      expect(InputSanitizer.isValidDevicePath('/dev/block/`reboot`'), isFalse);
      expect(InputSanitizer.isValidDevicePath(r'/dev/block/$(reboot)'), isFalse);
    });

    test('重定向注入被拒', () {
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda > /dev/null'),
          isFalse);
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda < /etc/passwd'),
          isFalse);
    });

    test('相对路径被拒', () {
      expect(InputSanitizer.isValidDevicePath('dev/block/sda'), isFalse);
      expect(InputSanitizer.isValidDevicePath('./sda'), isFalse);
      expect(InputSanitizer.isValidDevicePath('../sda'), isFalse);
    });

    test('换行符注入被拒', () {
      expect(InputSanitizer.isValidDevicePath('/dev/block/sda\nreboot'),
          isFalse);
    });

    test('空字符串被拒', () {
      expect(InputSanitizer.isValidDevicePath(''), isFalse);
    });
  });

  // ─────────────────────────────────────────────────
  group('isValidVolumeLabel', () {
    test('ASCII 卷标通过', () {
      expect(InputSanitizer.isValidVolumeLabel('Windows'), isTrue);
      expect(InputSanitizer.isValidVolumeLabel('DATA'), isTrue);
      expect(InputSanitizer.isValidVolumeLabel('My Disk'), isTrue);
    });

    test('中文卷标通过', () {
      expect(InputSanitizer.isValidVolumeLabel('数据'), isTrue);
      expect(InputSanitizer.isValidVolumeLabel('系统盘'), isTrue);
    });

    test('日文 / 韩文通过', () {
      expect(InputSanitizer.isValidVolumeLabel('データ'), isTrue);
      expect(InputSanitizer.isValidVolumeLabel('데이터'), isTrue);
    });

    test('shell 元字符被拒', () {
      expect(InputSanitizer.isValidVolumeLabel('a;b'), isFalse);
      expect(InputSanitizer.isValidVolumeLabel('a|b'), isFalse);
      expect(InputSanitizer.isValidVolumeLabel('a&b'), isFalse);
      expect(InputSanitizer.isValidVolumeLabel('a`b'), isFalse);
      expect(InputSanitizer.isValidVolumeLabel(r'a$b'), isFalse);
      expect(InputSanitizer.isValidVolumeLabel('a(b)'), isFalse);
      expect(InputSanitizer.isValidVolumeLabel('a<b>'), isFalse);
    });
  });

  // ─────────────────────────────────────────────────
  group('isValidPartitionName', () {
    test('常见分区名通过', () {
      for (final n in ['boot', 'system', 'vendor', 'userdata', 'boot_a']) {
        expect(InputSanitizer.isValidPartitionName(n), isTrue, reason: n);
      }
    });

    test('注入被拒', () {
      expect(InputSanitizer.isValidPartitionName('boot; rm -rf /'), isFalse);
      expect(InputSanitizer.isValidPartitionName('boot|cat'), isFalse);
      expect(InputSanitizer.isValidPartitionName(''), isFalse);
    });
  });

  // ─────────────────────────────────────────────────
  group('isValidSerialPort', () {
    test('常见串口通过', () {
      expect(InputSanitizer.isValidSerialPort('COM1'), isTrue);
      expect(InputSanitizer.isValidSerialPort('COM12'), isTrue);
      expect(InputSanitizer.isValidSerialPort('/dev/ttyUSB0'), isTrue);
      expect(InputSanitizer.isValidSerialPort('/dev/ttyACM0'), isTrue);
    });

    test('注入被拒', () {
      expect(InputSanitizer.isValidSerialPort('COM1; reboot'), isFalse);
      expect(InputSanitizer.isValidSerialPort('/dev/ttyUSB0|cat'), isFalse);
    });
  });

  // ─────────────────────────────────────────────────
  group('isValidHostPort', () {
    test('合法 host:port 通过', () {
      expect(InputSanitizer.isValidHostPort('127.0.0.1:5037'), isTrue);
      expect(InputSanitizer.isValidHostPort('localhost:5037'), isTrue);
    });

    test('注入被拒', () {
      expect(InputSanitizer.isValidHostPort('127.0.0.1:5037; reboot'), isFalse);
    });
  });

  // ─────────────────────────────────────────────────
  group('hasShellMetaChars', () {
    test('识别 shell 元字符', () {
      for (final c in [';', '|', '&', '`', r'$', '(', ')', '<', '>', '\n']) {
        expect(InputSanitizer.hasShellMetaChars('abc${c}def'), isTrue,
            reason: '字符: $c');
      }
    });

    test('普通文本没有元字符', () {
      expect(InputSanitizer.hasShellMetaChars('hello world'), isFalse);
      expect(InputSanitizer.hasShellMetaChars('/dev/block/sda'), isFalse);
    });
  });

  // ─────────────────────────────────────────────────
  group('explainDevicePath', () {
    test('合法路径返回 null（无错误）', () {
      expect(InputSanitizer.explainDevicePath('/dev/block/sda'), isNull);
    });

    test('注入路径返回错误说明', () {
      final reason =
          InputSanitizer.explainDevicePath('/dev/block/sda; rm -rf /');
      expect(reason, isNotNull);
      expect(reason, isNotEmpty);
    });

    test('相对路径的说明里提到 /dev', () {
      final reason = InputSanitizer.explainDevicePath('dev/block/sda');
      expect(reason, isNotNull);
      expect(reason!, contains('dev'));
    });
  });
}
