#include "log_capture.h"

#include <shlobj.h>
#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <cwchar>
#include <regex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "utils.h"

namespace {

// Set by the launcher for the app child: the log's path, and the marker that
// this process is the child. The Dart side reads it too (log_capture.dart).
constexpr wchar_t kLogFileVariable[] = L"RILL_LOG_FILE";

// RILL_LOG_CAPTURE=0 runs the app in one process with no log — for attaching a
// debugger to the app itself, which otherwise lands on the launcher.
constexpr wchar_t kSwitchVariable[] = L"RILL_LOG_CAPTURE";

constexpr size_t kKeepRuns = 10;
constexpr uint64_t kMaxFileBytes = 10 * 1024 * 1024;

// How long to keep reading after the app has exited. A grandchild that
// inherited the pipe would otherwise hold the launcher open.
constexpr DWORD kDrainMillis = 3000;

// A line the app writes to register a value to redact. Consumed here and
// never written anywhere; log_capture.dart is the other half.
constexpr char kSecretPrefix[] = "\x01rill-secret ";

constexpr char kRedacted[] = "\xC2\xAB" "redacted" "\xC2\xBB";

bool ReadVariable(const wchar_t* name, std::wstring* value) {
  DWORD size = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (size == 0) return false;
  std::wstring buffer(size, L'\0');
  DWORD written = ::GetEnvironmentVariableW(name, buffer.data(), size);
  buffer.resize(written);
  if (value != nullptr) *value = buffer;
  return true;
}

std::wstring ExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    DWORD length = ::GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) return L"";
    if (length < path.size()) {
      path.resize(length);
      return path;
    }
    path.resize(path.size() * 2);
  }
}

// %LOCALAPPDATA%\rill\logs, created if needed; empty if it cannot be.
std::wstring LogDirectory() {
  PWSTR base = nullptr;
  HRESULT result = ::SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &base);
  std::wstring dir = SUCCEEDED(result) ? base : L"";
  ::CoTaskMemFree(base);
  if (dir.empty()) return L"";
  dir += L"\\rill";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\logs";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  DWORD attributes = ::GetFileAttributesW(dir.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES || !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    return L"";
  }
  return dir;
}

