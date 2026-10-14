"""Validate BSL integration in an isolated LuaJIT and check archive contracts."""
from pathlib import Path
import argparse
import importlib.util
import unittest
from run_tests import DEFAULT_DLL, run_lua

ROOT = Path(__file__).resolve().parents[1]

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, default=DEFAULT_DLL)
    args = parser.parse_args()
    lua_result = run_lua(args.dll, ('backend.lua', 'contracts.lua', 'options.lua', 'bsl.lua'))
    spec = importlib.util.spec_from_file_location('hob_bsl_package_tests', ROOT / 'tests' / 'test_bsl_package.py')
    tests = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tests)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(tests))
    raise SystemExit(0 if lua_result == 0 and result.wasSuccessful() else 1)
