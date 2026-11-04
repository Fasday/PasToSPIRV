unit SketchVulkan;

// Minimal Vulkan 1.0 compute host for the sketch shader, loaded dynamically from
// vulkan-1.dll. Device-local storage buffers, host-visible staging buffers,
// one pipeline (three sketch passes or two thumbnail passes), and timestamp queries.
// Example code, not a general Vulkan binding.

interface

uses
  System.SysUtils;

type
  TGPUTimings = record
    Upload: Double;   // ms, GPU timestamps: staging -> device copy
    Kernels: Double;  // ms, GPU timestamps: all dispatches
    Download: Double; // ms, GPU timestamps: device -> staging copy
    HasTimestamps: Boolean;
  end;

  TSketchGPU = class
  private
    FLibrary: HMODULE;
    FInstance, FPhysical, FDevice, FQueue, FCommand: Pointer;
    FFamily: Cardinal;
    FTimestampBits: Cardinal;
    FTimestampPeriod: Single;
    FMaxStorageRange: Cardinal;
    FDeviceName: string;
    FSetLayout, FPipelineLayout, FShader, FPipeline, FPool, FSet, FCommandPool, FFence, FQueries: UInt64;
    FBuffers: array[0..5] of UInt64; // Source, Gray, Horizontal, Target, Upload, Download
    FMemory: array[0..5] of UInt64;
    FUploadMap, FDownloadMap: Pointer;
    FWidth, FHeight, FRadius: Integer;
    FTargetWidth, FTargetHeight: Integer;
    FThumbnail: Boolean;
    procedure LoadFunctions;
    procedure CreateDevice;
    procedure CreatePipeline(const ASpirv: TBytes);
    procedure ReleaseImageResources;
    function MemoryType(ABits, ARequired, APreferred: Cardinal): Cardinal;
    procedure CreateBuffer(AIndex: Integer; ASize: UInt64; AUsage, ARequired, APreferred: Cardinal);
    procedure Record_;
    procedure PrepareResources;
  public
    constructor Create(const ASpirvFile: string);
    destructor Destroy; override;
    // Allocates buffers and records the command buffer for one image size/radius.
    procedure Prepare(AWidth, AHeight, ARadius: Integer);
    procedure PrepareThumbnail(AWidth, AHeight, ATargetWidth, ATargetHeight: Integer);
    // Copies pixels to staging, runs everything on the GPU, copies the result back.
    function Run(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>): TGPUTimings;
    property DeviceName: string read FDeviceName;
    property MaxStorageRange: Cardinal read FMaxStorageRange;
  end;

implementation

uses
  Winapi.Windows,
  System.IOUtils,
  ThumbnailCPU,
  SketchShaderBindings;

