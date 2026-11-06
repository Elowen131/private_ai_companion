// 集成测试公共设施：用 sqflite_common_ffi 跑「真 SQLite」，而不是 stub。
// 文件名不以 _test.dart 结尾，只被 import，不会被当作测试套件执行。

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/schema.dart';

bool _ffiReady = false;

void initFfi() {
  if (_ffiReady) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  _ffiReady = true;
}

/// 每套用例用独立临时目录，绝不互相污染。
Future<Directory> tempDir(String tag) =>
    Directory.systemTemp.createTemp('aic_db_$tag');

Future<String> tempDbPath(String tag) async =>
    p.join((await tempDir(tag)).path, 'companion.db');

AppDatabase dbAt(String path) => AppDatabase(pathResolver: () async => path);

/// 构造「老设备」的 v1 数据库并写入真实业务数据，随后关闭。
Future<void> createV1WithData(String path) async {
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: dbVersionV1,
      onCreate: (d, _) async {
        for (final stmt in schemaV1Statements) {
          await d.execute(stmt);
        }
      },
    ),
  );
  await db.insert('user', {
    'id': 'u_local',
    'nickname': '本机用户',
  });
  await db.insert('persona', {
    'id': 'p_legacy',
    'name': '岑攸珩',
    'age': 19,
    'created_at': 1000,
    'updated_at': 1000,
  });
  await db.insert('conversation', {
    'id': 'c_legacy',
    'type': 'single',
    'title': '旧会话',
    'created_at': 1000,
    'updated_at': 1000,
  });
  await db.insert('message', {
    'id': 'm_legacy',
    'conversation_id': 'c_legacy',
    'sender_id': 'u_local',
    'sender_type': 'user',
    'content': '雨夜来客，门被敲响了',
    'turn_id': 1,
    'created_at': 1000,
    'updated_at': 1000,
  });
  await db.insert('important_memory', {
    'id': 'mem_legacy',
    'persona_id': 'p_legacy',
    'content': '用户喜欢热可可',
    'weight': 1.0,
    'created_at': 1000,
  });
  await db.close();
}

/// 生成一条最小但字段完整的消息（v1 表结构）。
Map<String, dynamic> messageRow(
  String id, {
  String conversationId = 'c1',
  String content = '测试消息',
  int createdAt = 2000,
}) =>
    {
      'id': id,
      'conversation_id': conversationId,
      'sender_id': 'u1',
      'sender_type': 'user',
      'content': content,
      'turn_id': 1,
      'is_deleted': 0,
      'recalled': 0,
      'created_at': createdAt,
      'updated_at': createdAt,
    };
