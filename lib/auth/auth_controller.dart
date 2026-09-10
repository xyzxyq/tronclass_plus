import 'package:get/get.dart';

import 'package:tronclass/auth/saved_account_storage.dart';
import 'package:tronclass/data/changke_client.dart';
import 'package:tronclass/data/get_storage.dart';
import 'package:tronclass/data/org_store.dart';

/// 当前是谁在用这个 App。
///
/// 登录态是「学校 + 账号」一对，光一个 bool 说不清楚，所以这里把当前
/// 账号的名字、学校、登录方式一并暴露出来，界面直接照着显示就行。
class AuthController extends GetxController {
  final isLoggedIn = false.obs;

  /// 姓名（学号）；没存过姓名就只有学号。
  final accountLabel = ''.obs;

  final orgName = ''.obs;

  /// 「账号密码登录」/「网页登录」，不知道就是空的。
  final loginMethodLabel = ''.obs;

  @override
  void onInit() {
    super.onInit();
    refreshState();
  }

  void refreshState() {
    final client = ChangkeClient.instance;
    final org = AppOrg.current;
    final username =
        getStorage.read<String>(GetStorageKeys.lastLoginUsername) ??
        client.username;

    isLoggedIn.value = client.isLoggedIn;
    orgName.value = org.orgName;

    final account = _findAccount(username, org.apiUrl);
    accountLabel.value = account?.label ?? username;
    loginMethodLabel.value = account?.loginMethodLabel ?? '';
  }

  SavedAccount? _findAccount(String username, String apiUrl) {
    for (final account in SavedAccountStorage.loadAccounts()) {
      if (account.username == username && account.org.apiUrl == apiUrl) {
        return account;
      }
    }
    return null;
  }

  /// 退出只清掉当前这套会话，账号本身还留在列表里，随时能再登。
  void logout() {
    ChangkeClient.instance.logout();
    refreshState();
  }
}