bool EndsWith(const std::wstring& text, const std::wstring& suffix) {
  return text.size() >= suffix.size() &&
         text.compare(text.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Leaves room for the run about to start, so there are kKeepRuns after it.
void PruneOldRuns(const std::wstring& dir) {
  std::vector<std::wstring> names;
  WIN32_FIND_DATAW data;
  HANDLE find = ::FindFirstFileW((dir + L"\\rill-*.log").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return;
  do {
    std::wstring name = data.cFileName;
    if (!(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && EndsWith(name, L".log")) {
      names.push_back(name);
    }
  } while (::FindNextFileW(find, &data));
  ::FindClose(find);

  // Names begin with a local timestamp, so name order is age order.
  std::sort(names.begin(), names.end());
  while (names.size() >= kKeepRuns) {
    const std::wstring path = dir + L"\\" + names.front();
    ::DeleteFileW(path.c_str());
    ::DeleteFileW((path + L".old").c_str());
    names.erase(names.begin());
  }
}

std::wstring FileStamp() {
  SYSTEMTIME t;
  ::GetLocalTime(&t);
  wchar_t buffer[32];
  swprintf_s(buffer, L"%04u%02u%02u-%02u%02u%02u", t.wYear, t.wMonth, t.wDay, t.wHour,
             t.wMinute, t.wSecond);
  return buffer;
}

std::string LineStamp(bool with_date) {
  SYSTEMTIME t;
  ::GetLocalTime(&t);
  char buffer[40];
  if (with_date) {
    sprintf_s(buffer, "%04u-%02u-%02u %02u:%02u:%02u.%03u ", t.wYear, t.wMonth, t.wDay, t.wHour,
              t.wMinute, t.wSecond, t.wMilliseconds);
  } else {
    sprintf_s(buffer, "%02u:%02u:%02u.%03u ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
  }
  return buffer;
}

std::string Trim(const std::string& text) {
  const char* space = " \t\r\n";
  size_t first = text.find_first_not_of(space);
  if (first == std::string::npos) return "";
  size_t last = text.find_last_not_of(space);
  return text.substr(first, last - first + 1);
}

// The same two rules as sidecar/src/redact.ts, and for the same reason: exact
// values the app registered, and auth-cookie-shaped NAME=VALUE pairs for
// values it never saw. Keep the name list in step with COOKIE_NAME there.
class Redactor {
 public:
  void Register(const std::string& raw) {
    const std::string value = Trim(raw);
    if (value.size() < 8) return;
    secrets_.insert(value);
    static const std::regex pair(R"((^|[;,\s])([^=;,\s]+)=([^;,\s]+))");
    for (std::sregex_iterator it(value.begin(), value.end(), pair), end; it != end; ++it) {
      const std::string cookie_value = (*it)[3].str();
      if (cookie_value.size() >= 8) secrets_.insert(cookie_value);
    }
  }

  std::string Apply(std::string text) const {
    for (const std::string& secret : secrets_) {
      size_t at = 0;
      while ((at = text.find(secret, at)) != std::string::npos) {
        text.replace(at, secret.size(), kRedacted);
        at += sizeof(kRedacted) - 1;
      }
    }
    // Every name in the list contains SID except LOGIN_INFO: a cheap test
    // that keeps the regex off almost every line.
    if (text.find("SID") == std::string::npos && text.find("LOGIN_INFO") == std::string::npos) {
      return text;
    }
    static const std::regex cookie_pair(
        R"(\b((?:__Secure-|__Host-)?(?:\d+P)?(?:S?APISID|SID|HSID|SSID|SIDCC|PSIDTS|PSIDCC|LOGIN_INFO|SAPISIDHASH))=([^;,\s"']+))");
    return std::regex_replace(text, cookie_pair, std::string("$1=") + kRedacted);
  }

 private:
  std::set<std::string> secrets_;
};

// One run's file, rotated to <name>.old at kMaxFileBytes so the tail — where a
// crash's last words are — is always in the current file. Also copies each
// line to the launcher's own stderr or console, when it has one.
class LogFile {
 public:
  ~LogFile() {
    if (file_ != INVALID_HANDLE_VALUE) ::CloseHandle(file_);
    if (tee_owned_) ::CloseHandle(tee_);
  }

  bool Open(const std::wstring& path) {
    path_ = path;
    file_ = ::CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
                          nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file_ == INVALID_HANDLE_VALUE) return false;
    OpenTee();
    return true;
  }

  void Write(const std::string& text, bool with_date = false) {
    const std::string line = LineStamp(with_date) + text + "\r\n";
    DWORD written = 0;
    ::WriteFile(file_, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
    bytes_ += written;
    Tee(text);
    if (bytes_ >= kMaxFileBytes) Rotate();
  }

 private:
  // A redirected stderr (a debugger, `Start-Process -RedirectStandardError`)
  // wins; otherwise the terminal this was started from, if any.
  void OpenTee() {
    HANDLE inherited = ::GetStdHandle(STD_ERROR_HANDLE);
    if (inherited != nullptr && inherited != INVALID_HANDLE_VALUE &&
        ::GetFileType(inherited) != FILE_TYPE_UNKNOWN) {
      tee_ = inherited;
      return;
    }
    if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
      tee_ = ::CreateFileW(L"CONOUT$", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_EXISTING, 0, nullptr);
      tee_owned_ = tee_ != INVALID_HANDLE_VALUE;
    }
  }

  void Tee(const std::string& text) {
    if (tee_ == nullptr || tee_ == INVALID_HANDLE_VALUE) return;
    const std::string line = text + "\n";
    if (::GetFileType(tee_) == FILE_TYPE_CHAR) {
      // A console takes UTF-16; bytes would be read in its code page.
      int length = ::MultiByteToWideChar(CP_UTF8, 0, line.data(), static_cast<int>(line.size()),
                                         nullptr, 0);
      std::wstring wide(length, L'\0');
      ::MultiByteToWideChar(CP_UTF8, 0, line.data(), static_cast<int>(line.size()), wide.data(),
                            length);
      DWORD written = 0;
      if (::WriteConsoleW(tee_, wide.data(), static_cast<DWORD>(wide.size()), &written, nullptr)) {
        return;
      }
    }
    DWORD written = 0;
    ::WriteFile(tee_, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
  }

  void Rotate() {
    ::CloseHandle(file_);
    const std::wstring old = path_ + L".old";
    ::MoveFileExW(path_.c_str(), old.c_str(), MOVEFILE_REPLACE_EXISTING);
    file_ = ::CreateFileW(path_.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_DELETE,
                          nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    bytes_ = 0;
    const std::string note =
        LineStamp(true) + "rill-launcher: size limit reached; earlier lines are in " +
        Utf8FromUtf16(old.substr(old.find_last_of(L'\\') + 1).c_str()) + "\r\n";
    DWORD written = 0;
    ::WriteFile(file_, note.data(), static_cast<DWORD>(note.size()), &written, nullptr);
    bytes_ += written;
  }

  std::wstring path_;
  HANDLE file_ = INVALID_HANDLE_VALUE;
  uint64_t bytes_ = 0;
  HANDLE tee_ = nullptr;
  bool tee_owned_ = false;
};

// Reads the app's output until the pipe closes or the read is cancelled.
void Pump(HANDLE pipe, LogFile* log, Redactor* redactor) {
  const size_t prefix_length = sizeof(kSecretPrefix) - 1;
  auto emit = [&](std::string line) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.compare(0, prefix_length, kSecretPrefix) == 0) {
      redactor->Register(line.substr(prefix_length));
      return;
    }
    log->Write(redactor->Apply(std::move(line)));
  };

  std::string pending;
  char buffer[8192];
  DWORD read = 0;
  while (::ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
    pending.append(buffer, read);
    size_t start = 0;
    size_t end;
    while ((end = pending.find('\n', start)) != std::string::npos) {
      emit(pending.substr(start, end - start));
      start = end + 1;
    }
    pending.erase(0, start);
    // A line that never ends is still written, in pieces.
    if (pending.size() > 64 * 1024) {
      emit(pending);
      pending.clear();
    }
  }
  if (!pending.empty()) emit(pending);
}

std::string Hex(DWORD value) {
  char buffer[16];
  sprintf_s(buffer, "0x%08lX", value);
  return buffer;
}

}  // namespace

bool RunAsLogLauncher(int* exit_code) {
#ifndef RILL_LOG_CAPTURE
  (void)exit_code;
  return false;
#else
  if (ReadVariable(kLogFileVariable, nullptr)) return false;  // This is the app.
  std::wstring capture;
  if (ReadVariable(kSwitchVariable, &capture) && capture == L"0") return false;

  const std::wstring dir = LogDirectory();
  const std::wstring exe = ExecutablePath();
  if (dir.empty() || exe.empty()) return false;
  PruneOldRuns(dir);
  const std::wstring path = dir + L"\\rill-" + FileStamp() + L"-" +
                            std::to_wstring(::GetCurrentProcessId()) + L".log";

  LogFile log;
  if (!log.Open(path)) return false;
  log.Write("rill-launcher: " + Utf8FromUtf16(exe.c_str()) + ", launcher pid " +
                std::to_string(::GetCurrentProcessId()),
            true);

  SECURITY_ATTRIBUTES inheritable{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  HANDLE read_end = nullptr;
  HANDLE write_end = nullptr;
  if (!::CreatePipe(&read_end, &write_end, &inheritable, 1 << 16)) {
    log.Write("rill-launcher: CreatePipe failed (" + std::to_string(::GetLastError()) +
              "); running the app without a log");
    return false;
  }
  ::SetHandleInformation(read_end, HANDLE_FLAG_INHERIT, 0);

  // Only the pipe is inherited, not every inheritable handle this process has.
  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  STARTUPINFOW own{};
  own.cb = sizeof(own);
  ::GetStartupInfoW(&own);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | (own.dwFlags & STARTF_USESHOWWINDOW);
  startup.StartupInfo.wShowWindow = own.wShowWindow;
  startup.StartupInfo.hStdOutput = write_end;
  startup.StartupInfo.hStdError = write_end;
  SIZE_T attributes_size = 0;
  ::InitializeProcThreadAttributeList(nullptr, 1, 0, &attributes_size);
  std::vector<BYTE> attributes(attributes_size);
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
  HANDLE inherited[] = {write_end};
  bool listed =
      ::InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributes_size) &&
      ::UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                  inherited, sizeof(inherited), nullptr, nullptr);

  ::SetEnvironmentVariableW(kLogFileVariable, path.c_str());
  std::wstring command_line = ::GetCommandLineW();
  PROCESS_INFORMATION app{};
  BOOL started = listed && ::CreateProcessW(exe.c_str(), command_line.data(), nullptr, nullptr, TRUE,
                                            EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED,
                                            nullptr, nullptr, &startup.StartupInfo, &app);
  DWORD start_error = ::GetLastError();
  ::SetEnvironmentVariableW(kLogFileVariable, nullptr);
  if (listed) ::DeleteProcThreadAttributeList(startup.lpAttributeList);
  ::CloseHandle(write_end);
  if (!started) {
    ::CloseHandle(read_end);
    log.Write("rill-launcher: could not start the app (" + std::to_string(start_error) +
              "); running it without a log");
    return false;
  }

  // Closing the launcher closes the app, rather than leaving it writing into a
  // pipe nobody reads.
  HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
  if (job != nullptr) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    ::SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    ::AssignProcessToJobObject(job, app.hProcess);
  }
  ::ResumeThread(app.hThread);
  ::CloseHandle(app.hThread);
  log.Write("rill-launcher: app pid " + std::to_string(app.dwProcessId));

  Redactor redactor;
  std::thread pump(Pump, read_end, &log, &redactor);
  ::WaitForSingleObject(app.hProcess, INFINITE);

  HANDLE pump_thread = pump.native_handle();
  if (::WaitForSingleObject(pump_thread, kDrainMillis) == WAIT_TIMEOUT) {
    // Repeated: a cancel that lands between two reads cancels nothing.
    do {
      ::CancelSynchronousIo(pump_thread);
    } while (::WaitForSingleObject(pump_thread, 100) == WAIT_TIMEOUT);
  }
  pump.join();
  ::CloseHandle(read_end);

  DWORD code = 0;
  ::GetExitCodeProcess(app.hProcess, &code);
  // An NTSTATUS error is a crash: 0xC0000409 a fast fail, 0xC0000005 an access
  // violation. The line exists so a crash leaves a record without a dump.
  const bool crashed = (code & 0xC0000000) == 0xC0000000;
  log.Write(std::string("rill-launcher: app ") + (crashed ? "CRASHED" : "exited") +
                " with code " + Hex(code),
            true);

  ::CloseHandle(app.hProcess);
  if (job != nullptr) ::CloseHandle(job);
  *exit_code = static_cast<int>(code);
  return true;
#endif
}
