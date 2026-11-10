"""Real storage-image and sampled-texture dispatches; standard library only."""
from __future__ import annotations

import ctypes as C
import json
import math
from pathlib import Path
import struct
from contextlib import ExitStack

from vulkan_smoke import (U32, U64, I32, PTR, P64, HEADER, structure, Extent3D,
                         MemoryRequirements, MemoryProperties, MemoryAllocateInfo,
                         LayoutBinding, DescriptorSetLayoutCreateInfo, PushConstantRange,
                         PipelineLayoutCreateInfo, ShaderModuleCreateInfo,
                         PipelineShaderStageCreateInfo, ComputePipelineCreateInfo,
                         DescriptorPoolSize, DescriptorPoolCreateInfo, DescriptorSetAllocateInfo,
                         DescriptorBufferInfo, WriteDescriptorSet, CommandPoolCreateInfo,
                         CommandBufferAllocateInfo, CommandBufferBeginInfo, MemoryBarrier,
                         FenceCreateInfo, SubmitInfo, StorageBuffer, VulkanRuntime, checked, compile_shader)

ImageCreateInfo = structure("ImageCreateInfo", HEADER + [("flags", U32), ("imageType", U32),
    ("format", U32), ("extent", Extent3D), ("mipLevels", U32), ("arrayLayers", U32),
    ("samples", U32), ("tiling", U32), ("usage", U32), ("sharingMode", U32),
    ("queueFamilyIndexCount", U32), ("pQueueFamilyIndices", PTR), ("initialLayout", U32)])
SubresourceRange = structure("SubresourceRange", [("aspectMask", U32), ("baseMipLevel", U32),
    ("levelCount", U32), ("baseArrayLayer", U32), ("layerCount", U32)])
ComponentMapping = structure("ComponentMapping", [("r", U32), ("g", U32), ("b", U32), ("a", U32)])
ImageViewCreateInfo = structure("ImageViewCreateInfo", HEADER + [("flags", U32), ("image", U64),
    ("viewType", U32), ("format", U32), ("components", ComponentMapping), ("subresourceRange", SubresourceRange)])
ImageMemoryBarrier = structure("ImageMemoryBarrier", HEADER + [("srcAccessMask", U32), ("dstAccessMask", U32),
    ("oldLayout", U32), ("newLayout", U32), ("srcQueueFamilyIndex", U32), ("dstQueueFamilyIndex", U32),
    ("image", U64), ("subresourceRange", SubresourceRange)])
SubresourceLayers = structure("SubresourceLayers", [("aspectMask", U32), ("mipLevel", U32),
    ("baseArrayLayer", U32), ("layerCount", U32)])
Offset3D = structure("Offset3D", [("x", I32), ("y", I32), ("z", I32)])
BufferImageCopy = structure("BufferImageCopy", [("bufferOffset", U64), ("bufferRowLength", U32),
    ("bufferImageHeight", U32), ("imageSubresource", SubresourceLayers),
    ("imageOffset", Offset3D), ("imageExtent", Extent3D)])
DescriptorImageInfo = structure("DescriptorImageInfo", [("sampler", U64), ("imageView", U64), ("imageLayout", U32)])
SamplerCreateInfo = structure("SamplerCreateInfo", HEADER + [("flags", U32), ("magFilter", U32),
    ("minFilter", U32), ("mipmapMode", U32), ("addressModeU", U32), ("addressModeV", U32),
    ("addressModeW", U32), ("mipLodBias", C.c_float), ("anisotropyEnable", U32),
    ("maxAnisotropy", C.c_float), ("compareEnable", U32), ("compareOp", U32),
    ("minLod", C.c_float), ("maxLod", C.c_float), ("borderColor", U32), ("unnormalizedCoordinates", U32)])
FormatProperties = structure("FormatProperties", [("linear", U32), ("optimal", U32), ("buffer", U32)])


