from pathlib import Path
import subprocess,hashlib
r=Path(__file__).resolve().parents[1];source=r/'native/terminal_input.c';out=r/'dist/terminal-input-native';out.mkdir(parents=True,exist_ok=True)
vc=Path(r'C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Auxiliary/Build/vcvars64.bat')
subprocess.run(f'call "{vc}" >nul && cl /nologo /LD /O2 /W4 /WX "{source}" /Fo"{out / "terminal_input.obj"}" /link /OUT:"{out / "terminal_input.dll"}" user32.lib',shell=True,check=True,cwd=out)
subprocess.run(f'call "{vc}" >nul && cl /nologo /O2 /W4 /WX "{r / "native/test_terminal_input.c"}" /Fo"{out / "test.obj"}" /Fe"{out / "test.exe"}" /link user32.lib',shell=True,check=True,cwd=out)
subprocess.run([str(out/'test.exe')],check=True)
data=(out/'terminal_input.dll').read_bytes();digest=hashlib.sha256(data).hexdigest()
(r/'compat/lll-0.1.14/src/terminal_input_binary.lua').write_text("-- Generated Bridge Combat input helper; build with native/build_terminal_input.py.\nreturn {sha256='"+digest+"',hex='"+data.hex()+"'}\n")
print('PASS native input policy; binary SHA256',digest)
