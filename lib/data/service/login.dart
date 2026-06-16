import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:tronclass/data/get_storage.dart';

// 简化版 LoginService，仅包含 tronclass 需要的功能

/// 默认需要在登录前清理的 CAS 会话 cookie 名称。
/// JSESSIONID 为 webflow 会话，route 为负载均衡节点亲和。
const Set<String> kCasSessionCookieNames = {'JSESSIONID', 'route'};

/// 登录前清理过期的 CAS 会话 cookie。
///
/// 残留的 JSESSIONID/route 会污染会话状态，导致服务端误报“密码错误”。
/// 这里模拟浏览器语义：删除该 host 下的会话 cookie，保留其余 cookie。
Future<void> removeCasSessionCookies(
  CookieJar jar, {
  Uri? casLoginUri,
  Set<String> names = kCasSessionCookieNames,
}) async {
  final uri = casLoginUri ?? Uri.parse('https://cas.guet.edu.cn/authserver/login');
  final existing = await jar.loadForRequest(uri);
  if (existing.isEmpty) return; // 空 jar（如冷启动/全新安装）无事可做
  // cookie_jar 没有「按名删」的 API：读出 → 滤掉目标名 → 按 host 整删 → 其余原样存回
  final keep = existing.where((c) => !names.contains(c.name)).toList();
  await jar.delete(uri); // 按 host 整删
  if (keep.isNotEmpty) await jar.saveFromResponse(uri, keep); // 保留 CASTGC 等
}

/// 读出当前 CAS 域上的 `route`（落到哪个后端节点），没有则返回空串——用于排查/日志。
Future<String> currentRoute(CookieJar jar, {Uri? casLoginUri}) async {
  final uri = casLoginUri ?? Uri.parse('https://cas.guet.edu.cn/authserver/login');
  final cookies = await jar.loadForRequest(uri);
  for (final c in cookies) {
    if (c.name == 'route') return c.value;
  }
  return '';
}

Map<String, String?> _parseLoginHtml(String html) {
  final doc = html_parser.parse(html);
  final aesKey = doc.getElementById("pwdEncryptSalt")?.attributes["value"];
  final execution = doc.getElementById("execution")?.attributes["value"];
  return {"aesKey": aesKey, "execution": execution};
}

// AES 加密实现 - 按照 Rust 中的逻辑
String encryptPassword(String password, List<int> key) {
  try {
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      throw ArgumentError("Key must be 16, 24, or 32 bytes long");
    }

    // 生成 IV：必须使用 16 个 ASCII 字母数字字符的字节，而不是任意随机字节。
    // 服务端（Wisedu CAS / CryptoJS）会对解密后的第一个分组做 UTF-8 解码，
    // 若 IV 为任意随机字节，约 62% 的情况首分组不是合法 UTF-8 会导致登录失败。
    final random = Random.secure();
    const String chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final ivStr = List.generate(16, (_) => chars[random.nextInt(chars.length)]).join();
    final iv = Uint8List.fromList(ivStr.codeUnits);

    // 生成 64 字节的随机字符串（字母数字字符）
    final randomStr = List.generate(64, (_) => chars[random.nextInt(chars.length)]).join();

    // 拼接随机字符串和密码
    final plaintext = randomStr + password;

    // 使用 AES-128-CBC 加密
    final keyBytes = Uint8List.fromList(key);
    final encryptKey = encrypt.Key(keyBytes);
    final ivKey = encrypt.IV(iv);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encryptKey, mode: encrypt.AESMode.cbc, padding: 'PKCS7')
    );
    final encrypted = encrypter.encrypt(plaintext, iv: ivKey);

    // 返回 Base64 编码的加密结果
    return encrypted.base64;
  } catch (e) {
    // 如果加密失败，打印错误并重新抛出
    print("加密失败: $e");
    rethrow;
  }
}

class LoginService {
  static Future<Response> loginCas({
    required Dio casDio,
    required String username,
    required String password,
    required String service,
    required String serviceHomeUrl,
    required CaptchaHandler captchaHandler,
    required FutureOr<bool> Function(Response response) successVerify,
    String? firstGetUrl,
    Map<String, dynamic>? firstGetQueryParameters,
  }) async {
    // 获取登录页面
    var uri = firstGetUrl ?? "authserver/login";

    var resp = await casDio.get(
      uri,
      queryParameters: firstGetQueryParameters ?? {'service': service},
    );

    var reqUri = resp.requestOptions.uri;
    checkVerification(reqUri);
    if (await successVerify(resp)) {
      return resp;
    }
    check401(resp);

    // 解析登录页面，获取 aesKey 和 execution
    final parseLoginHtmlResult = _parseLoginHtml(resp.data);
    final aesKey = parseLoginHtmlResult["aesKey"];
    final execution = parseLoginHtmlResult["execution"];

    if (aesKey == null || execution == null) {
      throw LogonFailedException(
        'http request to ${resp.requestOptions.uri} failed: aesKey is null'
      );
    }

    // 上报浏览器指纹（部分风控分支会校验，缺了更易被判异常；bfp 按帐号持久化）
    await reportFingerprint(casDio, username);

    // 获取验证码
    final captcha = await getCaptcha(casDio, username, captchaHandler);

    // 登录
    final uri1 = "authserver/login";
    final resp1 = await casDio.post(
      uri1,
      options: Options(
        contentType: "application/x-www-form-urlencoded",
        responseType: ResponseType.plain,
      ),
      queryParameters: {'service': service},
      data: {
        "username": username,
        "password": encryptPassword(password, utf8.encode(aesKey)),
        "rememberMe": true,
        "captcha": captcha,
        "_eventId": "submit",
        "cllt": "userNameLogin",
        "dllt": "generalLogin",
        "lt": "",
        "execution": execution
      },
    );

    reqUri = resp1.requestOptions.uri;
    checkVerification(reqUri);
    final success = await successVerify(resp1);
    if (success) {
      return resp1;
    }
    check401(resp1);
    throw LogonFailedException('Login failed');
  }

