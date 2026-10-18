"""Shared helpers for printing and summarising test results."""


def report(label: str, ok: bool, detail: str = "", width: int = 46) -> bool:
    """Prints one result line; returns ok so callers can collect it."""
    print(f"  {label:<{width}} {'OK' if ok else 'ERROR':<6} {detail}")
    return ok


def summarise(results: list[bool]) -> bool:
    """Prints the tally; True = everything passed."""
    failed = results.count(False)
    if failed:
        print(f"\n{failed} of {len(results)} checks failed.")
    else:
        print(f"\nAll {len(results)} checks passed.")
    return failed == 0
