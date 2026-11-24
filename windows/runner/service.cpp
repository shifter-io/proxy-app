#include <windows.h>

namespace {
constexpr wchar_t kServiceName[] = L"ShifterBackground";
SERVICE_STATUS_HANDLE status_handle = nullptr;
HANDLE stop_event = nullptr;

void Report(DWORD state, DWORD error = NO_ERROR) {
  SERVICE_STATUS status{};
  status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  status.dwCurrentState = state;
  status.dwWin32ExitCode = error;
  status.dwControlsAccepted = state == SERVICE_RUNNING
                                  ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
                                  : 0;
  if (state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING) {
    status.dwWaitHint = 5000;
    status.dwCheckPoint = 1;
  }
  SetServiceStatus(status_handle, &status);
}

DWORD WINAPI Control(DWORD code, DWORD, void*, void*) {
  if (code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN) {
    Report(SERVICE_STOP_PENDING);
    SetEvent(stop_event);
    return NO_ERROR;
  }
  if (code == SERVICE_CONTROL_INTERROGATE) return NO_ERROR;
  return ERROR_CALL_NOT_IMPLEMENTED;
}

void WINAPI Run(DWORD, wchar_t**) {
  stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  const DWORD event_error = stop_event ? NO_ERROR : GetLastError();
  status_handle = RegisterServiceCtrlHandlerExW(kServiceName, Control, nullptr);
  if (status_handle && stop_event) {
    Report(SERVICE_RUNNING);
    const DWORD result = WaitForSingleObject(stop_event, INFINITE);
    Report(SERVICE_STOPPED, result == WAIT_FAILED ? GetLastError() : NO_ERROR);
  } else if (status_handle) {
    Report(SERVICE_STOPPED, event_error);
  }
  if (stop_event) CloseHandle(stop_event);
}
}  // namespace

int wmain() {
  // The interactive agent owns user credentials, the tray and all routing.
  // The service is available to SCM at boot and never starts a user-writable
  // binary from its service account.
  SERVICE_TABLE_ENTRYW entries[] = {
      {const_cast<wchar_t*>(kServiceName), Run}, {nullptr, nullptr}};
  return StartServiceCtrlDispatcherW(entries) ? 0 : static_cast<int>(GetLastError());
}
