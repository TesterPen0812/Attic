#include <libproc.h>
#include <mach/mach_time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

// Kernel process counters, sampled twice by performance_probe.py. This is
// observational only; no task port, sudo, or power assertion is needed.
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int pid = atoi(argv[1]);
    struct rusage_info_v4 usage = {0};
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        perror("proc_pid_rusage");
        return 1;
    }
    // ri_user_time / ri_system_time are mach absolute ticks, not nanoseconds.
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return 1;
    uint64_t user_ns = (uint64_t)((__uint128_t)usage.ri_user_time * timebase.numer / timebase.denom);
    uint64_t system_ns = (uint64_t)((__uint128_t)usage.ri_system_time * timebase.numer / timebase.denom);
    printf("{\"user_time_ns\":%llu,\"system_time_ns\":%llu,"
           "\"package_idle_wakeups\":%llu,\"interrupt_wakeups\":%llu,"
           "\"physical_footprint_bytes\":%llu}\n",
           (unsigned long long)user_ns,
           (unsigned long long)system_ns,
           (unsigned long long)usage.ri_pkg_idle_wkups,
           (unsigned long long)usage.ri_interrupt_wkups,
           (unsigned long long)usage.ri_phys_footprint);
    return 0;
}