type
  VkResult = Int32;
  PUInt64 = ^UInt64;

  VkApplicationInfo = record
    sType: Cardinal; pNext: Pointer; pApplicationName: PAnsiChar; applicationVersion: Cardinal;
    pEngineName: PAnsiChar; engineVersion: Cardinal; apiVersion: Cardinal;
  end;
  VkInstanceCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags: Cardinal; pApplicationInfo: ^VkApplicationInfo;
    enabledLayerCount: Cardinal; ppEnabledLayerNames: Pointer;
    enabledExtensionCount: Cardinal; ppEnabledExtensionNames: Pointer;
  end;
  VkQueueFamilyProperties = record
    queueFlags, queueCount, timestampValidBits: Cardinal; granularity: array[0..2] of Cardinal;
  end;
  VkMemoryType = record propertyFlags, heapIndex: Cardinal; end;
  VkMemoryHeap = record size: UInt64; flags: Cardinal; end;
  VkPhysicalDeviceMemoryProperties = record
    memoryTypeCount: Cardinal; memoryTypes: array[0..31] of VkMemoryType;
    memoryHeapCount: Cardinal; memoryHeaps: array[0..15] of VkMemoryHeap;
  end;
  // Field order transcribed from vulkan_core.h (Vulkan 1.0); only a few are used.
  VkPhysicalDeviceLimits = record
    maxImageDimension1D, maxImageDimension2D, maxImageDimension3D, maxImageDimensionCube,
    maxImageArrayLayers, maxTexelBufferElements, maxUniformBufferRange, maxStorageBufferRange,
    maxPushConstantsSize, maxMemoryAllocationCount, maxSamplerAllocationCount: Cardinal;
    bufferImageGranularity, sparseAddressSpaceSize: UInt64;
    maxBoundDescriptorSets, maxPerStageDescriptorSamplers, maxPerStageDescriptorUniformBuffers,
    maxPerStageDescriptorStorageBuffers, maxPerStageDescriptorSampledImages,
    maxPerStageDescriptorStorageImages, maxPerStageDescriptorInputAttachments, maxPerStageResources,
    maxDescriptorSetSamplers, maxDescriptorSetUniformBuffers, maxDescriptorSetUniformBuffersDynamic,
    maxDescriptorSetStorageBuffers, maxDescriptorSetStorageBuffersDynamic, maxDescriptorSetSampledImages,
    maxDescriptorSetStorageImages, maxDescriptorSetInputAttachments, maxVertexInputAttributes,
    maxVertexInputBindings, maxVertexInputAttributeOffset, maxVertexInputBindingStride,
    maxVertexOutputComponents, maxTessellationGenerationLevel, maxTessellationPatchSize,
    maxTessellationControlPerVertexInputComponents, maxTessellationControlPerVertexOutputComponents,
    maxTessellationControlPerPatchOutputComponents, maxTessellationControlTotalOutputComponents,
    maxTessellationEvaluationInputComponents, maxTessellationEvaluationOutputComponents,
    maxGeometryShaderInvocations, maxGeometryInputComponents, maxGeometryOutputComponents,
    maxGeometryOutputVertices, maxGeometryTotalOutputComponents, maxFragmentInputComponents,
    maxFragmentOutputAttachments, maxFragmentDualSrcAttachments, maxFragmentCombinedOutputResources,
    maxComputeSharedMemorySize: Cardinal;
    maxComputeWorkGroupCount: array[0..2] of Cardinal;
    maxComputeWorkGroupInvocations: Cardinal;
    maxComputeWorkGroupSize: array[0..2] of Cardinal;
    subPixelPrecisionBits, subTexelPrecisionBits, mipmapPrecisionBits, maxDrawIndexedIndexValue,
    maxDrawIndirectCount: Cardinal;
    maxSamplerLodBias, maxSamplerAnisotropy: Single;
    maxViewports: Cardinal;
    maxViewportDimensions: array[0..1] of Cardinal;
    viewportBoundsRange: array[0..1] of Single;
    viewportSubPixelBits: Cardinal;
    minMemoryMapAlignment: NativeUInt;
    minTexelBufferOffsetAlignment, minUniformBufferOffsetAlignment, minStorageBufferOffsetAlignment: UInt64;
    minTexelOffset: Integer; maxTexelOffset: Cardinal; minTexelGatherOffset: Integer; maxTexelGatherOffset: Cardinal;
    minInterpolationOffset, maxInterpolationOffset: Single;
    subPixelInterpolationOffsetBits, maxFramebufferWidth, maxFramebufferHeight, maxFramebufferLayers,
    framebufferColorSampleCounts, framebufferDepthSampleCounts, framebufferStencilSampleCounts,
    framebufferNoAttachmentsSampleCounts, maxColorAttachments, sampledImageColorSampleCounts,
    sampledImageIntegerSampleCounts, sampledImageDepthSampleCounts, sampledImageStencilSampleCounts,
    storageImageSampleCounts, maxSampleMaskWords, timestampComputeAndGraphics: Cardinal;
    timestampPeriod: Single;
    maxClipDistances, maxCullDistances, maxCombinedClipAndCullDistances, discreteQueuePriorities: Cardinal;
    pointSizeRange, lineWidthRange: array[0..1] of Single;
    pointSizeGranularity, lineWidthGranularity: Single;
    strictLines, standardSampleLocations: Cardinal;
    optimalBufferCopyOffsetAlignment, optimalBufferCopyRowPitchAlignment, nonCoherentAtomSize: UInt64;
  end;
  VkPhysicalDeviceProperties = record
    apiVersion, driverVersion, vendorID, deviceID, deviceType: Cardinal;
    deviceName: array[0..255] of AnsiChar;
    pipelineCacheUUID: array[0..15] of Byte;
    limits: VkPhysicalDeviceLimits;
    sparseProperties: array[0..4] of Cardinal;
  end;
  VkDeviceQueueCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags, queueFamilyIndex, queueCount: Cardinal; pQueuePriorities: PSingle;
  end;
  VkDeviceCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags, queueCreateInfoCount: Cardinal; pQueueCreateInfos: ^VkDeviceQueueCreateInfo;
    enabledLayerCount: Cardinal; ppEnabledLayerNames: Pointer; enabledExtensionCount: Cardinal;
    ppEnabledExtensionNames: Pointer; pEnabledFeatures: Pointer;
  end;
  VkBufferCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags: Cardinal; size: UInt64; usage, sharingMode, queueFamilyIndexCount: Cardinal;
    pQueueFamilyIndices: Pointer;
  end;
  VkMemoryRequirements = record size, alignment: UInt64; memoryTypeBits: Cardinal; end;
  VkMemoryAllocateInfo = record sType: Cardinal; pNext: Pointer; allocationSize: UInt64; memoryTypeIndex: Cardinal; end;
  VkDescriptorSetLayoutBinding = record
    binding, descriptorType, descriptorCount, stageFlags: Cardinal; pImmutableSamplers: Pointer;
  end;
  VkDescriptorSetLayoutCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags, bindingCount: Cardinal; pBindings: ^VkDescriptorSetLayoutBinding;
  end;
  VkPushConstantRange = record stageFlags, offset, size: Cardinal; end;
  VkPipelineLayoutCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags, setLayoutCount: Cardinal; pSetLayouts: PUInt64;
    pushConstantRangeCount: Cardinal; pPushConstantRanges: ^VkPushConstantRange;
  end;
  VkShaderModuleCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags: Cardinal; codeSize: NativeUInt; pCode: Pointer;
  end;
  VkPipelineShaderStageCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags, stage: Cardinal; module: UInt64; pName: PAnsiChar;
    pSpecializationInfo: Pointer;
  end;
  VkComputePipelineCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags: Cardinal; stage: VkPipelineShaderStageCreateInfo;
    layout, basePipelineHandle: UInt64; basePipelineIndex: Integer;
  end;
  VkDescriptorPoolSize = record type_, descriptorCount: Cardinal; end;
  VkDescriptorPoolCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags, maxSets, poolSizeCount: Cardinal; pPoolSizes: ^VkDescriptorPoolSize;
  end;
  VkDescriptorSetAllocateInfo = record
    sType: Cardinal; pNext: Pointer; descriptorPool: UInt64; descriptorSetCount: Cardinal; pSetLayouts: PUInt64;
  end;
  VkDescriptorBufferInfo = record buffer, offset, range: UInt64; end;
  VkWriteDescriptorSet = record
    sType: Cardinal; pNext: Pointer; dstSet: UInt64; dstBinding, dstArrayElement, descriptorCount,
    descriptorType: Cardinal; pImageInfo: Pointer; pBufferInfo: ^VkDescriptorBufferInfo; pTexelBufferView: Pointer;
  end;
  VkCommandPoolCreateInfo = record sType: Cardinal; pNext: Pointer; flags, queueFamilyIndex: Cardinal; end;
  VkCommandBufferAllocateInfo = record
    sType: Cardinal; pNext: Pointer; commandPool: UInt64; level, commandBufferCount: Cardinal;
  end;
  VkCommandBufferBeginInfo = record sType: Cardinal; pNext: Pointer; flags: Cardinal; pInheritanceInfo: Pointer; end;
  VkMemoryBarrier = record sType: Cardinal; pNext: Pointer; srcAccessMask, dstAccessMask: Cardinal; end;
  VkBufferCopy = record srcOffset, dstOffset, size: UInt64; end;
  VkFenceCreateInfo = record sType: Cardinal; pNext: Pointer; flags: Cardinal; end;
  VkQueryPoolCreateInfo = record
    sType: Cardinal; pNext: Pointer; flags, queryType, queryCount, pipelineStatistics: Cardinal;
  end;
  VkSubmitInfo = record
    sType: Cardinal; pNext: Pointer; waitSemaphoreCount: Cardinal; pWaitSemaphores, pWaitDstStageMask: Pointer;
    commandBufferCount: Cardinal; pCommandBuffers: PPointer; signalSemaphoreCount: Cardinal; pSignalSemaphores: Pointer;
  end;

