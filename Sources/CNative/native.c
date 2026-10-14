#include "gpt_memory_native.h"
#include <signal.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

int gpt_list_pids(int **out_pids) {
    *out_pids = NULL;
    int estimate = proc_listallpids(NULL, 0);
    if (estimate <= 0) return -1;
    for (int attempt = 0; attempt < 4; attempt++) {
        int capacity = estimate + 256;
        int *pids = calloc((size_t)capacity, sizeof(int));
        if (!pids) return -1;
        int count = proc_listallpids(pids, capacity * (int)sizeof(int));
        if (count < 0) { free(pids); return -1; }
        if (count < capacity) { *out_pids = pids; return count; }
        free(pids);
        estimate = capacity * 2;
    }
    errno = EOVERFLOW;
    return -1;
}

/* Only recognized role constants leave this function. argv and env never do. */
static void safe_role_hint(int pid, char *out, size_t capacity) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0 || length < sizeof(int) || length > 4 * 1024 * 1024) return;
    char *data = calloc(1, length);
    if (!data) return;
    if (sysctl(mib, 3, data, &length, NULL, 0) != 0) { free(data); return; }
    int argc = 0;
    memcpy(&argc, data, sizeof(argc));
    if (argc <= 0 || argc > 65536) { free(data); return; }
    char *end = data + length;
    char *cursor = data + sizeof(argc);
    size_t size = strnlen(cursor, (size_t)(end - cursor));
    if (cursor + size >= end) { free(data); return; }
    cursor += size + 1;
    while (cursor < end && *cursor == '\0') cursor++;
    const char *hint = NULL;
    for (int i = 0; i < argc && cursor < end; i++) {
        size = strnlen(cursor, (size_t)(end - cursor));
        if (cursor + size >= end) break;
        const char *arg = cursor;
        if (!strcmp(arg, "--type=gpu-process")) { hint = "gpu"; break; }
        if (!strcmp(arg, "--type=renderer")) { hint = "renderer"; break; }
        if (!strncmp(arg, "--type=", 7)) hint = "app_service";
        /* Restrict script matching to path-like tokens; never scan eval bodies. */
        if (*arg == '/' || !strncmp(arg, "./", 2)) {
            const char *name = strrchr(arg, '/');
            name = name ? name + 1 : arg;
            if (!strcmp(name, "kernel.js") || !strcmp(name, "trusted-worker.js")) { hint = "tool_worker"; break; }
            if (strstr(arg, "mysql-readonly-connector")) { hint = "mcp_mysql"; break; }
            if (strstr(arg, "code-review-plugin") || strstr(arg, "/code-review/")) { hint = "mcp_code_review"; break; }
            if (strstr(arg, "codex-app-tools") || strstr(arg, "codex_app")) { hint = "mcp_app"; break; }
            if (strstr(arg, "cua-repl") || strstr(arg, "/cua_repl/")) { hint = "mcp_cua"; break; }
        }
        cursor += size + 1;
    }
    /* Relative server paths need their working-directory identity, not argv text. */
    if (!hint) {
        struct proc_vnodepathinfo vnode;
        memset(&vnode, 0, sizeof(vnode));
        if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, sizeof(vnode)) == sizeof(vnode)) {
            const char *cwd = vnode.pvi_cdir.vip_path;
            if (strstr(cwd, "mysql-readonly-connector")) hint = "mcp_mysql";
            else if (strstr(cwd, "code-review-plugin") || strstr(cwd, "/code-review/")) hint = "mcp_code_review";
            else if (strstr(cwd, "codex-app-tools")) hint = "mcp_app";
            else if (strstr(cwd, "cua-repl")) hint = "mcp_cua";
        }
    }
    if (hint) snprintf(out, capacity, "%s", hint);
    memset(data, 0, length);
    free(data);
}

int gpt_read_process(int pid, gpt_process_info *out) {
    memset(out, 0, sizeof(*out));
    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) return -1;
    out->pid = pid;
    out->parent_pid = (int)bsd.pbi_ppid;
    out->started_at = (double)bsd.pbi_start_tvsec + (double)bsd.pbi_start_tvusec / 1000000.0;
    /* BSD birth timestamp also identifies processes when rusage is denied. */
    out->start_ticks = bsd.pbi_start_tvsec * 1000000ULL + bsd.pbi_start_tvusec;
    if (proc_pidpath(pid, out->executable, sizeof(out->executable)) <= 0) {
        snprintf(out->executable, sizeof(out->executable), "%s", bsd.pbi_name[0] ? bsd.pbi_name : bsd.pbi_comm);
    }
    struct rusage_info_v4 usage;
    memset(&usage, 0, sizeof(usage));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
        out->metrics_valid = 1;
        out->footprint_bytes = usage.ri_phys_footprint;
        out->rss_bytes = usage.ri_resident_size;
        out->peak_footprint_bytes = usage.ri_lifetime_max_phys_footprint;
        out->cpu_time_ns = usage.ri_user_time + usage.ri_system_time;
    } else {
        out->metrics_errno = errno;
    }
    /* Guard PID reuse while querying metrics/path. */
    struct proc_bsdinfo after;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, sizeof(after)) != sizeof(after) ||
        bsd.pbi_start_tvsec != after.pbi_start_tvsec || bsd.pbi_start_tvusec != after.pbi_start_tvusec) return -1;
    return 0;
}

/* Revalidate the instance immediately before signalling one positive PID.
 * macOS has no pidfd; the final check and kill are not an atomic operation. */
