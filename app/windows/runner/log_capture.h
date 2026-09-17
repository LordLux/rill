#ifndef RUNNER_LOG_CAPTURE_H_
#define RUNNER_LOG_CAPTURE_H_

// Release builds run as two processes: this one becomes a launcher that owns
// the log file, and a second copy of rill.exe is the app, started with its
// stdout and stderr on a pipe. docs/architecture.md §2.11 has why.
//
// Returns true when this process acted as the launcher; the app has then
// already run and exited, and *exit_code is its exit code. Returns false when
// this process should run the app itself: a debug or profile build, the app
// child, capture turned off with RILL_LOG_CAPTURE=0, or a launcher that could
// not start the child.
bool RunAsLogLauncher(int* exit_code);

#endif  // RUNNER_LOG_CAPTURE_H_