class GPUImage:
    def __init__(self, runtime, spec, sampled, cleanup):
        self.runtime = runtime
        self.image, self.memory, self.view = U64(), U64(), U64()
        self.width, self.height, self.format = spec["width"], spec["height"], spec["format"]
        self.layout = 5 if sampled else 1
        self.sampled = sampled
        data = spec["data"]
        cleanup.callback(self.close)
        properties = FormatProperties()
        runtime.vkGetPhysicalDeviceFormatProperties(runtime.physical, self.format, C.byref(properties))
        required = 1 if sampled else 2
        if properties.optimal & required != required:
            raise RuntimeError(f"Device does not support format {self.format} for this image usage")
        info = ImageCreateInfo(sType=14, imageType=1, format=self.format, extent=Extent3D(self.width,self.height,1),
                              mipLevels=1, arrayLayers=1, samples=1,
                              usage=spec.get("usage", 3 | (4 if sampled else 8)))
        checked(runtime.vkCreateImage(runtime.device, C.byref(info), None, C.byref(self.image)), "vkCreateImage")
        requirements = MemoryRequirements()
        runtime.vkGetImageMemoryRequirements(runtime.device, self.image, C.byref(requirements))
        memory = MemoryProperties()
        runtime.vkGetPhysicalDeviceMemoryProperties(runtime.physical, C.byref(memory))
        indices = [i for i in range(memory.memoryTypeCount) if requirements.memoryTypeBits & (1 << i)]
        index = next((i for i in indices if memory.memoryTypes[i].propertyFlags & 1), indices[0])
        allocation = MemoryAllocateInfo(sType=5, allocationSize=requirements.size, memoryTypeIndex=index)
        checked(runtime.vkAllocateMemory(runtime.device, C.byref(allocation), None, C.byref(self.memory)), "vkAllocateMemory image")
        checked(runtime.vkBindImageMemory(runtime.device, self.image, self.memory, 0), "vkBindImageMemory")
        self.range = SubresourceRange(aspectMask=1, levelCount=1, layerCount=1)
        view = ImageViewCreateInfo(sType=15, image=self.image.value, viewType=1, format=self.format, subresourceRange=self.range)
        checked(runtime.vkCreateImageView(runtime.device, C.byref(view), None, C.byref(self.view)), "vkCreateImageView")
        self.upload = StorageBuffer(runtime, data, cleanup)
        self.download = StorageBuffer(runtime, bytes(len(data)), cleanup)
        self.copy = BufferImageCopy(imageSubresource=SubresourceLayers(aspectMask=1, layerCount=1),
                                    imageExtent=Extent3D(self.width,self.height,1))

    def transition(self, command, old, new, source_access, dest_access, source_stage, dest_stage):
        barrier = ImageMemoryBarrier(sType=45, srcAccessMask=source_access, dstAccessMask=dest_access,
            oldLayout=old, newLayout=new, srcQueueFamilyIndex=0xFFFFFFFF, dstQueueFamilyIndex=0xFFFFFFFF,
            image=self.image.value, subresourceRange=self.range)
        self.runtime.vkCmdPipelineBarrier(command, source_stage, dest_stage, 0, 0, None, 0, None, 1, C.byref(barrier))

    def close(self):
        if self.view: self.runtime.vkDestroyImageView(self.runtime.device, self.view, None)
        if self.image: self.runtime.vkDestroyImage(self.runtime.device, self.image, None)
        if self.memory: self.runtime.vkFreeMemory(self.runtime.device, self.memory, None)


