import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/database/app_database.dart';
import '../core/database/transfer_task_entity.dart';
import '../core/transfer/transfer_queue_manager.dart';

final transferQueueManagerProvider = ChangeNotifierProvider<TransferQueueManager>((ref) {
  return TransferQueueManager.instance;
});

final allTasksProvider = FutureProvider.autoDispose<List<TransferTask>>((ref) async {
  // Re-fetch when task list or task statuses change
  ref.watch(transferQueueManagerProvider.select((m) => m.taskListVersion));
  return AppDatabase.instance.getAllTasks();
});

final activeTasksProvider = FutureProvider.autoDispose<List<TransferTask>>((ref) async {
  ref.watch(transferQueueManagerProvider.select((m) => m.taskListVersion));
  return AppDatabase.instance.getActiveAndPendingTasks();
});
