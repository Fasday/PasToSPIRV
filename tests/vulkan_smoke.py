"""Optional, real Vulkan dispatch tests. Python stdlib only; no compiler dependency.

Run scripts/build.ps1 first, then: python tests/vulkan_smoke.py
Requires a 64-bit Python, Vulkan loader and a compute-capable Vulkan device.
The small runtime is test infrastructure, not the public integration API.
"""

from __future__ import annotations

import ctypes as C
import ctypes.util
import argparse
import json
import math
import random
from pathlib import Path
import struct
import subprocess
import sys
from contextlib import ExitStack


U32, U64, I32 = C.c_uint32, C.c_uint64, C.c_int32
PTR = C.c_void_p
P32, P64, PPTR = C.POINTER(U32), C.POINTER(U64), C.POINTER(PTR)


def structure(name, fields):
    return type(name, (C.Structure,), {"_fields_": fields})


HEADER = [("sType", U32), ("pNext", PTR)]
ApplicationInfo = structure("ApplicationInfo", HEADER + [
    ("pApplicationName", C.c_char_p), ("applicationVersion", U32),
    ("pEngineName", C.c_char_p), ("engineVersion", U32), ("apiVersion", U32)])
InstanceCreateInfo = structure("InstanceCreateInfo", HEADER + [
    ("flags", U32), ("pApplicationInfo", C.POINTER(ApplicationInfo)),
    ("enabledLayerCount", U32), ("ppEnabledLayerNames", PTR),
    ("enabledExtensionCount", U32), ("ppEnabledExtensionNames", PTR)])
DeviceQueueCreateInfo = structure("DeviceQueueCreateInfo", HEADER + [
    ("flags", U32), ("queueFamilyIndex", U32), ("queueCount", U32),
    ("pQueuePriorities", C.POINTER(C.c_float))])
DeviceCreateInfo = structure("DeviceCreateInfo", HEADER + [
    ("flags", U32), ("queueCreateInfoCount", U32),
    ("pQueueCreateInfos", C.POINTER(DeviceQueueCreateInfo)),
    ("enabledLayerCount", U32), ("ppEnabledLayerNames", PTR),
    ("enabledExtensionCount", U32), ("ppEnabledExtensionNames", PTR),
    ("pEnabledFeatures", PTR)])
Extent3D = structure("Extent3D", [("width", U32), ("height", U32), ("depth", U32)])
QueueFamilyProperties = structure("QueueFamilyProperties", [
    ("queueFlags", U32), ("queueCount", U32), ("timestampValidBits", U32),
    ("minImageTransferGranularity", Extent3D)])
MemoryType = structure("MemoryType", [("propertyFlags", U32), ("heapIndex", U32)])
MemoryHeap = structure("MemoryHeap", [("size", U64), ("flags", U32)])
MemoryProperties = structure("MemoryProperties", [
    ("memoryTypeCount", U32), ("memoryTypes", MemoryType * 32),
    ("memoryHeapCount", U32), ("memoryHeaps", MemoryHeap * 16)])
BufferCreateInfo = structure("BufferCreateInfo", HEADER + [
    ("flags", U32), ("size", U64), ("usage", U32), ("sharingMode", U32),
    ("queueFamilyIndexCount", U32), ("pQueueFamilyIndices", P32)])
MemoryRequirements = structure("MemoryRequirements", [
    ("size", U64), ("alignment", U64), ("memoryTypeBits", U32)])
MemoryAllocateInfo = structure("MemoryAllocateInfo", HEADER + [
    ("allocationSize", U64), ("memoryTypeIndex", U32)])
LayoutBinding = structure("LayoutBinding", [
    ("binding", U32), ("descriptorType", U32), ("descriptorCount", U32),
    ("stageFlags", U32), ("pImmutableSamplers", PTR)])
DescriptorSetLayoutCreateInfo = structure("DescriptorSetLayoutCreateInfo", HEADER + [
    ("flags", U32), ("bindingCount", U32), ("pBindings", C.POINTER(LayoutBinding))])
PushConstantRange = structure("PushConstantRange", [
    ("stageFlags", U32), ("offset", U32), ("size", U32)])
PipelineLayoutCreateInfo = structure("PipelineLayoutCreateInfo", HEADER + [
    ("flags", U32), ("setLayoutCount", U32), ("pSetLayouts", P64),
    ("pushConstantRangeCount", U32), ("pPushConstantRanges", C.POINTER(PushConstantRange))])
ShaderModuleCreateInfo = structure("ShaderModuleCreateInfo", HEADER + [
    ("flags", U32), ("codeSize", C.c_size_t), ("pCode", P32)])
PipelineShaderStageCreateInfo = structure("PipelineShaderStageCreateInfo", HEADER + [
    ("flags", U32), ("stage", U32), ("module", U64), ("pName", C.c_char_p),
    ("pSpecializationInfo", PTR)])
ComputePipelineCreateInfo = structure("ComputePipelineCreateInfo", HEADER + [
    ("flags", U32), ("stage", PipelineShaderStageCreateInfo), ("layout", U64),
    ("basePipelineHandle", U64), ("basePipelineIndex", I32)])
DescriptorPoolSize = structure("DescriptorPoolSize", [("type", U32), ("descriptorCount", U32)])
DescriptorPoolCreateInfo = structure("DescriptorPoolCreateInfo", HEADER + [
    ("flags", U32), ("maxSets", U32), ("poolSizeCount", U32),
    ("pPoolSizes", C.POINTER(DescriptorPoolSize))])
DescriptorSetAllocateInfo = structure("DescriptorSetAllocateInfo", HEADER + [
    ("descriptorPool", U64), ("descriptorSetCount", U32), ("pSetLayouts", P64)])
DescriptorBufferInfo = structure("DescriptorBufferInfo", [
    ("buffer", U64), ("offset", U64), ("range", U64)])
WriteDescriptorSet = structure("WriteDescriptorSet", HEADER + [
    ("dstSet", U64), ("dstBinding", U32), ("dstArrayElement", U32),
    ("descriptorCount", U32), ("descriptorType", U32), ("pImageInfo", PTR),
    ("pBufferInfo", C.POINTER(DescriptorBufferInfo)), ("pTexelBufferView", PTR)])
CommandPoolCreateInfo = structure("CommandPoolCreateInfo", HEADER + [
    ("flags", U32), ("queueFamilyIndex", U32)])
CommandBufferAllocateInfo = structure("CommandBufferAllocateInfo", HEADER + [
    ("commandPool", U64), ("level", U32), ("commandBufferCount", U32)])
CommandBufferBeginInfo = structure("CommandBufferBeginInfo", HEADER + [
    ("flags", U32), ("pInheritanceInfo", PTR)])
