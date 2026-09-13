// 启动期的窗口痕迹。
//
// 记录窗口从创建到显示出内容这一段的经过：何时被创建、何时被显示、客户区
// 多大、收到过哪些窗口消息，以及窗口有没有被系统标记成“隐身”——后者是
// “窗口在、点得到、却看不见”在 Windows 上的一种真实状态。
//
// 它和 Dart 侧日志分开写文件，因为这里的记录产生于 Flutter 引擎起来之前，
// 那时 Dart 侧还没有任何通道可用；两边按时间戳对齐即可还原先后顺序。
//
// 是否记录由设置里的“应用日志打印”开关决定，与其它日志一致：开关关着就
// 一个字都不写。文件超过 1 MB 自动轮转，轮转出的历史文件会被既有的日志
// 清理按天数与总大小上限一并收纳。

#ifndef RUNNER_STARTUP_PROBE_H_
#define RUNNER_STARTUP_PROBE_H_

#include <windows.h>

namespace startup_probe {

// 记录一行普通信息。
void Log(const char* message);

// 记录窗口当前状态：客户区尺寸、是否可见、是否最小化、是否被系统隐藏。
void LogWindowState(HWND window, const char* phase);

// 下面两个用于“可能反复发生”的窗口消息，按 [key] 分类各记前若干次。
//
// 拖动窗口会持续产生重画与尺寸变化，把每一次都写下来既无必要，也会让文件
// 无谓增长；而排查启动问题只需要知道“这类消息来过、窗口状态如何”。
void LogRepeated(const char* key, const char* message);
void LogWindowStateRepeated(const char* key, HWND window, const char* phase);

}  // namespace startup_probe

#endif  // RUNNER_STARTUP_PROBE_H_
