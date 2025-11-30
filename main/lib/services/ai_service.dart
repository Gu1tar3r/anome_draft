import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class AIService with ChangeNotifier {
  // 后端地址（可在构建时通过 --dart-define API_BASE_URL 覆盖）
  final String _baseUrl = const String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
  String _currentBookId = '';
  String _currentBookContent = '';
  int _currentPosition = 0;

  // 绑定当前书籍上下文：bookId、文本内容（供本地兜底）、当前位置
  void setBookContext(String bookId, String content, int position) {
    _currentBookId = bookId;
    _currentBookContent = content;
    _currentPosition = position;
  }

  // 请求后端 AI 问答接口；如无令牌或服务不可用，回退到本地占位回答
  Future<String> askQuestion(
    String question, {
    bool companionMode = false,
    String? accessToken,
  }) async {
    // 如令牌或 bookId 缺失，进行本地兜底回答
    if (accessToken == null || accessToken.isEmpty || _currentBookId.isEmpty) {
      return _localFallbackAnswer(question, companionMode: companionMode);
    }

    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/ai/query'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: json.encode({
          'bookId': _currentBookId,
          'question': question,
          'position': _currentPosition,
          'companionMode': companionMode,
        }),
      );

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final answer = data['answer'] as String?;
        if (answer != null && answer.isNotEmpty) return answer;
        return '后端返回空答案，请稍后重试。';
      }
      if (resp.statusCode == 404) {
        // 未找到分块，提示用户先执行导入后的 ingest（我们会在导入成功后自动触发）
        return '尚未生成书籍语料，请先完成导入并等待后台处理。若已导入，请稍后重试或在设置中开启云同步。';
      }
      if (resp.statusCode == 401) {
        return '登录状态失效，请重新登录后再试。';
      }
      // 其他错误回退到本地占位回答
      return _localFallbackAnswer(question, companionMode: companionMode);
    } catch (_) {
      // 网络或解析异常，回退本地
      return _localFallbackAnswer(question, companionMode: companionMode);
    }
  }

  String _localFallbackAnswer(String question, {bool companionMode = false}) {
    if (companionMode && _currentBookContent.isNotEmpty) {
      final contextBeforePosition = _currentBookContent.substring(0, _currentPosition.clamp(0, _currentBookContent.length));
      final preview = contextBeforePosition.length > 180
          ? contextBeforePosition.substring(contextBeforePosition.length - 180)
          : contextBeforePosition;
      return '伴读占位回答：基于当前阅读进度的片段参考，建议继续阅读以获取更多线索。片段预览：\n$preview';
    }
    return '占位回答：暂未连接云端 AI，或网络异常。请检查登录状态与后端配置后重试。';
  }
}
