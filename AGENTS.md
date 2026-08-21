# AGENTS.md

> Kelivo is a cross-platform Flutter LLM chat client (Android / iOS / macOS / Windows / Linux).
> This file defines hard constraints for AI-assisted development. Predictable, auditable, repeatable.

## 1. Repository Facts

- This is a Flutter app repository. Root `pubspec.yaml` declares `sdk: ^3.12.1` and `flutter: >=3.44.1` with `flutter.generate: true`.
- Main code lives in `lib/`, tests in `test/`. Local path dependencies exist:
  - `dependencies/mcp_client`
  - `dependencies/tray_manager/packages/tray_manager`
  - `dependencies/flutter_tts`
  - `dependencies/flutter-permission-handler/permission_handler_windows`
- Localization is driven by `l10n.yaml`:
  - `arb-dir: lib/l10n`
  - `template-arb-file: app_en.arb`
  - `output-localization-file: app_localizations.dart`
  - `untranslated-messages-file: desiredFileName.txt`
- There are exactly 4 ARB files that must stay in sync:
  - `lib/l10n/app_en.arb`
  - `lib/l10n/app_zh.arb`
  - `lib/l10n/app_zh_Hans.arb`
  - `lib/l10n/app_zh_Hant.arb`
- The following are generated or build artifacts. Never hand-edit them unless an explicit repository-maintained compatibility exception below applies:
  - `lib/l10n/app_localizations*.dart`
  - `lib/core/models/*.g.dart`
  - All other generated logic must go through commands, not manual edits
  - `.dart_tool/**`
  - `build/**`
- `lib/core/models/chat_message.g.dart` in the Kelivo 1.2.2 baseline is an explicit exception: upstream hand-maintains its legacy Hive field-2 reader so old `content` values can migrate into `MessagePart`. Treat it as a source-controlled compatibility adapter, not as an ordinary disposable generator output, until that migration contract is deliberately retired.
- The package name is `Kelivo`. Existing imports use `package:Kelivo/...` everywhere. Do not "normalize" the package name.
- Top-level platform entry is `_selectHome()` in `lib/main.dart`:
  - macOS / Windows / Linux -> `DesktopHomePage`
  - Android / iOS -> `HomePage`
- Desktop is NOT "mobile stretched wider":
  - `lib/desktop/desktop_home_page.dart` is the desktop app shell: nav rail, window title bar, hotkeys, desktop settings, translate/storage tabs, and other desktop-level interactions
  - `lib/desktop/desktop_chat_page.dart` is the desktop chat entry, currently reusing `HomePage`
  - `lib/features/home/pages/home_page.dart` only handles the shared chat page, switching internally by width to `home_mobile_layout.dart` or `home_desktop_layout.dart`
  - Therefore "wide/tablet layout" != "desktop app entry". Do not conflate them.
- Reusable UI primitives live in these locations:
  - `lib/shared/widgets/ios_tactile.dart`: `IosIconButton`, `IosCardPress`
  - `lib/shared/widgets/ios_tile_button.dart`
  - `lib/shared/widgets/ios_switch.dart`
  - `lib/shared/widgets/ios_checkbox.dart`
  - `lib/shared/widgets/ios_form_text_field.dart`
  - `lib/desktop/widgets/desktop_select_dropdown.dart`
  - `lib/shared/dialogs/**`
  - `lib/shared/responsive/**`
- Theme and dynamic color follow the repo as-is:
  - `lib/theme/**` is the single source of truth for theming and tokens
  - Android dynamic color is only enabled per-platform in `main.dart`. Do not extrapolate Android visual or interaction rules to desktop.

## 2. Working Style

- Communicate in Chinese throughout. Stay focused on the current task. No vague suggestions.
- Never abbreviate `JO-Kelivo` as `JO` anywhere, including communication, documentation, code comments, commit messages, release notes, UI text, or technical descriptions. Always write the full name `JO-Kelivo`. The only exception is the fixed term `JO化`, which exclusively means the process of transforming the original Kelivo into JO-Kelivo; this exception does not permit using `JO` alone in any other phrase or context.
- Future Git commit messages must be written in Chinese, including the subject and body. Technical identifiers, paths, version numbers, command names, and quoted external text may remain in their original form when necessary.
- Facts first. All conclusions must be based on current code, config, tests, build scripts, or git state. No guessing.
- Debug-first. Never add silent degradation, swallowed errors, hidden fallback paths, or fake success branches just to "make it run".
- Default to KISS / YAGNI:
  - Use the most direct, most verifiable approach first.
  - Do not pre-plant extra layers, empty abstractions, or config switches for "architectural completeness" or "might need it later".
