import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'transfer_task_entity.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._();
  AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  @visibleForTesting
  Future<void> initInMemoryForTest() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await _db?.close();
    _db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE transfer_tasks (
        id TEXT PRIMARY KEY,
        group_id TEXT,
        provider_type TEXT NOT NULL,
        source_account_id TEXT NOT NULL,
        dest_account_id TEXT NOT NULL,
        task_type TEXT NOT NULL,
        file_name TEXT NOT NULL,
        source_path TEXT NOT NULL,
        destination_path TEXT NOT NULL,
        total_bytes INTEGER NOT NULL DEFAULT 0,
        transferred_bytes INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        error_message TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_tasks_status ON transfer_tasks (status, created_at)
    ''');
  }

  Future<Database> _initDb() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await _getDatabasePath();
    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<String> _getDatabasePath() async {
    if (!kIsWeb && Platform.isWindows) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(appDocDir.path, 'unified_cloud_manager'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return p.join(dir.path, 'unified_transfers.db');
    }
    final defaultPath = await getDatabasesPath();
    return p.join(defaultPath, 'unified_transfers.db');
  }

  // --- Task CRUD Operations ---

  Future<void> insertTask(TransferTask task) async {
    final db = await database;
    await db.insert('transfer_tasks', task.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertTasksBatch(List<TransferTask> tasks) async {
    final db = await database;
    final batch = db.batch();
    for (final task in tasks) {
      batch.insert('transfer_tasks', task.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateTaskProgress({
    required String id,
    required int transferredBytes,
    required int totalBytes,
    required TransferStatus status,
    String? errorMessage,
  }) async {
    final db = await database;
    await db.update(
      'transfer_tasks',
      {
        'transferred_bytes': transferredBytes,
        'total_bytes': totalBytes,
        'status': status.name,
        'error_message': errorMessage,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> updateTaskStatus(String id, TransferStatus status, {String? errorMessage, int? retryCount}) async {
    final db = await database;
    final values = <String, dynamic>{
      'status': status.name,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (errorMessage != null) values['error_message'] = errorMessage;
    if (retryCount != null) values['retry_count'] = retryCount;

    await db.update('transfer_tasks', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<TransferTask>> getAllTasks() async {
    final db = await database;
    final list = await db.query('transfer_tasks', orderBy: 'created_at DESC');
    return list.map((m) => TransferTask.fromMap(m)).toList();
  }

  Future<List<TransferTask>> getActiveAndPendingTasks() async {
    final db = await database;
    final list = await db.query(
      'transfer_tasks',
      where: 'status IN (?, ?)',
      whereArgs: [TransferStatus.pending.name, TransferStatus.active.name],
      orderBy: 'created_at ASC',
    );
    return list.map((m) => TransferTask.fromMap(m)).toList();
  }

  Future<TransferTask?> getNextPendingTask() async {
    final db = await database;
    final list = await db.query(
      'transfer_tasks',
      where: 'status = ?',
      whereArgs: [TransferStatus.pending.name],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (list.isEmpty) return null;
    return TransferTask.fromMap(list.first);
  }

  Future<int> resetInterruptedActiveTasks() async {
    final db = await database;
    return await db.update(
      'transfer_tasks',
      {'status': TransferStatus.pending.name, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'status = ?',
      whereArgs: [TransferStatus.active.name],
    );
  }

  Future<void> deleteTask(String id) async {
    final db = await database;
    await db.delete('transfer_tasks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearCompletedTasks() async {
    final db = await database;
    await db.delete(
      'transfer_tasks',
      where: 'status IN (?, ?)',
      whereArgs: [TransferStatus.completed.name, TransferStatus.failed.name],
    );
  }

  Future<void> cancelIncompleteTasks() async {
    final db = await database;
    await db.delete(
      'transfer_tasks',
      where: 'status IN (?, ?, ?)',
      whereArgs: [
        TransferStatus.pending.name,
        TransferStatus.active.name,
        TransferStatus.paused.name,
      ],
    );
  }
}