class ImageRuntime(VulkanRuntime):
    def _bind_functions(self):
        super()._bind_functions()
        for name, info in (("Image",ImageCreateInfo),("ImageView",ImageViewCreateInfo),("Sampler",SamplerCreateInfo)):
            self.bind("vkCreate" + name, I32, PTR, C.POINTER(info), PTR, P64)
            self.bind("vkDestroy" + name, None, PTR, U64, PTR)
        self.bind("vkGetImageMemoryRequirements", None, PTR, U64, C.POINTER(MemoryRequirements))
        self.bind("vkBindImageMemory", I32, PTR, U64, U64, U64)
        self.bind("vkGetPhysicalDeviceFormatProperties", None, PTR, U32, C.POINTER(FormatProperties))
        self.bind("vkCmdCopyBufferToImage", None, PTR, U64, U64, U32, U32, C.POINTER(BufferImageCopy))
        self.bind("vkCmdCopyImageToBuffer", None, PTR, U64, U32, U64, U32, C.POINTER(BufferImageCopy))

    def run_images(self, module, payloads, image_specs, push, groups, linear=False):
        meta = json.loads(module.with_suffix(".json").read_text(encoding="utf-8"))
        resources = meta["buffers"] + meta["images"] + meta["textures"] + meta["samplers"]
        if any(item["set"] != 0 for item in resources): raise RuntimeError("Image test runtime supports set 0 only")
        if len(push) != sum(x["size"] for x in meta["push_constants"]): raise RuntimeError("Push size mismatch")
        with ExitStack() as cleanup:
            buffers = {x["name"]: StorageBuffer(self,payloads[x["name"]],cleanup) for x in meta["buffers"]}
            images = {x["name"]: GPUImage(self,image_specs[x["name"]],False,cleanup) for x in meta["images"]}
            images.update({x["name"]: GPUImage(self,image_specs[x["name"]],True,cleanup) for x in meta["textures"]})
            samplers = {}
            combined = [x for x in meta["textures"] if x["descriptor_type"] == "combined_image_sampler"]
            for item in meta["samplers"] + combined:
                if linear:
                    for image in images.values():
                        if image.sampled:
                            properties = FormatProperties()
                            self.vkGetPhysicalDeviceFormatProperties(self.physical,image.format,C.byref(properties))
                            if not properties.optimal & 0x1000: raise RuntimeError('Format does not support linear sampling')
                info = SamplerCreateInfo(sType=31, magFilter=int(linear), minFilter=int(linear), addressModeU=2,addressModeV=2,addressModeW=2,maxAnisotropy=1)
                samplers[item["name"]] = self.create("Sampler",info,cleanup)
            kinds = {"storage_buffer":7,"storage_image":3,"sampled_image":2,"sampler":0,"combined_image_sampler":1}
            bindings = (LayoutBinding * len(resources))(*(
                LayoutBinding(binding=x["binding"],descriptorType=kinds[x["descriptor_type"]],descriptorCount=1,stageFlags=0x20)
                for x in resources))
            descriptor_layout = U64(self.create("DescriptorSetLayout", DescriptorSetLayoutCreateInfo(sType=32,bindingCount=len(resources),pBindings=bindings),cleanup))
            push_range = PushConstantRange(stageFlags=0x20,size=len(push))
            pipeline_layout = self.create("PipelineLayout", PipelineLayoutCreateInfo(sType=30,setLayoutCount=1,pSetLayouts=C.pointer(descriptor_layout),
                pushConstantRangeCount=int(bool(push)),pPushConstantRanges=C.pointer(push_range) if push else None),cleanup)
            code = module.read_bytes(); words = (U32 * (len(code)//4)).from_buffer_copy(code)
            shader = self.create("ShaderModule",ShaderModuleCreateInfo(sType=16,codeSize=len(code),pCode=words),cleanup)
            stage = PipelineShaderStageCreateInfo(sType=18,stage=0x20,module=shader,pName=meta["entry_point"].encode("ascii"))
            pipeline_info = ComputePipelineCreateInfo(sType=29,stage=stage,layout=pipeline_layout,basePipelineIndex=-1)
            pipeline = U64()
            result = self.vkCreateComputePipelines(self.device,0,1,C.byref(pipeline_info),None,C.byref(pipeline))
            if pipeline: cleanup.callback(self.vkDestroyPipeline,self.device,pipeline.value,None)
            checked(result,"vkCreateComputePipelines image")
            counts = {}
            for x in resources: counts[kinds[x["descriptor_type"]]] = counts.get(kinds[x["descriptor_type"]],0) + 1
            pool_sizes = (DescriptorPoolSize * len(counts))(*(DescriptorPoolSize(k,v) for k,v in counts.items()))
            pool = self.create("DescriptorPool",DescriptorPoolCreateInfo(sType=33,maxSets=1,poolSizeCount=len(counts),pPoolSizes=pool_sizes),cleanup)
            set_info = DescriptorSetAllocateInfo(sType=34,descriptorPool=pool,descriptorSetCount=1,pSetLayouts=C.pointer(descriptor_layout))
            descriptor_set = U64(); checked(self.vkAllocateDescriptorSets(self.device,C.byref(set_info),C.byref(descriptor_set)),"vkAllocateDescriptorSets")
            infos, writes = [], []
            for item in resources:
                name = item["name"]; kind = kinds[item["descriptor_type"]]
                write = WriteDescriptorSet(sType=35,dstSet=descriptor_set.value,dstBinding=item["binding"],descriptorCount=1,descriptorType=kind)
                if kind == 7:
                    info = DescriptorBufferInfo(buffer=buffers[name].buffer.value,range=buffers[name].size)
                    write.pBufferInfo = C.pointer(info)
                else:
                    info = DescriptorImageInfo()
                    if kind == 0: info.sampler = samplers[name]
                    else: info.imageView, info.imageLayout = images[name].view.value, images[name].layout
                    if kind == 1: info.sampler = samplers[name]
                    write.pImageInfo = C.cast(C.pointer(info),PTR)
                infos.append(info); writes.append(write)
            write_array = (WriteDescriptorSet * len(writes))(*writes)
            self.vkUpdateDescriptorSets(self.device,len(writes),write_array,0,None)
            command_pool = self.create("CommandPool",CommandPoolCreateInfo(sType=39,queueFamilyIndex=self.family),cleanup)
            command_info = CommandBufferAllocateInfo(sType=40,commandPool=command_pool,commandBufferCount=1)
            command = PTR(); checked(self.vkAllocateCommandBuffers(self.device,C.byref(command_info),C.byref(command)),"vkAllocateCommandBuffers")
            checked(self.vkBeginCommandBuffer(command,C.byref(CommandBufferBeginInfo(sType=42,flags=1))),"vkBeginCommandBuffer")
            for image in images.values():
                image.transition(command,0,7,0,0x1000,1,0x1000)
                self.vkCmdCopyBufferToImage(command,image.upload.buffer,image.image,7,1,C.byref(image.copy))
                image.transition(command,7,image.layout,0x1000,0x20 if image.sampled else 0x60,0x1000,0x800)
            self.vkCmdBindPipeline(command,1,pipeline)
            self.vkCmdBindDescriptorSets(command,1,pipeline_layout,0,1,C.byref(descriptor_set),0,None)
            if push:
                push_data = C.create_string_buffer(push)
                self.vkCmdPushConstants(command,pipeline_layout,0x20,0,len(push),push_data)
            self.vkCmdDispatch(command,*groups)
            for image in images.values():
                image.transition(command,image.layout,6,0x20 if image.sampled else 0x60,0x800,0x800,0x1000)
                self.vkCmdCopyImageToBuffer(command,image.image,6,image.download.buffer,1,C.byref(image.copy))
            barrier = MemoryBarrier(sType=46,srcAccessMask=0x1040,dstAccessMask=0x2000)
            self.vkCmdPipelineBarrier(command,0x1800,0x4000,0,1,C.byref(barrier),0,None,0,None)
            checked(self.vkEndCommandBuffer(command),"vkEndCommandBuffer")
            fence = U64(self.create("Fence",FenceCreateInfo(sType=8),cleanup))
            submission = SubmitInfo(sType=4,commandBufferCount=1,pCommandBuffers=C.pointer(command))
            cleanup.callback(self.vkDeviceWaitIdle,self.device)
            checked(self.vkQueueSubmit(self.queue,1,C.byref(submission),fence),"vkQueueSubmit")
            checked(self.vkWaitForFences(self.device,1,C.byref(fence),1,10_000_000_000),"vkWaitForFences")
            self.dispatches += 1
            output = {name:C.string_at(buf.mapping,buf.size) for name,buf in buffers.items()}
            output.update({name:C.string_at(image.download.mapping,image.download.size) for name,image in images.items()})
            return output


def run_image_tests(root=None):
    root = root or Path(__file__).resolve().parents[1]
    output = root / "build/vulkan-images"; output.mkdir(parents=True,exist_ok=True)
    image_shader = compile_shader(root,output,"storage_image")
    texture_shader = compile_shader(root,output,"sample_texture")
    width,height = 7,5
    with ImageRuntime() as runtime:
        values = [(i * 1234567) & 0xFFFFFFFF for i in range(width * height)]
        values[0] = 0xFFFFFFFF
        data = struct.pack(f"<{len(values)}I",*values)
        spec = lambda fmt,payload: {"format":fmt,"width":width,"height":height,"data":payload}
        result = runtime.run_images(image_shader,{}, {"InputImage":spec(98,data),"OutputImage":spec(98,bytes(len(data)))},b"",(1,2,1))
        expected = struct.pack(f"<{len(values)}I",*((x+1)&0xFFFFFFFF for x in values))
        if result["OutputImage"] != expected or result["InputImage"] != data: raise AssertionError("R32UInt image load/store/query differs")
        for source_type,fmt,payload in (
                ("Image2D_R32Int",99,struct.pack(f"<{width*height}i",*(-i for i in range(width*height)))),
                ("Image2D_RGBA32Float",109,struct.pack(f"<{width*height*4}f",*(i*0.125 for i in range(width*height*4)))),
                ("Image2D_RGBA8",37,bytes([0,255,0,255] * (width*height)))):
            name = f"copy_{fmt}"
            source = f"var [Binding(0,0),ReadOnly] A: {source_type}; [Binding(0,1),WriteOnly] B: {source_type}; [LocalSize(8,4,1)] procedure Main; var P: Integer2; S: Integer2; begin P := Integer2(GlobalInvocationID.X,GlobalInvocationID.Y); S := ImageSize(A); if (P.X < S.X) and (P.Y < S.Y) then ImageStore(B,P,ImageLoad(A,P)); end;"
            (output/f"{name}.pas").write_text(source,encoding="utf-8")
            module = compile_shader(root,output,name,output)
            result = runtime.run_images(module,{}, {"A":spec(fmt,payload),"B":spec(fmt,bytes(len(payload)))},b"",(1,2,1))
            if result["B"] != payload: raise AssertionError(f"Storage image format {fmt} copy differs")
        pixels = [i * 0.125 for i in range(width*height*4)]
        payload = struct.pack(f"<{len(pixels)}f",*pixels)
        result = runtime.run_images(texture_shader,{"OutputData":bytes(len(payload))},{"SourceTexture":spec(109,payload)},struct.pack("<II",width,height),(1,1,1))
        if result["OutputData"] != payload: raise AssertionError("Explicit-LOD nearest texture sampling differs")
        source = 'var [Binding(0,0)] T: Texture2D; [Binding(0,1)] S: Sampler; [Binding(0,2)] O: array of Single4; procedure Main; begin if GlobalInvocationID.X = 0 then O[0] := SampleLevel(T,S,Single2(0.5),0); end;'
        (output/'linear.pas').write_text(source,encoding='utf-8')
        module = compile_shader(root,output,'linear',output)
        data = struct.pack('<16f',*(value for pixel in (0.0,2.0,4.0,6.0) for value in (pixel,pixel,pixel,1.0)))
        result = runtime.run_images(module,{'O':bytes(16)},{'T':{'format':109,'width':2,'height':2,'data':data}},b'',(1,1,1),linear=True)
        if struct.unpack('<4f',result['O']) != (3.0,3.0,3.0,1.0): raise AssertionError('Linear filtered texture sample differs')
        print(f"PASS: {runtime.dispatches} Vulkan storage-image/texture dispatches.")
        return runtime.dispatches


if __name__ == "__main__":
    run_image_tests()