- SOLID is a tool, not a goal:
  - Only split responsibilities when it genuinely reduces coupling and improves readability.
  - Do not shatter simple logic into a chain of tiny files just for formal layering.
- Minimal closed loop. Make only the minimum change needed for the current task. Do not fix unrelated issues on the side.
- Parallel context gathering by default during exploration:
  - Independent file reads, `rg` searches, `git status`, config checks, and log inspections should be batched in a single parallel round.
  - Do not serialize what can be parallelized.
- For complex tasks, write a brief Mini Control Contract before touching code:
  - `Primary Setpoint`: What exactly must be achieved
  - `Acceptance`: What command, test, or behavior proves it
  - `Guardrails`: What must not break as a side effect
  - `Boundary`: Which files/modules are in scope
  - `Risks`: 1 to 3 key risks

## 3. Mandatory Rules

### 3.1 All User-Visible Text Must Be Localized

- No user-visible text may be hardcoded in Dart UI code. This includes but is not limited to:
  - Page titles
  - Button labels
  - `SnackBar` / `Dialog` / `Tooltip` content
  - `semanticLabel`
  - Notification text
  - Tray menu text
- When adding or modifying user-visible strings, ALL 4 files must be updated simultaneously:
  - `lib/l10n/app_en.arb`
  - `lib/l10n/app_zh.arb`
  - `lib/l10n/app_zh_Hans.arb`
  - `lib/l10n/app_zh_Hant.arb`
- Updating only `app_en.arb` or only `app_zh.arb` and stopping is not acceptable.
- Placeholders, plurals, selects, and `@key` metadata must be consistent across all four ARB files.
- New keys follow the existing camelCase convention with a feature prefix. Do not use context-free short names like `title1` or `labelText`.
- After ARB changes, run:

```bash
flutter gen-l10n
```

- Never hand-edit `lib/l10n/app_localizations.dart` or `lib/l10n/app_localizations_*.dart`.
- `desiredFileName.txt` is the untranslated messages file. Do not introduce new untranslated entries. If you add a key, provide translations for all languages in the same change.

### 3.2 Generated Code Must Be Maintained Via Commands

- After modifying Hive models, `@HiveType`, `@HiveField`, or `part '*.g.dart'` references, normally run:

```bash
dart run build_runner build --delete-conflicting-outputs
```

- Generated file changes must correspond strictly to source changes. Do not hand-craft `*.g.dart` files except for an explicit source-controlled compatibility adapter documented in this file.
- `lib/core/models/chat_message.g.dart` is such an adapter in the Kelivo 1.2.2 baseline. Its `ChatMessageAdapter.read` must continue reading legacy Hive field 2 and passing it to `ChatMessage(content: ...)`; blindly accepting the generator's replacement can silently discard old message text during migration.
- Before running `build_runner` after the 1.2.2 baseline is accepted, inspect whether the task touches `ChatMessage` or can rewrite `chat_message.g.dart`. After generation, review the generated diff and verify the field-2-to-`content` mapping is still present. If the generator removed it, restore the documented compatibility behavior as an explicit adapter change and run the legacy Hive migration tests before proceeding.
- Any intentional change to this adapter requires all of:
  - A stated old-data compatibility reason
  - Review of `ChatMessage` Hive field numbers and constructor semantics
  - Focused tests proving legacy field 2 still becomes message text/`TextPart`
  - Confirmation that the new SQLite/`MessagePart` runtime does not resume Hive writes

### 3.3 Format Code Before Finishing

- Any change to Dart/Flutter code requires formatting before completion.
- Prefer formatting only the changed paths. For large changes, format `lib/` and `test/`.

