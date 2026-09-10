import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

import 'package:tronclass/data/get_storage.dart';
import 'package:tronclass/path.dart';

/// 备份文件的读写。
///
/// 里面装的是账号、会话、cookie 这些东西，落到文件里就等于把登录态
/// 交出去了，所以一律用用户自己的密码加密：密码经 PBKDF2 派生出密钥，
/// AES-256-CBC 加密，再附一段 HMAC——改过一个字节都能看出来，
/// 密码错了也能直接判出来，而不是解出一堆乱码。
class BackupService {
  BackupService._();

  static const formatTag = 'tronclass-backup';
  static const formatVersion = 1;

  /// 迭代次数按手机上能接受的耗时定，几百毫秒的量级。
  static const _iterations = 120000;
  static const _keyLength = 32; // AES-256
  static const _macLength = 32; // HMAC-SHA256
  static const _saltLength = 16;
  static const _ivLength = 16;

  static final _random = Random.secure();

  /// 打包成一份加密备份的字节。
  static Future<Uint8List> exportBytes(String password) async {
    final payload = jsonEncode({
      'exportedAt': DateTime.now().toIso8601String(),
      'storage': _readStorage(),
      'cookies': await _readCookies(),
    });

    final salt = _randomBytes(_saltLength);
    final iv = _randomBytes(_ivLength);
    final keys = _deriveKeys(password, salt);
    final cipherText = _aes(
      forEncryption: true,
      key: keys.encryption,
      iv: iv,
      data: Uint8List.fromList(utf8.encode(payload)),
    );

    final envelope = {
      'format': formatTag,
      'version': formatVersion,
      'kdf': {
        'algorithm': 'pbkdf2-hmac-sha256',
        'salt': base64Encode(salt),
        'iterations': _iterations,
      },
      'cipher': 'aes-256-cbc',
      'iv': base64Encode(iv),
      // 认证的是密文，先验后解，密码不对就不会去碰解密结果
      'mac': base64Encode(_hmac(keys.mac, cipherText)),
      'payload': base64Encode(cipherText),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  /// 读回一份备份并全量覆盖本地数据。
  ///
  /// 覆盖之后内存里的缓存（GetStorage 的值、已经建好的网络客户端）都还是
  /// 旧的，所以调用方要提示用户重开 App。
  static Future<BackupSummary> importBytes(
    Uint8List bytes,
    String password,
  ) async {
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupException('这不像是本 App 导出的备份文件');
    }

    if (envelope['format'] != formatTag) {
      throw const BackupException('这不像是本 App 导出的备份文件');
    }
    final version = envelope['version'];
    if (version is! int || version > formatVersion) {
      throw BackupException('备份版本 $version 比当前 App 还新，先升级 App 再导入');
    }

    final kdf = envelope['kdf'];
    final salt = base64Decode('${(kdf as Map)['salt']}');
    final iterations = kdf['iterations'] as int? ?? _iterations;
    final iv = base64Decode('${envelope['iv']}');
    final cipherText = base64Decode('${envelope['payload']}');
    final mac = base64Decode('${envelope['mac']}');

    final keys = _deriveKeys(password, salt, iterations: iterations);
    if (!_macEquals(_hmac(keys.mac, cipherText), mac)) {
      throw const BackupException('密码不对，或者文件被改过');
    }

    final plain = _aes(
      forEncryption: false,
      key: keys.encryption,
      iv: Uint8List.fromList(iv),
      data: Uint8List.fromList(cipherText),
    );
    final payload = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;

    final storage = Map<String, dynamic>.from(payload['storage'] as Map);
    final cookies = Map<String, dynamic>.from(
      (payload['cookies'] as Map?) ?? {},
    );

    await _writeStorage(storage);
    final cookieFiles = await _writeCookies(cookies);

    return BackupSummary(
      exportedAt: DateTime.tryParse('${payload['exportedAt']}'),
      storageKeys: storage.length,
      cookieFiles: cookieFiles,
    );
  }

  /// 默认文件名，带上日期好认。
  static String suggestedFileName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'tronclass-backup-'
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.tcbak';
  }

  // ---------- 本地数据 ----------

  static Map<String, dynamic> _readStorage() {
    final result = <String, dynamic>{};
    for (final key in getStorage.getKeys<Iterable<dynamic>>()) {
      result['$key'] = getStorage.read(key.toString());
    }
    return result;
  }

  static Future<void> _writeStorage(Map<String, dynamic> data) async {
    await getStorage.erase();
    for (final entry in data.entries) {
      await getStorage.write(entry.key, entry.value);
    }
    await getStorage.save();
  }

  static Directory get _cookieRoot =>
      Directory(p.join(applicationSupportDirectory.path, 'cookies'));

  /// cookie 是一堆小文件，按相对路径原样存进备份。
  static Future<Map<String, String>> _readCookies() async {
    final root = _cookieRoot;
    if (!root.existsSync()) return {};
    final result = <String, String>{};
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root.path);
      result[relative] = base64Encode(await entity.readAsBytes());
    }
    return result;
  }

  static Future<int> _writeCookies(Map<String, dynamic> files) async {
    final root = _cookieRoot;
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
    var count = 0;
    for (final entry in files.entries) {
      // 备份里的路径不该指到 cookies 目录外面去
      final target = File(p.normalize(p.join(root.path, entry.key)));
      if (!p.isWithin(root.path, target.path)) continue;
      await target.parent.create(recursive: true);
      await target.writeAsBytes(base64Decode('${entry.value}'));
      count++;
    }
    return count;
  }

  // ---------- 加解密 ----------

  static _BackupKeys _deriveKeys(
    String password,
    List<int> salt, {
    int iterations = _iterations,
  }) {
    final derived = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations,
          _keyLength + _macLength));
    final out = derived.process(Uint8List.fromList(utf8.encode(password)));
    return _BackupKeys(
      encryption: Uint8List.sublistView(out, 0, _keyLength),
      mac: Uint8List.sublistView(out, _keyLength),
    );
  }

  static Uint8List _aes({
    required bool forEncryption,
    required Uint8List key,
    required Uint8List iv,
    required Uint8List data,
  }) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
      forEncryption,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
    return cipher.process(data);
  }

  static Uint8List _hmac(Uint8List key, List<int> data) {
    final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    return hmac.process(Uint8List.fromList(data));
  }

  /// 逐字节比完再返回，别因为提前退出泄露对了几位。
  static bool _macEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _randomBytes(int length) => Uint8List.fromList(
    List<int>.generate(length, (_) => _random.nextInt(256)),
  );
}

class _BackupKeys {
  const _BackupKeys({required this.encryption, required this.mac});

  final Uint8List encryption;
  final Uint8List mac;
}

/// 导入完成后的简报，用来告诉用户到底恢复了些什么。
class BackupSummary {
  const BackupSummary({
    required this.exportedAt,
    required this.storageKeys,
    required this.cookieFiles,
  });

  final DateTime? exportedAt;
  final int storageKeys;
  final int cookieFiles;
}

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
