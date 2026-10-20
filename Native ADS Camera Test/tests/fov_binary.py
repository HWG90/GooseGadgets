"""Cold-load the independent FOV helper outside the game."""
import ctypes,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
DLL=ROOT/'dist/native/native_ads_fov_0_1_23.dll'
class Config(ctypes.Structure):
 _fields_=[('size',ctypes.c_uint32),('abi',ctypes.c_uint32)]+[(n,ctypes.c_uint64) for n in ('game','exe','context','camera','avatar_owner','request')]+[(n,ctypes.c_uint32) for n in ('avatar_index','avatar','body','weapon')]+[('reserved',ctypes.c_uint64)]
class Stats(ctypes.Structure):
 _fields_=[(n,ctypes.c_uint32) for n in ('size','abi','installed','armed','error','reserved')]+[(n,ctypes.c_uint64) for n in ('seen','forwarded','replaced','immediate_applies','binds','ads_forwarded')]+[(n,ctypes.c_float) for n in ('last_native','last_applied','source_degrees','padding')]
def main():
 assert ctypes.sizeof(Config)==80 and ctypes.sizeof(Stats)==88
 native=ctypes.WinDLL(str(DLL))
 types={'NADSF_Validate':[ctypes.POINTER(Config)],'NADSF_Begin':[ctypes.POINTER(Config),ctypes.POINTER(ctypes.c_uint64)],'NADSF_Bind':[ctypes.c_uint64,ctypes.c_uint64,ctypes.c_uint32],'NADSF_End':[ctypes.c_uint64],'NADSF_ReadStats':[ctypes.c_uint64,ctypes.POINTER(Stats)],'NADSF_Error':[]}
 for name,args in types.items():
  fn=getattr(native,name);fn.argtypes=args;fn.restype=ctypes.c_uint32
 s=Stats(size=88,abi=1);assert native.NADSF_ReadStats(0,ctypes.byref(s))==1
 assert s.installed==s.armed==s.replaced==s.immediate_applies==0
 c=Config(size=80,abi=1);assert native.NADSF_Validate(ctypes.byref(c))==0
 token=ctypes.c_uint64(12345);assert native.NADSF_Begin(ctypes.byref(c),ctypes.byref(token))==0 and token.value==0
 assert native.NADSF_Bind(0,0,0)==0 and native.NADSF_End(0)==0
 assert native.NADSF_ReadStats(0,ctypes.byref(s))==1 and s.installed==s.armed==0
 report={'dll_sha256':hashlib.sha256(DLL.read_bytes()).hexdigest(),'abi':1,'config_bytes':80,'stats_bytes':88,'six_exports_usable':True,'invalid_begin_zeroes_token':True,'zero_token_cannot_bind_or_end':True,'cold_unarmed':True,'separate_process':True}
 (ROOT/'dist/native/cold-fov-dll-abi.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
 print('Cold FOV DLL ABI passed: 6 exports, 80/88-byte layouts, zero-token rejection, no hooks armed')
if __name__=='__main__':main()
