"""LLDB diagnostic callbacks; attach only to a PID already verified by smooth_probe.

Counts Swift-only hosting environment updates, native appearance applications,
and implicit CA commits between non-inlined diagnostic ordering markers.
All timings from debugger-counted launches are unsuitable for acceptance.
"""
import json
from pathlib import Path

_breakpoints = {}
_destination = None
_finished = False


def start(debugger, destination):
    global _destination
    _destination = Path(destination)
    target = debugger.GetSelectedTarget()
    for name, expression in (
        ('hosting_environment_updates', r'^SwiftUI.NSHostingView.updateEnvironment\(\) -> \(\)$'),
        ('native_appearance_applications', r'^__C.NSAppearance.apply\(to:'),
        ('ca_transaction_commits', r'^CA::Transaction::commit\(\)$'),
    ):
        bp = target.BreakpointCreateByRegex(expression)
        bp.SetScriptCallbackFunction(__name__ + '.count')
        bp.SetEnabled(False)
        _breakpoints[name] = bp
    begin = target.BreakpointCreateByRegex(r'RevealCounts.beginOrder\(')
    end = target.BreakpointCreateByRegex(r'RevealCounts.endOrder\(')
    if not begin.GetNumLocations() or not end.GetNumLocations():
        raise RuntimeError('Missing non-inlined ordering markers')
    begin.SetScriptCallbackFunction(__name__ + '.begin')
    end.SetScriptCallbackFunction(__name__ + '.end')
    _destination.with_suffix('.ready').write_text(json.dumps({name: bp.GetNumLocations() for name, bp in _breakpoints.items()}))


def begin(frame, location, internal_dict):
    for bp in _breakpoints.values(): bp.SetEnabled(True)
    return False


def count(frame, location, internal_dict):
    return False


def end(frame, location, internal_dict):
    global _finished
    _finished = True
    for bp in _breakpoints.values(): bp.SetEnabled(False)
    return True


def finish(debugger):
    if not _finished:
        raise RuntimeError("Ordering end marker was not reached")
    record = {name: dict(locations=bp.GetNumLocations(), calls=bp.GetHitCount(),
                        functions=[bp.GetLocationAtIndex(i).GetAddress().GetSymbol().GetName()
                                   for i in range(bp.GetNumLocations())])
              for name, bp in _breakpoints.items()}
    _destination.write_text(json.dumps(record, indent=2))


def finish_and_detach(debugger):
    try:
        finish(debugger)
    finally:
        process = debugger.GetSelectedTarget().GetProcess()
        error = process.Detach()
        if error.Fail(): raise RuntimeError(str(error))
