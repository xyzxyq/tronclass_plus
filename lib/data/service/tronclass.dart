import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:tronclass/data/model/tron_class/rollcalls_response/rollcalls_response.dart';
import 'package:tronclass/data/model/tron_org.dart';
import 'package:tronclass/data/org_store.dart';
import 'package:tronclass/data/service/login.dart';

class TronClassService {
  static Future<String> getLoginCode(
      Dio dio, String username, String password, CaptchaHandler captchaHandler) async {
    final url =
        "https://identity.guet.edu.cn/auth/realms/guet/protocol/openid-connect/auth";
    final params = {
      "scope": "openid",
      "response_type": "code",
      "redirect_uri": "https://mobile.guet.edu.cn/cas-callback?_h5=true",
      "client_id": "TronClassH5",
      "autologin": "true"
    };
    final resp = await dio.get(url, queryParameters: params);
    final redirectUrl = resp.requestOptions.uri;
    final redirectUrlString = redirectUrl.toString();

    Uri callbackUrl;
    if (redirectUrlString
        .contains("https://mobile.guet.edu.cn/cas-callback?_h5=true")) {
      callbackUrl = redirectUrl;
    } else {
      final serviceUrl = redirectUrl.queryParameters['service'];
      if (serviceUrl == null) {
        throw Exception(
            "ChangKeService.getLoginServiceUrl: 'service' param is null!");
      }

      final resp1 = await LoginService.loginCas(
          casDio: dio,
          username: username,
          password: password,
          service: serviceUrl,
          serviceHomeUrl: "https://mobile.guet.edu.cn/",
          successVerify: (resp) async {
            final uri = resp.requestOptions.uri;
            final code = uri.queryParameters['code'];
            final ok = code != null;
            return ok;
          },
          captchaHandler: captchaHandler);
      callbackUrl = resp1.requestOptions.uri;
    }

    final code = callbackUrl.queryParameters["code"]!;
    return code;
  }

  static Future<String> getAccessToken(Dio dio, {required String code}) async {
    final url =
        "https://identity.guet.edu.cn/auth/realms/guet/protocol/openid-connect/token";
    final params = {
      "client_id": "TronClassH5",
      "redirect_uri": "https://mobile.guet.edu.cn/cas-callback?_h5=true",
      "code": code,
      "grant_type": "authorization_code",
      "scope": "openid"
    };
    final resp = await dio.post(url,
        data: params,
        options: Options(contentType: "application/x-www-form-urlencoded"));
    final accessToken = resp.data['access_token'];
    if (accessToken == null) {
      throw Exception("ChangKeService.getAccessToken: 'access_token' is null!");
    }
    return accessToken;
  }

  /// 拿 Keycloak 的 access_token 换畅课自己的会话。
  ///
  /// 服务端会同时下发 `session` cookie 和 `x-session-id` 头；cookie 由
  /// CookieManager 收着，这里返回的 sessionId 只是给请求补一个头
  /// （见 [ChangkeAuthInterceptor]）。个别学校不回这个头，那就退回读 cookie。
  static Future<String> loginDesktopEndpoint(
    Dio dio, {
    required String accessToken,
    String? apiUrl,
    Object? orgId,
  }) async {
    final url = "${apiUrl ?? AppOrg.current.apiUrl}/api/login?login=access_token";
    final data = {
      "access_token": accessToken,
      "org_id": orgId ?? AppOrg.current.id,
    };
    final resp = await dio.post(url, data: data);
    if (resp.statusCode != 200) {
      throw Exception(
          "换会话失败：$url HTTP ${resp.statusCode} ${_briefly(resp.data)}");
    }
    final sessionId = resp.headers.value('x-session-id') ??
        _sessionCookieOf(resp.headers.map['set-cookie']);
    if (sessionId == null) {
      throw Exception(
          "换会话失败：响应里既没有 x-session-id 也没有 session cookie "
          "(HTTP ${resp.statusCode})");
    }
    return sessionId;
  }