```bash
dart format <changed-paths>
```

- Unformatted code must not be committed.

### 3.4 Minimum Sufficient Verification After Completion

- Default minimum verification loop:

```bash
flutter analyze
flutter test
```

- If the change scope is clearly narrow, at minimum run the relevant test subset and explain in the delivery notes why only a subset was run.
- If the following content types are modified, the corresponding extra action is mandatory:

| Change Type | Required Action |
| --- | --- |
| ARB / localization | `flutter gen-l10n`, check `desiredFileName.txt`, then `flutter analyze` |
| Hive model / generated code | Run `dart run build_runner build --delete-conflicting-outputs` when applicable, review generated diffs, preserve the documented `chat_message.g.dart` legacy field-2 adapter contract, then run related migration tests |
| `pubspec.yaml` / dependencies | `flutter pub get`, then `flutter analyze` and related tests |
| `.github/workflows/**` / build scripts | Check ALL similar workflow files, not just one |
| Platform directories `android/ ios/ macos/ linux/ windows/` | At least one targeted platform verification; if impossible, state why explicitly |
| `dependencies/**` path dependencies | Run analysis/tests in the dependency's own directory, not just the root repo |
| `lib/desktop/**`, desktop hotkeys/tray/window logic | At least one desktop-targeted verification (e.g. `flutter run -d macos`, `flutter build macos`, or the corresponding Windows/Linux target); if only the current machine's platform was verified, state the uncovered platform boundary |

- If local environment limitations prevent completing any verification, the final delivery notes must explicitly state "what was not run, why, and where the risk lies".

### 3.5 Do Not Hand-Edit or Commit What Should Not Be Committed

- Never hand-edit:
  - `.dart_tool/**`
  - `build/**`
  - Content maintained by `flutter gen-l10n` / `build_runner`
- The root `plans/` directory is permanently local-only migration/control material and must remain covered by the root-anchored `/plans/` rule in `.gitignore`. Never track, force-add, stage additions or modifications, or commit file content from that directory. A staged deletion is allowed only when removing a legacy tracked path from the index. Do not make product or maintenance documentation depend on files stored there.
- Do not modify unless required by the task:
  - `.idea/**`
  - Platform signing, certificates, personal environment files
  - Workflows unrelated to the current task

### 3.6 Secrets and Fallback Mechanisms

- Never commit real secrets to source code.
- `lib/secrets/fallback.dart` currently contains placeholder implementations. CI injects real values across multiple workflows. Do not write real keys into the repo.
- Do not silently add new fallback keys, fallback APIs, or error-swallowing logic just to "make it run".
- If a fallback mechanism is genuinely needed, it must satisfy ALL of:
  - Explicit toggle
  - Clear logging
  - Can be disabled
  - Reason documented in the task description

### 3.7 Change Boundary and Duplicate Workflows

- This repo has multiple similar GitHub Actions workflow files, especially for builds. When touching build, versioning, or injection logic, check ALL similar workflows for sync.
- Do not expand scope just because you spotted something that "could be unified". Finish the current task first, then decide whether to open a separate refactoring task.
- When touching a path dependency, treat it as an independent module. Do not only patch the surface at the root repo level.

#### 3.7.1 External Baseline Replacement and Git History Boundary

- JO-Kelivo intentionally maintains Git history independent from any external baseline source. The baseline is replaceable implementation input, not part of JO-Kelivo's repository identity; it may come from official Kelivo, another Kelivo fork, or another explicitly selected compatible codebase.
- Replacing the baseline does NOT mean reconnecting commit ancestry to the selected source. Do not assume official Kelivo must remain the permanent or only possible baseline.
- Unless the user explicitly requests a Git-history strategy change, external baseline work must start from the current JO-Kelivo branch and preserve its linear history. Do not:
  - Create the replacement branch from an external baseline tag or branch
  - Rebase JO-Kelivo onto external baseline history
  - Merge unrelated external baseline history with `--allow-unrelated-histories`, including `-s ours` history-bridge merges
  - Replace `origin`, add an upstream remote, or otherwise change Git remotes as an implicit part of a source upgrade
