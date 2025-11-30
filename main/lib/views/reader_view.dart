import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:epub_view/epub_view.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../services/auth_service.dart';
import '../utils/selection_stub.dart'
    if (dart.library.html) '../utils/selection_web.dart' as sel;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:archive/archive.dart';
import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
// Remove this line if present:
// import 'package:universal_file/universal_file.dart' as ufile;
import '../models/book.dart';
import '../services/book_service.dart';
import '../services/ai_service.dart';

class ReaderView extends StatefulWidget {
  final Book book;
  final Uint8List? initialBytes;
  
  const ReaderView({Key? key, required this.book, this.initialBytes}) : super(key: key);

  @override
  ReaderViewState createState() => ReaderViewState();
}

class ReaderViewState extends State<ReaderView> {
  bool _showAIPanel = false;
  final TextEditingController _questionController = TextEditingController();
  bool _companionMode = false;
  String _aiResponse = '';
  bool _isLoading = false;
  EpubController? _epubController;
  late PdfViewerController _pdfController;
  String _bookContent = '';
  int _currentPosition = 0;
  Future<Uint8List?>? _pdfBytesFuture;
  bool _pdfLoadError = false;
  String _pdfErrorMessage = '';

  // 阅读设置（简单实现）
  double _fontScale = 1.0; // 0.8 ~ 1.8
  Color _bgColor = const Color(0xFFF8F4E8); // 默认米黄色护眼色
  Color _textColor = const Color(0xFF111111); // 文本颜色（受夜间模式影响）
  bool _isDarkMode = false; // 夜间模式
  Color _lastLightBgColor = const Color(0xFFF8F4E8); // 记录夜间模式关闭时的背景色
  bool _autoFlip = false; // 仅对 PDF 支持自动翻页
  int _autoFlipSeconds = 10; // 自动翻页间隔秒
  Timer? _autoFlipTimer;
  double _pdfZoom = 1.0; // PDF 缩放级别
  Future<String>? _txtFuture; // TXT 文本 Future
  String _txtContent = '';
  String? _selectedSnippet;

  @override
  void initState() {
    super.initState();
    _pdfController = PdfViewerController();
    _loadReaderSettings();
    _loadBook();
  }

  Future<Uint8List?> _getBookBytes() async {
    final bs = Provider.of<BookService>(context, listen: false);
    return bs.getBookBytes(widget.book);
  }

  Future<void> _loadBook() async {
    final aiService = Provider.of<AIService>(context, listen: false);
    if (widget.book.fileType == 'epub') {
      final bytes = widget.initialBytes ?? await _getBookBytes();
      if (bytes != null) {
        setState(() {
          _epubController = EpubController(
            document: EpubDocument.openData(bytes),
          );
        });
      }
      _bookContent = '这是EPUB书籍的内容示例。这只是一个模拟，实际应用中会从EPUB文件中提取真实内容。';
      _currentPosition = widget.book.lastPosition;
      aiService.setBookContext(widget.book.id, _bookContent, _currentPosition);
    } else if (widget.book.fileType == 'pdf') {
      setState(() {
        _pdfBytesFuture = widget.initialBytes != null ? Future.value(widget.initialBytes) : _getBookBytes();
      });
    } else if (_isTextLike(widget.book.fileType)) {
      setState(() {
        _txtFuture = _loadTextByType(widget.book.fileType, initial: widget.initialBytes);
      });
      _txtFuture?.then((value) {
        _txtContent = value;
        aiService.setBookContext(widget.book.id, _txtContent, _currentPosition);
      });
    }
  }

  bool _isTextLike(String t) {
    switch (t) {
      case 'txt':
      case 'md':
      case 'html':
      case 'htm':
      case 'docx':
      case 'rtf':
        return true;
      default:
        return false;
    }
  }

  Future<String> _loadTextByType(String type, {Uint8List? initial}) async {
    final bytes = initial ?? await _getBookBytes();
    if (bytes == null || bytes.isEmpty) return '';
    switch (type) {
      case 'txt':
        return _decodeTxt(bytes);
      case 'md':
        return _decodeMarkdownToPlain(bytes);
      case 'html':
      case 'htm':
        return _decodeHtmlToPlain(bytes);
      case 'docx':
        return _extractDocxText(bytes);
      case 'rtf':
        return _decodeRtfToPlain(bytes);
      default:
        return _decodeTxt(bytes);
    }
  }

