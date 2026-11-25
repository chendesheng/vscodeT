// TerminalProcess.onProcessExit at the POSIX host boundary. Keep the child
// waitable until its owner drains the PTY and collects the exit status.
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__DragonFly__)
#include <sys/event.h>

int vscodet_process_exit_fd(pid_t pid) {
    int fd = kqueue();
    if (fd < 0) return -1;
    struct kevent event;
    EV_SET(&event, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    int result;
    do {
        result = kevent(fd, &event, 1, NULL, 0, NULL);
    } while (result < 0 && errno == EINTR);
    if (result < 0 && errno == ESRCH) {
        // The child exited before registration. EOF makes the returned
        // descriptor immediately readable, including for an empty PTY.
        close(fd);
        int pipe_fds[2];
        if (pipe(pipe_fds) < 0) return -1;
        close(pipe_fds[1]);
        fd = pipe_fds[0];
        result = 0;
    }
    if (result < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}
#else
int vscodet_process_exit_fd(pid_t pid) {
    (void)pid;
    return -1;
}
#endif

void vscodet_wait_for_process_exit(pid_t pid, int wake_fd) {
    siginfo_t info;
    while (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) < 0 && errno == EINTR) {}
    const char ready = 1;
    while (write(wake_fd, &ready, 1) < 0 && errno == EINTR) {}
    close(wake_fd);
}
