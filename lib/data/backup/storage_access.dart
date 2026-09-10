import 'package:flutter/services.dart';

/// 走系统文件选择器读写文件（Android 侧实现见 `MainActivity.kt`）。
///
/// 用户自己挑文件、自己挑存到哪，App 不需要任何存储权限。
class StorageAccess {
  StorageAccess._();

  static const _channel = MethodChannel('tronclass/storage_access');

  /// 让用户选一个文件读进来。用户取消返回 null。
  static Future<PickedFile?> openDocument() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'openDocument',
    );
    if (result == null) return null;
    final bytes = result['bytes'];
    if (bytes is! Uint8List) return null;
    return PickedFile(name: '${result['name']}', bytes: bytes);
  }

  /// 让用户选个位置把内容存下去，返回存成的文件名。用户取消返回 null。
  static Future<String?> createDocument({
    required String name,
    required Uint8List bytes,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'createDocument',
      {'name': name, 'bytes': bytes},
    );
    if (result == null) return null;
    return '${result['name']}';
  }
}

class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}
