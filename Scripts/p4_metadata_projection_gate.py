#!/usr/bin/env python3
"""Blocking SQL proof; SwiftData getter counters alone are insufficient."""
import re
import sys
from pathlib import Path

log = Path(sys.argv[1]).read_text()
begin = log.index("P4_METADATA_QUERY_BEGIN")
end = log.index("P4_METADATA_QUERY_END", begin)
queries = [line for line in log[begin:end].splitlines() if "SELECT" in line.upper()]
selects = [line for line in queries if "ZCANVASSTROKEITEM" in line.upper()]
assert selects, "P4MetadataQueryBudget: no observed metadata SELECT"
assert not any("ZCANVASINKPAYLOADITEM" in line.upper() for line in queries), \
    "P4MetadataQueryBudget: metadata query touched the external payload entity"
for statement in selects:
    projection = statement.upper().split("SELECT", 1)[1].split(" FROM ", 1)[0]
    assert "*" not in projection and not re.search(r"\bZ(?:BINARY)?PAYLOAD\b", projection), \
        "P4MetadataQueryBudget: metadata SELECT includes a payload body"
    print(statement.strip())
print("P4MetadataQueryBudget: observed SQL excludes payload columns")
