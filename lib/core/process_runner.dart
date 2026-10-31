import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 命令执行结果
class ExecResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration duration;

  ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
  });

  bool get ok => exitCode == 0;

  /// 合并输出（很多 adb 命令把信息写 stderr）
  String get output {
    final out = stdout.trim();
    final err = stderr.trim();
    if (out.isEmpty) return err;
    if (err.isEmpty) return out;
    return '$out\n$err';
  }

  @override
  String toString() =>
      'ExecResult(code=$exitCode, out=${stdout.length}B, err=${stderr.length}B)';
}


/// 智能解码器
///
/// adb 在 Android 设备上输出的路径是 UTF-8，
/// 但 Windows 的 SystemEncoding 是 GBK/ANSI，直接解码会乱码。
/// 这里优先按 UTF-8 解码，失败则回退 SystemEncoding。
class SmartDecoder {
  SmartDecoder._();

  /// 解码字节
  static String decode(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return systemEncoding.decode(bytes);
    }
  }
}

/// 进程执行封装
///
/// 统一处理超时、编码、错误输出。
/// 所有外部命令（adb / fastboot）都走这里。
class ProcessRunner {
  ProcessRunner._();

  /// 执行命令并等待完成
  static Future<ExecResult> run(
    String executable,
    List<String> args, {
    Duration timeout = const Duration(seconds: 30),
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final sw = Stopwatch()..start();

    try {
      final result = await Process.run(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: environment,
        // 不用 SystemEncoding（Windows 是 GBK，会中文乱码）
        // 改为返回原始字节，手动按 UTF-8 解码
        stdoutEncoding: null,
        stderrEncoding: null,
      ).timeout(timeout);

      sw.stop();
      return ExecResult(
        exitCode: result.exitCode,
          stdout: SmartDecoder.decode(result.stdout),
          stderr: SmartDecoder.decode(result.stderr),
        duration: sw.elapsed,
      );
    } on TimeoutException {
      sw.stop();
      return ExecResult(
        exitCode: -1,
        stdout: '',
        stderr: '命令超时（${timeout.inSeconds} 秒）：$executable ${args.join(' ')}',
        duration: sw.elapsed,
      );
    } on ProcessException catch (e) {
      sw.stop();
      return ExecResult(
        exitCode: -2,
        stdout: '',
        stderr: '无法执行 $executable：${e.message}',
        duration: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return ExecResult(
        exitCode: -3,
        stdout: '',
        stderr: '未知错误：$e',
        duration: sw.elapsed,
      );
    }
  }

  /// 流式执行（用于长任务，如 adb install、fastboot flash）
  ///
  /// [onLine] 每收到一行调用一次
  /// 返回最终退出码
  static Future<int> stream(
    String executable,
    List<String> args, {
    required void Function(String line) onLine,
    Duration timeout = const Duration(seconds: 120),
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    try {
      final process = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
      );

      final completer = Completer<int>();

      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine);
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine);

      process.exitCode.then((code) {
        if (!completer.isCompleted) completer.complete(code);
      });

      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          onLine('[超时] 命令执行超过 ${timeout.inSeconds} 秒，已终止');
          return -1;
        },
      );
    } catch (e) {
      onLine('[错误] $e');
      return -2;
    }
  }
}
