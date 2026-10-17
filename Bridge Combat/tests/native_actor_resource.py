"""Exercise the compiled resource reader with isolated synthetic memory only."""
import argparse
import ctypes as C
import struct

GRAPH = 0xA486D4045106165C
NAME = 0x4D1C334D294DFA97
END = 0x7FFFFFFF
EMPTY = 0xFFFFFFFE


class Fixture:
    def __init__(self, type_overflow=False, name_overflow=False):
        # Actual batch307 dimensions distinguish storage from the hash modulus.
        self.manager = C.create_string_buffer(0x340)
        self.types = C.create_string_buffer(109 * 0xD0)
        self.names = C.create_string_buffer(218 * 24)
        self.rows = C.create_string_buffer(144 * 0xA0)
        self.graph = C.create_string_buffer(128)
        self.buffers = [self.manager, self.types, self.names, self.rows, self.graph]
        for i in range(109): self.put(self.types, i * 0xD0 + 0xC8, "I", EMPTY)
        for i in range(218): self.put(self.names, i * 24 + 16, "I", EMPTY)
        self.put(self.manager, 0x2E8, "IIQ", 109, 109, C.addressof(self.types))
        self.put(self.manager, 0x300, "II", 59, 79)
        head = (GRAPH >> 32) % 79
        self.ti = 94 if type_overflow else head
        if type_overflow:
            self.put(self.types, head * 0xD0, "Q", GRAPH ^ 1)
            self.put(self.types, head * 0xD0 + 0xC8, "I", self.ti)
        t = self.ti * 0xD0
        self.put(self.types, t, "Q", GRAPH)
        self.put(self.types, t + 8, "IIQ", 144, 150, C.addressof(self.rows))
        self.put(self.types, t + 0x20, "IIQ", 218, 218, C.addressof(self.names))
        self.put(self.types, t + 0x38, "II", 79, 159)
        self.put(self.types, t + 0xC8, "I", END)
        head = (NAME >> 32) % 159
        self.ni = 185 if name_overflow else head
        if name_overflow:
            self.put(self.names, head * 24, "Q", NAME ^ 1)
            self.put(self.names, head * 24 + 16, "I", self.ni)
        self.put(self.names, self.ni * 24, "QII", NAME, 93, 0)
        self.put(self.names, self.ni * 24 + 16, "I", END)
        self.put(self.rows, 93 * 0xA0, "Q", C.addressof(self.graph))
        self.put(self.graph, 0, "I", 22)

    @staticmethod
    def put(buffer, offset, fmt, *values):
        data = struct.pack("<" + fmt, *values)
        C.memmove(C.addressof(buffer) + offset, data, len(data))

    def snapshot(self):
        return [bytes(buffer) for buffer in self.buffers]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dll", help="Review helper built with --test-api")
    args = parser.parse_args()
    dll = C.CDLL(args.dll)
    query = dll.BC_test_actor_resource
    query.argtypes = [C.c_size_t, C.c_uint64, C.c_uint64, C.POINTER(C.c_size_t)]
    query.restype = C.c_uint32
    passed = 0

    def check(name, fixture, expected, key=NAME):
        nonlocal passed
        before = fixture.snapshot()
        result = C.c_size_t(0)
        ok = bool(query(C.addressof(fixture.manager), GRAPH, key, C.byref(result)))
        assert ok == expected, name
        assert fixture.snapshot() == before, name + " mutated its source"
        if expected: assert result.value == C.addressof(fixture.graph), name + " wrong resource"
        passed += 1

    check("direct heads", Fixture(), True)
    check("overflow name node beyond modulus", Fixture(name_overflow=True), True)
    check("overflow type node beyond modulus", Fixture(type_overflow=True), True)
    check("both overflow chains", Fixture(True, True), True)
    check("missing name refuses fallback", Fixture(), False, NAME ^ 1)
    f = Fixture(name_overflow=True)
    f.put(f.names, ((NAME >> 32) % 159) * 24 + 16, "I", 218)
    check("out-of-storage chain refused", f, False)
    f = Fixture(name_overflow=True)
    f.put(f.names, f.ni * 24, "Q", NAME ^ 1)
    f.put(f.names, f.ni * 24 + 16, "I", f.ni)
    check("cyclic chain bounded", f, False)
    f = Fixture()
    f.put(f.names, f.ni * 24 + 8, "I", 144)
    check("out-of-resource row refused", f, False)
    f = Fixture()
    f.put(f.rows, 93 * 0xA0, "Q", 0)
    check("null resource refused", f, False)
    f = Fixture()
    f.put(f.types, f.ti * 0xD0 + 0x3C, "I", 0)
    check("zero modulus refused", f, False)
    print(f"{passed}/10 native actor resource contracts passed; all reads preserved source memory")


if __name__ == "__main__":
    main()