MemoryBarrier = structure("MemoryBarrier", HEADER + [
    ("srcAccessMask", U32), ("dstAccessMask", U32)])
FenceCreateInfo = structure("FenceCreateInfo", HEADER + [("flags", U32)])
SubmitInfo = structure("SubmitInfo", HEADER + [
    ("waitSemaphoreCount", U32), ("pWaitSemaphores", P64), ("pWaitDstStageMask", P32),
    ("commandBufferCount", U32), ("pCommandBuffers", PPTR),
    ("signalSemaphoreCount", U32), ("pSignalSemaphores", P64)])


def checked(result, operation):
    if result != 0:
        raise RuntimeError(f"{operation} failed: VkResult {result}")


class StorageBuffer:
    def __init__(self, runtime, payload, cleanup):
        self.runtime = runtime
        self.buffer, self.memory, self.mapping = U64(), U64(), PTR()
        self.size = len(payload)
        cleanup.callback(self.close)
        info = BufferCreateInfo(sType=12, size=self.size, usage=0x23)
        checked(runtime.vkCreateBuffer(runtime.device, C.byref(info), None,
                                       C.byref(self.buffer)), "vkCreateBuffer")
        requirements = MemoryRequirements()
        runtime.vkGetBufferMemoryRequirements(runtime.device, self.buffer, C.byref(requirements))
        properties = MemoryProperties()
        runtime.vkGetPhysicalDeviceMemoryProperties(runtime.physical, C.byref(properties))
        memory_index = next((i for i in range(properties.memoryTypeCount)
                             if requirements.memoryTypeBits & (1 << i)
                             and properties.memoryTypes[i].propertyFlags & 6 == 6), None)
        if memory_index is None:
            raise RuntimeError("This smoke test requires host-visible, host-coherent buffer memory")
        allocation = MemoryAllocateInfo(sType=5, allocationSize=requirements.size,
                                        memoryTypeIndex=memory_index)
        checked(runtime.vkAllocateMemory(runtime.device, C.byref(allocation), None,
                                         C.byref(self.memory)), "vkAllocateMemory")
        checked(runtime.vkBindBufferMemory(runtime.device, self.buffer, self.memory, 0),
                "vkBindBufferMemory")
        checked(runtime.vkMapMemory(runtime.device, self.memory, 0, self.size, 0,
                                    C.byref(self.mapping)), "vkMapMemory")
        C.memmove(self.mapping, payload, self.size)

    def close(self):
        if self.mapping:
            self.runtime.vkUnmapMemory(self.runtime.device, self.memory)
        if self.buffer:
            self.runtime.vkDestroyBuffer(self.runtime.device, self.buffer, None)
        if self.memory:
            self.runtime.vkFreeMemory(self.runtime.device, self.memory, None)