- Treat external source under `参考文件/**` as read-only comparison input. Record the selected source repository or fork, version, tag or commit hash when available, and applicable license/attribution requirements, but do not treat the reference directory as a Git working tree or copy target wholesale.
- Apply external baseline upgrades as a controlled source snapshot replacement:
  - Before replacement, ensure the intended pre-replacement JO-Kelivo state is committed, record its exact commit hash, and create the replacement branch from that commit. A tag or separate archive may be added as an optional human-readable reference, but is not mandatory and does not substitute for committing the intended state or maintaining a real backup when one is needed
  - Classify paths as JO-Kelivo-owned, baseline-owned, mixed, generated, source-controlled compatibility adapters, local migration-control material, build artifacts, or explicitly excluded before copying anything
  - Review and accept external files by functional scope; a baseline-only file enters JO-Kelivo only when its runtime, build, test, or dependency role is understood
  - Preserve JO-Kelivo-owned identity, data isolation, update source, release policy, workflows, maintenance records, and packaging rules unless the task explicitly changes them
  - Never copy `.git/**`, `.dart_tool/**`, `build/**`, external personal environment files, or unrelated external workflows and documentation
  - Regenerate ordinary generated outputs with repository commands instead of copying or hand-editing them; preserve any explicitly documented source-controlled compatibility adapter and verify its contract after generation
- Restore and verify JO-Kelivo application identity and data-directory isolation before running the upgraded app or exercising any baseline-provided data migration. Such migration must operate on the JO-Kelivo data directory, never a baseline application's data directory.
- Replay JO-Kelivo behavior by requirement against the new architecture, not by blindly restoring old files or patches. If the selected baseline changed storage, models, routing, or persistence, adapt the JO-Kelivo behavior to the new source of truth and explicitly decide whether the old patch is replayed, replaced, or retired.
- Delivery notes for an external baseline replacement must state:
  - Previous and new baseline sources and versions
  - Accepted and intentionally excluded top-level path groups
  - JO-Kelivo patches replayed, replaced, or retired
  - Data, import/export, platform identity, and release compatibility results

### 3.8 Desktop Tasks: Determine Entry Layer First

- When the task mentions desktop, Windows, macOS, Linux, tray, hotkeys, window, context menu, or desktop settings, first determine which layer the issue belongs to:
  - Top-level desktop app shell: `lib/desktop/**`
  - Shared chat content layer: `lib/features/home/**`
  - Platform services or providers: `lib/core/**`, platform directories, or path dependencies
- For desktop app shell changes, check these first:
  - `lib/main.dart`
  - `lib/desktop/desktop_home_page.dart`
  - `lib/desktop/desktop_settings_page.dart`
  - `lib/desktop/setting/**`
  - `lib/desktop/window_title_bar.dart`
  - `lib/desktop/desktop_tray_controller.dart`
  - `lib/desktop/hotkeys/**`
- Only when the issue clearly belongs to "shared content area reused by desktop chat page" should you prioritize:
  - `lib/features/home/pages/home_page.dart`
  - `lib/features/home/pages/home_desktop_layout.dart`
  - `lib/features/home/widgets/**`
- Do not guess desktop platform behavior in `home_mobile_layout.dart` or mobile branches. Do not stuff desktop-specific control flow into mobile entry points.
- Desktop interactions differ from mobile. For example, chat messages currently use "long-press on mobile, right-click menu on desktop". Desktop tasks must consider hover, right-click, keyboard shortcuts, window size, and title bar -- not just touch gestures.
- If a task spans both the desktop shell and the shared content layer, state the primary landing point in the description first, then apply minimal changes in each respective layer. Do not scatter platform routing across unrelated locations.

### 3.9 UI Component Reuse and Custom iOS Style Boundary

- Before adding new UI, search these directories for existing components instead of hand-rolling a new one inline:
  - `lib/shared/widgets/**`
  - `lib/shared/dialogs/**`
  - `lib/shared/responsive/**`
  - `lib/desktop/widgets/**`
- Prefer reusing or extending existing components, such as:
  - `IosIconButton`
  - `IosCardPress`
  - `IosTileButton`
  - `IosSwitch`
  - `IosCheckbox`
  - `IosFormTextField`
  - `DesktopSelectDropdown`
  - `WindowTitleBar`
