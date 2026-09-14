"""Lossless RAT1 topology encoding; both paths reconstruct the original RME1."""
import ctypes
import os
from pathlib import Path
import struct
import sys


class CompactCodec:
    def __init__(self, library=None):
        suffix='dylib' if sys.platform=='darwin' else 'so'
        path=Path(library or os.environ.get('RIDGE_COMPACT_LIBRARY',f'/tmp/libridge_compact_mesh.{suffix}'))
        self.library=ctypes.CDLL(str(path))
        self.transform=self.library.ridge_compact_transform
        self.transform.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,
            ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t),ctypes.c_void_p,ctypes.c_size_t]
        self.transform.restype=ctypes.c_int

    def _run(self, mode, data):
        if not 28<=len(data)<=16*1024*1024:
            raise ValueError('Invalid codec input size')
        if mode:
            magic,nv,nt,iw,grid=struct.unpack('<4s4I',data[:20])
            if magic!=b'RAT1' or grid!=513 or not 4<=nv<=513*513 or not 2<=nt<=512*512*2 or iw not in (2,4):
                raise ValueError('Invalid topology header')
            capacity=28+nv*6+nt*3*iw
        else:
            capacity=len(data)+64
        incoming=ctypes.create_string_buffer(data)
        outgoing=ctypes.create_string_buffer(capacity)
        count=ctypes.c_size_t()
        error=ctypes.create_string_buffer(256)
        code=self.transform(mode,incoming,len(data),outgoing,capacity,ctypes.byref(count),error,256)
        if code:
            raise ValueError(error.value.decode('utf-8',errors='replace'))
        return outgoing.raw[:count.value]

    def encode(self, data):
        return self._run(0,data)

    def decode(self, data):
        return self._run(1,data)
