/// 学校（机构）信息，来自畅课的机构检索接口
/// `https://api-org.tronclass.com.cn/orgs?keywords=`。
class TronOrg {
  const TronOrg({
    required this.id,
    required this.orgName,
    required this.apiUrl,
    this.ntfUrl,
    this.identityConfig,
    this.area = 'cn',
    this.isPublic = false,
    this.accountType,
    this.enableCaptchaCode = false,
  });

  /// 公有云机构的接口地址：这类学校的记录里不带 `apiUrl`，
  /// 按区域取固定地址。
  static const publicApiUrls = {
    'cn': 'https://tronclass.com.cn',
    'tw': 'https://tronclass.com.tw',
    'hk': 'https://tronclass.com.tw',
    'mo': 'https://tronclass.com.tw',
  };

  /// 机构 id。登录接口要带上它。
  ///
  /// 类型按接口返回的原样保留：独立部署的学校是数字（桂电是 1），
  /// 公有云上的是字符串（形如 "1000000006"）。转成统一类型会让服务端
  /// 认不出这个机构，登录直接被判成账号密码不匹配。
  final Object? id;
  final String orgName;

  /// 该校畅课的接口根地址，例如 `https://courses.guet.edu.cn`。
  final String apiUrl;

  /// 通知服务地址，本 App 暂时用不到，保留是为了跟接口返回对齐。
  final String? ntfUrl;

  /// Keycloak 配置。为 null 说明这所学校不走统一身份认证，
  /// 只能用账号密码直登（`/api/login?login=user_name`）。
  final IdentityConfig? identityConfig;

  /// 机构库分区：cn / tw / hk / mo。
  final String area;

  /// 学校自己没有独立部署，用的是畅课的公有云。
  /// 这类学校走账号密码登录，没有统一身份认证。
  final bool isPublic;

  /// 账号形态。`unified` 的学校用 `user_name` 提交，其余按邮箱/人员编号分。
  final String? accountType;

  /// 这所学校强制要验证码。公有云的一律要。
  final bool enableCaptchaCode;

  bool get supportsIdentityLogin => identityConfig != null;

  /// 没有统一身份认证，但能用账号密码直接登。
  bool get supportsPasswordLogin => identityConfig == null;

  /// 登录时要不要填验证码。
  bool get requiresCaptcha => isPublic || enableCaptchaCode;

  static TronOrg? fromJson(Map<String, dynamic> json) {
    final area = (json['area'] as String?) ?? 'cn';
    final isPublic = json['isPublic'] == true;

    var apiUrl = (json['apiUrl'] as String?)?.trim();
    if (apiUrl == null || apiUrl.isEmpty) {
      // 公有云上的学校记录里不带 apiUrl，按区域取固定地址；
      // 两者都没有的多半是还没开通，登录不了。
      apiUrl = isPublic ? publicApiUrls[area] ?? publicApiUrls['cn'] : null;
    }
    if (apiUrl == null || apiUrl.isEmpty) return null;
    return TronOrg(
      id: json['id'],
      orgName: (json['orgName'] as String?) ?? '未命名机构',
      apiUrl: apiUrl.endsWith('/')
          ? apiUrl.substring(0, apiUrl.length - 1)
          : apiUrl,
      ntfUrl: (json['ntfUrl'] as String?) ?? (isPublic ? '$apiUrl/ntf' : null),
      identityConfig: IdentityConfig.fromJson(
        json['identityConfig'] as Map<String, dynamic>?,
      ),
      area: area,
      isPublic: isPublic,
      accountType: json['accountType'] as String?,
      enableCaptchaCode: json['enableCaptchaCode'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'orgName': orgName,
    'apiUrl': apiUrl,
    'ntfUrl': ntfUrl,
    'identityConfig': identityConfig?.toJson(),
    'area': area,
    'isPublic': isPublic,
    'accountType': accountType,
    'enableCaptchaCode': enableCaptchaCode,
  };

  @override
  bool operator ==(Object other) =>
      other is TronOrg && other.apiUrl == apiUrl && '${other.id}' == '$id';

  @override
  int get hashCode => Object.hash('$id', apiUrl);
}

/// 畅课返回的 Keycloak 配置（接口字段名带连字符，这里原样解析）。
class IdentityConfig {
  const IdentityConfig({
    required this.authServerUrl,
    required this.realm,
    required this.resource,
  });

  /// 形如 `https://identity.guet.edu.cn/auth`。
  final String authServerUrl;

  /// 形如 `guet`。
  final String realm;

  /// OIDC client_id，App 端是 `TronClassApp`。
  final String resource;

  static IdentityConfig? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final authServerUrl = (json['auth-server-url'] as String?)?.trim();
    final realm = (json['realm'] as String?)?.trim();
    final resource = (json['resource'] as String?)?.trim();
    if (authServerUrl == null || authServerUrl.isEmpty) return null;
    if (realm == null || realm.isEmpty) return null;
    if (resource == null || resource.isEmpty) return null;
    return IdentityConfig(
      authServerUrl: authServerUrl.endsWith('/')
          ? authServerUrl.substring(0, authServerUrl.length - 1)
          : authServerUrl,
      realm: realm,
      resource: resource,
    );
  }

  Map<String, dynamic> toJson() => {
    'auth-server-url': authServerUrl,
    'realm': realm,
    'resource': resource,
  };

  String get authorizationEndpoint =>
      '$authServerUrl/realms/$realm/protocol/openid-connect/auth';

  String get tokenEndpoint =>
      '$authServerUrl/realms/$realm/protocol/openid-connect/token';
}
