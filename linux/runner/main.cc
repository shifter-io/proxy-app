#include "my_application.h"
#include <dlfcn.h>
#include <unistd.h>
#include <string>

int main(int argc, char** argv) {
  char executable[4096];
  const auto size = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (size > 0) {
    executable[size] = 0;
    std::string library(executable);
    library = library.substr(0, library.find_last_of('/')) + "/lib/libshifter_updater.so";
    if (void* handle = dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL)) {
      auto bootstrap = reinterpret_cast<void (*)()>(dlsym(handle, "shifter_update_bootstrap"));
      if (bootstrap) bootstrap();
    }
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
