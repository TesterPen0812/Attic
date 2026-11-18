"""Check Attic's per-file allowance for fixed waits, skips, and retries."""

import argparse
from collections import Counter
from decimal import Decimal
import json
import os
from pathlib import Path
import re


ALLOWANCE_PATH = "Scripts/test_wait_allowance.json"
PATTERNS = ("sleep", "runloop", "skip", "long_timeout")
WAIT_ADVICE = (
    "wait on a condition or an XCTestExpectation with a deadline "
    "(e.g. `XCTNSPredicateExpectation` or a polling helper with a timeout), "
    "not for a fixed time"
)
ADVICE = {
    "sleep": WAIT_ADVICE,
    "runloop": WAIT_ADVICE,
    "skip": "make the test run, or delete it",
    "long_timeout": "wait on the condition the test needs; a long fixed timeout hides a hang",
    "retry_flags": "remove the retry setting and make the test pass on its first run",
}

NUMBER = (
    r"(?:0[xX][0-9a-fA-F_]+(?:\.[0-9a-fA-F_]+)?(?:[pP][+-]?[0-9_]+)?"
    r"|0[bB][01_]+|0[oO][0-7_]+"
    r"|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)"
)
NUMERIC_LITERAL = re.compile(NUMBER)
LEXEME = re.compile(r'\s+|//[^\r\n]*|/\*|#*(?:"""|")|`[^`\r\n]+`|' + NUMBER + r'|\w+|.')
BLOCK_DELIMITER = re.compile(r"/\*|\*/")
RETRY_SETTING = re.compile(
    r"""(?<![\w-])(?:["']testRepetitionMode["']|testRepetitionMode)\s*[:=]\s*"""
    r"""(?:["'](?:retryOnFailure|retryUntilPass|retry)["']|(?:retryOnFailure|retryUntilPass|retry)\b)"""
    r'|(?<![\w-])-retry-tests-on-failure(?![\w-])|"retryOnFailure"'
)
ITERATIONS = re.compile(r"(?<![\w-])-test-iterations(?![\w-])")
SHELL_SUFFIXES = {".sh", ".bash", ".zsh", ".ksh", ".dash", ".fish"}
SHELL_SHEBANG = re.compile(rb"^#![^\n]*[/\s](?:bash|dash|ksh|sh|zsh|fish)(?=[ \t\r\n]|$)")


def block_comment_end(source, cursor):
    depth = 1
    for match in BLOCK_DELIMITER.finditer(source, cursor):
        depth += 1 if match[0] == "/*" else -1
        if depth == 0:
            return match.end()
    return len(source)


def string_end(source, cursor, opener):
    quote = opener.lstrip("#")
    hashes = opener[:-len(quote)]
    close = quote + hashes
    escape = "\\" + hashes
    delimiter = re.compile(re.escape(close) + "|" + re.escape(escape))
    while match := delimiter.search(source, cursor):
        cursor = match.end()
        if match[0] == close:
            return cursor
        if source[cursor:cursor + 1] == "(":
            # Skip interpolations as part of the literal, including nested
            # strings and comments that contain parentheses or quotes.
            depth = 1
            for token, cursor in swift_tokens(source, cursor + 1):
                if token == "(":
                    depth += 1
                elif token == ")":
                    depth -= 1
                    if depth == 0:
                        break
            else:
                return len(source)
        else:
            cursor += 1
    return len(source)


def swift_tokens(source, cursor=0):
    while cursor < len(source):
        match = LEXEME.match(source, cursor)
        token = match[0]
        cursor = match.end()
        if token.isspace() or token.startswith("//"):
            continue
        if token == "/*":
            cursor = block_comment_end(source, cursor)
        elif token.endswith('"'):
            cursor = string_end(source, cursor, token)
            yield "<string literal>", cursor
        else:
            yield token.strip("`"), cursor


