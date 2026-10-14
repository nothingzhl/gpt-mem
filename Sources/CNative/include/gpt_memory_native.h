#ifndef GPT_MEMORY_NATIVE_H
#define GPT_MEMORY_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#include <sqlite3.h>

typedef struct {
    int pid;
    int parent_pid;
    int metrics_valid;
    int metrics_errno;
    uint64_t start_ticks;
    double started_at;
    uint64_t footprint_bytes;
    uint64_t rss_bytes;
    uint64_t peak_footprint_bytes;
    uint64_t cpu_time_ns;
    char executable[4096];
    char safe_hint[64];
} gpt_process_info;

typedef struct {
    uint64_t physical_bytes;
    uint64_t compressed_physical_bytes;
    uint64_t swap_used_bytes;
    int compressed_valid;
    int swap_valid;
    int pressure_level;
    int pressure_valid;
} gpt_system_info;

int gpt_list_pids(int **out_pids);
int gpt_read_process(int pid, gpt_process_info *out);
int gpt_signal_process(int pid, uint64_t birth, const char *executable, int signal_number);
int gpt_validate_process(int pid, uint64_t birth, const char *executable);
int gpt_read_working_directory(int pid, uint64_t birth, const char *executable, char *out, size_t capacity);
int gpt_read_command(int pid, uint64_t birth, const char *executable, char *out, size_t capacity);
void gpt_read_role_hint(int pid, char *out, size_t capacity);
void gpt_read_system(gpt_system_info *out);
int gpt_boot_id(char *out, size_t capacity);
double gpt_monotonic_seconds(void);
int gpt_lock_acquire(const char *path);
void gpt_lock_release(int fd);
#endif
