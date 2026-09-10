import 'package:dio/dio.dart';

import 'package:tronclass/data/model/tron_org.dart';

/// 学校检索：向畅课的机构检索服务按关键字查学校。
class OrgService {
  /// 机构库是一套 LeanCloud 应用，请求要带上它的应用凭证，缺了直接 400。
  static const _appHeaders = {
    'x-lc-id': 's0QbLDG5u6IrBSx9dC4yFiLr-gzGzoHsz',
    'x-lc-key': 'jEivEsoel0KxBdX4gDuO5Sak',
  };

  /// 机构库按区域分三个入口。
  static const _endpoints = {
    'cn': 'https://api-org.tronclass.com.cn/orgs',
    'tw': 'https://api-org.tronclass.com.tw/orgs',
    'hk': 'https://api-org.tronclass.com/orgs',
    'mo': 'https://api-org.tronclass.com/orgs',
  };

  /// 按关键字搜学校。关键字太短会返回一大堆结果，节流交给调用方。
  static Future<List<TronOrg>> search(
    Dio dio,
    String keywords, {
    String area = 'cn',
  }) async {
    final endpoint = _endpoints[area] ?? _endpoints['cn']!;
    final resp = await dio.get(
      endpoint,
      queryParameters: {'keywords': keywords},
      options: Options(
        // 机构库不认 App 的会话，别把 session 头带过去
        headers: {..._appHeaders, 'x-session-id': null},
        responseType: ResponseType.json,
      ),
    );

    final data = resp.data;
    final results = data is Map ? data['results'] : null;
    if (results is! List) return const [];
    return results
        .whereType<Map>()
        .map((e) => TronOrg.fromJson(Map<String, dynamic>.from(e)))
        .whereType<TronOrg>()
        .toList();
  }
}
