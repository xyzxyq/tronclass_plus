import 'package:tronclass/data/get_storage.dart';
import 'package:tronclass/data/model/tron_org.dart';

/// 当前选中的学校。整个 App 的接口地址都从这里取。
///
/// 默认是桂电——本 App 原本就是给桂电写的，桂电还有一条不用 WebView 的
/// 账号密码直登快捷通道（见 `TronClassService.login`）。
class AppOrg {
  AppOrg._();

  /// 桂电。字段取自 `api-org.tronclass.com.cn/orgs?keywords=桂林电子`。
  static const guet = TronOrg(
    id: 1,
    orgName: '桂林电子科技大学',
    apiUrl: 'https://courses.guet.edu.cn',
    ntfUrl: 'https://courses.guet.edu.cn/ntf',
    identityConfig: IdentityConfig(
      authServerUrl: 'https://identity.guet.edu.cn/auth',
      realm: 'guet',
      resource: 'TronClassApp',
    ),
  );

  static TronOrg? _cached;

  static TronOrg get current {
    final cached = _cached;
    if (cached != null) return cached;
    final raw = getStorage.read<Map>(GetStorageKeys.currentOrg);
    final restored = raw == null
        ? null
        : TronOrg.fromJson(Map<String, dynamic>.from(raw));
    return _cached = restored ?? guet;
  }

  /// 当前学校是不是桂电——桂电才显示账号密码直登。
  static bool get isGuet => current.apiUrl == guet.apiUrl;

  static Future<void> setCurrent(TronOrg org) async {
    _cached = org;
    await getStorage.write(GetStorageKeys.currentOrg, org.toJson());
  }

  /// 接口地址拼接。`path` 以 `/` 开头，例如 `/api/profile`。
  static String url(String path) => '${current.apiUrl}$path';
}
