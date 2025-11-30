import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'services/auth_service.dart';
import 'services/book_service.dart';
import 'services/ai_service.dart';
import 'views/login_view.dart';
import 'views/home_view.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 创建必要的目录
  if (!kIsWeb) {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${appDir.path}/books');
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }
    } catch (_) {
      // 忽略桌面端目录创建失败，避免阻塞启动
    }
  }
  
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => BookService()),
        ChangeNotifierProvider(create: (_) => AIService()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI阅读助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: FutureBuilder(
        future: Provider.of<AuthService>(context, listen: false).init(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return Consumer<AuthService>(
            builder: (context, authService, _) {
              return authService.isLoggedIn ? const HomeView() : const LoginView();
            },
          );
        },
      ),
    );
  }
}