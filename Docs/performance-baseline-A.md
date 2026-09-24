# Attic performance probe

Date: 2026-09-24T19:56:47Z
Commit: `66298945ac71e86f3bfa9b5f3976f1f41e25bd8b`
Preview: `com.taha.Attic.perf.9fd44b290a`
Fixture: A, no extra Done history

| Phase | Footprint end, MiB range | CPU, one-core % range | Interrupt wakeups/s range |
| --- | ---: | ---: | ---: |
| hidden_idle | 159.99–163.33 | 0.02–2.95 | 0.99–62.17 |
| tasks_open | 164.42–235.14 | 0.02–2.38 | 0.79–41.60 |
| canvas_open | 113.52–123.92 | 0.27–4.11 | 5.23–27.65 |
| after_hide | 112.91–122.97 | 0.03–1.57 | 1.09–27.64 |
| hidden_idle_final | 112.92–122.97 | 0.99–2.37 | 24.38–51.93 |

CPU and interrupt wake-ups are process-counter deltas over each fixed window; footprint is Apple's physical footprint. Transition/settling time is excluded.

CoordinatorInitToMenuStarted: 955.72–1208.84 ms (3 observations).
StoreOpen: 8.69–12.57 ms (3 observations).
PanelRevealToOrderedFront: 1.20–261.75 ms (6 observations).
PageSwitch: 312.33–540.11 ms (3 observations).
