"""Optional Vulkan 1.2 language probes; stdlib only, actual Delphi CPU reference."""
from __future__ import annotations

import ctypes as C
import json
import math
from pathlib import Path
import random
import struct
import subprocess

from vulkan_smoke import VulkanRuntime, structure, HEADER, U32, PTR, checked, compile_shader

Features = structure('Features', [('flags', U32 * 55)])
Features2 = structure('Features2', HEADER + [('features', Features)])
Storage16 = structure('Storage16', HEADER + [(n, U32) for n in (
    'storageBuffer16BitAccess', 'uniformAndStorageBuffer16BitAccess',
    'storagePushConstant16', 'storageInputOutput16')])
V12_NAMES = '''samplerMirrorClampToEdge drawIndirectCount storageBuffer8BitAccess
uniformAndStorageBuffer8BitAccess storagePushConstant8 shaderBufferInt64Atomics
shaderSharedInt64Atomics shaderFloat16 shaderInt8 descriptorIndexing
shaderInputAttachmentArrayDynamicIndexing shaderUniformTexelBufferArrayDynamicIndexing
shaderStorageTexelBufferArrayDynamicIndexing shaderUniformBufferArrayNonUniformIndexing
shaderSampledImageArrayNonUniformIndexing shaderStorageBufferArrayNonUniformIndexing
shaderStorageImageArrayNonUniformIndexing shaderInputAttachmentArrayNonUniformIndexing
shaderUniformTexelBufferArrayNonUniformIndexing shaderStorageTexelBufferArrayNonUniformIndexing
descriptorBindingUniformBufferUpdateAfterBind descriptorBindingSampledImageUpdateAfterBind
descriptorBindingStorageImageUpdateAfterBind descriptorBindingStorageBufferUpdateAfterBind
descriptorBindingUniformTexelBufferUpdateAfterBind descriptorBindingStorageTexelBufferUpdateAfterBind
descriptorBindingUpdateUnusedWhilePending descriptorBindingPartiallyBound descriptorBindingVariableDescriptorCount
runtimeDescriptorArray samplerFilterMinmax scalarBlockLayout imagelessFramebuffer uniformBufferStandardLayout
shaderSubgroupExtendedTypes separateDepthStencilLayouts hostQueryReset timelineSemaphore bufferDeviceAddress
bufferDeviceAddressCaptureReplay bufferDeviceAddressMultiDevice vulkanMemoryModel vulkanMemoryModelDeviceScope
vulkanMemoryModelAvailabilityVisibilityChains shaderOutputViewportIndex shaderOutputLayer subgroupBroadcastDynamicId'''.split()
V12Features = structure('V12Features', HEADER + [(n, U32) for n in V12_NAMES])
FLOAT_NAMES = [f'shader{kind}Float{width}' for kind in (
    'SignedZeroInfNanPreserve', 'DenormPreserve', 'DenormFlushToZero', 'RoundingModeRTE', 'RoundingModeRTZ')
    for width in (16, 32, 64)]
V12Properties = structure('V12Properties', HEADER + [
    ('driverID', U32), ('driverName', C.c_char * 256), ('driverInfo', C.c_char * 256),
    ('conformanceVersion', C.c_ubyte * 4), ('denormBehaviorIndependence', U32), ('roundingModeIndependence', U32)]
    + [(n, U32) for n in FLOAT_NAMES] + [('tail', C.c_ubyte * 256)])
Properties2 = structure('Properties2', HEADER + [('data', C.c_ubyte * 4096)])


class ExtendedRuntime(VulkanRuntime):
    def __init__(self):
        super().__init__((1 << 22) | (2 << 12))

    def configure_device(self, info):
        self.bind('vkGetPhysicalDeviceFeatures2', None, PTR, C.POINTER(Features2))
        self.bind('vkGetPhysicalDeviceProperties2', None, PTR, C.POINTER(Properties2))
        available12 = V12Features(sType=51)
        available16 = Storage16(sType=1000083000, pNext=C.addressof(available12))
        available = Features2(sType=1000059000, pNext=C.addressof(available16))
        self.vkGetPhysicalDeviceFeatures2(self.physical, C.byref(available))
        properties12 = V12Properties(sType=52)
        properties = Properties2(sType=1000059001, pNext=C.addressof(properties12))
        self.vkGetPhysicalDeviceProperties2(self.physical, C.byref(properties))
        self.enabled = set()
        self.core = Features()
        for index, name in ((39, 'shaderFloat64'), (40, 'shaderInt64'), (41, 'shaderInt16')):
            if not available.features.flags[index]:
                raise RuntimeError(f'Extended probes require {name}')
            self.core.flags[index] = 1
            self.enabled.add(name)
        self.f12 = V12Features(sType=51)
        for name in ('storageBuffer8BitAccess', 'storagePushConstant8', 'shaderInt8'):
            if not getattr(available12, name):
                raise RuntimeError(f'Extended probes require {name}')
            setattr(self.f12, name, 1)
            self.enabled.add(name)
        self.f16 = Storage16(sType=1000083000, pNext=C.addressof(self.f12))
        for name in ('storageBuffer16BitAccess', 'storagePushConstant16'):
            if not getattr(available16, name):
                raise RuntimeError(f'Extended probes require {name}')
            setattr(self.f16, name, 1)
            self.enabled.add(name)
        for width in (32, 64):
            for kind in ('SignedZeroInfNanPreserve', 'DenormPreserve', 'RoundingModeRTE'):
                name = f'shader{kind}Float{width}'
                if not getattr(properties12, name):
                    raise RuntimeError(f'Strict probes require {name}')
                self.enabled.add(name)
        info.pEnabledFeatures = C.addressof(self.core)
        info.pNext = C.addressof(self.f16)

    def run(self, module, *args, **kwargs):
        metadata = json.loads(module.with_suffix('.json').read_text('utf-8'))
        missing = set(metadata['required_features']) - self.enabled
        if missing:
            raise RuntimeError(f'Device features not enabled: {missing}')
        return super().run(module, *args, **kwargs)


