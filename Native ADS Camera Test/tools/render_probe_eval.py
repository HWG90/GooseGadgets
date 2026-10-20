"""Run a supplied read-only render research script through the existing bridge."""
import json
import re
import sys
from pathlib import Path
sys.path.insert(0, r'C:\Users\david\AppData\Local\LinksLinkToMemory\tools')
import llm
source = Path(sys.argv[1]).read_text()
result = str(llm.run(['eval local f=assert(loadstring('+json.dumps(source)+'));setfenv(f,getfenv(1));return f()'],timeout=45))
match = re.search(r'= bytes ([0-9a-fA-F]+)',result)
decoded = bytes.fromhex(match[1]).decode() if match else '\n'.join(x for x in result.splitlines() if ' > eval ' not in x)
Path(sys.argv[1]).with_suffix('.result.txt').write_text(decoded)
print(decoded)
