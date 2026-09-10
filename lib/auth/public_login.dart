import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tronclass/auth/login_session.dart';
import 'package:tronclass/auth/saved_account_storage.dart';
import 'package:tronclass/auth/web_login_credential.dart';
import 'package:tronclass/data/changke_client.dart';
import 'package:tronclass/data/model/tron_org.dart';
import 'package:tronclass/data/org_store.dart';
import 'package:tronclass/data/service/tronclass.dart';

/// 账号密码直登：给没有统一身份认证的学校用，公有云上的学校都是这样。
///
/// 和网页登录不同，这里不开 WebView，账号密码直接提交给学校的接口；
/// 公有云一律要验证码，验证码图片跟会话绑定，所以取图和登录必须用同一个
/// 网络客户端。
class PublicLogin {
  PublicLogin._();

  static Future<bool> run(
    TronOrg org, {
    required WebLoginCredential credential,
  }) async {
    if (credential.username.isEmpty || credential.password.isEmpty) {
      await LoginSession.showFailure('登录失败', '账号和密码都要填');
      return false;
    }

    // 学校先切过去：验证码、登录都要发到这所学校，会话也记在它名下
    await AppOrg.setCurrent(org);
    final client = ChangkeClient.getInstance(
      username: credential.username,
      org: org,
    );

    String? captchaCode;
    if (org.requiresCaptcha) {
      captchaCode = await _askCaptcha(client, org);
      if (captchaCode == null) return false; // 用户取消
    }

    try {
      final sessionId = await TronClassService.loginByUserInfo(
        client.dio,
        org: org,
        account: credential.username,
        password: credential.password,
        captchaCode: captchaCode,
      );
      client.adoptSession(sessionId);

      return await LoginSession.finish(
        client: client,
        org: org,
        username: credential.username,
        password: credential.password,
        loginMethod: LoginMethod.password,
      );
    } catch (e) {
      await LoginSession.showFailure('登录失败', LoginSession.describe(e));
      return false;
    }
  }

  /// 验证码对话框：显示图片、可以点图换一张。
  static Future<String?> _askCaptcha(ChangkeClient client, TronOrg org) {
    final image = Rx<Uint8List?>(null);
    final error = ''.obs;
    final loading = false.obs;
    final controller = TextEditingController();

    Future<void> refresh() async {
      if (loading.value) return;
      loading.value = true;
      error.value = '';
      try {
        image.value = await TronClassService.fetchCaptcha(
          client.dio,
          apiUrl: org.apiUrl,
        );
      } catch (e) {
        error.value = '$e';
      } finally {
        loading.value = false;
      }
    }

    refresh();

    return Get.dialog<String>(
      AlertDialog(
        title: const Text('输入验证码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${org.orgName}登录需要验证码，点图片可以换一张。',
                style: Get.textTheme.bodySmall),
            const SizedBox(height: 12),
            Obx(() {
              final bytes = image.value;
              return InkWell(
                onTap: refresh,
                child: Container(
                  height: 60,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: Get.theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: loading.value
                      ? const CircularProgressIndicator(strokeWidth: 2)
                      : bytes == null
                          ? const Text('点这里加载验证码')
                          : Image.memory(bytes, fit: BoxFit.contain),
                ),
              );
            }),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 4,
              textInputAction: TextInputAction.done,
              onSubmitted: (value) => Get.back<String>(result: value.trim()),
              decoration: const InputDecoration(
                labelText: '验证码',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            Obx(
              () => error.value.isEmpty
                  ? const SizedBox.shrink()
                  : Text(
                      error.value,
                      style: TextStyle(color: Get.theme.colorScheme.error),
                    ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<String>(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Get.back<String>(result: controller.text.trim()),
            child: const Text('登录'),
          ),
        ],
      ),
    );
  }
}
