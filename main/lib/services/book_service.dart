import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:universal_io/io.dart' as ufile;
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/book.dart';
import 'storage_adapter.dart';
import 'cloud_storage_service.dart';

class BookService with ChangeNotifier {
  List<Book> _books = [];
  List<Book> get books => _books;

  bool _isImporting = false;
  double _importProgress = 0.0;
  bool get isImporting => _isImporting;
  double get importProgress => _importProgress;

  // 缓存已解码的字节，避免重复Base64解码
  final Map<String, Uint8List> _bytesCache = {};
  // 存储适配器
  late final StorageAdapter _storage;
  bool _storageReady = false;
  final bool _enableCloudSync = const bool.fromEnvironment(
    'ENABLE_CLOUD_SYNC',
    defaultValue: false,
  );
  final CloudStorageService _cloud = CloudStorageService();

  BookService() {
    _storage = kIsWeb ? WebStorageAdapter() : FileStorageAdapter();
  }

  Future<void> init() async {
    await _storage.init();
    _storageReady = true;
    final prefs = await SharedPreferences.getInstance();
    final booksJson = prefs.getString('books');
    if (booksJson != null) {
      final List<dynamic> decoded = json.decode(booksJson);
      _books = decoded.map((item) => Book.fromJson(item)).toList();
      notifyListeners();
    }
  }

  Future<void> saveBooks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('books', json.encode(_books.map((e) => e.toJson()).toList()));

