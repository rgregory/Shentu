// The executable of the dummy app the tests drop on Shentu. Runs each step given as arguments
// and prints "<step> ok" or "<step> errno <n>"; exits with the number of failed steps.
//   read <path>     open and read a file
//   write <path>    create and write a file
//   tmp             write a file in $TMPDIR, which must be this run's own temp folder
//   connect <port>  TCP connect to 127.0.0.1:<port>
//   exec            start /usr/bin/true
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
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
            report("tmp", tmp && strstr(tmp, "menshen-run-") && writefile(path));
        } else if (!strcmp(step, "connect") && i + 1 < argc) {
            int s = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(atoi(argv[++i])) };
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
            report("connect", s >= 0 && connect(s, (struct sockaddr *)&addr, sizeof addr) == 0);
            if (s >= 0) close(s);
        } else if (!strcmp(step, "exec")) {
            pid_t pid;
            char *child[] = { "/usr/bin/true", NULL };
            int rc = posix_spawn(&pid, child[0], NULL, NULL, child, environ);
            if (rc == 0) waitpid(pid, NULL, 0);
            errno = rc;
            report("exec", rc == 0);
        }
    }
    fflush(stdout);
    usleep(300000);   // reports from a process that exits at once are often dropped
    return failed;
}
