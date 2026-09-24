# Attic performance probe

Date: 2026-09-24T17:30:13Z  
Commit: `635fdf5ac2f50329e75ae83b098eeaf7dbf2cc59`  
Preview: `com.taha.Attic.perf.250539c622`  
Fixture: A, no extra Done history

| Phase | Footprint end, MiB range | CPU, one-core % range | Idle wakeups/s range | Interrupt wakeups/s range |
| --- | ---: | ---: | ---: | ---: |
| hidden_idle | 159.66–163.13 | 0.04–0.05 | 0.00–0.00 | 1.68–1.98 |
| tasks_open | 163.09–200.03 | 0.67–58.22 | 0.00–0.00 | 8.22–42.32 |
| canvas_open | 91.24–116.95 | 0.01–26.89 | 0.00–0.00 | 0.59–110.63 |
| after_hide | 91.70–105.03 | 0.02–2.21 | 0.00–0.00 | 0.99–46.40 |

CPU and wake-ups are process-counter deltas over each fixed window; footprint is Apple's physical footprint. Transition/settling time is excluded.

AppLaunchToMenuReady: 706.50–884.23 ms (3 observations).
StoreOpen: 7.48–12.50 ms (3 observations).
PanelRevealToInteractive: 0.42–78.84 ms (8 observations).
PageSwitch: 277.23–352.36 ms (3 observations).
