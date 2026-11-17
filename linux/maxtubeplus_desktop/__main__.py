import os
import sys
import tempfile


def main():
    if "--self-test" in sys.argv:
        # Isolate the self-test from the real user's config/cache/downloads.
        # Must happen before the package reads its XDG paths on import.
        home = tempfile.mkdtemp(prefix="mtp-selftest-")
        for var, sub in (("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data")):
            os.environ[var] = os.path.join(home, sub)
    if "--version" in sys.argv:
        from . import __version__
        print(f"MaxTubePlus Desktop {__version__}")
        return 0
    from .ui.app import main as run
    return run()


if __name__ == "__main__":
    sys.exit(main())
