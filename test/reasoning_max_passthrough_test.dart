import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/api/chat_api_helpers.dart';
import 'package:Kelivo/core/services/api/providers/openai/openai_vendor_compat.dart';
import 'package:Kelivo/core/utils/openai_model_compat.dart';

/// max 档位改为“常显 + 原样发送”。
///
/// 以前选了 max，若模型表里没有 max，会被静默降级成 xhigh/high，界面显示的和
/// 实际发出的不一致。现在原样发出，供应商不接受就由供应商报错（HTTP 400 的
/// 响应体会原样进异常消息）。
void main() {
  test('预算到 max 档就发 max，不再按表降级', () {
    // gpt-5.1-codex-max 名字带 max，但表里恰好没有 max 档。
    expect(openAIEffortForBudget(128000, 'gpt-5.1-codex-max'), 'max');
    expect(openAIEffortForBudget(128000, 'grok-4.6'), 'max');
    // 未知模型也不再被降成 high。
    expect(openAIEffortForBudget(128000, 'totally-unknown-model'), 'max');
    expect(openAINormalizeReasoningEffort('max', 'grok-4.6'), 'max');
  });

  test('xhigh 也原样发送，不再按表降级', () {
    // 入口常显 + 发送原样：表里没有 xhigh 的模型也能选，且发出去就是 xhigh。
    expect(openAIEffortForBudget(64000, 'gpt-5.1-codex-max'), 'xhigh');
    expect(
      openAINormalizeReasoningEffort('xhigh', 'totally-unknown-model'),
      'xhigh',
    );
    expect(openAINormalizeReasoningEffort('xhigh', 'grok-4.5'), 'xhigh');
  });

  test('模型声明完全不接受档位参数时仍走自动', () {
    // Kimi Code 高速版：协议上就不带档位参数，发过去只会让普通对话也失败。
    expect(
      openAINormalizeReasoningEffort('max', 'kimi-for-coding-highspeed'),
      'auto',
    );
  });

  test('Claude 自适应模型选了 max 就发 max', () {
    // 注：Claude 侧那条“max 降级成 xhigh/high”的回退实际上不可达——
    // 能走到档位分支的模型（自适应/常开）在本地表里都已经含 max。改掉它是
    // 为了与“max 不降级”这条规则保持一致，不留下一个看着像能降级的陷阱。
    expect(claudeOutputConfig('claude-opus-4-6', 128000), {'effort': 'max'});
    expect(claudeOutputConfig('claude-fable-5', 128000), {'effort': 'max'});
  });
}