class VulkanRuntime:
    def __init__(self, api_version=1 << 22):
        if C.sizeof(PTR) != 8:
            raise RuntimeError("The Vulkan smoke test requires 64-bit Python")
        library = "vulkan-1.dll" if sys.platform == "win32" else C.util.find_library("vulkan")
        if not library:
            raise RuntimeError("Vulkan loader was not found")
        self.library = (C.WinDLL if sys.platform == "win32" else C.CDLL)(library)
        self.cleanup = ExitStack()
        self.device, self.instance, self.queue = PTR(), PTR(), PTR()
        self.dispatches = 0
        self.api_version = api_version
        self._bind_functions()

    def bind(self, name, result, *arguments):
        function = getattr(self.library, name)
        function.restype, function.argtypes = result, arguments
        setattr(self, name, function)

    def _bind_functions(self):
        self.bind("vkCreateInstance", I32, C.POINTER(InstanceCreateInfo), PTR, PPTR)
        self.bind("vkDestroyInstance", None, PTR, PTR)
        self.bind("vkEnumeratePhysicalDevices", I32, PTR, P32, PPTR)
        self.bind("vkGetPhysicalDeviceQueueFamilyProperties", None, PTR, P32,
                  C.POINTER(QueueFamilyProperties))
        self.bind("vkGetPhysicalDeviceMemoryProperties", None, PTR, C.POINTER(MemoryProperties))
        self.bind("vkCreateDevice", I32, PTR, C.POINTER(DeviceCreateInfo), PTR, PPTR)
        self.bind("vkDestroyDevice", None, PTR, PTR)
        self.bind("vkGetDeviceQueue", None, PTR, U32, U32, PPTR)
        self.bind("vkDeviceWaitIdle", I32, PTR)
        for name, info in [("Buffer", BufferCreateInfo), ("DescriptorSetLayout", DescriptorSetLayoutCreateInfo),
                           ("PipelineLayout", PipelineLayoutCreateInfo), ("ShaderModule", ShaderModuleCreateInfo),
                           ("DescriptorPool", DescriptorPoolCreateInfo), ("CommandPool", CommandPoolCreateInfo),
                           ("Fence", FenceCreateInfo)]:
            self.bind("vkCreate" + name, I32, PTR, C.POINTER(info), PTR, P64)
            self.bind("vkDestroy" + name, None, PTR, U64, PTR)
        self.bind("vkDestroyPipeline", None, PTR, U64, PTR)
        self.bind("vkGetBufferMemoryRequirements", None, PTR, U64, C.POINTER(MemoryRequirements))
        self.bind("vkAllocateMemory", I32, PTR, C.POINTER(MemoryAllocateInfo), PTR, P64)
        self.bind("vkFreeMemory", None, PTR, U64, PTR)
        self.bind("vkBindBufferMemory", I32, PTR, U64, U64, U64)
        self.bind("vkMapMemory", I32, PTR, U64, U64, U64, U32, PPTR)
        self.bind("vkUnmapMemory", None, PTR, U64)
        self.bind("vkCreateComputePipelines", I32, PTR, U64, U32,
                  C.POINTER(ComputePipelineCreateInfo), PTR, P64)
        self.bind("vkAllocateDescriptorSets", I32, PTR, C.POINTER(DescriptorSetAllocateInfo), P64)
        self.bind("vkUpdateDescriptorSets", None, PTR, U32, C.POINTER(WriteDescriptorSet), U32, PTR)
        self.bind("vkAllocateCommandBuffers", I32, PTR, C.POINTER(CommandBufferAllocateInfo), PPTR)
        self.bind("vkBeginCommandBuffer", I32, PTR, C.POINTER(CommandBufferBeginInfo))
        self.bind("vkEndCommandBuffer", I32, PTR)
        self.bind("vkCmdBindPipeline", None, PTR, U32, U64)
        self.bind("vkCmdBindDescriptorSets", None, PTR, U32, U64, U32, U32, P64, U32, P32)
        self.bind("vkCmdPushConstants", None, PTR, U64, U32, U32, U32, PTR)
        self.bind("vkCmdDispatch", None, PTR, U32, U32, U32)
        self.bind("vkCmdPipelineBarrier", None, PTR, U32, U32, U32, U32,
                  C.POINTER(MemoryBarrier), U32, PTR, U32, PTR)
        self.bind("vkQueueSubmit", I32, PTR, U32, C.POINTER(SubmitInfo), U64)
        self.bind("vkWaitForFences", I32, PTR, U32, P64, U32, U64)

    def __enter__(self):
        try:
            app = ApplicationInfo(sType=0, pApplicationName=b"PasToSPIRV smoke", apiVersion=self.api_version)
            instance_info = InstanceCreateInfo(sType=1, pApplicationInfo=C.pointer(app))
            checked(self.vkCreateInstance(C.byref(instance_info), None, C.byref(self.instance)),
                    "vkCreateInstance")
            self.cleanup.callback(self.vkDestroyInstance, self.instance, None)
            count = U32()
            checked(self.vkEnumeratePhysicalDevices(self.instance, C.byref(count), None),
                    "vkEnumeratePhysicalDevices")
            devices = (PTR * count.value)()
            checked(self.vkEnumeratePhysicalDevices(self.instance, C.byref(count), devices),
                    "vkEnumeratePhysicalDevices")
            selected = None
            for device_index, physical in enumerate(devices):
                queue_count = U32()
                self.vkGetPhysicalDeviceQueueFamilyProperties(physical, C.byref(queue_count), None)
                families = (QueueFamilyProperties * queue_count.value)()
                self.vkGetPhysicalDeviceQueueFamilyProperties(physical, C.byref(queue_count), families)
                for family_index, family in enumerate(families):
                    if family.queueCount and family.queueFlags & 2:
                        selected = physical, device_index, family_index
                        break
                if selected:
                    break
            if not selected:
                raise RuntimeError("No Vulkan device with a compute queue was found")
            self.physical, self.device_index, self.family = selected
            priority = C.c_float(1.0)
            queue_info = DeviceQueueCreateInfo(sType=2, queueFamilyIndex=self.family,
                                              queueCount=1, pQueuePriorities=C.pointer(priority))
            device_info = DeviceCreateInfo(sType=3, queueCreateInfoCount=1,
                                          pQueueCreateInfos=C.pointer(queue_info))
            self.configure_device(device_info)
            checked(self.vkCreateDevice(self.physical, C.byref(device_info), None,
                                        C.byref(self.device)), "vkCreateDevice")
            self.cleanup.callback(self.vkDestroyDevice, self.device, None)
            self.vkGetDeviceQueue(self.device, self.family, 0, C.byref(self.queue))
            return self
        except BaseException:
            self.cleanup.close()
            raise

    def __exit__(self, *exception):
        self.cleanup.close()

    def configure_device(self, device_info):
        """Optional test-only feature hook; the default Vulkan 1.0 path is unchanged."""

    def create(self, name, info, cleanup):
        handle = U64()
        checked(getattr(self, "vkCreate" + name)(self.device, C.byref(info), None,
                                                C.byref(handle)), "vkCreate" + name)
        cleanup.callback(getattr(self, "vkDestroy" + name), self.device, handle.value, None)
        return handle.value

    def run(self, module, payloads, push_constants, group_count, aliases=None):
        metadata = json.loads(module.with_suffix(".json").read_text(encoding="utf-8"))
        if any(item["set"] != 0 for item in metadata["buffers"]):
            raise RuntimeError("The smoke runtime only supports descriptor set 0")
        expected_push_size = sum(item["size"] for item in metadata["push_constants"])
        if len(push_constants) != expected_push_size:
            raise RuntimeError("Push-constant payload does not match reflection")
        with ExitStack() as cleanup:
            allocated = {}
            buffers = []
            for item in metadata["buffers"]:
                name = item['name']
                root_name = (aliases or {}).get(name, name)
                if root_name not in allocated:
                    allocated[root_name] = StorageBuffer(self, payloads[root_name], cleanup)
                if len(payloads[name]) != allocated[root_name].size:
                    raise ValueError('Aliased test descriptors must have the same size')
                buffers.append(allocated[root_name])
            count = len(buffers)
            bindings = (LayoutBinding * count)(*(
                LayoutBinding(binding=item["binding"], descriptorType=7, descriptorCount=1,
                              stageFlags=0x20) for item in metadata["buffers"]))
            layout_info = DescriptorSetLayoutCreateInfo(sType=32, bindingCount=count, pBindings=bindings)
            descriptor_layout = U64(self.create("DescriptorSetLayout", layout_info, cleanup))
            push_range = PushConstantRange(stageFlags=0x20, size=expected_push_size)
            pipeline_layout_info = PipelineLayoutCreateInfo(
                sType=30, setLayoutCount=1, pSetLayouts=C.pointer(descriptor_layout),
                pushConstantRangeCount=int(bool(expected_push_size)),
                pPushConstantRanges=C.pointer(push_range) if expected_push_size else None)
            pipeline_layout = self.create("PipelineLayout", pipeline_layout_info, cleanup)
            code = module.read_bytes()
            words = (U32 * (len(code) // 4)).from_buffer_copy(code)
            shader_info = ShaderModuleCreateInfo(sType=16, codeSize=len(code), pCode=words)
            shader = self.create("ShaderModule", shader_info, cleanup)
            stage = PipelineShaderStageCreateInfo(sType=18, stage=0x20, module=shader,
                                                  pName=metadata["entry_point"].encode("ascii"))
            pipeline_info = ComputePipelineCreateInfo(sType=29, stage=stage, layout=pipeline_layout,
                                                       basePipelineIndex=-1)
            pipeline = U64()
            pipeline_result = self.vkCreateComputePipelines(self.device, 0, 1, C.byref(pipeline_info),
                                                            None, C.byref(pipeline))
            if pipeline.value:
                cleanup.callback(self.vkDestroyPipeline, self.device, pipeline.value, None)
            checked(pipeline_result, "vkCreateComputePipelines")
            pool_size = DescriptorPoolSize(type=7, descriptorCount=count)
            pool_info = DescriptorPoolCreateInfo(sType=33, maxSets=1, poolSizeCount=1,
                                                 pPoolSizes=C.pointer(pool_size))
            pool = self.create("DescriptorPool", pool_info, cleanup)
            set_info = DescriptorSetAllocateInfo(sType=34, descriptorPool=pool,
                                                 descriptorSetCount=1, pSetLayouts=C.pointer(descriptor_layout))
            descriptor_set = U64()
            checked(self.vkAllocateDescriptorSets(self.device, C.byref(set_info), C.byref(descriptor_set)),
                    "vkAllocateDescriptorSets")
            buffer_infos = (DescriptorBufferInfo * count)(*(
                DescriptorBufferInfo(buffer=buffer.buffer.value, range=buffer.size) for buffer in buffers))
            writes = (WriteDescriptorSet * count)(*(
                WriteDescriptorSet(sType=35, dstSet=descriptor_set.value, dstBinding=item["binding"],
                                   descriptorCount=1, descriptorType=7, pBufferInfo=C.pointer(buffer_infos[i]))
                for i, item in enumerate(metadata["buffers"])))
            self.vkUpdateDescriptorSets(self.device, count, writes, 0, None)
            command_pool_info = CommandPoolCreateInfo(sType=39, queueFamilyIndex=self.family)
            command_pool = self.create("CommandPool", command_pool_info, cleanup)
            command_info = CommandBufferAllocateInfo(sType=40, commandPool=command_pool,
                                                      commandBufferCount=1)
            command = PTR()
            checked(self.vkAllocateCommandBuffers(self.device, C.byref(command_info), C.byref(command)),
                    "vkAllocateCommandBuffers")
            begin = CommandBufferBeginInfo(sType=42, flags=1)
            checked(self.vkBeginCommandBuffer(command, C.byref(begin)), "vkBeginCommandBuffer")
            self.vkCmdBindPipeline(command, 1, pipeline)
            self.vkCmdBindDescriptorSets(command, 1, pipeline_layout, 0, 1,
                                         C.byref(descriptor_set), 0, None)
            if push_constants:
                push_data = C.create_string_buffer(push_constants)
                self.vkCmdPushConstants(command, pipeline_layout, 0x20, 0, len(push_constants), push_data)
            self.vkCmdDispatch(command, group_count, 1, 1)
            barrier = MemoryBarrier(sType=46, srcAccessMask=0x40, dstAccessMask=0x2000)
            self.vkCmdPipelineBarrier(command, 0x800, 0x4000, 0, 1, C.byref(barrier), 0, None, 0, None)
            checked(self.vkEndCommandBuffer(command), "vkEndCommandBuffer")
            fence = U64(self.create("Fence", FenceCreateInfo(sType=8), cleanup))
            submission = SubmitInfo(sType=4, commandBufferCount=1, pCommandBuffers=C.pointer(command))
            # Queue completion must precede destruction, also on a failing assertion/timeout.
            cleanup.callback(self.vkDeviceWaitIdle, self.device)
            checked(self.vkQueueSubmit(self.queue, 1, C.byref(submission), fence), "vkQueueSubmit")
            checked(self.vkWaitForFences(self.device, 1, C.byref(fence), 1, 10_000_000_000),
                    "vkWaitForFences")
            self.dispatches += 1
            return {item["name"]: C.string_at(buffer.mapping, buffer.size)
                    for item, buffer in zip(metadata["buffers"], buffers)}


def compile_shader(root, output, name, folder="examples", include_dirs=(), optimize=False):
    module = output / f"{name}.spv"
    arguments = [str(root / "build/bin/PasToSPIRV.exe"), "compile",
                 str(root / folder / f"{name}.pas"), "-o", str(module)]
    for directory in include_dirs:
        arguments.extend(["-I", str(directory)])
    if optimize: arguments.append('-O1')
    completed = subprocess.run(arguments, capture_output=True, text=True, encoding="utf-8")
    if completed.returncode:
        raise RuntimeError(completed.stderr)
    return module


def main(require_shared_cpu=False):
    root = Path(__file__).resolve().parents[1]
    output = root / "build/vulkan"
    output.mkdir(parents=True, exist_ok=True)
    scale = compile_shader(root, output, "scale")
    integer_math = compile_shader(root, output, "integer_math")
    integer_edges = compile_shader(root, output, "integer_edges", "tests/fixtures")
    functions_for = compile_shader(root, output, "functions_for")
    for_edges = compile_shader(root, output, "for_edges", "tests/fixtures")
    function_edges = compile_shader(root, output, "function_edges", "tests/fixtures")
    vector_math = compile_shader(root, output, "vector_math")
    vector_edges = compile_shader(root, output, "vector_edges", "tests/fixtures")
    intrinsic_edges = compile_shader(root, output, "intrinsic_edges", "tests/fixtures")
    layout_records = compile_shader(root, output, "layout_records")
    aggregate_values = compile_shader(root, output, "aggregate_values", "tests/fixtures")
    modules_compute = compile_shader(root, output, "modules_compute", include_dirs=(root / "examples/modules",))
    histogram = compile_shader(root, output, "atomic_histogram")
    atomic_values = compile_shader(root, output, "atomic_values", "tests/fixtures")
    shared_reduce = compile_shader(root, output, "shared_reduce")
    const_shader = compile_shader(root, output, "const_namespace", "tests/fixtures", (root / "tests/fixtures/release_modules",))
    optimized_dir = output / 'optimized'
    optimized_dir.mkdir(exist_ok=True)
    const_optimized = compile_shader(root, optimized_dir, "const_namespace", "tests/fixtures", (root / "tests/fixtures/release_modules",), True)
    atomic_optimized = compile_shader(root, optimized_dir, "atomic_values", "tests/fixtures", optimize=True)
    cpu_reference = root / "build/bin/SharedSourceCheck.exe"
    shared_inputs = [root / "tests/SharedSourceCheck.dpr", *sorted((root / "examples/shared").glob("*.inc"))]
    cpu_ready = cpu_reference.exists() and all(path.stat().st_mtime_ns <= cpu_reference.stat().st_mtime_ns for path in shared_inputs)
    if not cpu_ready and require_shared_cpu:
        raise RuntimeError("A fresh SharedSourceCheck.exe is required; run scripts/test.ps1 or build tests/SharedSourceCheck.dpr")
    count = 137  # Intentionally not a multiple of the workgroup size.
    local_size = json.loads(scale.with_suffix(".json").read_text())["local_size"][0]
    groups = math.ceil(count / local_size)
    total = groups * local_size
    inputs = [((i % 29) - 14) * 0.25 for i in range(total)]
    sentinels = [-12345.0] * total
    pack_floats = lambda values: struct.pack(f"<{len(values)}f", *values)
    with VulkanRuntime() as runtime:
        result = runtime.run(scale, {"InputData": pack_floats(inputs), "OutputData": pack_floats(sentinels)},
                             struct.pack("<If", count, 2.5), groups)
        expected = [value * 2.5 for value in inputs[:count]] + sentinels[count:]
        if result["OutputData"] != pack_floats(expected):
            raise AssertionError("Scale GPU output differs from CPU reference or overwrote the tail")
        result = runtime.run(scale, {"InputData": pack_floats(inputs), "OutputData": pack_floats(sentinels)},
                             struct.pack("<If", 0, 2.5), groups)
        if result["OutputData"] != pack_floats(sentinels):
            raise AssertionError("Count=0 wrote to the output buffer")
        seed = [0, 1, -1, -2147483648, 2147483647, 2, -7, 10, 123, -100]
        values = [seed[i % len(seed)] for i in range(total)]
        pack_ints = lambda items: struct.pack(f"<{len(items)}I", *(item & 0xFFFFFFFF for item in items))
        expected = values.copy()
        for i in range(count):
            bits = values[i] & 0xFFFFFFFF
            for _ in range(3):
                bits = bits >> 1 if bits & 1 == 0 else (bits * 3 + 1) & 0xFFFFFFFF
            expected[i] = bits
        result = runtime.run(integer_math, {"Data": pack_ints(values)}, struct.pack("<I", count), groups)
        if result["Data"] != pack_ints(expected):
            raise AssertionError("Integer GPU output differs from modulo-32-bit CPU reference")
        result = runtime.run(functions_for, {"Data": pack_ints(values)}, struct.pack("<II", count, 3), groups)
        if result["Data"] != pack_ints(expected):
            raise AssertionError("Helper functions/for loop differ from the equivalent CPU and while implementation")
        result = runtime.run(functions_for, {"Data": pack_ints(values)}, struct.pack("<II", count, 0), groups)
        if result["Data"] != pack_ints(values):
            raise AssertionError("An empty for range changed the helper function result")
        sentinel = 0xA5A5A5A5
        edges = [-2, -1, 0x7FFFFFFF, 1, 2, 0, 0x7FFFFFFF, 0x80000000,
                 -7, -7, 7, 0, -1, 1, 2, 0]
        result = runtime.run(integer_edges, {"OutputData": pack_ints([sentinel] * 32)}, b"", 1)
        if result["OutputData"] != pack_ints(edges + [sentinel] * 16):
            raise AssertionError("Integer edge cases differ: division/remainder, shift masks, casts or wraparound")
        loops = [2, 2, 0, 0, 2, 2, 0, 0, 1, 1, 1, 1, 6, 5, 3, 18]
        result = runtime.run(for_edges, {"OutputData": pack_ints([sentinel] * 32)}, b"", 1)
        if result["OutputData"] != pack_ints(loops + [sentinel] * 16):
            raise AssertionError("For-loop edge cases differ: extrema, empty ranges, captured bounds or nesting")
        calls = [1, 3, 6, 10, 11, 10, 0, 1, 8, 6, 22, 3]
        result = runtime.run(function_edges, {"OutputData": pack_ints([sentinel] * 32)}, b"", 1)
        if result["OutputData"] != pack_ints(calls + [sentinel] * 20):
            raise AssertionError("Function edge cases differ: scalar returns, nested calls or value-parameter copies")
        vector_input = [((i % 17) - 8) * 0.125 for i in range(total * 3)]
        vector_sentinels = [-12345.0] * (total * 4)
        vector_payloads = {"InputData": pack_floats(vector_input), "OutputData": pack_floats(vector_sentinels)}
        result = runtime.run(vector_math, vector_payloads, struct.pack("<If", count, 1.5), groups)
        expected_vectors = vector_sentinels.copy()
        for i in range(count):
            xyz = [min(max(value * 1.5, -1.0), 1.0) for value in vector_input[i * 3:i * 3 + 3]]
            expected_vectors[i * 4:i * 4 + 4] = xyz + [math.sqrt(sum(value * value for value in xyz))]
        actual_vectors = struct.unpack(f"<{total * 4}f", result["OutputData"])
        for i, (actual, expected_value) in enumerate(zip(actual_vectors, expected_vectors)):
            if not math.isclose(actual, expected_value, rel_tol=1e-6, abs_tol=1e-6):
                raise AssertionError(f"Vector math differs at component {i}: {actual} != {expected_value}")
        if result["OutputData"][count * 16:] != pack_floats(vector_sentinels)[count * 16:]:
            raise AssertionError("Vector math overwrote the guarded output tail")
        if result["InputData"] != vector_payloads["InputData"]:
            raise AssertionError("Vector math modified the read-only input buffer")
        result = runtime.run(vector_math, vector_payloads, struct.pack("<If", 0, 1.5), groups)
        if result["OutputData"] != pack_floats(vector_sentinels):
            raise AssertionError("Count=0 modified the vector output buffer")

        vector_results = [0x80000000, 1, 2, 7, 0, 1, 2, 33, 0x7FFFFFFF, 1, 1, 0,
                          2, 1, 12, 3, 4, 1, 2, 3, 7, -1, 1, -1, 1, -2, 0, 2,
                          2, 3, 7, 7, 1, 1, 0xFFFFFFFF, 0xFFFFFFFF, 0]
        result = runtime.run(vector_edges, {"OutputData": pack_ints([sentinel] * 64)}, b"", 1)
        if result["OutputData"] != pack_ints(vector_results + [sentinel] * (64 - len(vector_results))):
            raise AssertionError("Vector edge cases differ: constructors, casts, component writes, arithmetic or comparisons")

        special_input = struct.pack("<II", 0xFFC12345, 0x80000000)  # quiet NaN, negative zero
        float_sentinels = pack_floats([-12345.0] * 64)
        result = runtime.run(intrinsic_edges, {"InputData": special_input, "OutputData": float_sentinels}, b"", 1)
        expected_math = [2, 0, math.nan, 4, 3, 3, 3, 3, math.nan, 0, 2, 25, 5, -1, 1, 0,
                         0, 1, 2, 3, 32, -1, -0.5, 0.5, 1, 0, 1]
        actual_math = struct.unpack("<64f", result["OutputData"])
        for i, expected_value in enumerate(expected_math):
            actual = actual_math[i]
            if (math.isnan(expected_value) and not math.isnan(actual)) or (
                    not math.isnan(expected_value) and not math.isclose(actual, expected_value, rel_tol=1e-6, abs_tol=1e-6)):
                raise AssertionError(f"Intrinsic differs at {i}: {actual} != {expected_value}")
        for i in (1, 15):
            if result["OutputData"][i * 4:i * 4 + 4] != struct.pack("<I", 0):
                raise AssertionError("Abs(-0.0) did not produce positive zero on this device")
        if result["OutputData"][len(expected_math) * 4:] != float_sentinels[len(expected_math) * 4:]:
            raise AssertionError("Intrinsic tests overwrote the output tail")
        if result["InputData"] != special_input:
            raise AssertionError("Intrinsic tests modified the input bit patterns")
        # The offsets below are an independent std430 oracle, not taken from reflection.
        item_payload = bytearray([0xA5] * (total * 64))
        item_values = []
        for i in range(total):
            position = [((i + j) % 13 - 6) * 0.25 for j in range(3)]
            weight = i * 0.125
            samples = [[(i % 7 + j + k) * 0.5 for j in range(3)] for k in range(2)]
            tag = 0xFFFFFFFF if i == 0 else i
            struct.pack_into("<4f", item_payload, i * 64, *position, weight)
            for k in range(2):
                struct.pack_into("<3f", item_payload, i * 64 + 16 + k * 16, *samples[k])
            struct.pack_into("<I", item_payload, i * 64 + 48, tag)
            item_values.append((position, weight, samples, tag))
        record_sentinels = bytes([0xA5] * (total * 64))
        vector_slots = bytes([0xA5] * (total * 16))
        layout_push = bytearray(48)
        struct.pack_into("<If", layout_push, 0, count, 1.5)
        struct.pack_into("<4f", layout_push, 16, 0.5, -0.25, 1.0, 0.5)
        struct.pack_into("<4f", layout_push, 32, 2.0, 3.0, 4.0, 5.0)
        payloads = {"InputData": bytes(item_payload), "OutputData": record_sentinels, "VectorData": vector_slots}
        result = runtime.run(layout_records, payloads, bytes(layout_push), groups)
        for i in range(count):
            position, weight, samples, tag = item_values[i]
            transformed = [value * 1.5 + shift for value, shift in zip(position, [0.5, -0.25, 1.0])]
            expected_values = transformed + [weight + 0.5]
            actual_values = list(struct.unpack_from("<4f", result["OutputData"], i * 64))
            for k in range(2):
                transformed_sample = [value + shift for value, shift in zip(samples[k], transformed)]
                transformed_sample[k] += [2.0, 5.0][k]
                expected_values.extend(transformed_sample)
                actual_values.extend(struct.unpack_from("<3f", result["OutputData"], i * 64 + 16 + k * 16))
            if actual_values != expected_values:
                raise AssertionError(f"Nested std430 record differs at element {i}")
            actual_tag = struct.unpack_from("<I", result["OutputData"], i * 64 + 48)[0]
            if actual_tag != (tag + 1) & 0xFFFFFFFF:
                raise AssertionError("Record integer field/copy differs")
            if list(struct.unpack_from("<3f", result["VectorData"], i * 16)) != transformed:
                raise AssertionError("Runtime vector3 array stride differs")
        if result["InputData"] != bytes(item_payload):
            raise AssertionError("Record shader modified its input buffer")
        if result["OutputData"][count * 64:] != record_sentinels[count * 64:]:
            raise AssertionError("Record shader overwrote the output tail")
        if result["VectorData"][count * 16:] != vector_slots[count * 16:]:
            raise AssertionError("Vector3 resource overwrote the output tail")
        struct.pack_into("<I", layout_push, 0, 0)
        result = runtime.run(layout_records, payloads, bytes(layout_push), groups)
        if result["OutputData"] != record_sentinels or result["VectorData"] != vector_slots:
            raise AssertionError("Count=0 modified aggregate resources")
        aggregates = [2, 12, 1, 5, 6, 3, 23, 2, 3, 0, 0, 0]
        result = runtime.run(aggregate_values, {"OutputData": pack_ints([sentinel] * 32)}, b"", 1)
        if result["OutputData"] != pack_ints(aggregates + [sentinel] * (32 - len(aggregates))):
            raise AssertionError("Aggregate Default/copy/parameter/return/index semantics differ")

        for base in ("Integer", "Cardinal", "Single"):
            for width in (1, 2, 3, 4):
                name = f"runtime_{base}_{width}"
                value_type = base if width == 1 else f"{base}{width}"
                source = (f"var [Binding(0,0)] Data: array of {value_type}; "
                          "procedure Main; begin if GlobalInvocationID.X < 2 then "
                          "Data[GlobalInvocationID.X] := Data[GlobalInvocationID.X] + 1; end;")
                (output / f"{name}.pas").write_text(source, encoding="utf-8")
                module = compile_shader(root, output, name, output)
                stride = 16 if width >= 3 else width * 4
                metadata = json.loads(module.with_suffix(".json").read_text())
                if metadata["buffers"][0]["array_stride"] != stride:
                    raise AssertionError("Runtime array reflection stride differs from std430")
                payload = bytearray([0xA5] * (stride * 4))
                expected_fields = []
                for i in range(2):
                    for j in range(width):
                        offset = i * stride + j * 4
                        if base == "Single":
                            value = i + j * 0.25
                            struct.pack_into("<f", payload, offset, value)
                            expected_fields.append((offset, struct.pack("<f", value + 1)))
                        else:
                            value = -100 + i + j if base == "Integer" else 0xFFFFFFFF - i - j
                            struct.pack_into("<I", payload, offset, value & 0xFFFFFFFF)
                            expected_fields.append((offset, struct.pack("<I", (value + 1) & 0xFFFFFFFF)))
                result = runtime.run(module, {"Data": bytes(payload)}, b"", 1)["Data"]
                for offset, expected_value in expected_fields:
                    if result[offset:offset + 4] != expected_value:
                        raise AssertionError(f"Runtime {value_type} element field differs")
                if result[2 * stride:] != bytes(payload[2 * stride:]):
                    raise AssertionError(f"Runtime {value_type} wrote past the guarded range")
        histogram_inputs = [(i * 7) & 0xFFFFFFFF for i in range(total)]
        expected_bins = [0] * 16
        for value in histogram_inputs[:count]: expected_bins[value % 16] += 1
        result = runtime.run(histogram, {"InputData": pack_ints(histogram_inputs), "Counts": pack_ints([0] * 16)}, struct.pack("<I", count), groups)
        if result["Counts"] != pack_ints(expected_bins): raise AssertionError("Atomic histogram lost concurrent increments")
        result = runtime.run(atomic_values, {"Values": pack_ints([10,0,0,0]), "SignedValues": pack_ints([-5,0])}, b"", 1)
        if result["Values"] != pack_ints([30,10,20,30]) or result["SignedValues"] != pack_ints([-7,-5]):
            raise AssertionError("Atomic exchange/compare-exchange/old-value semantics differ")
        reduction_input = [i + 1 for i in range(total)]
        expected_groups = [sum(reduction_input[i * 64:min(count,(i + 1) * 64)]) & 0xFFFFFFFF for i in range(groups)]
        result = runtime.run(shared_reduce, {"InputData": pack_ints(reduction_input), "OutputData": pack_ints([0] * groups)}, struct.pack("<I", count), groups)
        if result["OutputData"] != pack_ints(expected_groups): raise AssertionError("Workgroup shared reduction/barriers differ")
        const_expected = [8,4,5,8,3,0,50,8,0x7FFFFFFF]
        for module in (const_shader,const_optimized):
            result = runtime.run(module,{'OutputData':pack_ints([sentinel] * 16)},b'',1)
            if result['OutputData'] != pack_ints(const_expected + [sentinel] * 7):
                raise AssertionError('Qualified constants/types or O1 semantics differ')
        result = runtime.run(atomic_optimized, {"Values": pack_ints([10,0,0,0]), "SignedValues": pack_ints([-5,0])}, b"", 1)
        if result["Values"] != pack_ints([30,10,20,30]) or result["SignedValues"] != pack_ints([-7,-5]):
            raise AssertionError('O1 changed atomic side effects')
        # Second audit: Workgroup twin types, typed constants and selector order.
        audit_dir = output / 'audit2'
        audit_dir.mkdir(exist_ok=True)
        audit_sources = {
            'shared_twin': 'type TS = array[0..63] of Cardinal; var [Binding(0,0)] Data: array of TS; [Shared] S: TS; '
                           '[LocalSize(64,1,1)] procedure Main; var L: TS; begin S[LocalInvocationIndex] := LocalInvocationIndex; '
                           'Barrier; L := S; Barrier; if LocalInvocationIndex = 0 then begin Data[1] := L; S := Data[2]; Data[3] := S; end; '
                           'Data[0][LocalInvocationIndex] := L[63 - LocalInvocationIndex]; end;',
            'typed_const': 'const Big: Cardinal = $7FFFFFFF; var [Binding(0,0)] R: array of Cardinal; [Binding(0,1)] F: array of Single; '
                           'procedure Main; begin if GlobalInvocationID.X = 0 then begin if Big + 1 > 0 then R[0] := 1 else R[0] := 2; '
                           'F[0] := Big + 1; end; end;',
            'selector_order': 'type TRow = record Arr: array[0..3] of Cardinal; end; var [Binding(0,0)] Rows: array of TRow; '
                              '[Binding(0,1)] C: array of Cardinal; procedure Main; begin if GlobalInvocationID.X = 0 then '
                              'Rows[AtomicAdd(C[0],1)].Arr[AtomicAdd(C[0],1)] := 7; end;',
        }
        modules = {}
        for name, text in audit_sources.items():
            (audit_dir / f'{name}.pas').write_text(text, encoding='utf-8')
            for option in ('-O0', '-O1'):
                target = audit_dir / option[1:]
                target.mkdir(exist_ok=True)
                modules[name, option] = compile_shader(root, target, name, audit_dir, optimize=option == '-O1')
        for option in ('-O0', '-O1'):
            payload = bytearray(4 * 256)
            struct.pack_into('<64I', payload, 512, *(1000 + i for i in range(64)))
            words = struct.unpack('<256I', runtime.run(modules['shared_twin', option], {'Data': bytes(payload)}, b'', 1)['Data'])
            if (list(words[:64]) != [63 - i for i in range(64)] or list(words[64:128]) != list(range(64))
                    or list(words[192:]) != [1000 + i for i in range(64)]):
                raise AssertionError(f'Shared/buffer twin array conversion differs ({option})')
            result = runtime.run(modules['typed_const', option], {'R': bytes(4), 'F': bytes(4)}, b'', 1)
            if struct.unpack('<I', result['R'])[0] != 1 or struct.unpack('<f', result['F'])[0] != 2147483648.0:
                raise AssertionError(f'Typed Cardinal constant changed signedness ({option})')
            result = runtime.run(modules['selector_order', option], {'Rows': bytes(32), 'C': bytes(4)}, b'', 1)
            if struct.unpack('<8I', result['Rows']) != (0, 7, 0, 0, 0, 0, 0, 0):
                raise AssertionError(f'Selector indices are not evaluated in source order ({option})')
        if cpu_ready:
            rng = random.Random(0x5A17)
            shared_values = [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0xAAAAAAAA, 0x55555555]
            shared_values += [rng.getrandbits(32) for _ in range(total - len(shared_values))]
            shared_floats = [((i % 33) - 16) * 0.125 for i in range(total)]
            uint_input = output / "common-input.u32"
            float_input = output / "common-input.f32"
            uint_input.write_bytes(pack_ints(shared_values[:count]))
            float_input.write_bytes(pack_floats(shared_floats[:count]))
            common_payloads = {"InputData": pack_ints(shared_values), "OutputData": pack_ints([sentinel] * total),
                               "FloatData": pack_floats(shared_floats)}
            for rounds, factor in ((0, 0.0), (1, 1.5), (5, -0.75), (17, 2.0)):
                uint_output = output / f"common-{rounds}.u32"
                float_output = output / f"common-{rounds}.f32"
                for mode, input_path, output_path, parameter in (
                        ("integer", uint_input, uint_output, str(rounds)),
                        ("single", float_input, float_output, format(factor, ".9g"))):
                    reference = subprocess.run([str(cpu_reference), mode, str(input_path), str(output_path), parameter],
                                               capture_output=True, text=True, encoding="utf-8")
                    if reference.returncode:
                        raise RuntimeError(f"Delphi shared-source reference failed: {reference.stderr}")
                result = runtime.run(modules_compute, common_payloads, struct.pack("<IIf", count, rounds, factor), groups)
                if result["OutputData"] != uint_output.read_bytes() + pack_ints([sentinel] * (total - count)):
                    raise AssertionError(f"Actual Delphi/GPU shared integer code differs for {rounds} rounds")
                expected_float = struct.unpack(f"<{count}f", float_output.read_bytes())
                actual_float = struct.unpack(f"<{total}f", result["FloatData"])
                for i, (actual, expected_value) in enumerate(zip(actual_float, expected_float)):
                    if not math.isclose(actual, expected_value, rel_tol=1e-6, abs_tol=1e-6):
                        raise AssertionError(f"Actual Delphi/GPU shared Single code differs at {i}")
                if result["FloatData"][count * 4:] != common_payloads["FloatData"][count * 4:]:
                    raise AssertionError("Shared code overwrote the float tail")
                if result["InputData"] != common_payloads["InputData"]:
                    raise AssertionError("Shared code changed the read-only integer input")
            result = runtime.run(modules_compute, common_payloads, struct.pack("<IIf", 0, 5, 1.5), groups)
            if result["OutputData"] != common_payloads["OutputData"] or result["FloatData"] != common_payloads["FloatData"]:
                raise AssertionError("Count=0 modified shared-source outputs")
        else:
            print("WARNING: actual Delphi/GPU common-source comparison skipped; build a fresh SharedSourceCheck.exe.")
        # Unary minus/Abs of Low(Integer) must wrap; a tested driver folded OpSNegate as no-wrap.
        for optimize in (False, True):
            negate = compile_shader(root, output, "negate_wrap", "tests/fixtures", optimize=optimize)
            result = runtime.run(negate, {"I": struct.pack("<2i", -2147483648, 7), "O": bytes(24)}, b"", 1)
            got = struct.unpack("<6i", result["O"])
            if got != (-306783378, -306783378, 1, 0, -2, -306783378):
                raise AssertionError(f"Integer negation/Abs wraparound differs (O{int(optimize)}): {got}")
        # Language 1.2 syntax: inline var/const, for var, Inc/Dec, Low/High/Length/SizeOf,
        # case ranges, Ord/Odd/Sqr/Succ/Pred, calls without (), short-circuit and {$B+}.
        values = [k % 10 - 1 for k in range(64)]
        for optimize in (False, True):
            syntax = compile_shader(root, output, "syntax_features", "tests/fixtures", optimize=optimize)
            result = runtime.run(syntax, {"In": pack_ints(values), "Hits": bytes(256), "O": bytes(64 * 12 * 4)}, b"", 1)
            got = struct.unpack(f"<{64 * 12}i", result["O"])
            hits = struct.unpack("<64i", result["Hits"])
            for k, x in enumerate(values):
                case = 1 if 0 <= x <= 2 else 2 if x in (3, 5, 6, 7) else 3
                want = (4 * x, 10, 17, x * x + 10, case, (x & 1) + (x + 1) * 10 + (x - 1) * 100,
                        20, 2, int(x > 3), 0, 64, 6)
                if got[k * 12:(k + 1) * 12] != want or hits[k] != int(x > 3) + 1:
                    raise AssertionError(f"syntax_features O{int(optimize)} x={x}: {got[k*12:(k+1)*12]} "
                                         f"hits {hits[k]}, want {want} hits {int(x > 3) + 1}")
        # Language 1.3 syntax: enumerations, sets, if expressions, swizzles, multi-dimensional
        # arrays, record/vector typed constants, forward, overload and nested routines.
        def pascal_mod(a, b):
            return a - b * int(a / b)
        for optimize in (False, True):
            group2 = compile_shader(root, output, "syntax_group2", "tests/fixtures", optimize=optimize)
            result = runtime.run(group2, {"In": pack_ints(values), "Hits": bytes(256), "O": bytes(64 * 16 * 4)}, b"", 1)
            got = struct.unpack(f"<{64 * 16}i", result["O"])
            hits = struct.unpack("<64i", result["Hits"])
            for k, x in enumerate(values):
                even = pascal_mod(x, 2) == 0
                mode_set = 96 if pascal_mod(x, 3) == 0 else 64
                want = (
                    x if x > 4 else -x,
                    (x + 3 if even else 3 * x) + 2 * x * 100,
                    660,
                    mode_set + (1000 if mode_set == 96 else 0),
                    int(x in (1, 3, 5, 6, 7)) + (10 if not 0 <= x <= 2 else 0),
                    23 + 1200 + 20000 + 400000,
                    10101 * x + 4040,
                    34 + (20 if x & 1 else 2) * 100 + 2000,
                    x + 1000 + 15 + 100 * x + 7,
                    3 * x,
                    10 if x > 2 else 3,
                    1 + (100 if mode_set == 64 else 0) + 1000,
                    7,
                    5,
                    int(even),
                    12 if x > 0 else 34,
                )
                if got[k * 16:(k + 1) * 16] != want or hits[k] != int(x > 4):
                    raise AssertionError(f"syntax_group2 O{int(optimize)} x={x}: {got[k*16:(k+1)*16]} "
                                         f"hits {hits[k]}, want {want} hits {int(x > 4)}")
        print(f"PASS: {runtime.dispatches} real Vulkan dispatches, device #{runtime.device_index}, queue family {runtime.family}.")
        print(f"Checked {count} elements, integer overflow/logical shifts, bounds guards and Count=0.")
        print("Checked 16 numeric edge cases: signed div/mod, masked shifts, casts and wraparound.")
        print("Checked helper calls and 16 for-loop edge cases, including Integer/Cardinal endpoints.")
        print("Checked vector parameters/returns/components, numeric casts, intrinsics, NaN and signed zero.")
        print("Checked std430 records/arrays/push constants, aggregate values and all scalar/vector resource shapes.")
        if cpu_ready:
            print("Checked the SAME .inc sources compiled by Delphi and PasToSPIRV: exact integers, Single tolerance 1e-6.")
    from vulkan_images import run_image_tests
    image_dispatches = run_image_tests(root)
    sketch = root / 'build/bin/SketchBench.exe'
    if sketch.exists():
        completed = subprocess.run([str(sketch), '--sizes', '97x61,320x200', '--iterations', '2',
                                    '--cpu-iterations', '1', '--radius', '32', '--out', str(output / 'sketch')],
                                   capture_output=True, text=True, encoding='utf-8', timeout=300)
        if (completed.returncode or 'bit-identical' not in completed.stdout
                or completed.stdout.count('bit-identical') != 2):
            raise AssertionError(f'Sketch example GPU/CPU comparison failed:\n{completed.stdout}{completed.stderr}')
        print('PASS: sketch example, GPU output bit-identical to Delphi CPU output (2 sizes, radius 32).')
    else:
        print('WARNING: SketchBench.exe not built; sketch GPU comparison skipped.')
    thumbnail = root / 'build/bin/ThumbnailCheck.exe'
    if thumbnail.exists():
        completed = subprocess.run([str(thumbnail), '--gpu'], capture_output=True,
                                   text=True, encoding='utf-8', timeout=300)
        if completed.returncode or 'PASS: thumbnails CPU/GPU bit-identical' not in completed.stdout:
            raise AssertionError(f'Thumbnail GPU/CPU comparison failed:\n{completed.stdout}{completed.stderr}')
        print(completed.stdout.strip())
    else:
        print('WARNING: ThumbnailCheck.exe not built; thumbnail GPU comparison skipped.')
    print(f'PASS: total {runtime.dispatches + image_dispatches} validated CPU-reference Vulkan dispatches.')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-shared-cpu", action="store_true", help="Fail rather than skip an absent/stale Delphi shared-source reference")
    options = parser.parse_args()
    main(options.require_shared_cpu)