const
  STORAGE_BUFFER = 7;
  STAGE_COMPUTE = $20;
  BIND_COMPUTE = 1;
  MEMORY_DEVICE_LOCAL = 1;
  MEMORY_HOST_VISIBLE = 2;
  MEMORY_HOST_COHERENT = 4;
  MEMORY_HOST_CACHED = 8;
  USAGE_TRANSFER_SRC = 1;
  USAGE_TRANSFER_DST = 2;
  USAGE_STORAGE = $20;
  PIPE_TOP = 1;
  PIPE_COMPUTE = $800;
  PIPE_TRANSFER = $1000;
  PIPE_BOTTOM = $2000;
  PIPE_HOST = $4000;
  ACCESS_SHADER_READ = $20;
  ACCESS_SHADER_WRITE = $40;
  ACCESS_TRANSFER_READ = $800;
  ACCESS_TRANSFER_WRITE = $1000;
  ACCESS_HOST_READ = $2000;
  ACCESS_HOST_WRITE = $4000;
  TimestampCount = 6;
  GroupSize = 16; // matches [LocalSize(16, 16, 1)] in sketch.pas
  // Buffer order used by this host: Source, Gray, Horizontal, Target.
  BindingNumbers: array[0..3] of Cardinal = (PTS_Buffer_Source_Binding, PTS_Buffer_Gray_Binding,
    PTS_Buffer_Horizontal_Binding, PTS_Buffer_Target_Binding);

var
  vkCreateInstance: function(const [Ref] Info: VkInstanceCreateInfo; Allocator: Pointer; out Instance: Pointer): VkResult; stdcall;
  vkDestroyInstance: procedure(Instance, Allocator: Pointer); stdcall;
  vkEnumeratePhysicalDevices: function(Instance: Pointer; var Count: Cardinal; Devices: PPointer): VkResult; stdcall;
  vkGetPhysicalDeviceProperties: procedure(Physical: Pointer; out Properties: VkPhysicalDeviceProperties); stdcall;
  vkGetPhysicalDeviceQueueFamilyProperties: procedure(Physical: Pointer; var Count: Cardinal; Properties: Pointer); stdcall;
  vkGetPhysicalDeviceMemoryProperties: procedure(Physical: Pointer; out Properties: VkPhysicalDeviceMemoryProperties); stdcall;
  vkCreateDevice: function(Physical: Pointer; const [Ref] Info: VkDeviceCreateInfo; Allocator: Pointer; out Device: Pointer): VkResult; stdcall;
  vkDestroyDevice: procedure(Device, Allocator: Pointer); stdcall;
  vkGetDeviceQueue: procedure(Device: Pointer; Family, Index: Cardinal; out Queue: Pointer); stdcall;
  vkDeviceWaitIdle: function(Device: Pointer): VkResult; stdcall;
  vkCreateBuffer: function(Device: Pointer; const [Ref] Info: VkBufferCreateInfo; Allocator: Pointer; out Buffer: UInt64): VkResult; stdcall;
  vkDestroyBuffer: procedure(Device: Pointer; Buffer: UInt64; Allocator: Pointer); stdcall;
  vkGetBufferMemoryRequirements: procedure(Device: Pointer; Buffer: UInt64; out Requirements: VkMemoryRequirements); stdcall;
  vkAllocateMemory: function(Device: Pointer; const [Ref] Info: VkMemoryAllocateInfo; Allocator: Pointer; out Memory: UInt64): VkResult; stdcall;
  vkFreeMemory: procedure(Device: Pointer; Memory: UInt64; Allocator: Pointer); stdcall;
  vkBindBufferMemory: function(Device: Pointer; Buffer, Memory, Offset: UInt64): VkResult; stdcall;
  vkMapMemory: function(Device: Pointer; Memory, Offset, Size: UInt64; Flags: Cardinal; out Data: Pointer): VkResult; stdcall;
  vkUnmapMemory: procedure(Device: Pointer; Memory: UInt64); stdcall;
  vkCreateDescriptorSetLayout: function(Device: Pointer; const [Ref] Info: VkDescriptorSetLayoutCreateInfo; Allocator: Pointer; out Layout: UInt64): VkResult; stdcall;
  vkDestroyDescriptorSetLayout: procedure(Device: Pointer; Layout: UInt64; Allocator: Pointer); stdcall;
  vkCreatePipelineLayout: function(Device: Pointer; const [Ref] Info: VkPipelineLayoutCreateInfo; Allocator: Pointer; out Layout: UInt64): VkResult; stdcall;
  vkDestroyPipelineLayout: procedure(Device: Pointer; Layout: UInt64; Allocator: Pointer); stdcall;
  vkCreateShaderModule: function(Device: Pointer; const [Ref] Info: VkShaderModuleCreateInfo; Allocator: Pointer; out Module: UInt64): VkResult; stdcall;
  vkDestroyShaderModule: procedure(Device: Pointer; Module: UInt64; Allocator: Pointer); stdcall;
  vkCreateComputePipelines: function(Device: Pointer; Cache: UInt64; Count: Cardinal; const [Ref] Info: VkComputePipelineCreateInfo; Allocator: Pointer; out Pipeline: UInt64): VkResult; stdcall;
  vkDestroyPipeline: procedure(Device: Pointer; Pipeline: UInt64; Allocator: Pointer); stdcall;
  vkCreateDescriptorPool: function(Device: Pointer; const [Ref] Info: VkDescriptorPoolCreateInfo; Allocator: Pointer; out Pool: UInt64): VkResult; stdcall;
  vkDestroyDescriptorPool: procedure(Device: Pointer; Pool: UInt64; Allocator: Pointer); stdcall;
  vkAllocateDescriptorSets: function(Device: Pointer; const [Ref] Info: VkDescriptorSetAllocateInfo; out DescriptorSet: UInt64): VkResult; stdcall;
  vkUpdateDescriptorSets: procedure(Device: Pointer; WriteCount: Cardinal; Writes: Pointer; CopyCount: Cardinal; Copies: Pointer); stdcall;
  vkCreateCommandPool: function(Device: Pointer; const [Ref] Info: VkCommandPoolCreateInfo; Allocator: Pointer; out Pool: UInt64): VkResult; stdcall;
  vkDestroyCommandPool: procedure(Device: Pointer; Pool: UInt64; Allocator: Pointer); stdcall;
  vkAllocateCommandBuffers: function(Device: Pointer; const [Ref] Info: VkCommandBufferAllocateInfo; out Command: Pointer): VkResult; stdcall;
  vkResetCommandBuffer: function(Command: Pointer; Flags: Cardinal): VkResult; stdcall;
  vkBeginCommandBuffer: function(Command: Pointer; const [Ref] Info: VkCommandBufferBeginInfo): VkResult; stdcall;
  vkEndCommandBuffer: function(Command: Pointer): VkResult; stdcall;
  vkCmdBindPipeline: procedure(Command: Pointer; BindPoint: Cardinal; Pipeline: UInt64); stdcall;
  vkCmdBindDescriptorSets: procedure(Command: Pointer; BindPoint: Cardinal; Layout: UInt64; FirstSet, Count: Cardinal; Sets: PUInt64; DynamicCount: Cardinal; Dynamic: Pointer); stdcall;
  vkCmdPushConstants: procedure(Command: Pointer; Layout: UInt64; Stages, Offset, Size: Cardinal; Values: Pointer); stdcall;
  vkCmdDispatch: procedure(Command: Pointer; X, Y, Z: Cardinal); stdcall;
  vkCmdPipelineBarrier: procedure(Command: Pointer; SourceStages, TargetStages, Dependency, MemoryCount: Cardinal; Memory: Pointer; BufferCount: Cardinal; Buffers: Pointer; ImageCount: Cardinal; Images: Pointer); stdcall;
  vkCmdCopyBuffer: procedure(Command: Pointer; Source, Target: UInt64; Count: Cardinal; const [Ref] Region: VkBufferCopy); stdcall;
  vkCmdResetQueryPool: procedure(Command: Pointer; Pool: UInt64; First, Count: Cardinal); stdcall;
  vkCmdWriteTimestamp: procedure(Command: Pointer; Stage: Cardinal; Pool: UInt64; Query: Cardinal); stdcall;
  vkCreateQueryPool: function(Device: Pointer; const [Ref] Info: VkQueryPoolCreateInfo; Allocator: Pointer; out Pool: UInt64): VkResult; stdcall;
  vkDestroyQueryPool: procedure(Device: Pointer; Pool: UInt64; Allocator: Pointer); stdcall;
  vkGetQueryPoolResults: function(Device: Pointer; Pool: UInt64; First, Count: Cardinal; DataSize: NativeUInt; Data: Pointer; Stride: UInt64; Flags: Cardinal): VkResult; stdcall;
  vkCreateFence: function(Device: Pointer; const [Ref] Info: VkFenceCreateInfo; Allocator: Pointer; out Fence: UInt64): VkResult; stdcall;
  vkDestroyFence: procedure(Device: Pointer; Fence: UInt64; Allocator: Pointer); stdcall;
  vkResetFences: function(Device: Pointer; Count: Cardinal; Fences: PUInt64): VkResult; stdcall;
  vkWaitForFences: function(Device: Pointer; Count: Cardinal; Fences: PUInt64; WaitAll: Cardinal; Timeout: UInt64): VkResult; stdcall;
  vkQueueSubmit: function(Queue: Pointer; Count: Cardinal; const [Ref] Submit: VkSubmitInfo; Fence: UInt64): VkResult; stdcall;

