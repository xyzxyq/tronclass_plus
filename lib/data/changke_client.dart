import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:dio_redirect_interceptor/dio_redirect_interceptor.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:tronclass/data/get_storage.dart';
import 'package:tronclass/data/model/tron_org.dart';
import 'package:tronclass/data/org_store.dart';
import 'package:tronclass/data/service/login.dart';
import 'package:tronclass/data/service/tronclass.dart';
import 'package:tronclass/data/user_agent.dart';
import 'package:tronclass/http/proxy/setup_http_proxy.dart';
import 'package:tronclass/path.dart';

typedef CaptchaRequester = Future<String> Function(Uint8List image);

class ChangkeClient {
  ChangkeClient._();

  // 实例按「学校 + 账号」管理：同一个学号在不同学校是两套会话，
  // 混用的话会把 A 校的 x-session-id 发给 B 校，直接 401。
  static final Map<String, ChangkeClient> _instances = {};
  static String? _currentUsername;

  late final Dio _dio;
  late final Dio _casDio; // CAS 认证专用 Dio
  late final CookieJar _cookieJar;
  late final String _username;
  late final String _apiHost; // 接口域名
  late final String _orgKey; // 这套会话属于哪个学校（域名 + 机构 id）
  late final String _sessionKey; // Session ID 的存储键
  String? _sessionId;

  Dio get dio => _dio;
  Dio get casDio => _casDio;

  CookieJar get cookieJar => _cookieJar;

  String get username => _username;

  /// 接口域名，用来判断该不该带会话头。
  String get orgHost => _apiHost;

  /// 这套会话属于哪所学校（域名 + 机构 id）。
  String get orgKey => _orgKey;

  String? get sessionId => _sessionId;

  /// 这个账号固定的设备号，签到接口要带。
  String get deviceId => AppUserAgent.deviceOf(_username).deviceId;

  bool get isLoggedIn => _sessionId != null;

  /// 按「学校 + 账号」隔离的 CookieJar，学校这一层用 [_orgKeyOf] 的口径。
  ///
  /// 存过的位置换过两回（先是只按账号，后来加了域名），这里依次往回找，
  /// 找到就挪到新位置，老用户不用重新登录。
  static CookieJar _getCookieJar(
    String orgKey,
    String apiHost,
    String username,
  ) {
    if (kIsWeb) {
      return CookieJar();
    }
    final root = join(applicationSupportDirectory.path, 'cookies');
    final path = join(root, orgKey, username);
    if (!Directory(path).existsSync()) {
      final candidates = <String>[
        if (orgKey != apiHost) join(root, apiHost, username),
        if (_isLegacyOwner(apiHost, username)) join(root, username),
      ];
      for (final old in candidates) {
        final legacy = Directory(old);
        if (!legacy.existsSync()) continue;
        try {
          Directory(join(root, orgKey)).createSync(recursive: true);
          legacy.renameSync(path);
        } catch (_) {
          // 挪不动就算了，大不了重登一次
        }
        break;
      }
    }
    return PersistCookieJar(storage: FileStorage(path));
  }

  static String _hostOf(String apiUrl) => Uri.parse(apiUrl).host;

  /// 会话归属的标识。
  ///
  /// 光看域名不够：公有云上的学校全挂在同一个域名下，只按域名分的话，
  /// 两所学校的会话会互相顶掉。带上机构 id 才是一所学校一套。
  static String _orgKeyOf(TronOrg org) {
    final host = _hostOf(org.apiUrl);
    final id = '${org.id ?? ''}';
    return id.isEmpty ? host : '$host#$id';
  }

  static String _sessionKeyOf(String orgKey, String username) =>
      'changke_session_id_${orgKey}_$username';

