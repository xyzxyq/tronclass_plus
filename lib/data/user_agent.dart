import 'dart:math';

import 'package:tronclass/data/get_storage.dart';

/// 请求头统一在这里拼，避免用 dio 默认的 `Dart/x.y (dart:io)`
/// 被服务端当成非法客户端。
///
/// 设备标识按账号各存一套，首次用到时随机生成，之后固定：
/// 同一个账号始终是同一台设备（本来就该这样），不同账号之间看不出关联，
/// 也不会带上真实机型。
class AppUserAgent {
  AppUserAgent._();

  static final _random = Random();

  static final Map<String, DeviceProfile> _cache = {};

  /// 还不知道是谁时用的账号名（比如登录前的机构检索）。
  static const anonymousAccount = 'anonymous';

  static DeviceProfile deviceOf(String? account) {
    final key = (account == null || account.isEmpty)
        ? anonymousAccount
        : account;
    final cached = _cache[key];
    if (cached != null) return cached;

    final raw = getStorage.read<Map>(GetStorageKeys.deviceProfile(key));
    final restored = raw == null
        ? null
        : DeviceProfile.fromJson(Map<String, dynamic>.from(raw));
    if (restored != null) return _cache[key] = restored;

    final generated = DeviceProfile.random(_random);
    getStorage.write(GetStorageKeys.deviceProfile(key), generated.toJson());
    return _cache[key] = generated;
  }

  /// 接口（XHR）层用的 UA。
  static String api(String? account) {
    final device = deviceOf(account);
    return 'Mozilla/5.0 (Linux; Android ${device.androidVersion}; '
        '${device.model} Build/${device.buildId}; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/151.0.7922.199 Mobile Safari/537.36 TronClass/common';
  }

  /// 页面导航（WebView）层用的 UA，统一身份认证页面看到的是这个。
  static String webView(String? account) {
    final device = deviceOf(account);
    return 'Mozilla/5.0 (Linux; Android ${device.androidVersion}; '
        '${device.model} Build/${device.buildId}; ) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/92.0.4515.105 Mobile Safari/537.36TronClass/common;'
        'webank/h5face;webank/1.0;netType:NETWORK_4G;appVersion:1000022;'
        'packageName:$kWebViewRequestedWith';
  }

  /// 接口请求的固定头。网页容器是从 `http://localhost` 这个本地页面
  /// 发起请求的，所以 Referer / Origin 都是它。
  static Map<String, String> apiHeaders(String? account) => {
    'User-Agent': api(account),
    'Accept': 'application/json, text/plain, */*',
    'Referer': 'http://localhost/',
    'Origin': 'http://localhost',
  };

  /// CAS 页面用的头。CAS 那边的请求是 WebView 里的页面发出来的，
  /// UA 和 Accept-Language 跟着页面走。
  static Map<String, String> casHeaders(String? account) => {
    'User-Agent': webView(account),
    'Accept-Language': kAcceptLanguage,
  };
}

/// 页面里各类请求的 Accept，按浏览器实际发的值分开。
const kAcceptDocument =
    'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,'
    'image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9';
const kAcceptXhr = 'application/json, text/javascript, */*; q=0.01';
const kAcceptImage =
    'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8';

const kAcceptLanguage = 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7';

/// WebView 容器的包名标记，页面请求里带着这个头。
const kWebViewRequestedWith = 'com.wisdomgarden.trpc';

/// 畅课自己的 `/api/*` 额外带的 XHR 标记（身份认证、机构检索不带）。
const kXhrRequestedWith = 'XMLHttpRequest';

/// UA 里跟设备相关的那几段。
class DeviceProfile {
  const DeviceProfile({
    required this.androidVersion,
    required this.model,
    required this.buildId,
    required this.deviceId,
  });

  final String androidVersion;
  final String model;
  final String buildId;

  /// 签到接口要带的设备号。跟机型一起生成、一起固定，
  /// 同一个账号每次签到报的都是同一台设备。
  final String deviceId;

  /// 随机凑一台安卓机：型号是随机字母数字，build 号按安卓的命名格式拼，
  /// 都不取自本机。签到用的 deviceId 也从这里生成。
  factory DeviceProfile.random(Random random) {
    const digits = '0123456789';
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    String pick(String from, int count) =>
        List.generate(count, (_) => from[random.nextInt(from.length)]).join();

    // 形如 22021211RC：一串数字加两位字母，跟常见的安卓内部型号同格式。
    final model = '${pick(digits, 8)}${pick(letters, 2)}';

    // 形如 TKQ1.220807.001：四位代号 + 日期 + 序号。
    final year = 21 + random.nextInt(4);
    final month = 1 + random.nextInt(12);
    final day = 1 + random.nextInt(28);
    final buildId =
        '${pick(letters, 3)}${1 + random.nextInt(9)}.'
        '$year${month.toString().padLeft(2, '0')}'
        '${day.toString().padLeft(2, '0')}.'
        '${pick(digits, 3)}';

    // 形如 UUID v4，跟其它 App 报的设备号同一个格式。
    const hex = '0123456789abcdef';
    String block(int n) => pick(hex, n);
    final deviceId =
        '${block(8)}-${block(4)}-4${block(3)}-'
        '${'89ab'[random.nextInt(4)]}${block(3)}-${block(12)}';

    return DeviceProfile(
      androidVersion: '${11 + random.nextInt(5)}',
      model: model,
      buildId: buildId,
      deviceId: deviceId,
    );
  }

  static DeviceProfile? fromJson(Map<String, dynamic> json) {
    final androidVersion = json['androidVersion'] as String?;
    final model = json['model'] as String?;
    final buildId = json['buildId'] as String?;
    final deviceId = json['deviceId'] as String?;
    if (androidVersion == null || model == null || buildId == null) return null;
    if (deviceId == null || deviceId.isEmpty) {
      // 老数据里没有 deviceId，整套重新生成，省得半新半旧
      return null;
    }
    return DeviceProfile(
      androidVersion: androidVersion,
      model: model,
      buildId: buildId,
      deviceId: deviceId,
    );
  }

  Map<String, dynamic> toJson() => {
    'androidVersion': androidVersion,
    'model': model,
    'buildId': buildId,
    'deviceId': deviceId,
  };
}