procedure Check(AResult: VkResult; const AOperation: string);
begin
  if AResult <> 0 then
    raise EOSError.CreateFmt('%s failed: VkResult %d', [AOperation, AResult]);
end;

{ TSketchGPU }

constructor TSketchGPU.Create(const ASpirvFile: string);
begin
  inherited Create;
  FLibrary := LoadLibrary('vulkan-1.dll');
  if FLibrary = 0 then
    raise EOSError.Create('Vulkan loader (vulkan-1.dll) is not available');
  LoadFunctions;
  CreateDevice;
  CreatePipeline(TFile.ReadAllBytes(ASpirvFile));
end;

destructor TSketchGPU.Destroy;
begin
  if FDevice <> nil then
  begin
    vkDeviceWaitIdle(FDevice);
    ReleaseImageResources;
    if FQueries <> 0 then vkDestroyQueryPool(FDevice, FQueries, nil);
    if FFence <> 0 then vkDestroyFence(FDevice, FFence, nil);
    if FCommandPool <> 0 then vkDestroyCommandPool(FDevice, FCommandPool, nil);
    if FPipeline <> 0 then vkDestroyPipeline(FDevice, FPipeline, nil);
    if FShader <> 0 then vkDestroyShaderModule(FDevice, FShader, nil);
    if FPipelineLayout <> 0 then vkDestroyPipelineLayout(FDevice, FPipelineLayout, nil);
    if FSetLayout <> 0 then vkDestroyDescriptorSetLayout(FDevice, FSetLayout, nil);
    vkDestroyDevice(FDevice, nil);
  end;
  if FInstance <> nil then vkDestroyInstance(FInstance, nil);
  if FLibrary <> 0 then FreeLibrary(FLibrary);
  inherited;
end;

procedure TSketchGPU.LoadFunctions;
  function Entry(const AName: string): Pointer;
  begin
    Result := GetProcAddress(FLibrary, PChar(AName));
    if Result = nil then
      raise EOSError.Create('Missing Vulkan entry point ' + AName);
  end;