  /// 把响应体截短，够放进错误提示就行。
  static String _briefly(Object? data) {
    final text = data?.toString() ?? '';
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  static String? _sessionCookieOf(List<String>? setCookies) {
    if (setCookies == null) return null;
    for (final raw in setCookies) {
      final first = raw.split(';').first.trim();
      final i = first.indexOf('=');
      if (i > 0 && first.substring(0, i) == 'session') {
        return first.substring(i + 1);
      }
    }
    return null;
  }

  /// 通用登录第 2 步：用 WebView 里拿到的 code 换 access_token。
  ///
  /// 这里用的是 Keycloak 的 public client（没有 client_secret，也没有
  /// PKCE），所以这一步在 App 侧直接发就行。
  static Future<String> exchangeCodeForToken(
    Dio dio, {
    required IdentityConfig identityConfig,
    required String code,
    required String redirectUri,
  }) async {
    final resp = await dio.post(
      identityConfig.tokenEndpoint,
      data: {
        "grant_type": "authorization_code",
        "scope": "openid",
        "redirect_uri": redirectUri,
        "client_id": identityConfig.resource,
        "code": code,
      },
      options: Options(contentType: "application/x-www-form-urlencoded"),
    );
    final accessToken = resp.data is Map ? resp.data['access_token'] : null;
    if (accessToken is! String || accessToken.isEmpty) {
      throw Exception(
          "换 access_token 失败：HTTP ${resp.statusCode} "
          "${_briefly(resp.data)}");
    }
    return accessToken;
  }

  /// 取当前登录用户的资料。通用登录拿不到学号，用它来补。
  static Future<Map<String, dynamic>> getProfile(Dio dio,
      {String? apiUrl}) async {
    final url = "${apiUrl ?? AppOrg.current.apiUrl}/api/profile";
    final resp = await dio.get<Map<String, dynamic>>(url,
        options: Options(responseType: ResponseType.json));
    final data = resp.data;
    if (data == null) {
      throw Exception("TronClassService.getProfile: empty body");
    }
    return data;
  }

  /// 账号密码直登（没有统一身份认证的学校走这条，公有云都是这样）。
  ///
  /// 账号按形态分成三种提交方式：学校声明 `unified` 的用 `user_name`，
  /// 长得像邮箱的用 `email`，其余当人员编号用 `user_no`。
  static Future<String> loginByUserInfo(
    Dio dio, {
    required TronOrg org,
    required String account,
    required String password,
    String? captchaCode,
  }) async {
    final loginType = loginTypeOf(org, account);
    final body = <String, dynamic>{
      'password': password,
      'org_id': org.id,
      switch (loginType) {
        'unified' => 'user_name',
        'email' => 'email',
        _ => 'user_no',
      }: account,
      if (captchaCode != null && captchaCode.isNotEmpty)
        'captcha_code': captchaCode,
    };

    final resp = await dio.post<Map<String, dynamic>>(
      '${org.apiUrl}/api/login?login=$loginType',
      data: body,
      options: Options(responseType: ResponseType.json),
    );
    if (resp.statusCode != 200) {
      throw Exception(_loginErrorOf(resp));
    }
    final sessionId = resp.headers.value('x-session-id') ??
        _sessionCookieOf(resp.headers.map['set-cookie']);
    if (sessionId == null) {
      throw Exception(
          "登录失败：响应里既没有 x-session-id 也没有 session cookie");
    }
    return sessionId;
  }

  /// 邮箱长这样就按邮箱提交。
  static final _emailPattern =
      RegExp(r'^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}$', caseSensitive: false);

  static String loginTypeOf(TronOrg org, String account) {
    if (org.accountType == 'unified') return 'unified';
    return _emailPattern.hasMatch(account) ? 'email' : 'user_no';
  }

  /// 把服务端的报错翻成人话，验证码错和账号密码错要分得开。
  static String _loginErrorOf(Response<Map<String, dynamic>> resp) {
    final data = resp.data;
    final errors = data?['errors'];
    if (errors is Map && errors['captcha_code'] != null) {
      return '验证码不对';
    }
    final message = data?['message'];
    if (message is String && message.isNotEmpty) return message;
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      return '账号或密码不对';
    }
    return '登录失败：HTTP ${resp.statusCode} ${_briefly(data)}';
  }