  /// 老数据的会话键和 cookie 目录里没有学校，只有账号。判断这份老数据
  /// 是不是就属于当前这个学校：账号表里记着它是在哪登的，以那个为准；
  /// 表里查不到就当成桂电的（那时候只有桂电）。
  static bool _isLegacyOwner(String orgHost, String username) {
    final raw = getStorage.read<List<dynamic>>(GetStorageKeys.savedAccounts);
    for (final item in raw ?? const []) {
      if (item is! Map) continue;
      if (item['username'] != username) continue;
      final org = item['org'];
      final apiUrl = org is Map ? org['apiUrl'] : null;
      if (apiUrl is String && apiUrl.isNotEmpty) {
        return _hostOf(apiUrl) == orgHost;
      }
      break;
    }
    return orgHost == _hostOf(AppOrg.guet.apiUrl);
  }

  /// 这个「学校 + 账号」还留着会话没有。只读存储，不去建实例，
  /// 列表里逐条问一遍也不会有副作用。
  static bool hasStoredSession({
    required String username,
    required TronOrg org,
  }) => _readSession(_orgKeyOf(org), _hostOf(org.apiUrl), username) != null;

  /// 读会话，顺带兼容前两版的存储键。
  static String? _readSession(
    String orgKey,
    String apiHost,
    String username,
  ) {
    for (final key in <String>[
      _sessionKeyOf(orgKey, username),
      if (orgKey != apiHost) _sessionKeyOf(apiHost, username),
      if (_isLegacyOwner(apiHost, username)) 'changke_session_id_$username',
    ]) {
      final value = getStorage.read<String>(key);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// 获取实例。[org] 不传就用当前选中的学校。
  static ChangkeClient getInstance({String? username, TronOrg? org}) {
    username ??= _currentUsername ?? 'default';
    _currentUsername = username;
    final currentOrg = org ?? AppOrg.current;
    final apiHost = _hostOf(currentOrg.apiUrl);
    final orgKey = _orgKeyOf(currentOrg);
    final key = '$orgKey|$username';

    if (_instances[key] == null) {
      final instance = ChangkeClient._();
      instance._username = username;
      instance._apiHost = apiHost;
      instance._orgKey = orgKey;
      instance._sessionKey = _sessionKeyOf(orgKey, username);
      instance._cookieJar = _getCookieJar(orgKey, apiHost, username);

      // 创建主 Dio 实例（用于 tronclass API）
      instance._dio =
          Dio(
              BaseOptions(
                headers: AppUserAgent.apiHeaders(username),
                followRedirects: false,
                validateStatus: (status) => status != null,
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 30),
              ),
            )
            ..interceptors.addAll([
              CookieManager(instance._cookieJar),
              ChangkeAuthInterceptor(
                () => instance._sessionId,
                () => instance._apiHost,
              ),
              RedirectInterceptor(() => instance.dio),
            ]);

      // 创建 CAS Dio 实例（用于 CAS 认证）
      instance._casDio = Dio(
        BaseOptions(
          baseUrl: 'https://cas.guet.edu.cn/',
          headers: AppUserAgent.casHeaders(username),
          followRedirects: false,
          validateStatus: (status) => status != null,
          connectTimeout: const Duration(minutes: 1),
          receiveTimeout: const Duration(minutes: 5),
          sendTimeout: const Duration(minutes: 5),
        ),
      )..interceptors.addAll([
          CookieManager(instance._cookieJar),
          CasHeaderInterceptor(),
          RefererInterceptor(),
          RedirectInterceptor(() => instance.casDio),
        ]);

      // setupHttpProxy(
      //   instance.casDio,
      //   proxyUrl: "http://172.16.0.163:9000",
      //   allowBadCertificate: true,
      // );

      // 从 GetStorage 同步读取 session，读到的要是老键上的就顺手迁过来
      final session = _readSession(orgKey, apiHost, username);
      instance._sessionId = session;
      if (session != null &&
          getStorage.read<String>(instance._sessionKey) != session) {
        getStorage.write(instance._sessionKey, session);
      }
      _instances[key] = instance;
    }
    return _instances[key]!;
  }

  /// 便捷访问当前用户实例
  static ChangkeClient get instance => getInstance();

  /// 登录：获取并保存新的 session
  Future<void> login({
    required String username,
    required String password,
    required CaptchaRequester captchaRequester,
  }) async {
    // 登录前清理过期的 CAS 会话 cookie，避免残留会话导致误报“密码错误”
    await removeCasSessionCookies(_cookieJar);
    final session = await TronClassService.login(
      _casDio, // CAS 认证
      _dio, // 普通请求
      username: username,
      password: password,
      captchaHandler: (image) => captchaRequester(image),
    );
    _setSessionId(session);
  }

  /// 通用（WebView）登录成功后落地会话。
  ///
  /// cookie 已经在换 session 那一步由 CookieManager 收进 [_cookieJar] 了，
  /// 这里只补上 `x-session-id` 用的那个值。
  void adoptSession(String sessionId) {
    _setSessionId(sessionId);
  }

  /// 登出：清除 session
  void logout() {
    _setSessionId(null);
  }

  /// 设置 session ID（统一的读写入口）
  void _setSessionId(String? value) {
    _sessionId = value;
    if (value != null) {
      getStorage.write(_sessionKey, value);
    } else {
      getStorage.remove(_sessionKey);
    }
  }
}

/// CAS 的请求分三类：页面导航、页面里的 XHR、图片（验证码）。
/// 浏览器给这三类发的头不一样，这里照着补齐，别让请求看起来像脚本发的。
class CasHeaderInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final headers = options.headers;

