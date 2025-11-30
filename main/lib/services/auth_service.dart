import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/user.dart';

class AuthService with ChangeNotifier {
  User? _currentUser;
  bool get isLoggedIn => _currentUser != null;
  User? get currentUser => _currentUser;
  String? _accessToken;
  String? _refreshToken;
  // Allow overriding API base URL at build time:
  // flutter run --dart-define API_BASE_URL=https://api.example.com
  final String _baseUrl = const String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
  // 控制是否允许离线登录/注册回退（默认禁用）
  final bool _enableOfflineAuth = const bool.fromEnvironment(
    'ENABLE_OFFLINE_AUTH',
    defaultValue: false,
  );
  String? _lastDevCode; // 记录最近一次发送验证码返回的开发模式验证码（如果有）
  String? _lastErrorMessage; // 记录最近一次操作的错误原因（后端返回或本地校验）
  String? get lastErrorMessage => _lastErrorMessage;
  String? get accessToken => _accessToken;
  Map<String, dynamic> _userTable = {}; // 仅作离线备用

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('access_token');
    _refreshToken = prefs.getString('refresh_token');
    if (_accessToken != null) {
      try {
        final me = await _fetchMe();
        if (me != null) {
          _currentUser = me;
          await prefs.setString('user', json.encode(_currentUser!.toJson()));
          notifyListeners();
          return;
        }
      } catch (_) {}
    }
    // Try refresh token if access token failed
    if (_refreshToken != null) {
      final refreshed = await _refreshAccessToken();
      if (refreshed) {
        final me = await _fetchMe();
        if (me != null) {
          _currentUser = me;
          await prefs.setString('user', json.encode(_currentUser!.toJson()));
          notifyListeners();
          return;
        }
      }
    }
    // 后端不可用时的离线回退
    final userJson = prefs.getString('user');
    if (userJson != null) {
      _currentUser = User.fromJson(json.decode(userJson));
      notifyListeners();
    }
    final usersJson = prefs.getString('users');
    if (usersJson != null) {
      _userTable = json.decode(usersJson) as Map<String, dynamic>;
    }
  }

  Future<bool> login(String email, String password) async {
    if (email.isEmpty || password.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': password}),
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final token = data['accessToken'] as String?;
        final refresh = data['refreshToken'] as String?;
        final userJson = data['user'] as Map<String, dynamic>?;
        if (token != null && userJson != null) {
          _accessToken = token;
          _refreshToken = refresh;
          _currentUser = User.fromJson(userJson);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('access_token', token);
          if (refresh != null) {
            await prefs.setString('refresh_token', refresh);
          }
          await prefs.setString('user', json.encode(_currentUser!.toJson()));
          notifyListeners();
          return true;
        }
      }
    } catch (_) {}
    // 仅在明确允许时才回退到离线本地验证
    if (_enableOfflineAuth) {
      return _loginOffline(email, password);
    }
    return false;
  }

  // 请求邮箱验证码（用于注册或免密登录）
  Future<bool> requestCode(String email) async {
    if (!_validateEmail(email)) {
      _lastErrorMessage = '邮箱格式不正确';
      notifyListeners();
      return false;
    }
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/request-code'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': ''}),
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        _lastDevCode = data['devCode'] as String?; // 开发模式便于本地测试
        _lastErrorMessage = null;
        notifyListeners();
        return true;
      } else if (resp.statusCode == 429) {
        _lastErrorMessage = '请求过于频繁，请稍后再试';
        notifyListeners();
        return false;
      }
    } catch (e) {
      _lastErrorMessage = '网络异常：$e';
      notifyListeners();
    }
    return false;
  }

  // 免密登录：邮箱 + 验证码
  Future<bool> loginWithCode(String email, String code) async {
    if (!_validateEmail(email) || code.isEmpty) {
      _lastErrorMessage = '请输入有效邮箱和验证码';
      notifyListeners();
      return false;
    }
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/login-code'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'code': code}),
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final token = data['accessToken'] as String?;
        final refresh = data['refreshToken'] as String?;
        final userJson = data['user'] as Map<String, dynamic>?;
        if (token != null && userJson != null) {
          _accessToken = token;
          _refreshToken = refresh;
          _currentUser = User.fromJson(userJson);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('access_token', token);
          if (refresh != null) {
            await prefs.setString('refresh_token', refresh);
          }
          await prefs.setString('user', json.encode(_currentUser!.toJson()));
          _lastErrorMessage = null;
          notifyListeners();
          return true;
        }
      } else if (resp.statusCode == 400) {
        _lastErrorMessage = '验证码无效或已过期';
        notifyListeners();
      } else if (resp.statusCode == 404) {
        _lastErrorMessage = '用户不存在，请先注册';
        notifyListeners();
      }
    } catch (e) {
      _lastErrorMessage = '网络异常：$e';
      notifyListeners();
    }
    return false;
  }

  Future<bool> wechatLogin() async {
    // 模拟微信登录
    _currentUser = User(
      id: '2',
      name: '微信用户',
      email: 'wechat@example.com',
      avatarUrl: '',
    );
    
    // 保存用户信息
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user', json.encode(_currentUser!.toJson()));
    
    notifyListeners();
    return true;
  }

  Future<void> logout() async {
    _currentUser = null;
    _accessToken = null;
    _refreshToken = null;
    
    // 清除用户信息
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('user');
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    
    notifyListeners();
  }

  Future<bool> register(String email, String password, String code) async {
    if (!_validateEmail(email)) { _lastErrorMessage = '邮箱格式不正确'; notifyListeners(); return false; }
    if (!_validatePassword(password)) { _lastErrorMessage = '密码至少 6 位'; notifyListeners(); return false; }
    if (code.isEmpty) { _lastErrorMessage = '验证码不能为空'; notifyListeners(); return false; }
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': password, 'code': code}),
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        final token = data['accessToken'] as String?;
        final refresh = data['refreshToken'] as String?;
        final userJson = data['user'] as Map<String, dynamic>?;
        if (token != null && userJson != null) {
          _accessToken = token;
          _refreshToken = refresh;
          _currentUser = User.fromJson(userJson);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('access_token', token);
          if (refresh != null) {
            await prefs.setString('refresh_token', refresh);
          }
          await prefs.setString('user', json.encode(_currentUser!.toJson()));
          _lastErrorMessage = null;
          notifyListeners();
          return true;
        }
      } else {
        try {
          final err = json.decode(resp.body) as Map<String, dynamic>;
          _lastErrorMessage = (err['detail'] as String?) ?? '注册失败';
        } catch (_) {
          _lastErrorMessage = '注册失败';
        }
        notifyListeners();
      }
    } catch (_) {}
    // 仅在明确允许时才回退到离线注册
    if (_enableOfflineAuth) {
      return _registerOffline(email, password);
    }
    if (_lastErrorMessage == null) {
      _lastErrorMessage = '网络错误或后端不可用';
      notifyListeners();
    }
    return false;
  }

  String? get lastDevCode => _lastDevCode;

  Future<bool> sendRegisterCode(String email) async {
    if (!_validateEmail(email)) { _lastErrorMessage = '邮箱格式不正确'; notifyListeners(); return false; }
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/request-code'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'email': email, 'password': ''}),
      );
      if (resp.statusCode == 200) {
        // 开发模式下后端可能返回 { ok: true, devCode: "123456" }
        try {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          _lastDevCode = data['devCode'] as String?;
        } catch (_) {
          _lastDevCode = null;
        }
        _lastErrorMessage = null;
        notifyListeners();
        return true;
      } else {
        try {
          final err = json.decode(resp.body) as Map<String, dynamic>;
          _lastErrorMessage = (err['detail'] as String?) ?? '验证码发送失败';
        } catch (_) {
          _lastErrorMessage = '验证码发送失败';
        }
        notifyListeners();
      }
    } catch (_) {}
    if (_lastErrorMessage == null) {
      _lastErrorMessage = '网络错误或后端不可用';
      notifyListeners();
    }
    return false;
  }

  // 可选：修改密码
  Future<bool> changePassword(String email, String oldPassword, String newPassword) async {
    final record = _userTable[email];
    if (record == null) return false;
    final salt = record['salt'] as String? ?? '';
    final storedHash = record['hash'] as String? ?? '';
    if (_hashPassword(oldPassword, salt) != storedHash) return false;
    if (!_validatePassword(newPassword)) return false;
    final newSalt = _generateSalt();
    final newHash = _hashPassword(newPassword, newSalt);
    record['salt'] = newSalt;
    record['hash'] = newHash;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('users', json.encode(_userTable));
    return true;
  }

  String _generateSalt({int length = 16}) {
    final rnd = Random();
    final bytes = List<int>.generate(length, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes);
  }

  String _hashPassword(String password, String salt) {
    // 简易离线哈希，仅用于后端不可用时的本地回退
    final bytes = utf8.encode('$salt:$password');
    int h = 0;
    for (final b in bytes) {
      h = 0x1fffffff & (h + b);
      h = 0x1fffffff & (h + ((h << 10)));
      h ^= (h >> 6);
    }
    h = 0x1fffffff & (h + ((h << 3)));
    h ^= (h >> 11);
    h = 0x1fffffff & (h + ((h << 15)));
    return h.toRadixString(16);
  }

  bool _validateEmail(String email) {
    final re = RegExp(r'^\S+@\S+\.\S+$');
    return re.hasMatch(email);
  }

  bool _validatePassword(String password) {
    return password.length >= 6;
  }

  Future<User?> _fetchMe() async {
    if (_accessToken == null) return null;
    final resp = await http.get(
      Uri.parse('$_baseUrl/auth/me'),
      headers: {'Authorization': 'Bearer $_accessToken'},
    );
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      return User.fromJson(data);
    }
    // Attempt one refresh if unauthorized
    if (resp.statusCode == 401 && _refreshToken != null) {
      final ok = await _refreshAccessToken();
      if (ok) {
        final retry = await http.get(
          Uri.parse('$_baseUrl/auth/me'),
          headers: {'Authorization': 'Bearer $_accessToken'},
        );
        if (retry.statusCode == 200) {
          final data = json.decode(retry.body) as Map<String, dynamic>;
          return User.fromJson(data);
        }
      }
    }
    return null;
  }

  Future<bool> _refreshAccessToken() async {
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/auth/refresh'),
        headers: {'Authorization': 'Bearer $_refreshToken'},
      );
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final token = data['accessToken'] as String?;
        if (token != null) {
          _accessToken = token;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('access_token', token);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _loginOffline(String email, String password) async {
    final record = _userTable[email];
    if (record == null) return false;
    final salt = record['salt'] as String? ?? '';
    final storedHash = record['hash'] as String? ?? '';
    final inputHash = _hashPassword(password, salt);
    if (inputHash != storedHash) return false;
    _currentUser = User(
      id: record['id'] as String? ?? 'local-${email.hashCode}',
      name: record['name'] as String? ?? email.split('@').first,
      email: email,
      avatarUrl: record['avatarUrl'] as String? ?? '',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user', json.encode(_currentUser!.toJson()));
    notifyListeners();
    return true;
  }

  Future<bool> _registerOffline(String email, String password) async {
    if (_userTable.containsKey(email)) return false;
    final salt = _generateSalt();
    final hash = _hashPassword(password, salt);
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final name = email.split('@').first;
    _userTable[email] = {
      'id': id,
      'name': name,
      'salt': salt,
      'hash': hash,
      'avatarUrl': ''
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('users', json.encode(_userTable));
    _currentUser = User(id: id, name: name, email: email, avatarUrl: '');
    await prefs.setString('user', json.encode(_currentUser!.toJson()));
    notifyListeners();
    return true;
  }
}
