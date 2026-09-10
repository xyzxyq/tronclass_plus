/// 网页登录时用来快速填充的账号密码。
///
/// 它不参与登录本身——学校的认证页面怎么登还是怎么登，这里只是把
/// 账号密码摆在网页上方的小卡片里，方便复制粘贴，顺便在登录成功后
/// 一起存下来，下次不用再敲一遍。
class WebLoginCredential {
  const WebLoginCredential({this.username = '', this.password = ''});

  final String username;
  final String password;

  bool get isEmpty => username.isEmpty && password.isEmpty;
}
