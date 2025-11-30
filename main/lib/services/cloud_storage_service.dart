import 'dart:typed_data';
import 'package:http/http.dart' as http;

class CloudStorageService {
  final String _baseUrl = const String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  Future<bool> uploadBytes({
    required String accessToken,
    required String key,
    required Uint8List bytes,
    String contentType = 'application/octet-stream',
  }) async {
    final presignResp = await http.post(
      Uri.parse('$_baseUrl/storage/presign/put'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
      body: '{"key":"$key","contentType":"$contentType"}',
    );
    if (presignResp.statusCode != 200) {
      return false;
    }
    final data = presignResp.body;
    // Simple parse without bringing in json decode to keep footprint small
    final urlMatch = RegExp('"url"\s*:\s*"([^"]+)"').firstMatch(data);
    final headersMatch = RegExp('"headers"\s*:\s*\{([^}]*)\}').firstMatch(data);
    if (urlMatch == null) return false;
    final url = urlMatch.group(1)!;
    final putHeaders = <String, String>{};
    if (headersMatch != null) {
      final kvs = headersMatch.group(1)!;
      final pairs = kvs.split(',');
      for (final p in pairs) {
        final m = RegExp('"([^"]+)"\s*:\s*"([^"]*)"').firstMatch(p);
        if (m != null) {
          putHeaders[m.group(1)!] = m.group(2)!;
        }
      }
    }
    // Ensure content-type is set
    putHeaders.putIfAbsent('Content-Type', () => contentType);

    final putResp = await http.put(Uri.parse(url), headers: putHeaders, body: bytes);
    return putResp.statusCode >= 200 && putResp.statusCode < 300;
  }

  Future<String?> getDownloadUrl({
    required String accessToken,
    required String key,
  }) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/storage/presign/get?key=$key'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (resp.statusCode != 200) return null;
    final data = resp.body;
    final urlMatch = RegExp('"url"\s*:\s*"([^"]+)"').firstMatch(data);
    return urlMatch?.group(1);
  }
}

