// SPDX-License-Identifier: MIT
//
// A single C entry point for spawning the runner as a lower-privileged user, used
// only by Hearth's optional root-daemon privilege drop. macOS posix_spawn cannot
// set the uid, so this forks and does the drop in the child. Keeping it in C (not
// Swift) guarantees the child, between fork and execve, touches no Swift runtime
// and calls only async-signal-safe functions, which is required for a fork that is
// not immediately a posix_spawn.

#ifndef HEARTH_SPAWN_H
#define HEARTH_SPAWN_H

#include <sys/types.h>

// Fork, drop to (uid, gid, groups) in the child, redirect stdout/stderr to the
// given fds, close all other inherited fds, reset SIGTERM/SIGINT/SIGHUP to their
// default disposition and clear the signal mask, then execve(path, argv, envp).
// Returns the child pid in the parent, or the negated errno of the failed fork
// (a value < 0); the caller must not read raw errno, which its own runtime may
// have clobbered by the time it looks. The child fails closed with _exit(127)
// on any error, so it can never exec the runner as root. All pointers must
// remain valid for the duration of the call.
pid_t hearth_spawn_as_user(const char *path,
                           char *const argv[],
                           char *const envp[],
                           int out_fd,
                           int err_fd,
                           uid_t uid,
                           gid_t gid,
                           const gid_t *groups,
                           int ngroups);

#endif /* HEARTH_SPAWN_H */
