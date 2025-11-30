import 'dart:typed_data';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:universal_io/io.dart' as ufile;
import 'package:path/path.dart' as p;

abstract class StorageAdapter {
  Future<void> init();
  Future<void> saveBytes(String id, Uint8List bytes, {String? fileType});
  Future<Uint8List?> loadBytes(String id, {String? fileType});
  Future<void> delete(String id, {String? fileType});
}

// Web：使用 Hive（IndexedDB）存储二进制字节
class WebStorageAdapter implements StorageAdapter {
  late Box<dynamic> _box;

  @override
  Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<dynamic>('book_bytes');
  }

  @override
  Future<void> saveBytes(String id, Uint8List bytes, {String? fileType}) async {
    await _box.put(id, bytes);
  }

  @override
  Future<Uint8List?> loadBytes(String id, {String? fileType}) async {
    final data = _box.get(id);
    if (data is Uint8List) return data;
    return null;
  }

  @override
  Future<void> delete(String id, {String? fileType}) async {
    await _box.delete(id);
  }
}

// 非 Web：写入应用支持目录的文件
class FileStorageAdapter implements StorageAdapter {
  late String _root;

  @override
  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _root = p.join(dir.path, 'books');
    final d = ufile.Directory(_root);
    if (!(await d.exists())) {
      await d.create(recursive: true);
    }
  }

  String _pathFor(String id, {String? fileType}) {
    final name = fileType != null ? '$id.$fileType' : id;
    return p.join(_root, name);
  }

  @override
  Future<void> saveBytes(String id, Uint8List bytes, {String? fileType}) async {
    final path = _pathFor(id, fileType: fileType);
    final f = ufile.File(path);
    // 为提升导入速度，避免强制刷盘；写入由操作系统负责落盘
    await f.writeAsBytes(bytes);
  }

  @override
  Future<Uint8List?> loadBytes(String id, {String? fileType}) async {
    final path = _pathFor(id, fileType: fileType);
    final f = ufile.File(path);
    if (await f.exists()) {
      return await f.readAsBytes();
    }
    return null;
  }

  @override
  Future<void> delete(String id, {String? fileType}) async {
    final path = _pathFor(id, fileType: fileType);
    final f = ufile.File(path);
    if (await f.exists()) {
      await f.delete();
    }
  }
}
