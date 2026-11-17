import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/database/app_database.dart';
import '../core/database/transfer_task_entity.dart';
import '../core/transfer/transfer_queue_manager.dart';

final _transferQueueTickProvider = StreamProvider<int>((ref) {
  final controller = StreamController<int>();
  int tick = 0;
  void onChanged() {
    if (!controller.isClosed) {
      controller.add(++tick);
    }
  }

  TransferQueueManager.instance.addListener(onChanged);
  ref.onDispose(() {
    TransferQueueManager.instance.removeListener(onChanged);
    controller.close();
  });
  return controller.stream;
});

final transferQueueManagerProvider = Provider<TransferQueueManager>((ref) {
  ref.watch(_transferQueueTickProvider);
  return TransferQueueManager.instance;
});

final allTasksProvider = FutureProvider.autoDispose<List<TransferTask>>((ref) async {
  // Re-fetch when manager notifies
  ref.watch(transferQueueManagerProvider);
  return AppDatabase.instance.getAllTasks();
});

final activeTasksProvider = FutureProvider.autoDispose<List<TransferTask>>((ref) async {
  ref.watch(transferQueueManagerProvider);
  return AppDatabase.instance.getActiveAndPendingTasks();
});
