import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/services/logging/logger.dart';

/// 内置 TTS 模型的下载与就绪检查。
///
/// 为什么不打包进 APK：模型压缩后 30MB、解压后 31MB（其中 29MB 是 onnx 权重）。
/// 打进包会让每个用户都付这份代价，而绝大多数人可能根本不开朗读。所以做成
/// 「第一次用朗读时下载」，下完缓存在应用目录，卸载应用才清掉。
///
/// 模型选的是 sherpa-onnx 官方的 vits-icefall-zh-aishell3：
///   • 中文 VITS，纯离线，无网络依赖
///   • 压缩包 30MB，是中文模型里最小的可用档（其它普遍 60~160MB）
///   • 无需 espeak-ng 数据（v2.0 起 dataDir 已废弃），自带 lexicon
///   • 那个 172MB 的 rule.far 是可选的文本正则化规则，不下也能正常合成
///
/// 下载走多镜像：GitHub Releases 在国内直连经常 10 秒超时（实测），
/// 而 gh-proxy.org 实测 ~1MB/s、32 秒能下完。逐个尝试，谁先用谁。
class TtsModelManager {
  TtsModelManager({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const String _modelName = 'vits-icefall-zh-aishell3';

  /// GitHub 上的原始路径（不含域名）。
  static const String _releasePath =
      'k2-fsa/sherpa-onnx/releases/download/tts-models/$_modelName.tar.bz2';

  /// 镜像候选，按**实测速度**排序。
  ///
  /// 2026-11 实测（Range 请求拉 3MB）：
  ///   gh-proxy.org   206  0.96MB/s  → 31MB 约 32 秒
  ///   ghproxy.net    超时
  ///   gh-proxy.com   连接失败
  ///   ghfast.top     403（该站只放行 raw，不放行 release）
  ///   直连 github.com 10.6 秒超时
  /// 所以只保留实测可用的，外加自己人搭的备选在前。
  static const List<String> mirrors = [
    'https://gh-proxy.org/',
    'https://ghproxy.net/',
    'https://gh-proxy.com/',
    // 直连放最后：能通的环境直接走官方，不经过第三方。
    '',
  ];

  Directory? _root;

  /// 模型所在目录（解压后的）。未下载时返回预期路径，不保证存在。
  Future<Directory> modelDir() async {
    final root = await _appSupportDir();
    return Directory('${root.path}/tts/$_modelName');
  }

  Future<Directory> _appSupportDir() async {
    if (_root != null) return _root!;
    final dir = await getApplicationSupportDirectory();
    final ttsRoot = Directory('${dir.path}/tts');
    if (!await ttsRoot.exists()) {
      await ttsRoot.create(recursive: true);
    }
    _root = ttsRoot;
    return ttsRoot;
  }

  /// 判断模型是否已经下载完整。
  ///
  /// 用「关键文件都在且大小合理」作为判据，而不是只看目录存在 ——
  /// 下载中断会留下半个目录，那种情况下加载会崩在 native 层。
  Future<bool> isReady() async {
    final dir = await modelDir();
    if (!await dir.exists()) return false;
    final model = File('${dir.path}/model.onnx');
    final tokens = File('${dir.path}/tokens.txt');
    final lexicon = File('${dir.path}/lexicon.txt');
    if (!await model.exists() ||
        !await tokens.exists() ||
        !await lexicon.exists()) {
      return false;
    }
    // 29MB 的权重，小于 20MB 说明没下完。
    return await model.length() > 20 * 1024 * 1024;
  }

  /// 下载并解压。已就绪时直接返回。
  ///
  /// [onProgress] 传 0~1 的下载进度；[onMirror] 在切换镜像时回调，
  /// 用于给用户解释「为什么卡了一下」。
  Future<void> ensureReady({
    void Function(double progress)? onProgress,
    void Function(String mirror)? onMirror,
    CancelToken? cancelToken,
  }) async {
    if (await isReady()) {
      onProgress?.call(1);
      return;
    }
    final root = await _appSupportDir();
    final archive = File('${root.path}/$_modelName.tar.bz2');

    // 已经下过一半的包（上次中断）能续就续，不能续就重下。
    if (await archive.exists() && await archive.length() < 20 * 1024 * 1024) {
      await archive.delete();
    }

    if (!await archive.exists()) {
      await _downloadWithFallback(
        archive: archive,
        onProgress: onProgress,
        onMirror: onMirror,
        cancelToken: cancelToken,
      );
    }

    onProgress?.call(1);
    await _extract(archive, root);
    try {
      await archive.delete();
    } catch (_) {}

    if (!await isReady()) {
      throw Exception('模型下载后校验失败，请重试');
    }
    KazumiLogger().i('TTS model ready');
  }

  /// 依次尝试镜像，直到有一个下完。
  Future<void> _downloadWithFallback({
    required File archive,
    void Function(double progress)? onProgress,
    void Function(String mirror)? onMirror,
    CancelToken? cancelToken,
  }) async {
    final errors = <String>[];
    for (final prefix in mirrors) {
      final url = prefix.isEmpty
          ? 'https://github.com/$_releasePath'
          : '${prefix}https://github.com/$_releasePath';
      final label = prefix.isEmpty ? '直连' : prefix;
      onMirror?.call(label);
      try {
        await _dio.download(
          url,
          archive.path,
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) {
            if (total > 0) onProgress?.call(received / total);
          },
          options: Options(
            followRedirects: true,
            // 连接超时压到 12 秒：实测直连 GitHub 是 10.6 秒超时，
            // 给 30 秒会让用户干等半分钟才看到「换镜像」。
            connectTimeout: const Duration(seconds: 12),
            // 接收超时给足：31MB @ 1MB/s 要 32 秒，慢的时候可能 2 分钟。
            receiveTimeout: const Duration(minutes: 5),
          ),
        );
        // 大小校验：镜像返回 HTML 错误页时状态码也可能是 200。
        final size = await archive.length();
        if (size < 20 * 1024 * 1024) {
          throw Exception('文件不完整（${(size / 1048576).toStringAsFixed(1)}MB）');
        }
        return;
      } catch (e) {
        errors.add('$label: $e');
        KazumiLogger().w('TTS model download failed via $label: $e');
        // 换下一个镜像前清掉残缺文件，否则下一次会当成「已下载」。
        try {
          if (await archive.exists()) await archive.delete();
        } catch (_) {}
      }
    }
    throw Exception('所有镜像都失败：\n${errors.join("\n")}');
  }

  /// 解压 .tar.bz2。
  ///
  /// Flutter 没有内置的 bz2 解压，这里用系统 tar —— Android 5.0+ 与常见的
  /// 桌面系统都自带。失败时**不静默**：抛出去让 UI 提示。
  Future<void> _extract(File archive, Directory root) async {
    final target = await modelDir();
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    final result = await Process.run(
      'tar',
      ['-xjf', archive.path, '-C', root.path],
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw Exception('解压失败：${result.stderr}');
    }
  }

  /// 删掉已下载的模型（设置页提供「释放空间」）。
  Future<void> remove() async {
    final dir = await modelDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    final root = await _appSupportDir();
    final archive = File('${root.path}/$_modelName.tar.bz2');
    if (await archive.exists()) {
      await archive.delete();
    }
  }
}
