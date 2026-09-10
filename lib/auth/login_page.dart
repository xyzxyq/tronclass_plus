import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tronclass/auth/login_controller.dart';
import 'package:tronclass/auth/web_login_credential.dart';
import 'package:tronclass/data/org_store.dart';
import 'package:tronclass/routes.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  /// 其他学校：账号密码一样要填（登录时要靠它快速填充），
  /// 填好再去选学校。
  Future<void> _loginOtherOrg(LoginController controller) async {
    if (!(controller.formKey.currentState?.validate() ?? false)) return;

    final result = await Get.toNamed(
      AppRoute.orgSearchPage,
      arguments: WebLoginCredential(
        username: controller.usernameController.text.trim(),
        password: controller.passwordController.text,
      ),
    );
    if (result == true) Get.back(result: true);
  }

  @override
  Widget build(BuildContext context) {
    String? initialUsername;
    String? initialPassword;
    final args = Get.arguments;
    if (args is String) {
      initialUsername = args;
    } else if (args is Map) {
      final map = Map<String, dynamic>.from(args as Map);
      final user = map['username'];
      final pass = map['password'];
      if (user is String) initialUsername = user;
      if (pass is String) initialPassword = pass;
    }

    return GetBuilder<LoginController>(
      init: LoginController(
        initialUsername: initialUsername,
        initialPassword: initialPassword,
      ),
      builder: (controller) {
        return Scaffold(
          appBar: AppBar(title: const Text('登录')),
          body: SingleChildScrollView(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: controller.formKey,
                    autovalidateMode: AutovalidateMode.disabled,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary.withOpacity(0.3),
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.qr_code_scanner,
                                      size: 24,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    '登录 TronClass Plus',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Text(
                                '填好账号密码，再选下面对应的登录方式',
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                        TextFormField(
                          controller: controller.usernameController,
                          autofocus: false,
                          decoration: const InputDecoration(
                            labelText: '账号',
                            hintText: '学号 / 工号',
                            prefixIcon: Icon(Icons.person),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(16),
                              ),
                            ),
                          ),
                          validator: (v) {
                            return v!.trim().isNotEmpty ? null : '账号不能为空';
                          },
                        ),
                        const SizedBox(height: 16),
                        Obx(
                          () => TextFormField(
                            controller: controller.passwordController,
                            obscureText: !controller.passwordVisible.value,
                            autofocus: false,
                            decoration: InputDecoration(
                              labelText: '密码',
                              hintText: '学校统一身份认证的密码',
                              prefixIcon: const Icon(Icons.lock),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  controller.passwordVisible.value
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                ),
                                onPressed: controller.togglePasswordVisibility,
                              ),
                              border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(16),
                                ),
                              ),
                            ),
                            validator: (v) {
                              return v!.trim().isNotEmpty ? null : '密码不能为空';
                            },
                          ),
                        ),
                        const SizedBox(height: 24),
                        Obx(
                          () => ElevatedButton(
                            onPressed: controller.isSubmitting.value
                                ? null
                                : controller.submit,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 50),
                            ),
                            child: controller.isSubmitting.value
                                ? const Text('正在登录...')
                                : Text('${AppOrg.guet.orgName}登录'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Obx(
                          () => OutlinedButton(
                            onPressed: controller.isSubmitting.value
                                ? null
                                : () => _loginOtherOrg(controller),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 50),
                            ),
                            child: const Text('其他学校登录'),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '其他学校要先选学校，再在学校自己的登录页面里登；'
                          '上面填的账号密码会浮在页面上，点一下就能复制。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                        const SizedBox(height: 16),
                        // 已经登过的账号多数时候是从这里回来的，别做成一行小字
                        OutlinedButton.icon(
                          onPressed: () async {
                            final result = await Get.toNamed(
                              AppRoute.accountManagerPage,
                            );
                            if (result == true) {
                              Get.back(result: true);
                            }
                          },
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(double.infinity, 50),
                            side: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                          ),
                          icon: const Icon(Icons.manage_accounts),
                          label: const Text(
                            '管理已保存账号',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
