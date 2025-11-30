import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

class RegisterView extends StatefulWidget {
  const RegisterView({Key? key}) : super(key: key);

  @override
  State<RegisterView> createState() => _RegisterViewState();
}

class _RegisterViewState extends State<RegisterView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();
  bool _isLoading = false;
  bool _isSendingCode = false;
  int _countdown = 0;
  Timer? _timer;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _timer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    setState(() { _countdown = seconds; });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_countdown <= 1) {
        t.cancel();
        setState(() { _countdown = 0; });
      } else {
        setState(() { _countdown -= 1; });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1E3C72), Color(0xFF2A5298)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '注册账号',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                        labelText: '邮箱',
                        prefixIcon: Icon(Icons.email_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: '密码（至少6位）',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () {
                            setState(() { _obscurePassword = !_obscurePassword; });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _codeController,
                            decoration: const InputDecoration(
                              labelText: '邮箱验证码',
                              prefixIcon: Icon(Icons.verified_outlined),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 140,
                          child: OutlinedButton(
                            onPressed: (_isSendingCode || _countdown > 0)
                                ? null
                                : () async {
                                    setState(() { _isSendingCode = true; });
                                    final auth = Provider.of<AuthService>(context, listen: false);
                                    final ok = await auth.sendRegisterCode(_emailController.text);
                                    setState(() { _isSendingCode = false; });
                                    if (ok) {
                                      _startCountdown(60);
                                      final devCode = auth.lastDevCode;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(devCode != null ? '验证码已发送（开发模式）：$devCode' : '验证码已发送，请查收邮箱')),
                                      );
                                    } else {
                                      final msg = auth.lastErrorMessage ?? '验证码发送失败，请检查邮箱';
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                                    }
                                  },
                            child: _isSendingCode
                                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_countdown > 0 ? '重新发送($_countdown)' : '发送验证码'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _isLoading
                          ? null
                          : () async {
                              setState(() { _isLoading = true; });
                              final auth = Provider.of<AuthService>(context, listen: false);
                              final ok = await auth.register(
                                _emailController.text,
                                _passwordController.text,
                                _codeController.text,
                              );
                              setState(() { _isLoading = false; });
                              if (!ok && mounted) {
                                final msg = auth.lastErrorMessage ?? '注册失败，请检查邮箱、密码与验证码';
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                              }
                            },
                      child: _isLoading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                          : const Text('注册并登录'),
                    ),
                    const SizedBox(height: 12),
                    Builder(
                      builder: (context) {
                        final devCode = context.watch<AuthService>().lastDevCode;
                        if (devCode == null) return const SizedBox.shrink();
                        return Row(
                          children: [
                            Expanded(child: Text('开发模式验证码：$devCode', style: const TextStyle(color: Colors.orange))),
                            IconButton(
                              icon: const Icon(Icons.copy),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: devCode));
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制验证码')));
                                }
                              },
                            ),
                            TextButton(
                              onPressed: () {
                                _codeController.text = devCode;
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已填入开发验证码')));
                              },
                              child: const Text('填入'),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Builder(
                      builder: (context) {
                        final msg = context.watch<AuthService>().lastErrorMessage;
                        if (msg == null || msg.isEmpty) return const SizedBox.shrink();
                        return Text(msg, style: const TextStyle(color: Colors.red));
                      },
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                      },
                      child: const Text('已有账号？返回登录'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

