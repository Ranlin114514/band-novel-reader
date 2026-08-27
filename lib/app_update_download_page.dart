import 'dart:async';

import 'package:flutter/material.dart';

import 'app_update_service.dart';

class AppUpdateDownloadPage extends StatefulWidget {
  const AppUpdateDownloadPage({
    required this.update,
    required this.openInstaller,
    super.key,
  });

  final AppUpdateInfo update;
  final Future<Map<String, dynamic>> Function(String path) openInstaller;

  @override
  State<AppUpdateDownloadPage> createState() => _AppUpdateDownloadPageState();
}

class _AppUpdateDownloadPageState extends State<AppUpdateDownloadPage> {
  AppUpdateCancellationToken _cancellationToken = AppUpdateCancellationToken();
  AppUpdateDownloadProgress? _progress;
  String _stage = '准备下载更新包…';
  String? _error;
  String? _downloadedPath;
  bool _isDownloading = false;
  bool _installerOpened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _downloadAndInstall());
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _downloadAndInstall() async {
    if (_isDownloading) return;
    if (_cancellationToken.isCancelled) {
      _cancellationToken = AppUpdateCancellationToken();
    }
    setState(() {
      _isDownloading = true;
      _progress = null;
      _error = null;
      _downloadedPath = null;
      _installerOpened = false;
      _stage = '正在下载 ${widget.update.name}…';
    });
    try {
      final apk = await AppUpdateService.downloadApk(
        update: widget.update,
        cancellationToken: _cancellationToken,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
            final fraction = progress.fraction;
            _stage = fraction == null
                ? '正在下载更新包…'
                : '正在下载更新包 ${(fraction * 100).toStringAsFixed(1)}%';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadedPath = apk.path;
        _stage = '更新包已完整下载并通过基础校验，正在打开系统安装界面…';
      });
      await _openInstaller();
    } on AppUpdateCancelledException {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _stage = '更新下载已取消。';
          _error = '未安装任何更新。你可以返回后稍后再试。';
        });
      }
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _stage = '更新下载或校验失败。';
          _error = error.message.toString();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _stage = '更新流程未完成。';
          _error = '无法下载或打开更新包：$error';
        });
      }
    }
  }

  Future<void> _openInstaller() async {
    final path = _downloadedPath;
    if (path == null || _isDownloading) return;
    try {
      final result = await widget.openInstaller(path);
      if (!mounted) return;
      final status = result['status'];
      setState(() {
        _installerOpened = status == 'installer_opened';
        _stage = status == 'permission_required'
            ? '请在系统页面允许本应用安装未知来源应用，返回后可再次点击“立即安装”。'
            : '已打开系统安装界面，请按系统提示完成更新。';
      });
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message.toString();
          _stage = '无法打开系统安装界面。';
        });
      }
    }
  }

  void _cancel() {
    if (_isDownloading) {
      _cancellationToken.cancel();
      setState(() => _stage = '正在取消更新下载…');
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final fraction = progress?.fraction;
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_isDownloading,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('下载应用更新'),
          automaticallyImplyLeading: !_isDownloading,
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      _error == null
                          ? Icons.system_update_alt_outlined
                          : Icons.error_outline,
                      size: 48,
                      color: _error == null
                          ? colorScheme.primary
                          : colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.update.name,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _stage,
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    if (_isDownloading) ...[
                      LinearProgressIndicator(value: fraction),
                      const SizedBox(height: 8),
                      Text(
                        progress == null
                            ? '正在连接下载服务…'
                            : fraction == null
                            ? '已下载 ${_formatBytes(progress.receivedBytes)}'
                            : '${_formatBytes(progress.receivedBytes)} / ${_formatBytes(progress.totalBytes!)}  ${(fraction * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Card(
                        color: colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (_isDownloading)
                      OutlinedButton.icon(
                        onPressed: _cancel,
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('取消下载'),
                      )
                    else if (_downloadedPath != null && !_installerOpened)
                      FilledButton.icon(
                        onPressed: _openInstaller,
                        icon: const Icon(Icons.install_mobile_outlined),
                        label: const Text('立即安装'),
                      )
                    else if (_error != null)
                      FilledButton.icon(
                        onPressed: _downloadAndInstall,
                        icon: const Icon(Icons.refresh_outlined),
                        label: const Text('重新下载'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.check_outlined),
                        label: const Text('完成'),
                      ),
                    if (!_isDownloading) ...[
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('返回书库'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
