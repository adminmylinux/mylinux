#include <rfb/rfbclient.h>
#include <stdarg.h>
#include <stdio.h>

/* libvncclient reports through two printf-like globals (stderr by default, which nobody sees in an app). Swift cannot
   write a variadic C function, so this formats each message here and hands the line to a plain callback. */
/* the line goes to Swift (VncLog, exported under this name): a header imported into Swift cannot keep a variable */
extern void mylinux_vnc_log_line(const char *line, int error);

static void mylinux_vnc_emit(int error, const char *format, va_list args) {
    char line[1024];
    vsnprintf(line, sizeof line, format, args);
    mylinux_vnc_log_line(line, error);
}
static void mylinux_vnc_log(const char *format, ...) { va_list a; va_start(a, format); mylinux_vnc_emit(0, format, a); va_end(a); }
static void mylinux_vnc_err(const char *format, ...) { va_list a; va_start(a, format); mylinux_vnc_emit(1, format, a); va_end(a); }

static inline void mylinux_vnc_capture_log(void) {
    rfbClientLog = mylinux_vnc_log;
    rfbClientErr = mylinux_vnc_err;
}
