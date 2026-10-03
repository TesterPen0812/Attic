#!/usr/bin/env python3
"""Blocking SQL proof; SwiftData getter counters alone are insufficient."""
import re
import sys
from pathlib import Path

log = Path(sys.argv[1]).read_text()
begin = log.index("P4_METADATA_QUERY_BEGIN")
end = log.index("P4_METADATA_QUERY_END", begin)
selects = [line for line in log[begin:end].splitlines()
           if "SELECT" in line.upper() and "ZCANVASSTROKEITEM" in line.upper()]
assert selects, "P4MetadataQueryBudget: no observed metadata SELECT"
for statement in selects:
    projection = statement.upper().split("SELECT", 1)[1].split(" FROM ", 1)[0]
    assert not re.search(r"\bZ(?:BINARY)?PAYLOAD\b", projection), \
        "P4MetadataQueryBudget: metadata SELECT includes a payload body"
print("P4MetadataQueryBudget: observed SQL excludes payload columns")