- If a new style will appear on two or more pages, do not keep adding page-private widgets (e.g. new `_IosFilledButton`, `_TactileIconButton`, `_CustomDropdown` variants). Extract it to `lib/shared/widgets/` or `lib/desktop/widgets/` as a reusable component.
- Visual and interaction style defaults to "custom iOS style", not Android style:
  - Do not introduce Android ripple, Material default splash, default FAB emphasis, or Android-style button feedback
  - Hover/press feedback should prefer the existing iOS tactile components' approach: color, opacity, subtle scale transitions
  - Desktop allows hover, right-click, and focus states, but the overall feel must remain unified to the custom iOS style, not a Material/Android mashup
- If Material native components must be used for semantic or framework reasons, explicitly suppress off-style default feedback and consolidate styling into shared components instead of patching it piecemeal across pages.
- Icons, spacing, forms, dialogs, and panel styles should follow existing theme tokens and components. Do not mix multiple visual languages on the same page.

### 3.10 Tests and Self-Review Must Be Requirement-Driven

- Tests must be driven by requirements, defect symptoms, or acceptance criteria -- not by chasing implementation details.
- Before writing tests, list the minimum scenario set for this task. At minimum, explicitly cover:
  - Happy path
  - Boundary inputs
  - Error or failure paths
  - State transitions or interaction branches (if applicable)
- When fixing bugs, write a minimal failing case first, then fix. Do not only add an after-the-fact weak-assertion test that "happens to pass".
- Never widen public API surface, expose private internals, or distort production code responsibilities just to make tests easier to write.
- Before completion, perform at least one self-review explicitly checking these dimensions:
  - Maintainability: Is the code easier to read and modify than before?
  - Performance: Any obvious extra rebuilds, IO, traversals, or allocations introduced?
  - Security: Any input validation gaps, secret leaks, path/command injection, or permission boundary errors?
  - Style consistency: Does it match the repo's existing naming, organization, and UI language?
  - Documentation and comments: Does complex intent need minimal explanation?
  - Compatibility boundary: Does it affect existing user data, config, persisted fields, import/export formats, or established interactions?
- Compatibility is not a default-ignore item. When existing data or published behavior is involved, explicitly judge compatibility. If breaking, the delivery notes must state the breakage scope and migration path.

## 4. Recommended Execution Order

1. `git status --short` -- confirm workspace baseline.
2. Read relevant code and config. Write clear acceptance criteria. For desktop tasks, confirm entry topology first: `main.dart` -> `lib/desktop/**` -> shared chat layout. For external baseline work, confirm the independent-history rule and classify path ownership before replacement.
3. Batch all independent context reads, searches, and status checks in parallel, then decide the minimal change landing point.
4. List requirement scenarios and verification methods first, then make minimal changes. Do not mix in unrelated refactoring.
5. Run the generation, formatting, analysis, and test commands relevant to this task.
6. Self-review `git diff`. Confirm no missed localization, generated files, compatibility risks, or unrelated changes.
7. When delivering, state explicitly:
   - What was changed
   - What commands were run
   - What verification was skipped
   - What residual risks remain

## 5. Pre-Commit Checklist

- All new user-visible text uses `AppLocalizations`.
- All 4 ARB files have been updated in sync.
- `flutter gen-l10n` has been executed and generated files match ARB content.
- If Hive models were touched, `build_runner` has been executed when applicable; generated diffs were reviewed, and the `chat_message.g.dart` legacy field-2 mapping was preserved and tested.
- `dart format` has been executed.
- `flutter analyze` has been executed.
- Related `flutter test` has been executed. If no related tests exist, create and run them following official testing standards.
- Test scenarios cover the happy path, boundary values, and failure paths for this task's requirements -- not just a single green run.
- Desktop tasks have confirmed the entry layer. No desktop-only logic leaked into mobile branches.
- New or adjusted UI prioritized reuse of existing shared / desktop components. No near-duplicate widgets created.
- New UI does not introduce unnecessary Android ripple or Material default interaction feedback.
- At least one round of self-review completed, checking maintainability, performance, security, style consistency, and compatibility boundary.
- No real secrets, build artifacts, or unrelated files committed.
- The root `plans/` directory remains ignored, `git ls-files plans` is empty in the prospective index, and no addition or modification from that directory is staged or committed.
- If workflows / platform directories / path dependencies were touched, corresponding extra verification has been done.
- External baseline work remained on JO-Kelivo history unless the user explicitly approved a history strategy change; the exact pre-replacement JO-Kelivo commit and replacement branch point, source provenance, accepted/excluded paths, and replayed/replaced/retired JO-Kelivo patches are recorded.

