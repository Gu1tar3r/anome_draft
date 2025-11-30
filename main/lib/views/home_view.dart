import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../models/book.dart';
import '../services/auth_service.dart';
import '../services/book_service.dart';
import 'reader_view.dart';

class HomeView extends StatefulWidget {
  const HomeView({Key? key}) : super(key: key);

  @override
  _HomeViewState createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  // 底部导航索引
  int _currentIndex = 0;

  // 首页轮播相关
  final PageController _carouselController = PageController();
  Timer? _carouselTimer;
  int _carouselPage = 0;
  final List<String> _carouselImages = const [
    // 使用网络占位图，后续可替换为本地 assets 图片
    'https://picsum.photos/id/1015/1200/400',
    'https://picsum.photos/id/1043/1200/400',
  ];

  // 记录已通过悬停预取的书籍，避免重复预取（用于书架页）
  final Set<String> _hoverPrefetched = {};
  @override
  void initState() {
    super.initState();
    // 初始化书籍数据
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bs = Provider.of<BookService>(context, listen: false);
      bs.init().then((_) {
        _prefetchMostRecent(bs);
      });
    });

    // 启动首页轮播自动滚动
    _carouselTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      _carouselPage = (_carouselPage + 1) % _carouselImages.length;
      _carouselController.animateToPage(
        _carouselPage,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
    });
  }

  // 后台预取最近阅读的一本书籍，提升“点击即开”速度
  void _prefetchMostRecent(BookService bs) {
    if (bs.books.isEmpty) return;
    final sorted = [...bs.books];
    sorted.sort((a, b) => b.lastReadTime.compareTo(a.lastReadTime));
    final recent = sorted.first;
    bs.getBookBytes(recent);
  }

  // 鼠标悬停卡片时预取该书籍字节（Web/桌面生效）
  void _prefetchOnHover(Book book) {
    if (_hoverPrefetched.add(book.id)) {
      final bs = Provider.of<BookService>(context, listen: false);
      bs.getBookBytes(book);
    }
  }

  @override
  void dispose() {
    _carouselTimer?.cancel();
    _carouselController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final bookService = Provider.of<BookService>(context);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle(_currentIndex)),
        actions: [
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            onPressed: () => authService.logout(),
            tooltip: '退出登录',
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildHomeTab(context),
          _buildBookshelfTab(context, bookService),
          _buildInterpretationTab(context),
          _buildBlogTab(context),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (idx) => setState(() => _currentIndex = idx),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: '首页'),
          BottomNavigationBarItem(icon: Icon(Icons.book), label: '书架'),
          BottomNavigationBarItem(icon: Icon(Icons.psychology), label: '书籍AI解读'),
          BottomNavigationBarItem(icon: Icon(Icons.article), label: 'AI书籍博客'),
        ],
      ),
      floatingActionButton: _currentIndex == 1
          ? FloatingActionButton(
              onPressed: () async {
                final bs = Provider.of<BookService>(context, listen: false);
                // 显示导入进度弹窗
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (ctx) {
                    return AlertDialog(
                      title: const Text('正在导入书籍'),
                      content: Consumer<BookService>(
                        builder: (_, svc, __) {
                          final percent = (svc.importProgress * 100).clamp(0, 100).toStringAsFixed(0);
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              LinearProgressIndicator(value: svc.importProgress),
                              const SizedBox(height: 12),
                              Text('进度：$percent%'),
                            ],
                          );
                        },
                      ),
                    );
                  },
                );

                final book = await bs.importBook();

                if (mounted) {
                  Navigator.of(context, rootNavigator: true).pop(); // 关闭弹窗
                }

                if (book != null && mounted) {
                  final bytes = await bs.getBookBytes(book);
                  if (!mounted) return;
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ReaderView(book: book, initialBytes: bytes),
                    ),
                  );
                }
              },
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  String _appBarTitle(int idx) {
    switch (idx) {
      case 0:
        return '首页';
      case 1:
        return '我的书架';
      case 2:
        return '书籍AI解读';
      case 3:
        return 'AI书籍博客';
      default:
        return 'AI阅读助手';
    }
  }

  Widget _buildHomeTab(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部静谧图片轮播
          SizedBox(
            height: 180,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                PageView.builder(
                  controller: _carouselController,
                  itemCount: _carouselImages.length,
                  onPageChanged: (i) => setState(() => _carouselPage = i),
                  itemBuilder: (ctx, i) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          _carouselImages[i],
                          fit: BoxFit.cover,
                          width: double.infinity,
                        ),
                      ),
                    );
                  },
                ),
                // 简单圆点指示器
                Positioned(
                  bottom: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_carouselImages.length, (i) {
                      final active = i == _carouselPage;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: active ? 10 : 8,
                        height: active ? 10 : 8,
                        decoration: BoxDecoration(
                          color: active ? Colors.white : Colors.white70,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: const [
                            BoxShadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1)),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 简单欢迎与提示文案
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  '欢迎开始今日阅读',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 6),
                Text(
                  '保持专注，享受宁静的阅读时光。',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildBookshelfTab(BuildContext context, BookService bookService) {
    if (bookService.books.isEmpty) {
      return const Center(
        child: Text('您的书架还是空的，点击右下角按钮导入书籍'),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.7,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: bookService.books.length,
      itemBuilder: (context, index) {
        final book = bookService.books[index];
        return MouseRegion(
          onEnter: (_) => _prefetchOnHover(book),
          child: GestureDetector(
            onTap: () async {
              // 进入阅读页前预取字节，减少打开等待
              final bs = Provider.of<BookService>(context, listen: false);
              final bytes = await bs.getBookBytes(book);
              if (!mounted) return;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ReaderView(book: book, initialBytes: bytes),
                ),
              );
            },
            child: Card(
              elevation: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      color: Colors.grey[300],
                      child: Center(
                        child: Text(
                          (book.title.isNotEmpty
                              ? book.title.substring(0, 1).toUpperCase()
                              : '?'),
                          style: const TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          book.author,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '上次阅读: ${book.lastReadTime.year}/${book.lastReadTime.month}/${book.lastReadTime.day}',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInterpretationTab(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.psychology, size: 48, color: Colors.blueAccent),
            SizedBox(height: 12),
            Text(
              '书籍AI解读',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              '敬请期待：为您生成高质量的书籍要点、结构化解读与阅读建议。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlogTab(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.article, size: 48, color: Colors.deepOrange),
            SizedBox(height: 12),
            Text(
              'AI书籍博客',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              '敬请期待：结合AI生成书评、读书笔记与主题博客内容。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