  static final Random _rng = Random.secure();

  /// 获取按帐号持久化的浏览器指纹（bfp）。
  /// 真实浏览器的指纹是稳定的，首次生成后存入 getStorage，后续登录复用同一值。
  static String getOrCreateBfp(String username) {
    final key = GetStorageKeys.casBfp(username);
    var bfp = getStorage.read<String>(key);
    if (bfp == null || bfp.isEmpty) {
      bfp = List.generate(
              16, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      getStorage.write(key, bfp);
    }
    return bfp;
  }

  /// 上报浏览器指纹：GET /authserver/bfp/info?bfp=[16字节hex]&_=[时间戳]
  /// bfp 按帐号持久化（见 [getOrCreateBfp]）。
  static Future<void> reportFingerprint(Dio dio, String username) async {
    final bfp = getOrCreateBfp(username);
    await dio.get(
      "authserver/bfp/info",
      queryParameters: {
        "bfp": bfp,
        "_": DateTime.timestamp().millisecondsSinceEpoch,
      },
      options: Options(responseType: ResponseType.plain),
    );
  }

  static Future<String> getCaptcha(
    Dio dio,
    String username,
    CaptchaHandler captchaHandler,
  ) async {
    final checkNeedCaptchaResp = await dio.get(
      "authserver/checkNeedCaptcha.htl",
      queryParameters: {
        "username": username,
        "_": DateTime.timestamp().millisecondsSinceEpoch
      },
      options: Options(responseType: ResponseType.plain),
    );
    final checkNeedCaptcha = jsonDecode(checkNeedCaptchaResp.data);

    if (checkNeedCaptcha['isNeed'] == true) {
      final image = await dio.get(
        "authserver/getCaptcha.htl?${DateTime.timestamp().millisecondsSinceEpoch}",
        options: Options(responseType: ResponseType.bytes),
      );
      final captcha = await captchaHandler(image.data);
      return captcha;
    }
    return "";
  }

  static void check401(Response<dynamic> resp1) {
    if (resp1.statusCode == 401) {
      final html = resp1.data;
      final doc = html_parser.parse(html);
      final errorTip = doc.querySelector("#showErrorTip")?.text;
      throw LogonFailedException(
        "状态码：${resp1.statusCode} ${errorTip ?? 'Login failed'}"
      );
    }
  }

  static void checkVerification(Uri reqUri) {
    if (reqUri.toString().contains('/authserver/reAuthCheck/reAuthLoginView.do')) {
      throw RequireLoginVerificationCodeException('Verification code required');
    }
  }

  static Future<DynamicCodeResponse> sendDynamicCode({
    required Dio dio,
    required String username,
  }) async {
    final resp = await dio.post(
      "authserver/dynamicCode/getDynamicCodeByReauth.do",
      data: {
        "userName": username,
        "authCodeTypeName": "reAuthDynamicCodeType",
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.plain,
      ),
    );

    final dynamic raw = resp.data;
    final Map<String, dynamic> data = raw is Map
        ? Map<String, dynamic>.from(raw as Map)
        : Map<String, dynamic>.from(jsonDecode(raw.toString()));
    return DynamicCodeResponse.fromJson(data);
  }

  static Future<ReAuthResponse> reAuthCheck({
    required Dio dio,
    required String code,
  }) async {
    final resp = await dio.post(
      "authserver/reAuthCheck/reAuthSubmit.do",
      data: {
        "service": "",
        "reAuthType": 3,
        "isMultifactor": true,
        "password": "",
        "dynamicCode": code,
        "uuid": "",
        "answer1": "",
        "answer2": "",
        "otpCode": "",
        "skipTmpReAuth": true,
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.json,
      ),
    );

    final dynamic raw = resp.data;
    final Map<String, dynamic> data = raw is Map
        ? Map<String, dynamic>.from(raw as Map)
        : Map<String, dynamic>.from(jsonDecode(raw.toString()));
    return ReAuthResponse.fromJson(data);
  }
}

typedef CaptchaHandler = Future<String> Function(Uint8List image);

class LogonFailedException implements Exception {
  final String msg;

  LogonFailedException(this.msg);

  @override
  String toString() => msg;
}

class RequireLoginVerificationCodeException implements Exception {
  final String msg;

  RequireLoginVerificationCodeException(this.msg);

  @override
  String toString() => msg;
}

class DynamicCodeResponse {
  final String? res;
  final String? mobile;
  final String? returnMessage;
  final int? codeTime;

  DynamicCodeResponse({
    this.res,
    this.mobile,
    this.returnMessage,
    this.codeTime,
  });

  factory DynamicCodeResponse.fromJson(Map<String, dynamic> json) {
    return DynamicCodeResponse(
      res: json['res'] as String?,
      mobile: json['mobile'] as String?,
      returnMessage: json['returnMessage'] as String?,
      codeTime: json['codeTime'] is int
          ? json['codeTime'] as int
          : int.tryParse(json['codeTime']?.toString() ?? ''),
    );
  }
}

class ReAuthResponse {
  final String? code;
  final String? msg;

  ReAuthResponse({this.code, this.msg});

  factory ReAuthResponse.fromJson(Map<String, dynamic> json) {
    return ReAuthResponse(
      code: json['code'] as String?,
      msg: json['msg'] as String?,
    );
  }
}