begin
  @vkCreateInstance := Entry('vkCreateInstance'); @vkDestroyInstance := Entry('vkDestroyInstance');
  @vkEnumeratePhysicalDevices := Entry('vkEnumeratePhysicalDevices');
  @vkGetPhysicalDeviceProperties := Entry('vkGetPhysicalDeviceProperties');
  @vkGetPhysicalDeviceQueueFamilyProperties := Entry('vkGetPhysicalDeviceQueueFamilyProperties');
  @vkGetPhysicalDeviceMemoryProperties := Entry('vkGetPhysicalDeviceMemoryProperties');
  @vkCreateDevice := Entry('vkCreateDevice'); @vkDestroyDevice := Entry('vkDestroyDevice');
  @vkGetDeviceQueue := Entry('vkGetDeviceQueue'); @vkDeviceWaitIdle := Entry('vkDeviceWaitIdle');
  @vkCreateBuffer := Entry('vkCreateBuffer'); @vkDestroyBuffer := Entry('vkDestroyBuffer');
  @vkGetBufferMemoryRequirements := Entry('vkGetBufferMemoryRequirements');
  @vkAllocateMemory := Entry('vkAllocateMemory'); @vkFreeMemory := Entry('vkFreeMemory');
  @vkBindBufferMemory := Entry('vkBindBufferMemory'); @vkMapMemory := Entry('vkMapMemory'); @vkUnmapMemory := Entry('vkUnmapMemory');
  @vkCreateDescriptorSetLayout := Entry('vkCreateDescriptorSetLayout'); @vkDestroyDescriptorSetLayout := Entry('vkDestroyDescriptorSetLayout');
  @vkCreatePipelineLayout := Entry('vkCreatePipelineLayout'); @vkDestroyPipelineLayout := Entry('vkDestroyPipelineLayout');
  @vkCreateShaderModule := Entry('vkCreateShaderModule'); @vkDestroyShaderModule := Entry('vkDestroyShaderModule');
  @vkCreateComputePipelines := Entry('vkCreateComputePipelines'); @vkDestroyPipeline := Entry('vkDestroyPipeline');
  @vkCreateDescriptorPool := Entry('vkCreateDescriptorPool'); @vkDestroyDescriptorPool := Entry('vkDestroyDescriptorPool');
  @vkAllocateDescriptorSets := Entry('vkAllocateDescriptorSets'); @vkUpdateDescriptorSets := Entry('vkUpdateDescriptorSets');
  @vkCreateCommandPool := Entry('vkCreateCommandPool'); @vkDestroyCommandPool := Entry('vkDestroyCommandPool');
  @vkAllocateCommandBuffers := Entry('vkAllocateCommandBuffers'); @vkResetCommandBuffer := Entry('vkResetCommandBuffer');
  @vkBeginCommandBuffer := Entry('vkBeginCommandBuffer'); @vkEndCommandBuffer := Entry('vkEndCommandBuffer');
  @vkCmdBindPipeline := Entry('vkCmdBindPipeline'); @vkCmdBindDescriptorSets := Entry('vkCmdBindDescriptorSets');
  @vkCmdPushConstants := Entry('vkCmdPushConstants'); @vkCmdDispatch := Entry('vkCmdDispatch');
  @vkCmdPipelineBarrier := Entry('vkCmdPipelineBarrier'); @vkCmdCopyBuffer := Entry('vkCmdCopyBuffer');
  @vkCmdResetQueryPool := Entry('vkCmdResetQueryPool'); @vkCmdWriteTimestamp := Entry('vkCmdWriteTimestamp');
  @vkCreateQueryPool := Entry('vkCreateQueryPool'); @vkDestroyQueryPool := Entry('vkDestroyQueryPool');
  @vkGetQueryPoolResults := Entry('vkGetQueryPoolResults');
  @vkCreateFence := Entry('vkCreateFence'); @vkDestroyFence := Entry('vkDestroyFence');
  @vkResetFences := Entry('vkResetFences'); @vkWaitForFences := Entry('vkWaitForFences');
  @vkQueueSubmit := Entry('vkQueueSubmit');
end;

procedure TSketchGPU.CreateDevice;
var
  Application: VkApplicationInfo;
  InstanceInfo: VkInstanceCreateInfo;
  Count, FamilyCount: Cardinal;
  I, J: Integer;
  Devices: TArray<Pointer>;
  Families: TArray<VkQueueFamilyProperties>;
  Properties: VkPhysicalDeviceProperties;
  Priority: Single;
  QueueInfo: VkDeviceQueueCreateInfo;
  DeviceInfo: VkDeviceCreateInfo;
  Score, BestScore: Integer;
begin
  FillChar(Application, SizeOf(Application), 0);
  Application.pApplicationName := 'PasToSPIRV sketch benchmark';
  Application.apiVersion := 1 shl 22; // Vulkan 1.0
  FillChar(InstanceInfo, SizeOf(InstanceInfo), 0);
  InstanceInfo.sType := 1;
  InstanceInfo.pApplicationInfo := @Application;
  Check(vkCreateInstance(InstanceInfo, nil, FInstance), 'vkCreateInstance');
  Count := 0;
  Check(vkEnumeratePhysicalDevices(FInstance, Count, nil), 'vkEnumeratePhysicalDevices');
  if Count = 0 then
    raise EOSError.Create('No Vulkan devices found');
  SetLength(Devices, Count);
  Check(vkEnumeratePhysicalDevices(FInstance, Count, @Devices[0]), 'vkEnumeratePhysicalDevices');
  // Prefer a discrete GPU, then integrated, with a compute queue.
  BestScore := -1;
  for I := 0 to Integer(Count) - 1 do
  begin
    vkGetPhysicalDeviceProperties(Devices[I], Properties);
    FamilyCount := 0;
    vkGetPhysicalDeviceQueueFamilyProperties(Devices[I], FamilyCount, nil);
    if FamilyCount = 0 then Continue;
    SetLength(Families, FamilyCount);
    vkGetPhysicalDeviceQueueFamilyProperties(Devices[I], FamilyCount, @Families[0]);
    for J := 0 to Integer(FamilyCount) - 1 do
      if (Families[J].queueCount > 0) and (Families[J].queueFlags and 2 <> 0) then
      begin
        case Properties.deviceType of
          2: Score := 3; // discrete
          1: Score := 2; // integrated
        else
          Score := 1;
        end;
        if Score > BestScore then
        begin
          BestScore := Score;
          FPhysical := Devices[I];
          FFamily := J;
          FTimestampBits := Families[J].timestampValidBits;
          FTimestampPeriod := Properties.limits.timestampPeriod;
          FMaxStorageRange := Properties.limits.maxStorageBufferRange;
          FDeviceName := string(UTF8String(PAnsiChar(@Properties.deviceName[0])));
        end;
        Break;
      end;
  end;
  if FPhysical = nil then
    raise EOSError.Create('No Vulkan device with a compute queue');
  Priority := 1;
  FillChar(QueueInfo, SizeOf(QueueInfo), 0);
  QueueInfo.sType := 2;
  QueueInfo.queueFamilyIndex := FFamily;
  QueueInfo.queueCount := 1;
  QueueInfo.pQueuePriorities := @Priority;
  FillChar(DeviceInfo, SizeOf(DeviceInfo), 0);
  DeviceInfo.sType := 3;
  DeviceInfo.queueCreateInfoCount := 1;
  DeviceInfo.pQueueCreateInfos := @QueueInfo;
  Check(vkCreateDevice(FPhysical, DeviceInfo, nil, FDevice), 'vkCreateDevice');
  vkGetDeviceQueue(FDevice, FFamily, 0, FQueue);
end;