    // 将索引上传到云端，便于跨设备同步书库（仅上传必要元数据）
    if (_enableCloudSync) {
      try {
        final token = prefs.getString('access_token');
        if (token != null && token.isNotEmpty) {
          final index = _buildCloudIndexJson();
          final ok = await _cloud.uploadBytes(
            accessToken: token,
            key: 'books/index.json',
            bytes: Uint8List.fromList(utf8.encode(index)),
            contentType: 'application/json',
          );
          if (!ok) {
            // 静默失败：保持本地可用，不影响使用
          }
        }
      } catch (_) {}
    }
  }

  // 平滑推进进度到目标值（0~1）
  Future<void> _animateProgressTo(double target) async {
    const step = 0.02;
    while (_importProgress < target) {
      _importProgress = (_importProgress + step).clamp(0.0, target);
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 30));
    }
  }

  // 统一提供书籍字节
  Future<Uint8List?> getBookBytes(Book book) async {
    if (_bytesCache.containsKey(book.id)) {
      return _bytesCache[book.id];
    }
    // Prefer adapter storage
    final fromStorage = await _storage.loadBytes(book.id, fileType: book.fileType);
    if (fromStorage != null) {
      _bytesCache[book.id] = fromStorage;
      return fromStorage;
    }
    // Fallbacks for old data
    if (book.bytesBase64 != null && book.bytesBase64!.isNotEmpty) {
      try {
        final bytes = base64Decode(book.bytesBase64!);
        _bytesCache[book.id] = bytes;
        return bytes;
      } catch (_) {}
    }
    if (!kIsWeb && book.filePath.isNotEmpty) {
      try {
        final bytes = await ufile.File(book.filePath).readAsBytes();
        _bytesCache[book.id] = bytes;
        return bytes;
      } catch (_) {}
    }
    // 云端回退：本地缺失时尝试从对象存储拉取并缓存
    if (_enableCloudSync) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('access_token');
        if (token != null && token.isNotEmpty) {
          final key = 'books/${book.id}.${book.fileType}';
          final url = await _cloud.getDownloadUrl(accessToken: token, key: key);
          if (url != null) {
            final resp = await http.get(Uri.parse(url));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final bytes = resp.bodyBytes;
              // 写入适配器以便离线使用
              await _storage.saveBytes(book.id, bytes, fileType: book.fileType);
              _bytesCache[book.id] = bytes;
              return bytes;
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<Book?> importBook() async {
    try {
      _isImporting = true;
      _importProgress = 0.0;
      notifyListeners();

      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['epub', 'pdf', 'txt', 'md', 'html', 'htm', 'docx', 'rtf'],
        withData: true,
      );
      if (result == null) {
        _isImporting = false;
        _importProgress = 0.0;
        notifyListeners();
        return null;
      }

      await _animateProgressTo(0.2);

      final picked = result.files.single;
      final fileName = picked.name;
      final fileExtension = fileName.split('.').last.toLowerCase();
      if (fileExtension != 'epub' &&
          fileExtension != 'pdf' &&
          fileExtension != 'txt' &&
          fileExtension != 'md' &&
          fileExtension != 'html' &&
          fileExtension != 'htm' &&
          fileExtension != 'docx' &&
          fileExtension != 'rtf') {
        _isImporting = false;
        _importProgress = 0.0;
        notifyListeners();
        return null;
      }

      Uint8List? bytes;
      if (kIsWeb) {
        bytes = picked.bytes;
      } else {
        if (picked.path != null && picked.path!.isNotEmpty) {
          bytes = await ufile.File(picked.path!).readAsBytes();
        } else {
          bytes = picked.bytes;
        }
      }
      await _animateProgressTo(0.6);

      if (bytes == null) {
        _isImporting = false;
        _importProgress = 0.0;
        notifyListeners();
        return null;
      }

      final book = Book(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: fileName.replaceAll('.$fileExtension', ''),
        author: '未知作者',
        filePath: kIsWeb ? '' : (picked.path ?? ''),
        fileType: fileExtension,
        bytesBase64: null, // stop storing huge Base64 blobs
      );

      // 确保存储适配器已初始化（避免用户启动后立即导入导致未初始化）
      if (!_storageReady) {
        await _storage.init();
        _storageReady = true;
      }

      // Save bytes via adapter and progress to 85%
      await Future.wait([
        _storage.saveBytes(book.id, bytes, fileType: fileExtension),
        _animateProgressTo(0.85),
      ]);

      // Optional: sync to cloud object storage using presigned PUT
      if (_enableCloudSync) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final token = prefs.getString('access_token');
          if (token != null && token.isNotEmpty) {
            final key = 'books/${book.id}.${fileExtension}';
            final contentType = _contentTypeFor(fileExtension);
            final ok = await _cloud.uploadBytes(
              accessToken: token,
              key: key,
              bytes: bytes,
              contentType: contentType,
            );
            if (ok) {
              await _animateProgressTo(0.92);
              // 上传成功后，自动触发后端 AI 语料生成
              try {
                final baseUrl = const String.fromEnvironment(
                  'API_BASE_URL',
                  defaultValue: 'http://localhost:8000',
                );
                final resp = await http.post(
                  Uri.parse('$baseUrl/ai/ingest'),
                  headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer $token',
                  },
                  body: json.encode({'bookId': book.id, 'fileType': fileExtension}),
                );
                if (resp.statusCode == 200) {
                  await _animateProgressTo(0.96);
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }

      _bytesCache[book.id] = bytes;
      _books.add(book);
      await saveBooks();

      await _animateProgressTo(1.0);
      await Future.delayed(const Duration(milliseconds: 150));
      _isImporting = false;
      _importProgress = 0.0;
      notifyListeners();

      return book;
    } catch (e) {
      print('导入书籍失败: $e');
      _isImporting = false;
      _importProgress = 0.0;
      notifyListeners();
      return null;
    }
  }

  // 构建云端索引（不包含大体积字段）
  String _buildCloudIndexJson() {
    final list = _books
        .map((b) => {
              'id': b.id,
              'title': b.title,
              'author': b.author,
              'fileType': b.fileType,
              'lastPosition': b.lastPosition,
              'lastReadTime': b.lastReadTime?.toIso8601String(),
            })
        .toList();
    return json.encode({'version': 1, 'items': list});
  }

  // 初始化时尝试从云端下载索引并与本地合并（本地优先）
  Future<void> initWithCloudMerge() async {
    await _storage.init();
    _storageReady = true;
    final prefs = await SharedPreferences.getInstance();
    final booksJson = prefs.getString('books');
    if (booksJson != null) {
      final List<dynamic> decoded = json.decode(booksJson);
      _books = decoded.map((item) => Book.fromJson(item)).toList();
      notifyListeners();
    }
    if (_enableCloudSync) {
      try {
        final token = prefs.getString('access_token');
        if (token != null && token.isNotEmpty) {
          final url = await _cloud.getDownloadUrl(accessToken: token, key: 'books/index.json');
          if (url != null) {
            final resp = await http.get(Uri.parse(url));
            if (resp.statusCode >= 200 && resp.statusCode < 300) {
              final data = json.decode(resp.body);
              final List<dynamic> items = (data['items'] ?? []) as List<dynamic>;
              // 合并到本地（避免重复）
              for (final it in items) {
                final id = it['id'] as String?;
                if (id == null) continue;
                final exists = _books.any((b) => b.id == id);
                if (!exists) {
                  _books.add(Book(
                    id: id,
                    title: (it['title'] ?? '') as String,
                    author: (it['author'] ?? '未知作者') as String,
                    filePath: '',
                    fileType: (it['fileType'] ?? 'epub') as String,
                    bytesBase64: null,
                    lastPosition: (it['lastPosition'] ?? 0) as int,
                    lastReadTime: (it['lastReadTime'] != null)
                        ? DateTime.tryParse(it['lastReadTime'] as String)
                        : null,
                  ));
                }
              }
              await saveBooks();
              notifyListeners();
            }
          }
        }
      } catch (_) {}
    }
  }

  String _contentTypeFor(String ext) {
    switch (ext) {
      case 'epub':
        return 'application/epub+zip';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
      case 'md':
      case 'rtf':
      case 'html':
      case 'htm':
        return 'text/plain';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> updateReadingProgress(String bookId, int position) async {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index != -1) {
      _books[index].lastPosition = position;
      _books[index].lastReadTime = DateTime.now();
      await saveBooks();
      notifyListeners();
    }
  }
}
