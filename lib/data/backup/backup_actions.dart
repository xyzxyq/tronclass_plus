import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:tronclass/common/toast.dart';
import 'package:tronclass/data/backup/backup_service.dart';
import 'package:tronclass/data/backup/storage_access.dart';

/// 备份的界面流程：问密码、选存哪、选文件、报结果。
class BackupActions {
  BackupActions._();

  /// 导出：输两遍密码 → 加密 → 让用户自己决定存到哪或者发给谁。
  static Future<void> export() async {
    final password = await _askPassword(
      title: '导出数据',
      message: '备份里有账号、密码和登录态，必须设一个密码才能导出。'
          '这个密码只用来加密文件，忘了就解不开了，我们也帮不了。',
      confirm: true,
    );
    if (password == null) return;

    final Uint8List bytes;
    try {
      bytes = await BackupService.exportBytes(password);
    } catch (e) {
      await _showMessage('导出失败', '$e');
      return;
    }

    final fileName = BackupService.suggestedFileName();
    final choice = await _askDestination();
    if (choice == null) return;

    try {
      if (choice == _Destination.save) {
        final saved = await StorageAccess.createDocument(
          name: fileName,
          bytes: bytes,
        );
        if (saved == null) return; // 用户自己取消了
        toastSuccess0('已保存为 $saved');
      } else {
        // 分享要有个实际文件，先落到缓存目录再交给系统
        final dir = await getTemporaryDirectory();
        final file = File(p.join(dir.path, fileName));
        await file.writeAsBytes(bytes);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'application/octet-stream')],
            subject: fileName,
          ),
        );
      }
    } catch (e) {
      await _showMessage('导出失败', '$e');
    }
  }

  /// 导入：选文件 → 输密码 → 全量覆盖。
  static Future<void> import() async {
    final PickedFile? picked;
    try {
      picked = await StorageAccess.openDocument();
    } catch (e) {
      await _showMessage('导入失败', '$e');
      return;
    }
    if (picked == null) return;
    final bytes = picked.bytes;

    final password = await _askPassword(
      title: '导入数据',
      message: '输入导出时设的密码。导入会覆盖当前所有账号和登录态。',
      confirm: false,
    );
    if (password == null) return;

    try {
      final summary = await BackupService.importBytes(bytes, password);
      final exportedAt = summary.exportedAt;
      await _showMessage(
        '导入完成',
        [
          if (exportedAt != null)
            '备份时间：${exportedAt.toLocal().toString().split('.').first}',
          '恢复了 ${summary.storageKeys} 项设置、${summary.cookieFiles} 个会话文件。',
          '请完全退出 App 再重新打开，新数据才会生效。',
        ].join('\n'),
      );
    } on BackupException catch (e) {
      await _showMessage('导入失败', e.message);
    } catch (e) {
      await _showMessage('导入失败', '$e');
    }
  }

  static Future<_Destination?> _askDestination() {
    return Get.dialog<_Destination>(
      SimpleDialog(
        title: const Text('备份放到哪'),
        children: [
          SimpleDialogOption(
            onPressed: () => Get.back(result: _Destination.save),
            child: const ListTile(
              leading: Icon(Icons.save_alt),
              title: Text('保存到设备'),
              subtitle: Text('自己选个文件夹'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Get.back(result: _Destination.share),
            child: const ListTile(
              leading: Icon(Icons.ios_share),
              title: Text('分享'),
              subtitle: Text('发给自己的网盘、聊天工具等'),
            ),
          ),
        ],
      ),
    );
  }

  static Future<String?> _askPassword({
    required String title,
    required String message,
    required bool confirm,
  }) {
    final passwordController = TextEditingController();
    final repeatController = TextEditingController();
    final visible = false.obs;
    final error = ''.obs;

    void submit() {
      final password = passwordController.text;
      if (password.isEmpty) {
        error.value = '密码不能为空';
        return;
      }
      if (confirm && password != repeatController.text) {
        error.value = '两次输入的密码不一样';
        return;
      }
      Get.back<String>(result: password);
    }

    return Get.dialog<String>(
      AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message, style: Get.textTheme.bodySmall),
              const SizedBox(height: 16),
              Obx(
                () => TextField(
                  controller: passwordController,
                  autofocus: true,
                  obscureText: !visible.value,
                  onSubmitted: (_) => confirm ? null : submit(),
                  decoration: InputDecoration(
                    labelText: '密码',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        visible.value ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => visible.value = !visible.value,
                    ),
                  ),
                ),
              ),
              if (confirm) ...[
                const SizedBox(height: 12),
                Obx(
                  () => TextField(
                    controller: repeatController,
                    obscureText: !visible.value,
                    onSubmitted: (_) => submit(),
                    decoration: const InputDecoration(
                      labelText: '再输一遍',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
              Obx(
                () => error.value.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error.value,
                          style: TextStyle(color: Get.theme.colorScheme.error),
                        ),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<String>(),
            child: const Text('取消'),
          ),
          FilledButton(onPressed: submit, child: const Text('确定')),
        ],
      ),
    );
  }

  static Future<void> _showMessage(String title, String message) {
    return Get.dialog<void>(
      AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          TextButton(onPressed: () => Get.back(), child: const Text('知道了')),
        ],
      ),
    );
  }
}

enum _Destination { save, share }