procedure TSketchGPU.CreatePipeline(const ASpirv: TBytes);
var
  Bindings: array[0..3] of VkDescriptorSetLayoutBinding;
  SetLayoutInfo: VkDescriptorSetLayoutCreateInfo;
  PushRange: VkPushConstantRange;
  LayoutInfo: VkPipelineLayoutCreateInfo;
  ModuleInfo: VkShaderModuleCreateInfo;
  PipelineInfo: VkComputePipelineCreateInfo;
  PoolInfo: VkCommandPoolCreateInfo;
  CommandInfo: VkCommandBufferAllocateInfo;
  FenceInfo: VkFenceCreateInfo;
  QueryInfo: VkQueryPoolCreateInfo;
  I: Integer;
begin
  if (Length(ASpirv) < 20) or (Length(ASpirv) mod 4 <> 0) then
    raise EArgumentException.Create('Invalid SPIR-V module');
  FillChar(Bindings, SizeOf(Bindings), 0);
  for I := 0 to 3 do
  begin
    Bindings[I].binding := BindingNumbers[I];
    Bindings[I].descriptorType := STORAGE_BUFFER;
    Bindings[I].descriptorCount := 1;
    Bindings[I].stageFlags := STAGE_COMPUTE;
  end;
  FillChar(SetLayoutInfo, SizeOf(SetLayoutInfo), 0);
  SetLayoutInfo.sType := 32;
  SetLayoutInfo.bindingCount := 4;
  SetLayoutInfo.pBindings := @Bindings[0];
  Check(vkCreateDescriptorSetLayout(FDevice, SetLayoutInfo, nil, FSetLayout), 'vkCreateDescriptorSetLayout');
  // The push range size comes from the generated bindings unit (std430 ABI).
  PushRange.stageFlags := STAGE_COMPUTE;
  PushRange.offset := 0;
  PushRange.size := PTS_Push_Params_Size;
  FillChar(LayoutInfo, SizeOf(LayoutInfo), 0);
  LayoutInfo.sType := 30;
  LayoutInfo.setLayoutCount := 1;
  LayoutInfo.pSetLayouts := @FSetLayout;
  LayoutInfo.pushConstantRangeCount := 1;
  LayoutInfo.pPushConstantRanges := @PushRange;
  Check(vkCreatePipelineLayout(FDevice, LayoutInfo, nil, FPipelineLayout), 'vkCreatePipelineLayout');
  FillChar(ModuleInfo, SizeOf(ModuleInfo), 0);
  ModuleInfo.sType := 16;
  ModuleInfo.codeSize := Length(ASpirv);
  ModuleInfo.pCode := @ASpirv[0];
  Check(vkCreateShaderModule(FDevice, ModuleInfo, nil, FShader), 'vkCreateShaderModule');
  FillChar(PipelineInfo, SizeOf(PipelineInfo), 0);
  PipelineInfo.sType := 29;
  PipelineInfo.stage.sType := 18;
  PipelineInfo.stage.stage := STAGE_COMPUTE;
  PipelineInfo.stage.module := FShader;
  PipelineInfo.stage.pName := 'Main';
  PipelineInfo.layout := FPipelineLayout;
  PipelineInfo.basePipelineIndex := -1;
  Check(vkCreateComputePipelines(FDevice, 0, 1, PipelineInfo, nil, FPipeline), 'vkCreateComputePipelines');
  FillChar(PoolInfo, SizeOf(PoolInfo), 0);
  PoolInfo.sType := 39;
  PoolInfo.flags := 2; // reset individual command buffers
  PoolInfo.queueFamilyIndex := FFamily;
  Check(vkCreateCommandPool(FDevice, PoolInfo, nil, FCommandPool), 'vkCreateCommandPool');
  FillChar(CommandInfo, SizeOf(CommandInfo), 0);
  CommandInfo.sType := 40;
  CommandInfo.commandPool := FCommandPool;
  CommandInfo.commandBufferCount := 1;
  Check(vkAllocateCommandBuffers(FDevice, CommandInfo, FCommand), 'vkAllocateCommandBuffers');
  FillChar(FenceInfo, SizeOf(FenceInfo), 0);
  FenceInfo.sType := 8;
  Check(vkCreateFence(FDevice, FenceInfo, nil, FFence), 'vkCreateFence');
  if FTimestampBits > 0 then
  begin
    FillChar(QueryInfo, SizeOf(QueryInfo), 0);
    QueryInfo.sType := 11;
    QueryInfo.queryType := 2; // timestamp
    QueryInfo.queryCount := TimestampCount;
    Check(vkCreateQueryPool(FDevice, QueryInfo, nil, FQueries), 'vkCreateQueryPool');
  end;
end;

function TSketchGPU.MemoryType(ABits, ARequired, APreferred: Cardinal): Cardinal;
var
  Memory: VkPhysicalDeviceMemoryProperties;
  I: Integer;
  Flags: Cardinal;
begin
  vkGetPhysicalDeviceMemoryProperties(FPhysical, Memory);
  for I := 0 to Integer(Memory.memoryTypeCount) - 1 do
  begin
    Flags := Memory.memoryTypes[I].propertyFlags;
    if (ABits and (1 shl I) <> 0) and (Flags and (ARequired or APreferred) = ARequired or APreferred) then
      Exit(I);
  end;
  for I := 0 to Integer(Memory.memoryTypeCount) - 1 do
    if (ABits and (1 shl I) <> 0) and (Memory.memoryTypes[I].propertyFlags and ARequired = ARequired) then
      Exit(I);
  raise EOSError.Create('No suitable Vulkan memory type');
end;

procedure TSketchGPU.CreateBuffer(AIndex: Integer; ASize: UInt64; AUsage, ARequired, APreferred: Cardinal);
var
  Info: VkBufferCreateInfo;
  Requirements: VkMemoryRequirements;
  Allocation: VkMemoryAllocateInfo;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.sType := 12;
  Info.size := ASize;
  Info.usage := AUsage;
  Check(vkCreateBuffer(FDevice, Info, nil, FBuffers[AIndex]), 'vkCreateBuffer');
  vkGetBufferMemoryRequirements(FDevice, FBuffers[AIndex], Requirements);
  FillChar(Allocation, SizeOf(Allocation), 0);
  Allocation.sType := 5;
  Allocation.allocationSize := Requirements.size;
  Allocation.memoryTypeIndex := MemoryType(Requirements.memoryTypeBits, ARequired, APreferred);
  Check(vkAllocateMemory(FDevice, Allocation, nil, FMemory[AIndex]), 'vkAllocateMemory');
  Check(vkBindBufferMemory(FDevice, FBuffers[AIndex], FMemory[AIndex], 0), 'vkBindBufferMemory');
