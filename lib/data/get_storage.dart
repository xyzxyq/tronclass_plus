import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:path_provider/path_provider.dart';

late GetStorage getStorage;

late GetStorage networkCacheStorage;

Future<void> initGetStorage() async {
  if (!GetPlatform.isWeb) {
    final path = await getApplicationSupportDirectory();
    getStorage = GetStorage('GetStorage', path.path);
    networkCacheStorage = GetStorage('NetworkCache', path.path);
  } else {
    getStorage = GetStorage('GetStorage');
    networkCacheStorage = GetStorage('NetworkCache');
  }
  await getStorage.initStorage;
  await networkCacheStorage.initStorage;
}

class GetStorageKeys {
  static const teachingEvaluationToken = "teachingEvaluationToken";
  static const isMobileMode = "isMobileMode";
  static const isCleanWebSession = "isCleanWebSession";
  static const lastLoginUsername = "lastLoginUsername";
  static const savedAccounts = "savedAccounts";
  static const accountEncryptionKey = "accountEncryptionKey";

  /// 当前选中的学校（机构），见 [AppOrg]
  static const currentOrg = "currentOrg";

  /// 每个账号自己的设备标识：随机生成一次就固定下来，
  /// 拼 UA 和签到的 deviceId 都用它，见 [AppUserAgent]
  static String deviceProfile(String account) => "deviceProfile_$account";

  /// CAS 浏览器指纹（bfp），按帐号持久化，模拟真实浏览器稳定指纹
  static String casBfp(String username) => "cas_bfp_$username";
}
