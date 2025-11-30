class Book {
  final String id;
  final String title;
  final String author;
  final String coverUrl;
  final String filePath;
  final String fileType; // epub, pdf
  final String? bytesBase64; // 新增：存文件内容的Base64
  int lastPosition;
  DateTime lastReadTime;

  Book({
    required this.id,
    required this.title,
    required this.author,
    this.coverUrl = '',
    required this.filePath,
    required this.fileType,
    this.bytesBase64,
    this.lastPosition = 0,
    DateTime? lastReadTime,
  }) : lastReadTime = lastReadTime ?? DateTime.now();

  factory Book.fromJson(Map<String, dynamic> json) {
    return Book(
      id: json['id'] as String,
      title: json['title'] as String,
      author: json['author'] as String,
      coverUrl: json['coverUrl'] as String? ?? '',
      filePath: json['filePath'] as String,
      fileType: json['fileType'] as String,
      bytesBase64: json['bytesBase64'] as String?, // 新增
      lastPosition: json['lastPosition'] as int? ?? 0,
      lastReadTime: DateTime.parse(json['lastReadTime'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'coverUrl': coverUrl,
      'filePath': filePath,
      'fileType': fileType,
      'bytesBase64': bytesBase64, // 新增
      'lastPosition': lastPosition,
      'lastReadTime': lastReadTime.toIso8601String(),
    };
  }
}