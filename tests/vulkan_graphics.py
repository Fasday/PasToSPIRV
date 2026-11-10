"""Native vertex/fragment pipeline and combined-texture controls; stdlib only."""
from __future__ import annotations

import ctypes as C
import json
from pathlib import Path
import struct
import subprocess
from contextlib import ExitStack

from vulkan_smoke import (
    U32, U64, I32, PTR, P64, HEADER, structure, checked,
    StorageBuffer, PipelineLayoutCreateInfo, ShaderModuleCreateInfo,
    PipelineShaderStageCreateInfo, CommandPoolCreateInfo, CommandBufferAllocateInfo,
    CommandBufferBeginInfo, MemoryBarrier, FenceCreateInfo, SubmitInfo, compile_shader,
)
from vulkan_images import ImageRuntime, GPUImage

F32 = C.c_float
Rect = structure('Rect', [('x', I32), ('y', I32), ('width', U32), ('height', U32)])
Viewport = structure('Viewport', [(n, F32) for n in ('x', 'y', 'width', 'height', 'minDepth', 'maxDepth')])
Attachment = structure('Attachment', [(n, U32) for n in ('flags', 'format', 'samples',
    'loadOp', 'storeOp', 'stencilLoadOp', 'stencilStoreOp', 'initialLayout', 'finalLayout')])
AttachmentRef = structure('AttachmentRef', [('attachment', U32), ('layout', U32)])
Subpass = structure('Subpass', [('flags', U32), ('pipelineBindPoint', U32),
    ('inputAttachmentCount', U32), ('pInputAttachments', PTR), ('colorAttachmentCount', U32),
    ('pColorAttachments', C.POINTER(AttachmentRef)), ('pResolveAttachments', PTR),
    ('pDepthStencilAttachment', PTR), ('preserveAttachmentCount', U32), ('pPreserveAttachments', PTR)])
RenderPassInfo = structure('RenderPassInfo', HEADER + [('flags', U32),
    ('attachmentCount', U32), ('pAttachments', C.POINTER(Attachment)), ('subpassCount', U32),
    ('pSubpasses', C.POINTER(Subpass)), ('dependencyCount', U32), ('pDependencies', PTR)])
FramebufferInfo = structure('FramebufferInfo', HEADER + [('flags', U32), ('renderPass', U64),
    ('attachmentCount', U32), ('pAttachments', P64), ('width', U32), ('height', U32), ('layers', U32)])
VertexBinding = structure('VertexBinding', [('binding', U32), ('stride', U32), ('inputRate', U32)])
VertexAttribute = structure('VertexAttribute', [('location', U32), ('binding', U32), ('format', U32), ('offset', U32)])
VertexInput = structure('VertexInput', HEADER + [('flags', U32), ('bindingCount', U32),
    ('bindings', C.POINTER(VertexBinding)), ('attributeCount', U32), ('attributes', C.POINTER(VertexAttribute))])
InputAssembly = structure('InputAssembly', HEADER + [('flags', U32), ('topology', U32), ('restart', U32)])
ViewportState = structure('ViewportState', HEADER + [('flags', U32), ('viewportCount', U32),
    ('viewports', C.POINTER(Viewport)), ('scissorCount', U32), ('scissors', C.POINTER(Rect))])
Rasterization = structure('Rasterization', HEADER + [(n, U32) for n in ('flags',
    'depthClamp', 'discard', 'polygonMode', 'cullMode', 'frontFace', 'depthBias')] +
    [(n, F32) for n in ('depthBiasConstant', 'depthBiasClamp', 'depthBiasSlope', 'lineWidth')])
Multisample = structure('Multisample', HEADER + [('flags', U32), ('samples', U32),
    ('sampleShading', U32), ('minSampleShading', F32), ('sampleMask', PTR),
    ('alphaToCoverage', U32), ('alphaToOne', U32)])
BlendAttachment = structure('BlendAttachment', [(n, U32) for n in ('enable',
    'srcColor', 'dstColor', 'colorOp', 'srcAlpha', 'dstAlpha', 'alphaOp', 'writeMask')])
BlendState = structure('BlendState', HEADER + [('flags', U32), ('logicEnable', U32),
    ('logicOp', U32), ('count', U32), ('attachments', C.POINTER(BlendAttachment)), ('constants', F32 * 4)])
