"""Build/run focused native pending fixtures in isolated non-game processes."""
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    setup = Path(r"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat")
    for name in ("native_actor_pending", "native_core_pending"):
        args = ["cl.exe", "/nologo", "/MT", "/O2", "/EHsc", "/std:c++17", "/W4",
                f"/Fo{output / name}.obj", f"/Fe{output / name}.exe", str(ROOT / "tests" / f"{name}.cpp")]
        command = f'call "{setup}" >nul && {subprocess.list2cmdline(args)}'
        result = subprocess.run('cmd.exe /d /s /c "' + command + '"', cwd=output,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / f"{name}-build.log").write_text(result.stdout)
        if result.returncode:
            print(result.stdout)
            raise SystemExit(result.returncode)
        result = subprocess.run([str(output / f"{name}.exe")], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / f"{name}-result.txt").write_text(result.stdout)
        print(result.stdout.strip())
        if result.returncode:
            raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
