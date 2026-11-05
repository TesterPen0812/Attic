// Local-only Mach diagnostics. Keep the suspended interval in C: no Swift ARC,
// Swift runtime, malloc, logging, dyld lookup, locks or Objective-C messages.
#if defined(ATTIC_IDLE_SAMPLER) && defined(__arm64__)
#include <dlfcn.h>
#include <libgen.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/machine.h>
#include <mach/arm/thread_status.h>
#include <mach/task_info.h>
#include <mach/vm_statistics.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

// Metrics: valid mask, thread user/system us, task faults/pageins/COW,
// host-wide decompressed pages, task phys_footprint/resident/compressed bytes.
uint32_t AtticIdleMainThread(void) { return mach_thread_self(); }
void AtticIdleReleaseThread(uint32_t port) {
    if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
}

void AtticIdleReadMetrics(uint32_t port, uint64_t out[10]) {
    memset(out, 0, 10 * sizeof(uint64_t));
    thread_basic_info_data_t thread;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (port != MACH_PORT_NULL && thread_info(port, THREAD_BASIC_INFO, (thread_info_t)&thread, &count) == KERN_SUCCESS) {
        out[0] |= 1;
        out[1] = (uint64_t)thread.user_time.seconds * 1000000 + thread.user_time.microseconds;
        out[2] = (uint64_t)thread.system_time.seconds * 1000000 + thread.system_time.microseconds;
    }
    task_events_info_data_t events;
    count = TASK_EVENTS_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_EVENTS_INFO, (task_info_t)&events, &count) == KERN_SUCCESS) {
        out[0] |= 2;
        out[3] = (uint32_t)events.faults;
        out[4] = (uint32_t)events.pageins;
        out[5] = (uint32_t)events.cow_faults;
    }
    host_t host = mach_host_self();
    vm_statistics64_data_t vm;
    count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS) {
        out[0] |= 4;
        out[6] = vm.decompressions; // SYSTEM-WIDE, never attributed to Attic.
    }
    mach_port_deallocate(mach_task_self(), host);
    task_vm_info_data_t memory;
    count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count) == KERN_SUCCESS) {
        out[0] |= 8;
        out[7] = memory.phys_footprint;
        out[8] = memory.resident_size;
        out[9] = memory.compressed;
    }
}

// out[0] = run_state, [1] = waiting, [2] = frame count, [3] = status
// (1 sampled, 2 thread_info unavailable, 3 registers unavailable),
// [4...35] = program counters. All storage is reserved by the caller BEFORE
// thread_suspend. This function's only calls between suspend and resume are
// Mach traps. Even error paths unconditionally resume a suspended thread.
void AtticIdleCapture(uint32_t port, uint64_t out[36]) {
    memset(out, 0, 36 * sizeof(uint64_t));
    if (port == MACH_PORT_NULL || pthread_main_np()) return;
    if (thread_suspend(port) != KERN_SUCCESS) return;

    thread_basic_info_data_t basic;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    kern_return_t basic_result = thread_info(port, THREAD_BASIC_INFO, (thread_info_t)&basic, &count);
    if (basic_result == KERN_SUCCESS) {
        out[0] = basic.run_state;
        out[1] = basic.run_state == TH_STATE_WAITING;
    } else {
        out[3] = 2;
    }

    arm_thread_state64_t state;
    count = ARM_THREAD_STATE64_COUNT;
    kern_return_t state_result = thread_get_state(port, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    if (state_result == KERN_SUCCESS) {
        uint64_t pc = arm_thread_state64_get_pc(state);
        uint64_t fp = arm_thread_state64_get_fp(state);
        out[4] = pc;
        out[2] = 1;
        out[3] = 1;
        // AArch64 ABI: [previous FP, saved LR]. Read two words at a time,
        // bounding depth, alignment and total stack distance (1 MiB).
        const uint64_t first_fp = fp;
        for (uint32_t i = 1; i < 32; ++i) {
            if (fp < 4096 || (fp & 15) || fp - first_fp > 1048576) break;
            uint64_t words[2] = {0, 0};
            mach_vm_size_t bytes = 0;
            if (mach_vm_read_overwrite(mach_task_self(), fp, sizeof(words), (mach_vm_address_t)words, &bytes) != KERN_SUCCESS
                || bytes != sizeof(words)) break;
            uint64_t lr = words[1];
#if __has_feature(ptrauth_calls)
            lr = (uint64_t)ptrauth_strip((void *)lr, ptrauth_key_return_address);
#endif
            if (lr == 0) break;
            out[4 + i] = lr;
            out[2] = i + 1;
            if (words[0] <= fp || words[0] - first_fp > 1048576) break;
            fp = words[0];
        }
    } else if (out[3] == 0) {
        out[3] = 3;
    }
    (void)thread_resume(port); // Every successful suspend reaches this line.
}

// Called ONLY after the thread has resumed. dyld/dladdr may take locks.
uint32_t AtticIdleDescribePC(uint64_t pc, char name[96], char uuid[37], uint64_t *offset) {
    name[0] = '\0'; uuid[0] = '\0'; *offset = 0;
    Dl_info info;
    if (!dladdr((void *)pc, &info) || !info.dli_fbase || !info.dli_fname) return 0;
    const char *leaf = strrchr(info.dli_fname, '/');
    strlcpy(name, leaf ? leaf + 1 : info.dli_fname, 96);
    *offset = pc - (uintptr_t)info.dli_fbase;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if ((const void *)header != info.dli_fbase || header->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *h = (const struct mach_header_64 *)header;
        const struct load_command *cmd = (const struct load_command *)(h + 1);
        for (uint32_t n = 0; n < h->ncmds; ++n) {
            if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(struct uuid_command)) {
                const struct uuid_command *u = (const struct uuid_command *)cmd;
                snprintf(uuid, 37,
                    "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    u->uuid[0], u->uuid[1], u->uuid[2], u->uuid[3], u->uuid[4], u->uuid[5],
                    u->uuid[6], u->uuid[7], u->uuid[8], u->uuid[9], u->uuid[10], u->uuid[11],
                    u->uuid[12], u->uuid[13], u->uuid[14], u->uuid[15]);
                return 1;
            }
            cmd = (const struct load_command *)((const char *)cmd + cmd->cmdsize);
        }
    }
    return 1; // Offset and image name still usable without a UUID.
}
#endif