int gpt_validate_process(int pid, uint64_t birth, const char *executable) {
    if (pid <= 1 || pid == getpid() || !birth || !executable) { errno = EINVAL; return -1; }
    gpt_process_info live;
    if (gpt_read_process(pid, &live) != 0) return -1;
    if (live.start_ticks != birth || strcmp(live.executable, executable) != 0) { errno = ESRCH; return -1; }
    struct proc_bsdinfo bsd;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd)) return -1;
    if (bsd.pbi_uid != getuid() || bsd.pbi_ruid != getuid()) { errno = EPERM; return -1; }
    if (bsd.pbi_start_tvsec * 1000000ULL + bsd.pbi_start_tvusec != birth) { errno = ESRCH; return -1; }
    return 0;
}
int gpt_signal_process(int pid, uint64_t birth, const char *executable, int signal_number) {
    if (signal_number != SIGTERM && signal_number != SIGKILL) { errno = EINVAL; return -1; }
    if (gpt_validate_process(pid, birth, executable) != 0) return -1;
    return kill(pid, signal_number);
}

/* Explicit UI request only. Return argc NUL-separated arguments, never env. */
int gpt_read_command(int pid, uint64_t birth, const char *executable, char *out, size_t capacity) {
    if (!out || capacity == 0 || capacity > 16 * 1024) { errno = EINVAL; return -1; }
    memset(out, 0, capacity);
    if (gpt_validate_process(pid, birth, executable) != 0) return -1;
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t length = 0;
    if (sysctl(mib, 3, NULL, &length, NULL, 0) != 0) return -1;
    if (length < sizeof(int) || length > 4 * 1024 * 1024) { errno = EOVERFLOW; return -1; }
    size_t allocated = length;
    char *data = calloc(1, allocated);
    if (!data) return -1;
    int result = -1;
    if (sysctl(mib, 3, data, &length, NULL, 0) != 0) goto done;
    if (length < sizeof(int) || length > allocated) { errno = EINVAL; goto done; }
    int argc = 0; memcpy(&argc, data, sizeof(argc));
    if (argc <= 0 || argc > 65536) { errno = EINVAL; goto done; }
    char *cursor = data + sizeof(argc), *end = data + length;
    size_t size = strnlen(cursor, (size_t)(end - cursor));
    if (cursor + size >= end) { errno = EINVAL; goto done; }
    cursor += size + 1;
    while (cursor < end && *cursor == '\0') cursor++;
    size_t used = 0;
    for (int index = 0; index < argc; index++) {
        size = strnlen(cursor, (size_t)(end - cursor));
        if (cursor + size >= end) { errno = EINVAL; goto done; }
        if (size + 1 > capacity - used) { errno = EOVERFLOW; goto done; }
        memcpy(out + used, cursor, size + 1); used += size + 1; cursor += size + 1;
    }
    if (gpt_validate_process(pid, birth, executable) != 0) goto done;
    result = (int)used;
done:
    memset(data, 0, allocated); free(data);
    if (result < 0) memset(out, 0, capacity);
    return result;
}

/* Caller asks for hints only for app-owned processes, minimizing argv reads. */
void gpt_read_role_hint(int pid, char *out, size_t capacity) {
    if (capacity) out[0] = '\0';
    safe_role_hint(pid, out, capacity);
}

void gpt_read_system(gpt_system_info *out) {
    memset(out, 0, sizeof(*out));
    size_t size = sizeof(out->physical_bytes);
    sysctlbyname("hw.memsize", &out->physical_bytes, &size, NULL, 0);
    struct xsw_usage swap;
    size = sizeof(swap);
    if (!sysctlbyname("vm.swapusage", &swap, &size, NULL, 0)) {
        out->swap_used_bytes = swap.xsu_used; out->swap_valid = 1;
    }
    size = sizeof(out->pressure_level);
    if (!sysctlbyname("kern.memorystatus_vm_pressure_level", &out->pressure_level, &size, NULL, 0)) out->pressure_valid = 1;
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
        vm_size_t page_size = 0;
        if (host_page_size(host, &page_size) == KERN_SUCCESS) {
            out->compressed_physical_bytes = (uint64_t)vm.compressor_page_count * page_size;
            out->compressed_valid = 1;
        }
    }
    mach_port_deallocate(mach_task_self(), host);
}

int gpt_boot_id(char *out, size_t capacity) {
    /* launchd's fixed birth timestamp works even where kern.* is sandboxed. */
    struct proc_bsdinfo launchd;
    if (proc_pidinfo(1, PROC_PIDTBSDINFO, 0, &launchd, sizeof(launchd)) == sizeof(launchd)) {
        snprintf(out, capacity, "launchd:%llu.%06llu", launchd.pbi_start_tvsec, launchd.pbi_start_tvusec);
        return 0;
    }
    size_t size = capacity;
    if (!sysctlbyname("kern.bootsessionuuid", out, &size, NULL, 0)) return 0;
    struct timeval boot;
    size = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0)) return -1;
    snprintf(out, capacity, "%lld.%06d", (long long)boot.tv_sec, (int)boot.tv_usec);
    return 0;
}

double gpt_monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

int gpt_lock_acquire(const char *path) {
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) { int error = errno; close(fd); errno = error; return -1; }
    char owner[32];
    int length = snprintf(owner, sizeof(owner), "%d\n", getpid());
    if (ftruncate(fd, 0) || write(fd, owner, (size_t)length) != length) {
        int error = errno; flock(fd, LOCK_UN); close(fd); errno = error; return -1;
    }
    return fd;
}

void gpt_lock_release(int fd) {
    if (fd >= 0) { flock(fd, LOCK_UN); close(fd); }
}
