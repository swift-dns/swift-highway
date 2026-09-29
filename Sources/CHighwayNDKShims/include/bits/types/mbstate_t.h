// NDK r29's libc++ would get mbstate_t by #include_next <wchar.h>, defining its wchar.h
// overloads twice under Clang modules (android/ndk#2230). NDK r30 includes this instead.
#include <bits/mbstate_t.h>
