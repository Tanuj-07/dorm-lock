// launcher so launchd can run the bridge w/ its own bt permission.
// macos checks bt perms against the "responsible" app, so this .app (has the
// bt usage string in Info.plist) spawns python as a child like terminal does
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static pid_t child = 0;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(void) {
    const char *home = getenv("HOME");
    if (!home) home = "/Users/tanuj";
    char dir[1024], py[1024];
    snprintf(dir, sizeof dir, "%s/dorm-lock", home);
    snprintf(py, sizeof py, "%s/dorm-lock-venv/bin/python3", home);
    if (chdir(dir) != 0) { perror("chdir"); return 1; }

    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);

    char *argv[] = {py, "-u", "bridge.py", NULL};
    int rc = posix_spawn(&child, py, NULL, NULL, argv, environ);
    if (rc != 0) { fprintf(stderr, "spawn failed: %d\n", rc); return 1; }

    int st;
    while (waitpid(child, &st, 0) < 0) {
        if (errno != EINTR) return 1;
    }
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    return 1;
}
