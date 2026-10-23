#!/usr/bin/env python3
"""Copy every non-system dylib the binary needs into Contents/Frameworks and
rewrite load paths to @rpath, so the app does not depend on Homebrew paths."""
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def dependencies(path):
    output = subprocess.run(["otool", "-L", path], check=True, capture_output=True, text=True).stdout
    lines = output.splitlines()[1:]
    return [line.strip().split(" (")[0] for line in lines]


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


def bundle(binary, frameworks):
    os.makedirs(frameworks, exist_ok=True)
    pending = [binary]
    copied = {}
    while pending:
        current = pending.pop()
        for dependency in dependencies(current):
            if dependency.startswith(SYSTEM_PREFIXES) or dependency.startswith("@"):
                continue
            name = os.path.basename(dependency)
            target = os.path.join(frameworks, name)
            if dependency not in copied:
                shutil.copy(os.path.realpath(dependency), target)
                os.chmod(target, 0o755)
                run("install_name_tool", "-id", f"@rpath/{name}", target)
                copied[dependency] = target
                pending.append(target)
            run("install_name_tool", "-change", dependency, f"@rpath/{name}", current)
    run("install_name_tool", "-add_rpath", "@executable_path/../Frameworks", binary)
    for name in sorted(os.path.basename(p) for p in copied):
        print(f"  bundled {name}")


if __name__ == "__main__":
    bundle(sys.argv[1], sys.argv[2])