GraphicsInfo = structure('GraphicsInfo', HEADER + [('flags', U32), ('stageCount', U32),
    ('stages', C.POINTER(PipelineShaderStageCreateInfo)), ('vertexInput', C.POINTER(VertexInput)),
    ('assembly', C.POINTER(InputAssembly)), ('tessellation', PTR), ('viewport', C.POINTER(ViewportState)),
    ('raster', C.POINTER(Rasterization)), ('multisample', C.POINTER(Multisample)), ('depth', PTR),
    ('blend', C.POINTER(BlendState)), ('dynamic', PTR), ('layout', U64), ('renderPass', U64),
    ('subpass', U32), ('base', U64), ('baseIndex', I32)])
RenderBegin = structure('RenderBegin', HEADER + [('renderPass', U64), ('framebuffer', U64),
    ('area', Rect), ('clearCount', U32), ('clear', PTR)])


class GraphicsRuntime(ImageRuntime):
    required_queue_flags = 3

    def _bind_functions(self):
        super()._bind_functions()
        for name, info in [('RenderPass', RenderPassInfo), ('Framebuffer', FramebufferInfo)]:
            self.bind('vkCreate' + name, I32, PTR, C.POINTER(info), PTR, P64)
            self.bind('vkDestroy' + name, None, PTR, U64, PTR)
        self.bind('vkCreateGraphicsPipelines', I32, PTR, U64, U32, C.POINTER(GraphicsInfo), PTR, P64)
        self.bind('vkCmdBeginRenderPass', None, PTR, C.POINTER(RenderBegin), U32)
        self.bind('vkCmdEndRenderPass', None, PTR)
        self.bind('vkCmdBindVertexBuffers', None, PTR, U32, U32, P64, P64)
        self.bind('vkCmdDraw', None, PTR, U32, U32, U32, U32)

    def draw(self, vertex, fragment):
        width, height = 32, 16
        with ExitStack() as cleanup:
            image = GPUImage(self, dict(width=width, height=height, format=37,
                usage=3 | 8 | 0x10, data=bytes(width * height * 4)), False, cleanup)
            attachment = Attachment(format=37, samples=1, loadOp=1, storeOp=0,
                stencilLoadOp=2, stencilStoreOp=1, initialLayout=1, finalLayout=1)
            color_ref = AttachmentRef(0, 2)
            subpass = Subpass(colorAttachmentCount=1, pColorAttachments=C.pointer(color_ref))
            render_pass = self.create('RenderPass', RenderPassInfo(sType=38, attachmentCount=1,
                pAttachments=C.pointer(attachment), subpassCount=1, pSubpasses=C.pointer(subpass)), cleanup)
            view = U64(image.view.value)
            framebuffer = self.create('Framebuffer', FramebufferInfo(sType=37,
                renderPass=render_pass, attachmentCount=1, pAttachments=C.pointer(view),
                width=width, height=height, layers=1), cleanup)
            layout = self.create('PipelineLayout', PipelineLayoutCreateInfo(sType=30), cleanup)
            stages = []
            for module, flag in [(vertex, 1), (fragment, 0x10)]:
                meta = json.loads(module.with_suffix('.json').read_text())
                code = module.read_bytes()
                words = (U32 * (len(code) // 4)).from_buffer_copy(code)
                shader = self.create('ShaderModule', ShaderModuleCreateInfo(sType=16,
                    codeSize=len(code), pCode=words), cleanup)
                stages.append(PipelineShaderStageCreateInfo(sType=18, stage=flag,
                    module=shader, pName=meta['entry_point'].encode('ascii')))
            stage_array = (PipelineShaderStageCreateInfo * 2)(*stages)
            binding = VertexBinding(0, 28, 0)
            attributes = (VertexAttribute * 2)(VertexAttribute(0, 0, 106, 0), VertexAttribute(1, 0, 109, 12))
            inputs = VertexInput(sType=19, bindingCount=1, bindings=C.pointer(binding),
                attributeCount=2, attributes=attributes)
            assembly = InputAssembly(sType=20, topology=3)
            viewport = Viewport(0, 0, width, height, 0, 1)
            scissor = Rect(0, 0, width, height)
            viewports = ViewportState(sType=22, viewportCount=1, viewports=C.pointer(viewport),
                scissorCount=1, scissors=C.pointer(scissor))
            raster = Rasterization(sType=23, lineWidth=1)
            samples = Multisample(sType=24, samples=1)
            blend_attachment = BlendAttachment(writeMask=15)
            blend = BlendState(sType=26, count=1, attachments=C.pointer(blend_attachment))
            info = GraphicsInfo(sType=28, stageCount=2, stages=stage_array,
                vertexInput=C.pointer(inputs), assembly=C.pointer(assembly), viewport=C.pointer(viewports),
                raster=C.pointer(raster), multisample=C.pointer(samples), blend=C.pointer(blend),
                layout=layout, renderPass=render_pass, baseIndex=-1)
            pipeline = U64()
            result = self.vkCreateGraphicsPipelines(self.device, 0, 1, C.byref(info), None, C.byref(pipeline))
            if pipeline.value:
                cleanup.callback(self.vkDestroyPipeline, self.device, pipeline.value, None)
            checked(result, 'vkCreateGraphicsPipelines')
            payload = b''.join(struct.pack('<7f', x, y, 0.0, 0.125, 0.25, 0.375, 0.5)
                for x, y in [(-1, -1), (3, -1), (-1, 3)])
            vertices = StorageBuffer(self, payload, cleanup, usage=0x83)
            pool = self.create('CommandPool', CommandPoolCreateInfo(sType=39, queueFamilyIndex=self.family), cleanup)
            command = PTR()
            allocation = CommandBufferAllocateInfo(sType=40, commandPool=pool, commandBufferCount=1)
            checked(self.vkAllocateCommandBuffers(self.device, C.byref(allocation), C.byref(command)), 'command allocation')
            checked(self.vkBeginCommandBuffer(command, C.byref(CommandBufferBeginInfo(sType=42, flags=1))), 'begin commands')
            image.transition(command, 0, 1, 0, 0x100, 1, 0x400)
            clear = (F32 * 4)(0, 0, 0, 0)
            begin = RenderBegin(sType=43, renderPass=render_pass, framebuffer=framebuffer,
                area=scissor, clearCount=1, clear=C.addressof(clear))
            self.vkCmdBeginRenderPass(command, C.byref(begin), 0)
            self.vkCmdBindPipeline(command, 0, pipeline)
            offset = U64()
            self.vkCmdBindVertexBuffers(command, 0, 1, C.byref(vertices.buffer), C.byref(offset))
            self.vkCmdDraw(command, 3, 1, 0, 0)
            self.vkCmdEndRenderPass(command)
            image.transition(command, 1, 6, 0x100, 0x800, 0x400, 0x1000)
            self.vkCmdCopyImageToBuffer(command, image.image, 6, image.download.buffer, 1, C.byref(image.copy))
            barrier = MemoryBarrier(sType=46, srcAccessMask=0x1000, dstAccessMask=0x2000)
            self.vkCmdPipelineBarrier(command, 0x1000, 0x4000, 0, 1, C.byref(barrier), 0, None, 0, None)
            checked(self.vkEndCommandBuffer(command), 'end commands')
            fence = U64(self.create('Fence', FenceCreateInfo(sType=8), cleanup))
            submission = SubmitInfo(sType=4, commandBufferCount=1, pCommandBuffers=C.pointer(command))
            cleanup.callback(self.vkDeviceWaitIdle, self.device)
            checked(self.vkQueueSubmit(self.queue, 1, C.byref(submission), fence), 'submit graphics')
            checked(self.vkWaitForFences(self.device, 1, C.byref(fence), 1, 10_000_000_000), 'wait graphics')
            return C.string_at(image.download.mapping, image.download.size)


def compile_text(root, output, name, text, optimize, entry=None):
    source = output / f'{name}.pasm'
    source.write_text(text, encoding='utf-8')
    module = output / f'{name}_O{int(optimize)}.spv'
    arguments = [str(root / 'build/bin/PasToSPIRV.exe'), 'compile', str(source), '-o', str(module)]
    if entry:
        arguments += ['--entry-point', entry]
    if optimize:
        arguments.append('-O1')
    completed = subprocess.run(arguments, capture_output=True, text=True, encoding='utf-8')
    if completed.returncode:
        raise RuntimeError(completed.stderr)
    return module


def interface_pixel(px, py, exchanged):
    """RGBA8 which graphics_interface_*.pasm must produce at a pixel centre."""
    if px == 5 or (px == 9 and py >= 8):
        return (0, 0, 0, 0)  # Discarded: the clear value stays.
    if py == 0:
        return (round((px + 0.5) / 32 * 255), round(0.5 / 16 * 255), round(0.75 * 255), round(0.5 * 255))
    x = (px + 0.5) / 32 * 2 - 1
    y = (py + 0.5) / 16 * 2 - 1
    # Screen-space weights of the corners (-1,-1), (3,-1), (-1,3) and the vertex index at each.
    weights = [1 - (x + 1) / 4 - (y + 1) / 4, (x + 1) / 4, (y + 1) / 4]
    index = [0, 2, 1] if exchanged else [0, 1, 2]
    linear = sum(b * i for b, i in zip(weights, index))
    # Clip-space w of vertex i is 1 + i: perspective-correct interpolation divides by it.
    smooth = (sum(b * i / (1 + i) for b, i in zip(weights, index)) /
              sum(b / (1 + i) for b, i in zip(weights, index)))
    # Corner order 0,1,2 is clockwise with y down: back-facing for counter-clockwise front faces.
    # Flat values come from the provoking vertex 0: Id = (7, 40), Tag = 200.
    return (round(0.25 * 255), round(min(smooth * 0.5, 1) * 255), round(min(linear * 0.5, 1) * 255),
            255 if exchanged else 128)


def check_interfaces(runtime, root, output):
    vertex_text = (root / 'tests/fixtures/graphics_interface_vertex.pasm').read_text(encoding='utf-8')
    fragment_text = (root / 'tests/fixtures/graphics_interface_fragment.pasm').read_text(encoding='utf-8')
    for profile, entry in [('', None), (', Vulkan11', None), (', Vulkan12, StrictFloat', 'main')]:
        for optimize in [False, True]:
            for exchanged in [False, True]:
                vertex_source = vertex_text.replace('[Vertex]', f'[Vertex{profile}]')
                if exchanged:
                    vertex_source = vertex_source.replace('    1: Result', '    2: Result')
                    assert vertex_source.count('    2: Result') == 1
                tag = f'{len(profile)}{int(exchanged)}'
                vertex = compile_text(root, output, f'interface_vertex_{tag}', vertex_source, optimize, entry)
                fragment = compile_text(root, output, f'interface_fragment_{tag}',
                                        fragment_text.replace('[Fragment]', f'[Fragment{profile}]'), optimize, entry)
                pixels = runtime.draw(vertex, fragment)
                for y in range(16):
                    for x in range(32):
                        expected = interface_pixel(x, y, exchanged)
                        actual = pixels[(y * 32 + x) * 4:(y * 32 + x + 1) * 4]
                        if any(abs(a - b) > 1 for a, b in zip(actual, expected)):
                            raise AssertionError(('interface', profile, optimize, exchanged, x, y, tuple(actual), expected))


def check_fetch(runtime, root, output):
    source_texels = [(x + 10 * y + 0.25, 100.0 + x, 200.0 + y, 1.0) for y in range(3) for x in range(5)]
    index_texels = [1000 + x + 16 * y for y in range(2) for x in range(4)]
    plain_texels = [(0.5 + x, 0.75 + y, -1.0 * (x + 2 * y), 2.0) for y in range(2) for x in range(2)]
    for optimize in [False, True]:
        module = compile_shader(root, output, 'combined_fetch', 'tests/fixtures', optimize=optimize)
        result = runtime.run_images(module, {'OutF': bytes(60 * 16), 'OutU': bytes(15 * 16), 'OutS': bytes(16 * 16)}, {
            'Source': dict(width=5, height=3, format=109, data=struct.pack('<60f', *(v for t in source_texels for v in t))),
            'Indices': dict(width=4, height=2, format=98, data=struct.pack('<8I', *index_texels)),
            'Plain': dict(width=2, height=2, format=109, data=struct.pack('<16f', *(v for t in plain_texels for v in t))),
        }, b'', (1, 1, 1))
        fetched = struct.unpack('<240f', result['OutF'])
        indices = struct.unpack('<60I', result['OutU'])
        sizes = struct.unpack('<64i', result['OutS'])
        for i in range(15):
            x, y = i % 5, i // 5
            for slot in (0, 1, 3):  # Integer2 fetch, Cardinal2 fetch, nearest sample at the centre
                if fetched[(i * 4 + slot) * 4:(i * 4 + slot) * 4 + 4] != source_texels[i]:
                    raise AssertionError(('combined fetch', optimize, slot, x, y))
            if fetched[(i * 4 + 2) * 4:(i * 4 + 2) * 4 + 4] != plain_texels[(y & 1) * 2 + (x & 1)]:
                raise AssertionError(('separate texture fetch', optimize, x, y))
            if indices[i * 4] != index_texels[(y % 2) * 4 + (x % 4)]:
                raise AssertionError(('unsigned fetch', optimize, x, y, indices[i * 4]))
            if sizes[i * 4:i * 4 + 4] != (5, 3, 4, 2):
                raise AssertionError(('TextureSize', optimize, sizes[i * 4:i * 4 + 4]))
        if sizes[60:64] != (2, 2, 7, 9):
            raise AssertionError(('TextureSize of a separate texture', optimize, sizes[60:64]))


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / 'build/vulkan-graphics'
    output.mkdir(parents=True, exist_ok=True)
    with GraphicsRuntime() as runtime:
        check_interfaces(runtime, root, output)
        for optimize in [False, True]:
            vertex = compile_shader(root, output, 'graphics_vertex', 'tests/fixtures', optimize=optimize)
            fragment = compile_shader(root, output, 'graphics_fragment', 'tests/fixtures', optimize=optimize)
            for discard in [False, True]:
                selected = fragment
                if discard:
                    source = (root / 'tests/fixtures/graphics_fragment.pasm').read_text().replace('Pixel.X < 0.0', 'Pixel.X < 16.0')
                    (output / 'discard.pas').write_text(source)
                    selected = compile_shader(root, output, 'discard', output, optimize=optimize)
                pixels = runtime.draw(vertex, selected)
                for y in range(16):
                    for x in range(32):
                        expected = (0, 0, 0, 0) if discard and x < 16 else (64, 128, 191, 255)
                        actual = pixels[(y * 32 + x) * 4:(y * 32 + x + 1) * 4]
                        if any(abs(a - b) > 1 for a, b in zip(actual, expected)):
                            raise AssertionError((optimize, discard, x, y, tuple(actual), expected))
    with ImageRuntime() as runtime:
        check_fetch(runtime, root, output)
        for optimize in [False, True]:
            module = compile_shader(root, output, 'combined_texture', 'tests/fixtures', optimize=optimize)
            values = struct.pack('<16f', *([0.25, 0.5, 0.75, 1.0] * 4))
            result = runtime.run_images(module, {'Target': bytes(16)}, {
                'Source': dict(width=2, height=2, format=109, data=values),
                'Indices': dict(width=2, height=2, format=98, data=struct.pack('<4I', 100, 200, 300, 400)),
            }, b'', (1, 1, 1))
            if struct.unpack('<4I', result['Target']) != (166, 130, 193, 258):
                raise AssertionError(('combined texture result', struct.unpack('<4I', result['Target'])))
            sample = compile_shader(root, output, 'combined_sample', 'tests/fixtures', optimize=optimize)
            values = struct.pack('<16f', *(v for p in [0.0, 2.0, 4.0, 6.0] for v in [p, p, p, 1.0]))
            result = runtime.run_images(sample, {'Target': bytes(16)}, {
                'Source': dict(width=2, height=2, format=109, data=values),
            }, b'', (1, 1, 1), linear=True)
            if struct.unpack('<4f', result['Target']) != (3.0, 3.0, 3.0, 1.0):
                raise AssertionError('Combined explicit-LOD linear sampling differs')
            numeric = compile_shader(root, output, 'graphics_vector_math', 'tests/fixtures', optimize=optimize)
            result = runtime.run(numeric, {'Counts': bytes(4), 'Target': bytes(48)}, b'', 1)
            if struct.unpack('<I', result['Counts'])[0] != 2 or struct.unpack('<12i', result['Target']) != (
                    0, 10, 1, 11, -4, -2, -1, -1, -8, 2, -1, 0):
                raise AssertionError('Mixed constructors, evaluation order or signed vector shifts differ')
    print('PASS: native vertex/fragment, varying inputs, fine derivatives, helper Discard and combined float/uint texel fetch, O0/O1.')
    print('Checked VertexIndex/InstanceIndex, Flat integer varyings, smooth vs NoPerspective, FragCoord, FrontFacing '
          '(both windings), Discard in a loop and a nested routine, a renamed entry point (3 profiles).')
    print('Checked every texel: TexelFetch (Integer2/Cardinal2, combined and separate), TextureSize, combined SampleLevel.')


if __name__ == '__main__':
    main()
