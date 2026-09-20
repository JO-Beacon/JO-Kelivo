import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/services/mcp/workspace_stdio_command.dart';
import 'package:Kelivo/core/services/workspace/workspace_runtime.dart';
import '../../../support/fake_workspace_runtime.dart';

void main() {
  for (final command in ['npx', 'uvx']) {
    test(
      'missing $command reports installation guidance before opening stdin',
      () async {
        final runtime = FakeWorkspaceRuntime()
          ..enqueueNext([
            const CommandExited(
              exitCode: 1,
              timedOut: false,
              cancelled: false,
              interrupted: false,
              duration: Duration.zero,
            ),
          ]);
        await expectLater(
          requireWorkspaceStdioCommand(
            runtime: runtime,
            command: command,
            cwd: '/root',
            environment: const {},
            timeout: const Duration(seconds: 1),
            isCancelled: () => false,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              allOf(contains(command), contains('Install')),
            ),
          ),
        );
        expect(runtime.requests.single.keepStdinOpen, isFalse);
      },
    );
  }
  test('probe uses the same guest cwd and overridden environment', () async {
    final runtime = FakeWorkspaceRuntime();
    await requireWorkspaceStdioCommand(
      runtime: runtime,
      command: '/my tools/node',
      cwd: '/root',
      environment: const {'PATH': '/custom/bin'},
      timeout: const Duration(seconds: 1),
      isCancelled: () => false,
    );
    expect(runtime.requests.single.env, {'PATH': '/custom/bin'});
    expect(
      runtime.requests.single.command,
      "command -v '/my tools/node' >/dev/null 2>&1",
    );
  });
  test('空命令在启动前拒绝', () async {
    final runtime = FakeWorkspaceRuntime();
    await expectLater(
      requireWorkspaceStdioCommand(
        runtime: runtime,
        command: '  ',
        cwd: '/root',
        environment: const {},
        timeout: const Duration(seconds: 1),
        isCancelled: () => false,
      ),
      throwsStateError,
    );
    expect(runtime.requests, isEmpty);
  });

  test('取消探测不继续启动服务器', () async {
    final runtime = FakeWorkspaceRuntime();
    await expectLater(
      requireWorkspaceStdioCommand(
        runtime: runtime,
        command: 'node',
        cwd: '/root',
        environment: const {},
        timeout: const Duration(seconds: 1),
        isCancelled: () => true,
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cancelled'),
        ),
      ),
    );
    expect(runtime.requests.single.keepStdinOpen, isFalse);
  });

  test('探测超时会等待取消，不误报命令未安装', () async {
    final runtime = _StalledProbeRuntime();
    await expectLater(
      requireWorkspaceStdioCommand(
        runtime: runtime,
        command: 'node',
        cwd: '/root',
        environment: const {},
        timeout: const Duration(milliseconds: 10),
        isCancelled: () => false,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(runtime.cancelled, isTrue);
  });

  for (final events in <List<CommandEvent>>[
    [],
    [
      const CommandExited(
        exitCode: 2,
        timedOut: false,
        cancelled: false,
        interrupted: false,
        duration: Duration.zero,
      ),
    ],
    [
      const CommandExited(
        exitCode: 1,
        timedOut: true,
        cancelled: false,
        interrupted: false,
        duration: Duration.zero,
      ),
    ],
  ]) {
    test('探测异常退出不误报命令未安装：$events', () async {
      final runtime = FakeWorkspaceRuntime()..enqueueNext(events);
      await expectLater(
        requireWorkspaceStdioCommand(
          runtime: runtime,
          command: 'node',
          cwd: '/root',
          environment: const {},
          timeout: const Duration(seconds: 1),
          isCancelled: () => false,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Could not check'),
          ),
        ),
      );
    });
  }
}

class _StalledProbeRuntime extends FakeWorkspaceRuntime {
  final events = StreamController<CommandEvent>();
  bool cancelled = false;
  @override
  Stream<CommandEvent> run(CommandRequest request) {
    requests.add(request);
    return events.stream;
  }

  @override
  Future<void> cancel(String runId) async {
    await events.close();
    cancelled = true;
  }
}
