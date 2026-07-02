// SPDX-License-Identifier: MIT

#include "hearth_spawn.h"

#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <grp.h>
#include <errno.h>

pid_t hearth_spawn_as_user(const char *path,
                           char *const argv[],
                           char *const envp[],
                           int out_fd,
                           int err_fd,
                           uid_t uid,
                           gid_t gid,
                           const gid_t *groups,
                           int ngroups) {
    // Everything the child needs that is not async-signal-safe is computed
    // BEFORE the fork: the fd table size (getdtablesize may allocate), the
    // default-signal action, and the empty mask. The forked child of a
    // multithreaded parent may only use async-signal-safe calls, and the stack
    // copies carry these values across.
    int maxfd = getdtablesize();
    struct sigaction dfl;
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    dfl.sa_flags = 0;
    sigset_t empty;
    sigemptyset(&empty);

    errno = 0;
    pid_t pid = fork();
    if (pid < 0) {
        // Fork failure: hand the error back as a negative errno so the caller
        // does not have to read errno after its own runtime has run.
        return (pid_t)(errno > 0 ? -errno : -1);
    }
    if (pid > 0) {
        // Parent. Nothing to clean up here; the caller owns the pipe fds.
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
    for (int fd = 3; fd < maxfd; fd++) {
        close(fd);
    }

    // Hearth leaves SIGTERM/SIGINT/SIGHUP ignored and blocked for its dispatch
    // signal sources; SIG_IGN and the blocked mask survive execve, so reset them or
    // the runner would not die from Hearth's graceful SIGTERM. sigaction is
    // async-signal-safe; signal() is not.
    sigaction(SIGTERM, &dfl, NULL);
    sigaction(SIGINT, &dfl, NULL);
    sigaction(SIGHUP, &dfl, NULL);
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