end;

procedure TSketchGPU.ReleaseImageResources;
var
  I: Integer;
begin
  if FUploadMap <> nil then vkUnmapMemory(FDevice, FMemory[4]);
  if FDownloadMap <> nil then vkUnmapMemory(FDevice, FMemory[5]);
  FUploadMap := nil;
  FDownloadMap := nil;
  if FPool <> 0 then vkDestroyDescriptorPool(FDevice, FPool, nil);
  FPool := 0;
  FSet := 0;
  for I := 0 to High(FBuffers) do
  begin
    if FBuffers[I] <> 0 then vkDestroyBuffer(FDevice, FBuffers[I], nil);
    if FMemory[I] <> 0 then vkFreeMemory(FDevice, FMemory[I], nil);
    FBuffers[I] := 0;
    FMemory[I] := 0;
  end;
end;

procedure TSketchGPU.Prepare(AWidth, AHeight, ARadius: Integer);
begin
  if (AWidth < 1) or (AHeight < 1) or (ARadius < 1) or (ARadius > 32) then
    raise EArgumentException.Create('Invalid sketch dimensions/radius');
  FWidth := AWidth;
  FHeight := AHeight;
  FTargetWidth := AWidth;
  FTargetHeight := AHeight;
  FRadius := ARadius;
  FThumbnail := False;
  PrepareResources;
end;

procedure TSketchGPU.PrepareThumbnail(AWidth, AHeight, ATargetWidth, ATargetHeight: Integer);
begin
  ValidateThumbnailSizes(AWidth, AHeight, ATargetWidth, ATargetHeight);
  FWidth := AWidth;
  FHeight := AHeight;
  FTargetWidth := ATargetWidth;
  FTargetHeight := ATargetHeight;
  FRadius := 0;
  FThumbnail := True;
  PrepareResources;
end;

procedure TSketchGPU.PrepareResources;
var
  Size, TargetSize, ScratchSize: UInt64;
  Sizes: array[0..3] of UInt64;
  I: Integer;
  PoolSize: VkDescriptorPoolSize;
  PoolInfo: VkDescriptorPoolCreateInfo;
  SetInfo: VkDescriptorSetAllocateInfo;
  BufferInfos: array[0..3] of VkDescriptorBufferInfo;
  Writes: array[0..3] of VkWriteDescriptorSet;
begin
  Size := UInt64(FWidth) * UInt64(FHeight) * 4;
  TargetSize := UInt64(FTargetWidth) * UInt64(FTargetHeight) * 4;
  ScratchSize := UInt64(FTargetWidth) * UInt64(FHeight) * 4;
  if Size > FMaxStorageRange then
    raise EArgumentException.CreateFmt('Image needs %d bytes per buffer; the device allows %d', [Size, FMaxStorageRange]);
  vkDeviceWaitIdle(FDevice);
  ReleaseImageResources;
  Sizes[0] := Size;
  Sizes[1] := ScratchSize;
  if FThumbnail then Sizes[2] := 4 else Sizes[2] := Size;
  Sizes[3] := TargetSize;
  CreateBuffer(0, Size, USAGE_STORAGE or USAGE_TRANSFER_DST, 0, MEMORY_DEVICE_LOCAL);
  CreateBuffer(1, Sizes[1], USAGE_STORAGE, 0, MEMORY_DEVICE_LOCAL);
  CreateBuffer(2, Sizes[2], USAGE_STORAGE, 0, MEMORY_DEVICE_LOCAL);
  CreateBuffer(3, TargetSize, USAGE_STORAGE or USAGE_TRANSFER_SRC, 0, MEMORY_DEVICE_LOCAL);
  CreateBuffer(4, Size, USAGE_TRANSFER_SRC, MEMORY_HOST_VISIBLE or MEMORY_HOST_COHERENT, 0);
  CreateBuffer(5, TargetSize, USAGE_TRANSFER_DST, MEMORY_HOST_VISIBLE or MEMORY_HOST_COHERENT, MEMORY_HOST_CACHED);
  Check(vkMapMemory(FDevice, FMemory[4], 0, Size, 0, FUploadMap), 'vkMapMemory upload');
  Check(vkMapMemory(FDevice, FMemory[5], 0, TargetSize, 0, FDownloadMap), 'vkMapMemory download');
  PoolSize.type_ := STORAGE_BUFFER;
  PoolSize.descriptorCount := 4;
  FillChar(PoolInfo, SizeOf(PoolInfo), 0);
  PoolInfo.sType := 33;
  PoolInfo.maxSets := 1;
  PoolInfo.poolSizeCount := 1;
  PoolInfo.pPoolSizes := @PoolSize;
  Check(vkCreateDescriptorPool(FDevice, PoolInfo, nil, FPool), 'vkCreateDescriptorPool');
  FillChar(SetInfo, SizeOf(SetInfo), 0);
  SetInfo.sType := 34;
  SetInfo.descriptorPool := FPool;
  SetInfo.descriptorSetCount := 1;
  SetInfo.pSetLayouts := @FSetLayout;
  Check(vkAllocateDescriptorSets(FDevice, SetInfo, FSet), 'vkAllocateDescriptorSets');
  FillChar(Writes, SizeOf(Writes), 0);
  for I := 0 to 3 do
  begin
    BufferInfos[I].buffer := FBuffers[I];
    BufferInfos[I].offset := 0;
    BufferInfos[I].range := Sizes[I];
    Writes[I].sType := 35;
    Writes[I].dstSet := FSet;
    Writes[I].dstBinding := BindingNumbers[I];
    Writes[I].descriptorCount := 1;
    Writes[I].descriptorType := STORAGE_BUFFER;
    Writes[I].pBufferInfo := @BufferInfos[I];
  end;
  vkUpdateDescriptorSets(FDevice, 4, @Writes[0], 0, nil);
  Record_;
end;