  String _decodeTxt(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return latin1.decode(bytes);
      } catch (_) {
        return String.fromCharCodes(bytes);
      }
    }
  }

  String _decodeMarkdownToPlain(Uint8List bytes) {
    var s = _decodeTxt(bytes);
    // Remove code fences
    s = s.replaceAll(RegExp(r"```[\s\S]*?```"), '\n');
    // Inline code
    s = s.replaceAll(RegExp(r"`([^`]*)"), r"$1");
    // Headers
    s = s.replaceAll(RegExp(r"^\s{0,3}#{1,6}\s*", multiLine: true), '');
    // Bold/italic markers
    s = s.replaceAll(RegExp(r"[*_]{1,3}"), '');
    // Links: [text](url)
    s = s.replaceAllMapped(RegExp(r"\[([^\]]+)\]\(([^)]+)\)"), (m) => "${m[1]} (${m[2]})");
    // Images: ![alt](url)
    s = s.replaceAllMapped(RegExp(r"!\[([^\]]*)\]\(([^)]+)\)"), (m) => "[图片] ${m[1]} (${m[2]})");
    // Lists
    s = s.replaceAll(RegExp(r"^\s*[-*+]\s+", multiLine: true), '• ');
    s = s.replaceAll(RegExp(r"^\s*\d+\.\s+", multiLine: true), '• ');
    // Horizontal rules
    s = s.replaceAll(RegExp(r"^\s*([-*_]){3,}\s*$", multiLine: true), '\n');
    return s.trim();
  }

  String _decodeHtmlToPlain(Uint8List bytes) {
    var s = _decodeTxt(bytes);
    // Remove script/style blocks
    s = s.replaceAll(RegExp(r"<script[\s\S]*?</script>", caseSensitive: false), '');
    s = s.replaceAll(RegExp(r"<style[\s\S]*?</style>", caseSensitive: false), '');
    // Line breaks
    s = s.replaceAll(RegExp(r"<(br|BR)\s*/?>"), '\n');
    s = s.replaceAll(RegExp(r"</p>", caseSensitive: false), '\n');
    // Strip tags
    s = s.replaceAll(RegExp(r"<[^>]+>"), '');
    // Basic entities
    s = s.replaceAll('&nbsp;', ' ')
         .replaceAll('&amp;', '&')
         .replaceAll('&lt;', '<')
         .replaceAll('&gt;', '>')
         .replaceAll('&quot;', '"')
         .replaceAll('&apos;', "'");
    return s.trim();
  }

  String _extractDocxText(Uint8List bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final doc = archive.files.firstWhere(
        (f) => f.name == 'word/document.xml',
        orElse: () => ArchiveFile('none', 0, null),
      );
      if (doc.content == null) return '';
      final xml = utf8.decode((doc.content as List<int>));
      final paragraphs = xml.split('</w:p>');
      final buffer = StringBuffer();
      final tRegex = RegExp(r"<w:t[^>]*>([\s\S]*?)</w:t>");
      for (final p in paragraphs) {
        final matches = tRegex.allMatches(p);
        if (matches.isEmpty) continue;
        for (final m in matches) {
          var text = m.group(1) ?? '';
          text = text.replaceAll('&amp;', '&').replaceAll('&lt;', '<').replaceAll('&gt;', '>')
                     .replaceAll('&quot;', '"').replaceAll('&apos;', "'");
          buffer.write(text);
        }
        buffer.writeln();
      }
      return buffer.toString().trim();
    } catch (_) {
      return '';
    }
  }

  String _decodeRtfToPlain(Uint8List bytes) {
    var s = latin1.decode(bytes, allowInvalid: true);
    // Convert hex escapes \'hh
    s = s.replaceAllMapped(RegExp(r"\\'([0-9a-fA-F]{2})"), (m) {
      final code = int.parse(m.group(1)!, radix: 16);
      return String.fromCharCode(code);
    });
    // Paragraphs
    s = s.replaceAll(RegExp(r"\\par"), '\n');
    // Remove control words and symbols
    s = s.replaceAll(RegExp(r"\\[a-zA-Z]+\d* ?"), '');
    // Remove groups
    s = s.replaceAll('{', '').replaceAll('}', '');
    return s.trim();
  }

  void _startAutoFlipIfNeeded() {
    _autoFlipTimer?.cancel();
    if (_autoFlip && widget.book.fileType == 'pdf') {
      _autoFlipTimer = Timer.periodic(Duration(seconds: _autoFlipSeconds), (_) {
        // 简单的自动翻页逻辑：PDF 调用 nextPage
        _pdfController.nextPage();
      });
    }
  }

  @override
  void dispose() {
    _autoFlipTimer?.cancel();
    _questionController.dispose();
    _pdfController.dispose();
    super.dispose();
  }

  Future<void> _loadReaderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final fontScale = prefs.getDouble('reader_font_scale');
    final bgColorInt = prefs.getInt('reader_bg_color');
    final darkMode = prefs.getBool('reader_dark_mode');
    final autoFlip = prefs.getBool('reader_auto_flip');
    final autoFlipSecs = prefs.getInt('reader_auto_flip_secs');

    setState(() {
      if (fontScale != null) _fontScale = fontScale;
      if (bgColorInt != null) {
        _lastLightBgColor = Color(bgColorInt);
        _bgColor = _lastLightBgColor;
      }
      _isDarkMode = darkMode ?? false;
      if (_isDarkMode) {
        _bgColor = Colors.black;
        _textColor = Colors.white;
      } else {
        _textColor = const Color(0xFF111111);
      }
      _autoFlip = autoFlip ?? false;
      _autoFlipSeconds = autoFlipSecs ?? 10;
    });
  }

  Future<void> _saveReaderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reader_font_scale', _fontScale);
    await prefs.setBool('reader_dark_mode', _isDarkMode);
    await prefs.setInt('reader_bg_color', _lastLightBgColor.toARGB32());
    await prefs.setBool('reader_auto_flip', _autoFlip);
    await prefs.setInt('reader_auto_flip_secs', _autoFlipSeconds);
  }

  

  Future<void> _askQuestion() async {
    if (_questionController.text.isEmpty) return;
    
    setState(() {
      _isLoading = true;
    });
    
    final aiService = Provider.of<AIService>(context, listen: false);
    final auth = Provider.of<AuthService>(context, listen: false);
    final response = await aiService.askQuestion(
      _questionController.text,
      companionMode: _companionMode,
      accessToken: auth.accessToken,
    );
    
    setState(() {
      _aiResponse = response;
      _isLoading = false;
    });
  }

  bool _isLikelyPdf(Uint8List bytes) {
    if (bytes.length < 5) return false;
    return bytes[0] == 0x25 && // '%'
        bytes[1] == 0x50 &&    // 'P'
        bytes[2] == 0x44 &&    // 'D'
        bytes[3] == 0x46 &&    // 'F'
        bytes[4] == 0x2D;      // '-'
  }

  @override
  Widget build(BuildContext context) {
    // 根据宽度自适应：窄屏增大阅读区比例、减小 AI 面板占比
    final width = MediaQuery.of(context).size.width;
    final readerFlex = width >= 1000
        ? (_showAIPanel ? 3 : 5)
        : (_showAIPanel ? 5 : 8);
    final aiFlex = width >= 1000 ? 2 : 3;
  
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          IconButton(
            icon: Icon(_showAIPanel ? Icons.close : Icons.chat),
            onPressed: () {
              setState(() {
                _showAIPanel = !_showAIPanel;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '阅读设置',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                showDragHandle: true,
                builder: (ctx) {
                  return StatefulBuilder(
                    builder: (ctx, sheetSetState) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('字体大小'),
                            Slider(
                              value: _fontScale,
                              min: 0.8,
                              max: 1.8,
                              divisions: 10,
                              label: _fontScale.toStringAsFixed(1),
                              onChanged: (v) {
                                sheetSetState(() {});
                                setState(() => _fontScale = v);
                                _saveReaderSettings();
                              },
                            ),
                            const SizedBox(height: 8),
                            SwitchListTile(
                              title: const Text('夜间模式'),
                              value: _isDarkMode,
                              onChanged: (v) {
                                sheetSetState(() {});
                                setState(() {
                                  _isDarkMode = v;
                                  if (_isDarkMode) {
                                    _textColor = Colors.white;
                                    _bgColor = Colors.black;
                                  } else {
                                    _textColor = const Color(0xFF111111);
                                    _bgColor = _lastLightBgColor;
                                  }
                                  _saveReaderSettings();
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            const Text('背景颜色'),
                            IgnorePointer(
                              ignoring: _isDarkMode,
                              child: Opacity(
                                opacity: _isDarkMode ? 0.5 : 1.0,
                                child: Wrap(
                                  spacing: 8,
                                  children: [
                                    _ColorChip(
                                      color: const Color(0xFFF8F4E8),
                                      selected: _bgColor.toARGB32() == const Color(0xFFF8F4E8).toARGB32() && !_isDarkMode,
                                      onTap: () {
                                        sheetSetState(() {});
                                        setState(() {
                                          _bgColor = const Color(0xFFF8F4E8);
                                          _lastLightBgColor = _bgColor;
                                          _saveReaderSettings();
                                        });
                                      },
                                    ),
                                    _ColorChip(
                                      color: Colors.white,
                                      selected: _bgColor == Colors.white && !_isDarkMode,
                                      onTap: () {
                                        sheetSetState(() {});
                                        setState(() {
                                          _bgColor = Colors.white;
                                          _lastLightBgColor = _bgColor;
                                          _saveReaderSettings();
                                        });
                                      },
                                    ),
                                    _ColorChip(
                                      color: const Color(0xFFEFEFEF),
                                      selected: _bgColor.toARGB32() == const Color(0xFFEFEFEF).toARGB32() && !_isDarkMode,
                                      onTap: () {
                                        sheetSetState(() {});
                                        setState(() {
                                          _bgColor = const Color(0xFFEFEFEF);
                                          _lastLightBgColor = _bgColor;
                                          _saveReaderSettings();
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (widget.book.fileType == 'pdf') ...[
                              const Text('PDF 缩放'),
                              Slider(
                                value: _pdfZoom,
                                min: 0.8,
                                max: 3.0,
                                divisions: 11,
                                label: _pdfZoom.toStringAsFixed(1),
                                onChanged: (v) {
                                  sheetSetState(() {});
                                  setState(() {
                                    _pdfZoom = double.parse(v.toStringAsFixed(1));
                                    _pdfController.zoomLevel = _pdfZoom;
                                  });
                                },
                              ),
                            ],
                            const SizedBox(height: 8),
                            SwitchListTile(
                              title: const Text('自动翻页（仅PDF）'),
                              value: _autoFlip,
                              onChanged: (v) {
                                sheetSetState(() {});
                                setState(() {
                                  _autoFlip = v;
                                  _startAutoFlipIfNeeded();
                                  _saveReaderSettings();
                                });
                              },
                            ),
                            if (_autoFlip) ...[
                              const Text('自动翻页间隔（秒）'),
                              Slider(
                                value: _autoFlipSeconds.toDouble(),
                                min: 3,
                                max: 60,
                                divisions: 19,
                                label: _autoFlipSeconds.toString(),
                                onChanged: (v) {
                                  sheetSetState(() {});
                                  setState(() {
                                    _autoFlipSeconds = v.round();
                                    _startAutoFlipIfNeeded();
                                    _saveReaderSettings();
                                  });
                                },
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
      body: Row(
        children: [
          // 阅读区域（自适应 flex）
          Expanded(
            flex: readerFlex,
              child: Container(
              color: _bgColor,
              child: widget.book.fileType == 'epub'
                  ? _epubController == null
                      ? const Center(child: CircularProgressIndicator())
                      : Theme(
                          data: Theme.of(context).copyWith(
                            textTheme: Theme.of(context).textTheme.apply(
                                  bodyColor: _isDarkMode ? Colors.white : _textColor,
                                  displayColor: _isDarkMode ? Colors.white : _textColor,
                                ),
                          ),
                          child: MediaQuery(
                            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(_fontScale)),
                            child: DefaultTextStyle.merge(
                              style: TextStyle(
                                color: _isDarkMode ? Colors.white : _textColor,
                              ),
                              child: EpubView(
                                controller: _epubController!,
                                onDocumentLoaded: (document) {
                                  if (widget.book.lastPosition > 0) {
                                    // 实际应用中需要转换位置到EpubCFI格式
                                  }
                                },
                                onChapterChanged: (chapter) {
                                  Provider.of<BookService>(context, listen: false)
                                      .updateReadingProgress(widget.book.id, _currentPosition);
                                },
                              ),
                            ),
                          ),
                        )
                  : widget.book.fileType == 'pdf'
                      ? FutureBuilder<Uint8List?>(
                          future: _pdfBytesFuture ?? _getBookBytes(),
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    'PDF 加载出错：${snapshot.error}',
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                ),
                              );
                            }
                            final data = snapshot.data;
                            if (data == null || data.isEmpty) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            // 简单校验：检查是否以 %PDF- 开头
                            bool isPdf = _isLikelyPdf(data);
                            if (!isPdf) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Text(
                                    '文件不是有效的 PDF（未检测到 %PDF- 头）。',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              );
                            }
                            if (_pdfLoadError) {
                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    _pdfErrorMessage.isEmpty
                                        ? 'PDF 加载失败，请重试或重新导入文件。'
                                        : 'PDF 加载失败：$_pdfErrorMessage',
                                    style: const TextStyle(color: Colors.red),
                                  ),
                                ),
                              );
                            }
                            _startAutoFlipIfNeeded();
                            return SfPdfViewer.memory(
                              data,
                              controller: _pdfController,
                              key: ValueKey('pdf_${widget.book.id}_zoom_${_pdfZoom.toStringAsFixed(1)}_${data.length}'),
                              onPageChanged: (details) {
                                Provider.of<BookService>(context, listen: false)
                                    .updateReadingProgress(widget.book.id, details.newPageNumber);
                              },
                              onDocumentLoaded: (details) {
                                // 恢复缩放和上次页码（如果有）
                                _pdfController.zoomLevel = _pdfZoom;
                                final last = widget.book.lastPosition;
                                if (last > 0 && last <= details.document.pages.count) {
                                  _pdfController.jumpToPage(last);
                                }
                              },
                              onDocumentLoadFailed: (details) {
                                setState(() {
                                  _pdfLoadError = true;
                                  _pdfErrorMessage = '${details.error}: ${details.description}';
                                });
                              },
                              onTextSelectionChanged: (details) {
                                setState(() {
                                  _selectedSnippet = details.selectedText;
                                });
                              },
                            );
                          },
                        )
                      : FutureBuilder<String>(
                          future: _txtFuture ?? _loadTextByType(widget.book.fileType),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) {
                              return const Center(child: CircularProgressIndicator());
                            }
                            final content = snapshot.data ?? '';
                            return MediaQuery(
                              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(_fontScale)),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: SelectableText(
                                  content.isEmpty ? '空文本或解析失败' : content,
                                  style: TextStyle(color: _isDarkMode ? Colors.white : _textColor),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ),
          
          // AI助手面板（自适应 flex）
          if (_showAIPanel)
            Expanded(
              flex: aiFlex,
              child: Container(
                color: Colors.grey[100],
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text(
                      'AI阅读助手',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('伴读模式'),
                      subtitle: const Text('AI只考虑您当前阅读位置之前的内容'),
                      value: _companionMode,
                      onChanged: (value) {
                        setState(() {
                          _companionMode = value;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _questionController,
                      decoration: const InputDecoration(
                        labelText: '向AI提问',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () async {
                            String? text = _selectedSnippet;
                            text ??= await sel.getSelectedText();
                            if (!mounted) return;
                            if (!context.mounted) return;
                            if (text != null && text.trim().isNotEmpty) {
                              setState(() {
                                _questionController.text = text!;
                              });
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('未检测到选中文字，请先在内容区拖拽选择。')),
                              );
                            }
                          },
                          icon: const Icon(Icons.format_quote),
                          label: const Text('引用选中内容'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: _isLoading ? null : _askQuestion,
                          child: _isLoading
                              ? const CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                )
                              : const Text('提交问题'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: SingleChildScrollView(
                          child: Text(_aiResponse.isEmpty
                              ? '在这里提问关于书籍的问题，或者使用伴读模式获取更有针对性的回答。'
                              : _aiResponse),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// 简易颜色选择组件
class _ColorChip extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorChip({
    Key? key,
    required this.color,
    required this.selected,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Colors.blue : Colors.grey[400]!,
            width: selected ? 2 : 1,
          ),
        ),
      ),
    );
  }
}
