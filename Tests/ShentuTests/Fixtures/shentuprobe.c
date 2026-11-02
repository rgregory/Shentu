// The executable of the dummy app the tests drop on Shentu. Runs each step given as arguments
// and prints "<step> ok" or "<step> errno <n>"; exits with the number of failed steps.
//   read <path>     open and read a file
//   write <path>    create and write a file
//   tmp             write a file in $TMPDIR, which must be this run's own temp folder
//   connect <port>  TCP connect to 127.0.0.1:<port>
//   unix <path>     connect to a Unix-domain socket
//   ae <pid>        send the process an Apple Event it doesn't handle (no reply, never interact,
//                   so no consent prompt) and print "ae status <OSStatus>"
//   exec            start /usr/bin/true
//   helper <path>   fork a child that writes its pid to <path> and sleeps 120 s
//   sleep <s>       sleep
//   crash           abort()
// Types only: CoreServices is loaded at run time, by the `ae` step alone, so every other step
// runs a probe as lean as before.
#include <CoreServices/CoreServices.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static int failed = 0;

static void report(const char *name, int ok) {
    if (ok) printf("%s ok\n", name);
    else { printf("%s errno %d\n", name, errno); failed++; }
}

static int readfile(const char *path) {
    char buf[64];
    int fd = open(path, O_RDONLY);
    int ok = fd >= 0 && read(fd, buf, sizeof buf) >= 0;
    if (fd >= 0) close(fd);
    return ok;
}

static int writefile(const char *path) {
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0600);
    int ok = fd >= 0 && write(fd, "x\n", 2) == 2;
    if (fd >= 0) close(fd);
    return ok;
}

int main(int argc, char **argv) {
    char path[4096];
    for (int i = 1; i < argc; i++) {
        const char *step = argv[i];
        if (!strcmp(step, "read") && i + 1 < argc) {
            report("read", readfile(argv[++i]));
        } else if (!strcmp(step, "write") && i + 1 < argc) {
            report("write", writefile(argv[++i]));
        } else if (!strcmp(step, "tmp")) {
            const char *tmp = getenv("TMPDIR");
            errno = 0;
            snprintf(path, sizeof path, "%s/probe.txt", tmp ? tmp : "");
            report("tmp", tmp && strstr(tmp, "shentu-run-") && writefile(path));
        } else if (!strcmp(step, "connect") && i + 1 < argc) {
            int s = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(atoi(argv[++i])) };
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
            report("connect", s >= 0 && connect(s, (struct sockaddr *)&addr, sizeof addr) == 0);
            if (s >= 0) close(s);
        } else if (!strcmp(step, "unix") && i + 1 < argc) {
            int s = socket(AF_UNIX, SOCK_STREAM, 0);
            struct sockaddr_un addr = { .sun_family = AF_UNIX };
            strncpy(addr.sun_path, argv[++i], sizeof addr.sun_path - 1);
            report("unix", s >= 0 && connect(s, (struct sockaddr *)&addr, sizeof addr) == 0);
            if (s >= 0) close(s);
        } else if (!strcmp(step, "ae") && i + 1 < argc) {
            pid_t pid = atoi(argv[++i]);
            dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
            OSErr (*createDesc)(DescType, const void *, Size, AEDesc *) = dlsym(RTLD_DEFAULT, "AECreateDesc");
            OSErr (*createEvent)(AEEventClass, AEEventID, const AEAddressDesc *, AEReturnID, AETransactionID, AppleEvent *) = dlsym(RTLD_DEFAULT, "AECreateAppleEvent");
            OSStatus (*send)(const AppleEvent *, AppleEvent *, AESendMode, long) = dlsym(RTLD_DEFAULT, "AESendMessage");
            OSErr (*dispose)(AEDesc *) = dlsym(RTLD_DEFAULT, "AEDisposeDesc");
            AEAddressDesc target = { typeNull, NULL };
            AppleEvent event = { typeNull, NULL };
            OSStatus st = createDesc && createEvent && send && dispose ? noErr : -1;
            if (st == noErr) st = createDesc(typeKernelProcessID, &pid, sizeof pid, &target);
            if (st == noErr) st = createEvent('shnt', 'noop', &target, kAutoGenerateReturnID, kAnyTransactionID, &event);
            if (st == noErr) st = send(&event, NULL, kAENoReply | kAENeverInteract, 120);
            if (dispose) { dispose(&event); dispose(&target); }
            printf("ae status %d\n", (int)st);
        } else if (!strcmp(step, "exec")) {
            pid_t pid;
            char *child[] = { "/usr/bin/true", NULL };
            int rc = posix_spawn(&pid, child[0], NULL, NULL, child, environ);
            if (rc == 0) waitpid(pid, NULL, 0);
            errno = rc;
            report("exec", rc == 0);
        } else if (!strcmp(step, "home")) {
            const char *home = getenv("HOME");
            snprintf(path, sizeof path, "%s/home-settings", home ? home : "");
            report("home", home && writefile(path));
        } else if (!strcmp(step, "setsid") || !strcmp(step, "setpgid")) {
            pid_t child = fork();
            if (child == 0) _exit((!strcmp(step, "setsid") ? setsid() : setpgid(0, 0)) < 0 ? 1 : 0);
            int status = 0;
            if (child > 0) waitpid(child, &status, 0);
            report(step, child > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0);
        } else if (!strcmp(step, "spawn-group")) {
            posix_spawnattr_t attr;
            posix_spawnattr_init(&attr);
            posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
            posix_spawnattr_setpgroup(&attr, 0);
            pid_t child;
            char *args[] = { argv[0], NULL };
            int rc = posix_spawn(&child, argv[0], NULL, &attr, args, environ);
            if (rc == 0) waitpid(child, NULL, 0);
            posix_spawnattr_destroy(&attr);
            report(step, rc == 0);
        } else if ((!strcmp(step, "helper") || !strcmp(step, "helper-detach")) && i + 1 < argc) {
            const char *pidpath = argv[++i];
            fflush(stdout);
            pid_t pid = fork();
            if (pid == 0) {
                if (!strcmp(step, "helper-detach")) { setsid(); setpgid(0, 0); }
                char b[32];
                int n = snprintf(b, sizeof b, "%d\n", getpid());
                int fd = open(pidpath, O_CREAT | O_WRONLY | O_TRUNC, 0600);
                if (fd >= 0) { write(fd, b, n); close(fd); }
                sleep(120);
                _exit(0);
            }
            report("helper", pid > 0);
        } else if (!strcmp(step, "sleep") && i + 1 < argc) {
            sleep(atoi(argv[++i]));
        } else if (!strcmp(step, "crash")) {
            fflush(stdout);
            abort();
        }
    }
    fflush(stdout);
    usleep(300000);   // reports from a process that exits at once are often dropped
    return failed;
}