procedure TSketchGPU.Record_;
var
  Begin_: VkCommandBufferBeginInfo;
  Barrier: VkMemoryBarrier;
  Region: VkBufferCopy;
  Params: TPTS_Push_Params;
  Pass, FirstPass, LastPass: Cardinal;
  GroupsX, GroupsY: Cardinal;
  procedure Stamp(AStage, AIndex: Cardinal);
  begin
    if FQueries <> 0 then vkCmdWriteTimestamp(FCommand, AStage, FQueries, AIndex);
  end;
  procedure Wait(ASourceStage, ATargetStage, ASourceAccess, ATargetAccess: Cardinal);
  begin
    Barrier.srcAccessMask := ASourceAccess;
    Barrier.dstAccessMask := ATargetAccess;
    vkCmdPipelineBarrier(FCommand, ASourceStage, ATargetStage, 0, 1, @Barrier, 0, nil, 0, nil);
  end;
begin
  Check(vkResetCommandBuffer(FCommand, 0), 'vkResetCommandBuffer');
  FillChar(Begin_, SizeOf(Begin_), 0);
  Begin_.sType := 42;
  Check(vkBeginCommandBuffer(FCommand, Begin_), 'vkBeginCommandBuffer');
  FillChar(Barrier, SizeOf(Barrier), 0);
  Barrier.sType := 46;
  Region.srcOffset := 0;
  Region.dstOffset := 0;
  Region.size := UInt64(FWidth) * UInt64(FHeight) * 4;
  if FQueries <> 0 then vkCmdResetQueryPool(FCommand, FQueries, 0, TimestampCount);
  Wait(PIPE_HOST, PIPE_TRANSFER, ACCESS_HOST_WRITE, ACCESS_TRANSFER_READ);
  Stamp(PIPE_TOP, 0);
  vkCmdCopyBuffer(FCommand, FBuffers[4], FBuffers[0], 1, Region);
  Stamp(PIPE_TRANSFER, 1);
  Wait(PIPE_TRANSFER, PIPE_COMPUTE, ACCESS_TRANSFER_WRITE, ACCESS_SHADER_READ);
  vkCmdBindPipeline(FCommand, BIND_COMPUTE, FPipeline);
  vkCmdBindDescriptorSets(FCommand, BIND_COMPUTE, FPipelineLayout, 0, 1, @FSet, 0, nil);
  GroupsX := (Cardinal(FTargetWidth) + GroupSize - 1) div GroupSize;
  GroupsY := (Cardinal(FHeight) + GroupSize - 1) div GroupSize;
  FillChar(Params, SizeOf(Params), 0);
  Params.F_Width := FWidth;
  Params.F_Height := FHeight;
  Params.F_Radius := FRadius;
  Params.F_TargetWidth := FTargetWidth;
  Params.F_TargetHeight := FTargetHeight;
  if FThumbnail then
  begin
    FirstPass := 3;
    LastPass := 4;
  end
  else
  begin
    FirstPass := 0;
    LastPass := 2;
  end;
  for Pass := FirstPass to LastPass do
  begin
    if Pass > FirstPass then
      Wait(PIPE_COMPUTE, PIPE_COMPUTE, ACCESS_SHADER_WRITE, ACCESS_SHADER_READ);
    if Pass = 4 then
      GroupsY := (Cardinal(FTargetHeight) + GroupSize - 1) div GroupSize;
    Params.F_Pass := Pass;
    vkCmdPushConstants(FCommand, FPipelineLayout, STAGE_COMPUTE, 0, SizeOf(Params), @Params);
    vkCmdDispatch(FCommand, GroupsX, GroupsY, 1);
  end;
  Stamp(PIPE_COMPUTE, 2);
  Wait(PIPE_COMPUTE, PIPE_TRANSFER, ACCESS_SHADER_WRITE, ACCESS_TRANSFER_READ);
  Stamp(PIPE_TRANSFER, 3);
  Region.size := UInt64(FTargetWidth) * UInt64(FTargetHeight) * 4;
  vkCmdCopyBuffer(FCommand, FBuffers[3], FBuffers[5], 1, Region);
  Stamp(PIPE_TRANSFER, 4);
  Wait(PIPE_TRANSFER, PIPE_HOST, ACCESS_TRANSFER_WRITE, ACCESS_HOST_READ);
  Stamp(PIPE_BOTTOM, 5);
  Check(vkEndCommandBuffer(FCommand), 'vkEndCommandBuffer');
end;

function TSketchGPU.Run(const ASource: TArray<Cardinal>; var ATarget: TArray<Cardinal>): TGPUTimings;
var
  Size: NativeInt;
  Submit: VkSubmitInfo;
  Stamps: array[0..TimestampCount - 1] of UInt64;
  Mask: UInt64;
  I: Integer;
  function Milliseconds(AFrom, ATo: Integer): Double;
  begin
    Result := ((Stamps[ATo] - Stamps[AFrom]) and Mask) * FTimestampPeriod / 1E6;
  end;
begin
  if (FUploadMap = nil) or (FDownloadMap = nil) or
    (Length(ASource) <> NativeInt(FWidth) * FHeight) or
    (Length(ATarget) <> NativeInt(FTargetWidth) * FTargetHeight) then
    raise EArgumentException.Create('GPU buffers are unprepared or pixel counts differ');
  Size := NativeInt(FWidth) * FHeight * 4;
  Move(ASource[0], FUploadMap^, Size);
  FillChar(Submit, SizeOf(Submit), 0);
  Submit.sType := 4;
  Submit.commandBufferCount := 1;
  Submit.pCommandBuffers := @FCommand;
  Check(vkResetFences(FDevice, 1, @FFence), 'vkResetFences');
  Check(vkQueueSubmit(FQueue, 1, Submit, FFence), 'vkQueueSubmit');
  Check(vkWaitForFences(FDevice, 1, @FFence, 1, 30 * UInt64(1000000000)), 'vkWaitForFences');
  Move(FDownloadMap^, ATarget[0], NativeInt(FTargetWidth) * FTargetHeight * 4);
  Result := Default(TGPUTimings);
  if FQueries <> 0 then
  begin
    Check(vkGetQueryPoolResults(FDevice, FQueries, 0, TimestampCount, SizeOf(Stamps), @Stamps[0],
      SizeOf(UInt64), 1 or 2), 'vkGetQueryPoolResults'); // 64-bit, wait
    if FTimestampBits >= 64 then Mask := High(UInt64) else Mask := (UInt64(1) shl FTimestampBits) - 1;
    for I := 0 to High(Stamps) do Stamps[I] := Stamps[I] and Mask;
    Result.Upload := Milliseconds(0, 1);
    Result.Kernels := Milliseconds(1, 2);
    Result.Download := Milliseconds(3, 4);
    Result.HasTimestamps := True;
  end;
end;

end.
