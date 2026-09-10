import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tronclass/auth/auth_controller.dart';
import 'package:tronclass/auth/saved_account_storage.dart';
import 'package:tronclass/common/toast.dart';
import 'package:tronclass/data/changke_client.dart';
import 'package:tronclass/data/get_storage.dart';
import 'package:tronclass/data/model/tron_org.dart';
import 'package:tronclass/data/service/tronclass.dart';

/// 登录拿到会话之后的收尾：认证页登进来的和账号密码登进来的，
/// 到这一步要做的事完全一样，就别各写一遍了。
class LoginSession {
  LoginSession._();

  /// 探一次资料确认会话真能用，然后把账号存下来、设为当前账号。
  static Future<bool> finish({
    required ChangkeClient client,
    required TronOrg org,
    required String username,
    String? password,
    required String loginMethod,
  }) async {
    String displayName = username;
    try {
      final profile = await TronClassService.getProfile(
        client.dio,
        apiUrl: org.apiUrl,
      );
      final name = profile['name'];
      if (name is String && name.isNotEmpty) displayName = name;
    } catch (_) {
      // 资料拿不到不影响登录，签到接口该能用还是能用
    }

    await SavedAccountStorage.upsertAccount(
      username: username,
      password: password,
      displayName: displayName == username ? null : displayName,
      org: org,
      loginMethod: loginMethod,
    );
    await getStorage.write(GetStorageKeys.lastLoginUsername, username);
    await getStorage.write(GetStorageKeys.isCleanWebSession, true);
    if (Get.isRegistered<AuthController>()) {
      Get.find<AuthController>().refreshState();
    }

    // 这里只能用 toast：Get.snackbar 会往路由栈里压一层，
    // 调用方紧接着的 Get.back 就会把它当成页面弹掉，页面反而留在原地。
    toastSuccess0('登录成功：$displayName · ${org.orgName}');
    return true;
  }

  /// 把异常翻成用户能看懂的话。网络层的错最常见，也最容易让人一头雾水。
  static String describe(Object error) {
    if (error is DioException) {
      final url = error.requestOptions.uri;
      final host = url.host;
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return '连接 $host 超时。换个网络再试试。';
        case DioExceptionType.badCertificate:
          return '$host 的证书有问题，连接不安全，已经停下来了。';
        case DioExceptionType.connectionError:
        case DioExceptionType.unknown:
          final inner = error.error;
          if (inner is SocketException || inner is HttpException) {
            return '连不上 $host。\n\n'
                '这个地址是学校在畅课机构库里登记的，有些学校的服务只能在'
                '校园网里访问；连着校园网或用学校 VPN 再试一次。\n\n'
                '原始错误：${inner is SocketException ? inner.message : inner}';
          }
          return '请求 $url 失败：${error.message ?? error}';
        default:
          return '请求 $url 失败：${error.message ?? error}';
      }
    }
    return '$error';
  }

  /// 失败原因用对话框显示：toast 一闪而过，看不清是哪一步挂的。
  static Future<void> showFailure(String title, String message) {
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