def has_before_argument(tokens, start):
    """Find the second label of run(mode:before:), past nested expressions."""
    depth = 0
    for index in range(start, len(tokens)):
        token = tokens[index]
        if depth == 0:
            if token == ",":
                return tokens[index + 1:index + 3] == ["before", ":"]
            if token == ")":
                return False
        if token in ("(", "[", "{"):
            depth += 1
        elif token in (")", "]", "}"):
            depth -= 1
    return False


def is_long_timeout(argument):
    if len(argument) >= 5 and argument[:3] == [".", "seconds", "("] and argument[4] == ")":
        argument = [argument[3], *argument[5:]]
    if len(argument) < 2 or argument[1] not in (",", ")"):
        return False
    literal = argument[0]
    if not NUMERIC_LITERAL.fullmatch(literal):
        return False

    literal = literal.replace("_", "").lower()
    if literal.startswith("0x") and ("p" in literal or "." in literal):
        try:
            return float.fromhex(literal) >= 30
        except OverflowError:
            return True
    if literal.startswith(("0x", "0b", "0o")):
        return int(literal, 0) >= 30
    return Decimal(literal) >= 30


def count_waits(source):
    tokens = [token for token, _ in swift_tokens(source)]
    counts = Counter()
    for index, token in enumerate(tokens):
        previous = tokens[index - 1] if index else ""
        if token == "timeout" and previous in ("(", ",") and tokens[index + 1:index + 2] == [":"]:
            if is_long_timeout(tokens[index + 2:index + 8]):
                counts["long_timeout"] += 1
        if token == "XCTSkip" and tokens[index + 1:index + 4] == [".", "init", "("]:
            counts["skip"] += 1
        if tokens[index + 1:index + 2] != ["("] or previous == "func":
            continue

        qualifier = tokens[index - 2] if previous == "." and index >= 2 else ""
        if token in ("sleep", "usleep"):
            if previous != "." or qualifier in ("Darwin", "Glibc") or (
                token == "sleep" and qualifier in ("Thread", "Task")
            ):
                counts["sleep"] += 1
        elif token in ("XCTSkip", "XCTSkipIf", "XCTSkipUnless"):
            counts["skip"] += 1
        elif token == "CFRunLoopRunInMode":
            counts["runloop"] += 1
        elif token == "run" and previous == ".":
            label = tokens[index + 2:index + 4]
            if (
                label == ["until", ":"]
                and index >= 4
                and tokens[index - 4:index - 2] == ["RunLoop", "."]
                and qualifier in ("current", "main")
            ) or (
                label == ["mode", ":"] and has_before_argument(tokens, index + 4)
            ):
                counts["runloop"] += 1
    return counts


def retry_settings(source):
    flags = RETRY_SETTING.findall(source)
    # Retry and iteration options may be assembled in separate shell variables.
    if flags:
        flags.extend(ITERATIONS.findall(source))
    return flags


def retry_source(path, relative):
    if path.suffix in (".xctestplan", ".xcscheme"):
        return True
    if relative.parts[:2] == (".github", "workflows"):
        return path.suffix in (".yml", ".yaml")
    if relative.parts[0] not in ("Scripts", "script"):
        return False
    if path.suffix in SHELL_SUFFIXES:
        return True
    if not path.suffix and path.stat().st_mode & 0o111:
        with path.open("rb") as stream:
            return bool(SHELL_SHEBANG.match(stream.readline(512)))
    return False


def scan(root):
    files = {}
    retry_flags = []
    swift_files = 0
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = sorted(set(subdirectories) - {".git", ".build", "build", "DerivedData"})
        for name in sorted(names):
            path = Path(directory) / name
            if path.is_symlink():
                continue
            relative = path.relative_to(root)
            if path.suffix == ".swift" and any(part.endswith("Tests") for part in relative.parts[:-1]):
                swift_files += 1
                counts = count_waits(path.read_text(encoding="utf-8"))
                if counts:
                    files[relative.as_posix()] = dict(counts)
            elif retry_source(path, relative):
                flags = retry_settings(path.read_text(encoding="utf-8"))
                retry_flags.extend(f"{relative.as_posix()}:{flag}" for flag in flags)
    return {"version": 1, "files": files, "retry_flags": sorted(retry_flags)}, swift_files