    if (options.responseType == ResponseType.bytes) {
      // 验证码图片
      headers['Accept'] = kAcceptImage;
      headers['X-Requested-With'] = kWebViewRequestedWith;
      headers['Sec-Fetch-Mode'] = 'no-cors';
      headers['Sec-Fetch-Dest'] = 'image';
      headers['Sec-Fetch-Site'] = 'same-origin';
    } else if (_isNavigation(options.uri.path)) {
      // 登录页本身：跳转过去的，是一次文档导航
      headers['Accept'] = kAcceptDocument;
      headers['X-Requested-With'] = kWebViewRequestedWith;
      headers['Upgrade-Insecure-Requests'] = '1';
      headers['Sec-Fetch-Mode'] = 'navigate';
      headers['Sec-Fetch-Dest'] = 'document';
      headers['Sec-Fetch-User'] = '?1';
      headers['Sec-Fetch-Site'] = 'same-origin';
    } else {
      // 登录页里的接口调用（指纹上报、验证码判断、动态码……）
      headers['Accept'] = kAcceptXhr;
      headers['X-Requested-With'] = kXhrRequestedWith;
      headers['Sec-Fetch-Mode'] = 'cors';
      headers['Sec-Fetch-Dest'] = 'empty';
      headers['Sec-Fetch-Site'] = 'same-origin';
    }

    handler.next(options);
  }

  /// 只有登录页是整页跳转，其余路径都是页面里发的请求。
  static bool _isNavigation(String path) =>
      path.endsWith('/authserver/login') || path.endsWith('/authserver/login/');
}

/// 给每个请求带上 `Referer = 当前请求 URI`。
/// 金智 CAS 的部分风控分支会校验 Referer，缺了它更容易被判异常。
class RefererInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers['Referer'] = options.uri.toString();
    handler.next(options);
  }
}

class ChangkeAuthInterceptor extends Interceptor {
  final String? Function() getSessionId;
  final String Function() getOrgHost;

  ChangkeAuthInterceptor(this.getSessionId, this.getOrgHost);

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // 只给这套会话所属学校的畅课接口带会话头和 XHR 标记：
    // 发给别的学校是无效会话，发给机构检索、身份认证更是白给。
    if (options.uri.host != getOrgHost()) {
      handler.next(options);
      return;
    }

    options.headers['X-Requested-With'] = kXhrRequestedWith;
    final sessionId = getSessionId();
    if (sessionId != null) {
      options.headers['x-session-id'] = sessionId;
    }
    handler.next(options);
  }
}
