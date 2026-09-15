import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/chat/widgets/frosted/chat_frosted_backdrop.dart';
import 'package:Kelivo/features/chat/widgets/frosted/frosted_surface.dart';
import 'package:Kelivo/features/chat/widgets/chat_assistant_background.dart';
import 'package:Kelivo/features/chat/widgets/chat_gradient_background.dart';
import 'package:Kelivo/features/home/widgets/chat_input_overlay_layout.dart';
import 'package:Kelivo/theme/chat_bubble_style.dart';

import '../../../../support/business_test_harness.dart';

ResolvedBubbleStyle _style(double sigma) => ResolvedBubbleStyle(
  background: const Color(0xA8FFFFFF),
  border: const Color(0x24FFFFFF),
  text: const Color(0xFF111111),
  borderWidth: 0.8,
  radius: 16,
  blurSigma: sigma,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugFrostedForceLiveBackdropFilter = false;
    debugFrostedForceSnapshotFailure = false;
  });

  testWidgets(
    'gradient without an image uses live glass without capturing frames',
    (tester) async {
      final assistants = AssistantProvider(
        preferences: createBusinessTestPreferences(),
      );
      await assistants.loaded;
      final id = await assistants.addAssistant(name: 'Gradient');
      await assistants.setCurrentAssistant(id);
      final settings = SettingsProvider(createBusinessTestPreferences());
      await settings.loaded;
      addTearDown(assistants.dispose);
      addTearDown(settings.dispose);
      await assistants.updateAssistant(
        assistants.currentAssistant!.copyWith(useGradientBackground: true),
      );
      await tester.pumpWidget(
        _app(
          assistants: assistants,
          settings: settings,
          backdrop: const ChatAssistantBackground(),
          child: Center(
            child: FrostedSurface(
              style: _style(12),
              borderRadius: BorderRadius.circular(16),
              child: const SizedBox(width: 200, height: 100),
            ),
          ),
        ),
      );
      final controller = tester
          .widget<ChatFrostedBackdropScope>(
            find.byType(ChatFrostedBackdropScope),
          )
          .controller;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.mode, FrostedRenderMode.liveBackdropFilter);
        expect(controller.debugCaptureCount, 0);
      }
      expect(_countLayers<BackdropFilterLayer>(tester), greaterThan(0));
      await assistants.updateAssistant(
        assistants.currentAssistant!.copyWith(useGradientBackground: false),
      );
      await tester.pumpAndSettle();
      expect(controller.mode, FrostedRenderMode.uniform);
      expect(_countLayers<BackdropFilterLayer>(tester), 0);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('image snapshots resume after turning the gradient off', (
    tester,
  ) async {
    final assistants = AssistantProvider(
      preferences: createBusinessTestPreferences(),
    );
    await assistants.loaded;
    final id = await assistants.addAssistant(name: 'Gradient');
    await assistants.setCurrentAssistant(id);
    final settings = SettingsProvider(createBusinessTestPreferences());
    await settings.loaded;
    addTearDown(assistants.dispose);
    addTearDown(settings.dispose);
    await assistants.updateAssistant(
      assistants.currentAssistant!.copyWith(
        background: 'https://example.com/wallpaper.png',
      ),
    );
    await tester.pumpWidget(
      _app(
        assistants: assistants,
        settings: settings,
        child: Center(
          child: FrostedSurface(
            style: _style(12),
            borderRadius: BorderRadius.circular(16),
            child: const SizedBox(width: 200, height: 100),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<ChatFrostedBackdropScope>(find.byType(ChatFrostedBackdropScope))
        .controller;
    expect(controller.mode, FrostedRenderMode.cached);
    final captures = controller.debugCaptureCount;
    expect(captures, greaterThan(0));
    await assistants.updateAssistant(
      assistants.currentAssistant!.copyWith(useGradientBackground: true),
    );
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.mode, FrostedRenderMode.liveBackdropFilter);
    expect(controller.debugCaptureCount, captures);
    await assistants.updateAssistant(
      assistants.currentAssistant!.copyWith(useGradientBackground: false),
    );
    await tester.pumpAndSettle();
    expect(controller.mode, FrostedRenderMode.cached);
    expect(controller.debugCaptureCount, greaterThan(captures));
    expect(
      assistants.currentAssistant!.background,
      'https://example.com/wallpaper.png',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final animated in [false, true]) {
    testWidgets(
      'gradient rendering stays bounded during a 2000-message streaming chat: animated=$animated',
      (tester) async {
        final assistants = AssistantProvider(
          preferences: createBusinessTestPreferences(),
        );
        await assistants.loaded;
        final id = await assistants.addAssistant(name: 'Gradient');
        await assistants.setCurrentAssistant(id);
        await assistants.updateAssistant(
          assistants.currentAssistant!.copyWith(
            useGradientBackground: true,
            gradientBackgroundAnimated: animated,
          ),
        );
        final settings = SettingsProvider(createBusinessTestPreferences());
        await settings.loaded;
        final tokens = ValueNotifier<int>(0);
        final scroll = ScrollController();
        addTearDown(assistants.dispose);
        addTearDown(settings.dispose);
        addTearDown(tokens.dispose);
        addTearDown(scroll.dispose);
        debugGradientPictureBuildCount = 0;
        debugGradientShaderBuildCount = 0;
        await tester.pumpWidget(
          _app(
            assistants: assistants,
            settings: settings,
            backdrop: const ChatAssistantBackground(),
            child: ValueListenableBuilder<int>(
              valueListenable: tokens,
              builder: (_, count, child) {
                return ChatInputOverlayLayout(
                  topInset: 80,
                  backgroundImageActive: true,
                  topBackground: const ChatAssistantBackground(
                    pinnedToBackdrop: true,
                  ),
                  bottomOverlay: const SizedBox(height: 60, width: 200),
                  content: ListView.builder(
                    controller: scroll,
                    reverse: true,
                    itemCount: 2000,
                    itemExtent: 80,
                    itemBuilder: (_, index) => FrostedSurface(
                      style: _style(14),
                      borderRadius: BorderRadius.circular(16),
                      child: Text(
                        index == 0 ? 'Streaming $count' : 'Message $index',
                        textDirection: TextDirection.ltr,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final controller = tester
            .widget<ChatFrostedBackdropScope>(
              find.byType(ChatFrostedBackdropScope),
            )
            .controller;
        expect(
          controller.mode,
          animated
              ? FrostedRenderMode.liveBackdropFilter
              : FrostedRenderMode.cached,
        );
        final captures = controller.debugCaptureCount;
        final pictures = debugGradientPictureBuildCount;
        final shaders = debugGradientShaderBuildCount;
        if (!animated) expect(captures, greaterThan(0));
        for (var frame = 0; frame < 120; frame++) {
          tokens.value++;
          if (frame % 10 == 0) scroll.jumpTo(frame * 10.0);
          await tester.pump(const Duration(microseconds: 8333));
        }
        expect(debugGradientShaderBuildCount, shaders);
        expect(
          debugGradientPictureBuildCount - pictures,
          animated ? inInclusiveRange(28, 30) : 0,
        );
        expect(controller.debugCaptureCount, captures);
        if (!animated) {
          expect(_countLayers<BackdropFilterLayer>(tester), 0);
          final generation = controller.generation;
          await assistants.updateAssistant(
            assistants.currentAssistant!.copyWith(
              gradientBackgroundOffsetY: 0.5,
            ),
          );
          await tester.pumpAndSettle();
          expect(controller.generation, greaterThan(generation));
          expect(controller.debugCaptureCount, greaterThan(captures));
          expect(controller.mode, FrostedRenderMode.cached);
          final previousFrameCaptures = controller.debugCaptureCount;
          await assistants.updateAssistant(
            assistants.currentAssistant!.copyWith(gradientBackgroundPhase: 16),
          );
          await tester.pumpAndSettle();
          expect(
            controller.debugCaptureCount,
            greaterThan(previousFrameCaptures),
          );
          expect(controller.mode, FrostedRenderMode.cached);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

Widget _app({
  required AssistantProvider assistants,
  required SettingsProvider settings,
  required Widget child,
  Widget backdrop = const ColoredBox(color: Color(0xFF4D5C92)),
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AssistantProvider>.value(value: assistants),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
    ],
    child: MaterialApp(
      home: ChatFrostedBackdrop(backdrop: backdrop, child: child),
    ),
  );
}

int _countLayers<T extends Layer>(WidgetTester tester) {
  var count = 0;
  void walk(Layer layer) {
    if (layer is T) count++;
    if (layer is ContainerLayer) {
      var child = layer.firstChild;
      while (child != null) {
        walk(child);
        child = child.nextSibling;
      }
    }
  }

  walk(tester.binding.renderViews.first.debugLayer!);
  return count;
}
