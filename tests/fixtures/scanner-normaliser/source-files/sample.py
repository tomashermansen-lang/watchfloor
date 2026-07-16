import sys
from pathlib import Path


def main():
    """Entry point."""
    root = Path(".")
    for f in root.iterdir():
        if f.suffix == ".py":
            print(f.name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
