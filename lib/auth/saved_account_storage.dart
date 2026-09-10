import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:tronclass/data/get_storage.dart';
import 'package:tronclass/data/model/tron_org.dart';
import 'package:tronclass/data/org_store.dart';

class SavedAccount {
  final String username;

  /// 姓名，来自 `/api/profile` 的 `name`。拿不到就是 null，
  /// 界面上退回显示学号。
  final String? displayName;

  /// 密码只有桂电账号密码直登才有；通用（WebView）登录拿不到密码，这里是 null。
  final String? encryptedPassword;
  final String? iv;

  /// 这个账号属于哪所学校。老数据没有这个字段，按桂电算。
  final TronOrg org;

  /// 当初是怎么登进来的，见 [LoginMethod]。老数据没记，
  /// 按「有没有存密码」倒推。
  final String loginMethod;
  final DateTime updatedAt;

  SavedAccount({
    required this.username,
    this.displayName,
    this.encryptedPassword,
    this.iv,
    required this.org,
    required this.loginMethod,
    required this.updatedAt,
  });

  /// 有密码才能一键重登；没有的只能再走一次网页登录。
  bool get canReloginSilently => encryptedPassword != null && iv != null;

  String get loginMethodLabel => loginMethod == LoginMethod.password
      ? '账号密码登录'
      : '网页登录';

  /// 列表上给人看的标题：有姓名就「姓名（学号）」，没有就只有学号。
  String get label => (displayName == null || displayName!.isEmpty)
      ? username
      : '$displayName（$username）';

  Map<String, dynamic> toMap() {
    return {
      'username': username,
      'displayName': displayName,
      'loginMethod': loginMethod,
      'encryptedPassword': encryptedPassword,
      'iv': iv,
      'org': org.toJson(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory SavedAccount.fromMap(Map<String, dynamic> map) {
    final rawOrg = map['org'];
    return SavedAccount(
      username: map['username'] as String,
      displayName: map['displayName'] as String?,
      encryptedPassword: map['encryptedPassword'] as String?,
      iv: map['iv'] as String?,
      org: (rawOrg is Map
              ? TronOrg.fromJson(Map<String, dynamic>.from(rawOrg))
              : null) ??
          AppOrg.guet,
      loginMethod: (map['loginMethod'] as String?) ??
          (map['encryptedPassword'] == null
              ? LoginMethod.webView
              : LoginMethod.password),
      updatedAt:
          DateTime.tryParse(map['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 账号是怎么登进来的。
class LoginMethod {
  LoginMethod._();

  /// 账号密码直登（桂电走 CAS 那条）。
  static const password = 'password';

  /// 网页登录：在学校的统一身份认证页面里登。
  static const webView = 'webview';
}

class SavedAccountStorage {
  static const _ivLength = 16;

  static final Random _random = Random.secure();

  static encrypt.Encrypter _buildEncrypter() {
    final keyBytes = _loadOrCreateKey();
    final key = encrypt.Key(keyBytes);
    return encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
    );
  }

  static Uint8List _loadOrCreateKey() {
    final stored = getStorage.read<String>(GetStorageKeys.accountEncryptionKey);
    if (stored != null && stored.isNotEmpty) {
      return Uint8List.fromList(base64Decode(stored));
    }
    final keyBytes = _randomBytes(32);
    getStorage.write(
      GetStorageKeys.accountEncryptionKey,
      base64Encode(keyBytes),
    );
    return keyBytes;
  }

  static List<SavedAccount> loadAccounts() {
    final rawList =
        getStorage.read<List<dynamic>>(GetStorageKeys.savedAccounts) ?? [];
    return rawList
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .map(SavedAccount.fromMap)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  static Future<void> _persist(List<SavedAccount> accounts) async {
    await getStorage.write(
      GetStorageKeys.savedAccounts,
      accounts.map((e) => e.toMap()).toList(),
    );
  }

  /// 保存/更新一个账号。[password] 只有桂电直登那条路会传；
  /// 通用登录只传 [org]。[displayName] 拿不到时沿用已存的，别把名字冲掉。
  static Future<void> upsertAccount({
    required String username,
    String? password,
    String? displayName,
    TronOrg? org,
    required String loginMethod,
  }) async {
    final accounts = loadAccounts();
    final existing = accounts
        .where((e) => e.username == username)
        .cast<SavedAccount?>()
        .firstWhere((e) => true, orElse: () => null);
    String? encryptedPassword;
    String? ivBase64;
    if (password != null && password.isNotEmpty) {
      final ivBytes = _randomBytes(_ivLength);
      final iv = encrypt.IV(ivBytes);
      encryptedPassword = _buildEncrypter().encrypt(password, iv: iv).base64;
      ivBase64 = base64Encode(ivBytes);
    }

    final updated = SavedAccount(
      username: username,
      displayName: (displayName != null && displayName.isNotEmpty)
          ? displayName
          : existing?.displayName,
      encryptedPassword: encryptedPassword,
      iv: ivBase64,
      org: org ?? AppOrg.current,
      loginMethod: loginMethod,
      updatedAt: DateTime.now(),
    );

    accounts.removeWhere((element) => element.username == username);
    accounts.insert(0, updated);
    await _persist(accounts);
  }

  static Future<void> removeAccount(String username) async {
    final accounts = loadAccounts()..removeWhere((e) => e.username == username);
    await _persist(accounts);
  }

  static String? decryptPassword(SavedAccount account) {
    final rawIv = account.iv;
    final rawPassword = account.encryptedPassword;
    if (rawIv == null || rawPassword == null) return null;
    try {
      final iv = encrypt.IV(base64Decode(rawIv));
      final encrypted = encrypt.Encrypted.from64(rawPassword);
      return _buildEncrypter().decrypt(encrypted, iv: iv);
    } catch (_) {
      return null;
    }
  }

  static Uint8List _randomBytes(int length) {
    final bytes = List<int>.generate(length, (_) => _random.nextInt(256));
    return Uint8List.fromList(bytes);
  }
}