## 6. External Best Practices

- Code should follow the Flutter contribution guide:
  - https://github.com/flutter/flutter/blob/main/CONTRIBUTING.md
- Tests should reference:
  - https://github.com/flutter/flutter/blob/main/docs/contributing/testing/Writing-Effective-Tests.md
  - https://github.com/flutter/flutter/blob/main/docs/contributing/testing/Running-and-writing-tests.md
- For Flutter code style, follow the Flutter styleguide first. Follow Effective Dart: Style only when it does not conflict:
  - https://github.com/flutter/flutter/blob/main/docs/contributing/Style-guide-for-Flutter-repo.md
  - https://dart.dev/effective-dart/style
- If the repo ever introduces `engine/`-level changes, add engine test guidance then. The repo currently has no such directory; do not apply it mechanically.
- PR descriptions should include the Pre-launch Checklist from the Flutter PR template when applicable:
  - https://github.com/flutter/flutter/blob/main/.github/PULL_REQUEST_TEMPLATE.md

## 7. Design Principles

- Readability first. Code is for humans to read, not for machines to show off.
- Default against bloated implementations, idle abstractions, and academic over-engineering.
- If you can remove complexity, remove it. If you can avoid a branch, avoid it. If you can skip a layer of indirection, skip it.
- Simple, stable, and verifiable first. "Elegant" comes after.
- Avoid dual state and dual truth. Keep one source of truth.
- Write only what is needed now, but write it right.
- Error messages must be useful -- they should help locate and recover, not just say "failed".
- Mechanisms over hand-picked magic constants. If a threshold must be hardcoded, explain why and state its boundaries.
- When small-step verification is possible, do not make large irreversible changes.

## 8. Historical Pitfall Log

> Record significant pitfalls encountered during development here.

- Recording principles:
  - Only record issues that actually occurred in this repo and have reuse value for future development.
  - Do not write "heard this might happen" hearsay entries.
  - When adding entries, prefer "symptom -> root cause -> fix/constraint". Avoid recording conclusions without context.

## 9. Context Tree Product Direction

> This section locks product decisions that must not drift back into the old linear model.

- Context branching is message-level `Message Fork`, not a vague tree and not a one-question-one-answer pair model. Tool, agent, and reasoning messages are ordinary nodes in the active branch.
- The normal chat surface displays the active branch only. Side branches stay hidden except through a branch map.
- Regenerating always creates a new branch from the message before the regenerated reply. The old setting `display_regenerate_delete_trailing_messages_v1` is obsolete and must not be reintroduced; the UI must always behave as `truncateFuture=false`.
- Continuing from an old message creates a child branch and does not mutate the original branch.
- Deleting a message deletes its descendants in the tree; sibling branches remain intact.
- Persistence must explicitly store message parent relationships, branch identity, and the active branch. Chatbox's implicit "main chain plus side tails" model is not the storage source of truth.
- Old linear conversations migrate into a single active branch; imported Chatbox forks must preserve side branches rather than flattening them.
- Chatbox `Thread` is treated as a JO-Kelivo conversation.
- Automatic hidden compaction is out of scope. Context compression remains explicit: generate a summary, create a new conversation, insert the summary as its first user message, and switch to it.
- The former "Clear Context" control is a reversible context boundary toggle labeled as mask/restore, not deletion.

## Appendix: Skills Usage Rules

- Before starting a task, scan available skill documents in `/.agents/skills/`.
- When activating a skill, declare the skill name and purpose in communication.
- Regular development does not mandate any specific skill. Activate only when semantically matched.