def run_extended_tests(root: Path):
    output = root / 'build/vulkan-extended'
    output.mkdir(parents=True, exist_ok=True)
    count = 128
    rng = random.Random(192834)
    integers = [0, 1, (1 << 64)-1, 1 << 63, (1 << 63)-1, 0x12345678ABCDEF00]
    integers += [rng.getrandbits(64) for _ in range(count-len(integers))]
    floats = [0.0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5,
              float('inf'), -float('inf'), float('nan'), 1e100, -1e100,
              2**-1074, -(2**-1074), 2**-1022, 2147483648.0, -2147483648.0,
              2147483647.0, 2147483647.5, -2147483648.5,
              math.nextafter(2**63, 0.0), float(2**63), math.nextafter(-2**63, -math.inf)]
    floats += [rng.uniform(-1e6, 1e6) for _ in range(count-len(floats))]
    raw_int = struct.pack(f'<{count}Q', *integers)
    raw_float = struct.pack(f'<{count}d', *floats)
    (output / 'ints.bin').write_bytes(raw_int)
    (output / 'reals.bin').write_bytes(raw_float)
    reference = root / 'build/bin/ExtendedNumericCheck.exe'
    subprocess.run([str(reference), str(output/'ints.bin'), str(output/'reals.bin'),
                    str(output/'expected.bin')], check=True, capture_output=True)
    expected = struct.unpack(f'<{count*28}Q', (output/'expected.bin').read_bytes())
    with ExtendedRuntime() as runtime:
        for optimize in (False, True):
            numeric = compile_shader(root, output, 'extended_numeric', 'tests/fixtures', optimize=optimize)
            result = runtime.run(numeric, {
                'Input': raw_int, 'Reals': raw_float,
                'Bytes': bytes((i*3) & 255 for i in range(count)),
                'Words': struct.pack(f'<{count}H', *((i*1009) & 65535 for i in range(count))),
                'Output': bytes(count*28*8)}, b'', 2)
            actual = struct.unpack(f'<{count*28}Q', result['Output'])
            for index, (a, b) in enumerate(zip(actual, expected)):
                slot = index % 28
                if slot in (17, 18, 19, 20) and math.isnan(struct.unpack('<d', struct.pack('<Q', b))[0]):
                    assert math.isnan(struct.unpack('<d', struct.pack('<Q', a))[0])
                else:
                    assert a == b, f'numeric {index//28}:{slot} O{int(optimize)}: {a:016x} != {b:016x}'
            refs = compile_shader(root, output, 'extended_references', 'tests/fixtures', optimize=optimize)
            result = runtime.run(refs, {'Output': bytes(64*9*4)}, b'', 1)
            actual = struct.unpack('<576i', result['Output'])
            for i in range(64):
                assert actual[i*9:(i+1)*9] == (2*(i+1), 6, 11, 2, 7, 10, 5, 9, 123), actual[i*9:(i+1)*9]
            alias = compile_shader(root, output, 'extended_alias', 'tests/fixtures', optimize=optimize)
            result = runtime.run(alias, {'Bytes': bytes(256), 'Words': bytes(256),
                                       'Wide': bytes(256), 'Output': bytes(512)}, b'', 1,
                                 aliases={'Words': 'Bytes', 'Wide': 'Bytes'})
            actual = struct.unpack('<128I', result['Output'])
            for i in range(64):
                assert actual[2*i] == (i | ((i+1) << 8) | ((0xAB00+i) << 16))
                assert actual[2*i+1] == i | ((i+1) << 8)
            table = compile_shader(root, output, 'constant_tables')
            result = runtime.run(table, {'Output': bytes(64*4)}, b'', 1)
            assert struct.unpack('<64i', result['Output']) == (2, 4, 8, 16) * 16
            # Language 1.3: references to variables captured by nested routines, var overloads, forward.
            group2 = compile_shader(root, output, 'syntax_group2_refs', 'tests/fixtures', optimize=optimize)
            result = runtime.run(group2, {'Output': bytes(64*4*4)}, b'', 1)
            actual = struct.unpack('<256i', result['Output'])
            for i in range(64):
                want = (170 + i, 26, 14, 100 if i & 3 == 3 else 0)
                assert actual[i*4:(i+1)*4] == want, f'syntax_group2_refs O{int(optimize)} {i}: {actual[i*4:(i+1)*4]} != {want}'
        print(f'PASS: extended Vulkan 1.2, {runtime.dispatches} dispatches, Delphi numeric reference, '
              'true reference aliases, control flow, byte/word alias views, nested captures, O0/O1.')


if __name__ == '__main__':
    run_extended_tests(Path(__file__).resolve().parents[1])
