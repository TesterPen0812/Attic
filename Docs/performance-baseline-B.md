# Attic performance probe

Date: 2026-09-24T22:49:05Z
Commit: `cecd6af610bcb9da7101643f466c4f8ba4648823`
Preview: `com.taha.Attic.perf.9c77866cfd`
Fixture: B, 5,000 Done tasks included

| Phase | Footprint end, MiB range | CPU, one-core % range | Interrupt wakeups/s range |
| --- | ---: | ---: | ---: |
| hidden_idle | 163.78–166.24 | 0.03–0.04 | 0.98–1.08 |
| tasks_open | 170.77–174.49 | 0.02–0.03 | 0.79–0.89 |
| canvas_open | 98.14–118.59 | 0.02–0.02 | 0.69–0.79 |
| after_hide | 101.67–121.80 | 0.04–0.06 | 1.08–1.09 |
| hidden_idle_final | 101.67–121.80 | 0.03–0.04 | 1.09–1.09 |

CPU and interrupt wake-ups are process-counter deltas over each fixed window; footprint is Apple's physical footprint. Transition/settling time is excluded.

CoordinatorInitToMenuStarted: 754.58–1155.18 ms (3 observations).
StoreOpen: 7.84–15.74 ms (3 observations).
PanelRevealToOrderedFront: 1.08–308.47 ms (6 observations).
PageSwitch: 282.08–312.15 ms (3 observations).