  /// 取一张验证码图片。它跟会话绑定，所以必须和登录用同一个 dio。
  static Future<Uint8List> fetchCaptcha(Dio dio, {required String apiUrl}) async {
    final resp = await dio.get<List<int>>(
      '$apiUrl/api/captcha-code',
      queryParameters: {'t': DateTime.now().millisecondsSinceEpoch},
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data;
    if (resp.statusCode != 200 || data == null || data.isEmpty) {
      throw Exception('验证码取不到：HTTP ${resp.statusCode}');
    }
    return Uint8List.fromList(data);
  }

  /// 拿 `/api/profile` 探一下会话还认不认。认就返回资料，不认返回 null。
  static Future<Map<String, dynamic>?> probeSession(Dio dio,
      {String? apiUrl}) async {
    final url = "${apiUrl ?? AppOrg.current.apiUrl}/api/profile";
    final resp = await dio.get<Map<String, dynamic>>(url,
        options: Options(responseType: ResponseType.json));
    if (resp.statusCode != 200) return null;
    final data = resp.data;
    return (data != null && data['id'] != null) ? data : null;
  }

  static Future<String> login(
    Dio casDio,
    Dio dio, {
    required String username,
    required String password,
    required CaptchaHandler captchaHandler,
  }) async {
    final code = await getLoginCode(casDio, username, password, captchaHandler);
    final token = await getAccessToken(dio, code: code);
    final sessionId = await loginDesktopEndpoint(dio, accessToken: token);
    return sessionId;
  }

  static Future<Response<Map<String, dynamic>>> signQr(Dio dio,
      {required String rollcallId,
      required String data,
      required String deviceId}) async {
    final url = AppOrg.url("/api/rollcall/$rollcallId/answer_qr_rollcall");
    final body = {
      "data": data,
      "deviceId": deviceId,
    };
    final resp = await dio.put<Map<String, dynamic>>(url,
        data: body, options: Options(responseType: ResponseType.json));
    return resp;
  }

  static Future<Response<Map<String, dynamic>>> signNumber(Dio dio,
      {required String rollcallId,
      required String numberCode,
      required String deviceId}) async {
    final url = AppOrg.url("/api/rollcall/$rollcallId/answer_number_rollcall");
    final body = {
      "numberCode": numberCode,
      "deviceId": deviceId,
    };
    final resp = await dio.put<Map<String, dynamic>>(url,
        data: body, options: Options(responseType: ResponseType.json));
    return resp;
  }

  static Future<RollcallsResponse> getRollcalls(Dio dio) async {
    final url = AppOrg.url("/api/radar/rollcalls?api_version=1.1.0");
    final resp =
        await dio.get(url, options: Options(responseType: ResponseType.json));
    return RollcallsResponse.fromJson(resp.data);
  }

  static Future<Response<Map<String, dynamic>>> signRadar(
    Dio dio, {
    required String rollcallId,
    required String deviceId,
    required double latitude,
    required double longitude,
    required double accuracy,
    // You can use the default values
    double altitude = 0,
    // You can use the default values
    double? altitudeAccuracy,
    // You can use the default values
    double? speed,
    // You can use the default values
    String? heading,
  }) async {
    final url = AppOrg.url("/api/rollcall/$rollcallId/answer?api_version=1.1.2");
    final body = {
      "deviceId": deviceId,
      "latitude": latitude,
      "longitude": longitude,
      "speed": speed,
      "accuracy": accuracy,
      "altitude": altitude,
      "altitudeAccuracy": altitudeAccuracy,
      "heading": heading
    };
    final resp = await dio.put<Map<String, dynamic>>(url,
        data: body, options: Options(responseType: ResponseType.json));
    return resp;
  }
}
