import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get.dart';

import 'package:tronclass/auth/login_session.dart';
import 'package:tronclass/auth/web_login_credential.dart';
import 'package:tronclass/auth/saved_account_storage.dart';
import 'package:tronclass/auth/webview_login_page.dart';
import 'package:tronclass/common/toast.dart';
import 'package:tronclass/data/changke_client.dart';
import 'package:tronclass/data/model/tron_org.dart';
import 'package:tronclass/data/org_store.dart';
import 'package:tronclass/data/user_agent.dart';
import 'package:tronclass/data/service/tronclass.dart';
import 'package:tronclass/routes.dart';

/// 通用登录（所有畅课学校都能用）。
///
/// 流程一共四步：
/// 1. 机构库搜到学校，拿到 `apiUrl` 和 Keycloak 配置（[TronOrg]）；
/// 2. WebView 打开学校的统一身份认证，等它跳回 callback 带 `code`；
/// 3. 用 code 换 access_token；
/// 4. `POST {apiUrl}/api/login?login=access_token` 换畅课自己的会话。
///
/// 桂电那条不用 WebView 的账号密码直登仍然保留，见
/// [TronClassService.login]。
class GenericLogin {
  GenericLogin._();

  /// 走完整个流程。成功返回 true，失败/取消返回 false 并已经弹过提示。
  ///
  /// [credential] 是用户在登录页填好的账号密码，只用来在认证页上浮那张
  /// 可复制的卡片，并在登录成功后一起存下来。
  static Future<bool> run(
    TronOrg org, {
    required WebLoginCredential credential,
  }) async {
    if (!org.supportsIdentityLogin) {
      toastFailure0('${org.orgName}没有开放统一身份认证，暂时登录不了');
      return false;
    }

    final result = await Get.toNamed(
      AppRoute.webviewLoginPage,
      arguments: WebViewLoginArgs(org: org, credential: credential),
    );

    if (result is WebViewLoginFailure) {
      await LoginSession.showFailure('认证页返回失败', result.message);
      return false;
    }
    if (result is! String || result.isEmpty) {
      // 用户自己返回了，不用打扰他
      return false;
    }

    try {
      // 学校先切过去，后面所有请求（包括 x-session-id 该带给谁）都按它算
      await AppOrg.setCurrent(org);

      // 换 token 用一次性的 Dio：这一步是身份认证服务器的事，
      // 既不需要学校侧的 cookie，也不该为它建一个用户实例。
      final tokenDio = Dio(
        BaseOptions(
          headers: AppUserAgent.apiHeaders(credential.username),
          validateStatus: (status) => status != null,
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final String accessToken;
      try {
        accessToken = await TronClassService.exchangeCodeForToken(
          tokenDio,
          identityConfig: org.identityConfig!,
          code: result,
          redirectUri: kTronCallbackUrl,
        );
      } finally {
        tokenDio.close();
      }

      // 账号名从 token 里取（Keycloak 的 preferred_username 就是学号），
      // 这样在换会话之前就知道该用哪个 CookieJar。
      final username = _usernameFromToken(accessToken) ?? _fallbackUser;
      final client = ChangkeClient.getInstance(username: username, org: org);

      final sessionId = await TronClassService.loginDesktopEndpoint(
        client.dio,
        accessToken: accessToken,
        apiUrl: org.apiUrl,
        orgId: org.id,
      );
      client.adoptSession(sessionId);

      return await LoginSession.finish(
        client: client,
        org: org,
        username: username,
        // 认证页登进来的账号未必是卡片里填的那个，对得上才连密码一起存
        password:
            credential.username == username ? credential.password : null,
        loginMethod: LoginMethod.webView,
      );
    } catch (e) {
      await LoginSession.showFailure('登录失败', LoginSession.describe(e));
      return false;
    }
  }

  /// token 里读不出学号时兜底用的实例名。
  static const _fallbackUser = 'unknown-user';

  /// 解 JWT 的 payload 取 `preferred_username`。解不出来就返回 null，
  /// 交给调用方退回别的办法。
  static String? _usernameFromToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final map = jsonDecode(payload);
      final name = map is Map ? map['preferred_username'] : null;
      return name is String && name.isNotEmpty ? name : null;
    } catch (_) {
      return null;
    }
  }
}
