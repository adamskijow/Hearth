// SPDX-License-Identifier: MIT

#include "hearth_spawn.h"

#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <grp.h>

pid_t hearth_spawn_as_user(const char *path,
                           char *const argv[],
                           char *const envp[],
                           int out_fd,
                           int err_fd,
                           uid_t uid,
                           gid_t gid,
                           const gid_t *groups,
                           int ngroups) {
    pid_t pid = fork();
    if (pid != 0) {
        // Parent (pid > 0) or fork failure (pid == -1). Nothing to clean up here;
        // the caller owns the pipe fds.
        return pid;
    }

    // ---- child: async-signal-safe calls only, then execve or _exit ----

    // New process group led by the child, matching the posix_spawn SETPGROUP path,
    // so Hearth can killpg the whole runner tree.
    setpgid(0, 0);

    // stdout and stderr onto the pipes Hearth reads.
    if (dup2(out_fd, STDOUT_FILENO) == -1) _exit(127);
    if (dup2(err_fd, STDERR_FILENO) == -1) _exit(127);

    // Close every other inherited fd so none of Hearth's descriptors (the log, the
    // control socket, the single-instance lock) leak into the runner. This mirrors
    // POSIX_SPAWN_CLOEXEC_DEFAULT on the default path.
    int maxfd = getdtablesize();
    for (int fd = 3; fd < maxfd; fd++) {
        close(fd);
    }

    // Hearth leaves SIGTERM/SIGINT/SIGHUP ignored and blocked for its dispatch
    // signal sources; SIG_IGN and the blocked mask survive execve, so reset them or
    // the runner would not die from Hearth's graceful SIGTERM.
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);

    // Drop privileges. The group list and gid must be set before the uid: once the
    // uid is dropped these calls are no longer permitted. Fail closed on any error.
    if (setgid(gid) != 0) _exit(127);
    if (setgroups(ngroups, groups) != 0) _exit(127);
    if (setuid(uid) != 0) _exit(127);

    // Never exec the runner if privileges did not actually drop.
    if (getuid() != uid || geteuid() != uid) _exit(127);

    execve(path, argv, envp);
    _exit(127); // execve returns only on failure
}
