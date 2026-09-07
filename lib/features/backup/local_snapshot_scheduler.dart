import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../core/providers/local_snapshot_provider.dart';

class LocalSnapshotScheduler extends StatefulWidget {
  const LocalSnapshotScheduler({super.key, required this.child});
  final Widget child;
  @override
  State<LocalSnapshotScheduler> createState() => _LocalSnapshotSchedulerState();
}

class _LocalSnapshotSchedulerState extends State<LocalSnapshotScheduler>
    with WidgetsBindingObserver {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedule();
    } else {
      _timer?.cancel();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 8), () async {
      if (!mounted) return;
      await context.read<LocalSnapshotProvider>().runIfDue();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