def read_allowance(path):
    allowance = json.loads(path.read_text(encoding="utf-8"))
    if (
        not isinstance(allowance, dict)
        or allowance.get("version") != 1
        or not isinstance(allowance.get("files"), dict)
        or not isinstance(allowance.get("retry_flags"), list)
    ):
        raise ValueError("expected version 1 with files and retry_flags")
    for name, counts in allowance["files"].items():
        if not isinstance(counts, dict) or not counts or any(
            pattern not in PATTERNS or type(count) is not int or count < 1
            for pattern, count in counts.items()
        ):
            raise ValueError(f"{name}: expected positive counts for known patterns; omit zero counts")
    if any(not isinstance(flag, str) or ":" not in flag for flag in allowance["retry_flags"]):
        raise ValueError("retry flags must be strings formatted as path:flag")
    return allowance


def differences(root, actual, allowance, *, raises_only=False):
    actual_files, allowed_files = actual["files"], allowance["files"]
    for path in sorted(actual_files.keys() | allowed_files.keys()):
        for pattern in PATTERNS:
            count = actual_files.get(path, {}).get(pattern, 0)
            allowed = allowed_files.get(path, {}).get(pattern, 0)
            if count > allowed or (count < allowed and not raises_only):
                yield diagnostic(path, pattern, count, allowed, (root / path).is_file())

    actual_flags = Counter(actual["retry_flags"])
    allowed_flags = Counter(allowance["retry_flags"])
    for flag in sorted(actual_flags.keys() | allowed_flags.keys()):
        count, allowed = actual_flags[flag], allowed_flags[flag]
        if count > allowed or (count < allowed and not raises_only):
            path = flag.split(":", 1)[0]
            yield diagnostic(flag, "retry_flags", count, allowed, (root / path).is_file())


def diagnostic(path, pattern, count, allowed, exists):
    if count > allowed:
        advice = ADVICE[pattern]
    elif not exists:
        advice = f"the file no longer exists; remove its entry in {ALLOWANCE_PATH} in this change"
    else:
        advice = f"you removed {allowed - count}; lower the allowance in {ALLOWANCE_PATH} in this change"
    return f"{path}: {pattern} count {count}, allowance {allowed}; {advice}"


def summary(actual, swift_files):
    files = actual["files"]
    totals = ", ".join(
        f"{pattern}={sum(counts.get(pattern, 0) for counts in files.values())} "
        f"in {sum(pattern in counts for counts in files.values())} files"
        for pattern in PATTERNS
    )
    return (
        f"Test wait guard: {swift_files} Swift test files scanned, {len(files)} with matches; "
        f"{totals}; retry_flags={len(actual['retry_flags'])}"
    )


def main(argv=None, *, root=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-allowance", action="store_true", help="write current counts")
    parser.add_argument("--allow-raise", action="store_true", help="permit increases when writing")
    args = parser.parse_args(argv)
    if args.allow_raise and not args.write_allowance:
        parser.error("--allow-raise requires --write-allowance")
    root = Path(__file__).resolve().parents[1] if root is None else root
    path = root / ALLOWANCE_PATH

    try:
        actual, swift_files = scan(root)
    except (OSError, ValueError) as error:
        print(f"Could not scan test waits: {error}")
        return 1
    try:
        errors = []
        if path.exists() or not args.write_allowance:
            allowance = read_allowance(path)
            if not args.allow_raise:
                errors = list(differences(root, actual, allowance, raises_only=args.write_allowance))
        if args.write_allowance:
            if errors:
                errors.append(
                    "Pass --allow-raise to increase an allowance and give a one-line reason in the pull request."
                )
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(actual, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (OSError, ValueError) as error:
        errors = [f"{ALLOWANCE_PATH}: {error}"]

    for error in errors:
        print(error)
    print(summary(actual, swift_files))
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
