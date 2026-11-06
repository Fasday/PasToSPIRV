unit PTS.Reflection;

interface

uses
  PTS.IR,
  PTS.Source;

function BuildReflection(AModule: TShaderModule; const AVersion: string; ASources: TSourceProgram = nil; AOptimize: Boolean = False): string;

implementation

uses
  System.JSON,
  PTS.Types,
  PTS.Layout,
  PTS.Features;
// All resource categories are explicit; opaque images are not byte buffers.

procedure AddReference(AObject: TJSONObject; const AName, AIDName: string;
  AType: TShaderType; AComposite: TCompositeType);
begin
  AObject.AddPair(AName, TypeReferenceName(AType, AComposite));
  if AComposite <> nil then AObject.AddPair(AIDName, TJSONNumber.Create(AComposite.ID));
end;

function DescribeMembers(AComposite: TCompositeType): TJSONArray;
var
  Field: TTypeField;
  Member: TJSONObject;
begin
  Result := TJSONArray.Create;
  try
    for Field in AComposite.Fields do
    begin
      Member := TJSONObject.Create;
      Result.AddElement(Member);
      Member.AddPair('name', Field.Name);
      AddReference(Member, 'type', 'type_id', Field.DataType, Field.Composite);
      Member.AddPair('offset', TJSONNumber.Create(Int64(Field.Offset)));
      Member.AddPair('size', TJSONNumber.Create(Int64(TypeSize(Field.DataType, Field.Composite))));
      Member.AddPair('alignment', TJSONNumber.Create(Int64(TypeAlignment(Field.DataType, Field.Composite))));
    end;
  except
    Result.Free;
    raise;
  end;
end;

function BuildReflection(AModule: TShaderModule; const AVersion: string; ASources: TSourceProgram; AOptimize: Boolean): string;
var
  Root, Item: TJSONObject;
  LocalSize, Buffers, PushConstants, Types: TJSONArray;
  Variable: TShaderVariable;
  Composite: TCompositeType;
  I: Integer;
  AccessName: string;
  SourceFile: TSourceFile;
  Document: TSourceDocument;
  Edge: TSourceDependency;
  Sources, Modules, Dependencies: TJSONArray;
  Images, Textures, Samplers, Shared: TJSONArray;
  Required, RequiredExtensions: TJSONArray;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('format_version', TJSONNumber.Create(2));
    Root.AddPair('compiler', 'PasToSPIRV');
    Root.AddPair('compiler_version', AVersion);
    Root.AddPair('language_version','1.3');
    if AModule.Vulkan11 then
    begin
      Root.AddPair('profile', 'compute-vulkan1.1');
      Root.AddPair('target_env', 'vulkan1.1');
      Root.AddPair('spirv_version', '1.3');
    end
    else if AModule.Extended then
    begin
      Root.AddPair('profile','compute-vulkan1.2');
      Root.AddPair('target_env', 'vulkan1.2');
      Root.AddPair('spirv_version', '1.3');
    end
    else
    begin
      Root.AddPair('profile','compute-vulkan1.0');
      Root.AddPair('target_env', 'vulkan1.0');
      Root.AddPair('spirv_version', '1.0');
    end;
    Required := TJSONArray.Create; Root.AddPair('required_features', Required);
    if (stInt64 in AModule.UsedTypes) or (stUInt64 in AModule.UsedTypes) then Required.Add('shaderInt64');
    if stDouble in AModule.UsedTypes then Required.Add('shaderFloat64');
    if stByte in AModule.UsedTypes then
    begin
      Required.Add('shaderInt8');
    end;
    if stWord in AModule.UsedTypes then
    begin
      Required.Add('shaderInt16');
    end;
    if AModule.Storage8 then Required.Add('storageBuffer8BitAccess');
    if AModule.Storage16 then Required.Add('storageBuffer16BitAccess');
    if AModule.Push8 then Required.Add('storagePushConstant8');
    if AModule.Push16 then Required.Add('storagePushConstant16');
    if AModule.Vulkan11 then
    begin
      RequiredExtensions := TJSONArray.Create;
      Root.AddPair('required_device_extensions', RequiredExtensions);
      if stByte in AModule.UsedTypes then
        RequiredExtensions.Add('VK_KHR_shader_float16_int8');
      if AModule.Storage8 or AModule.Push8 then
        RequiredExtensions.Add('VK_KHR_8bit_storage');
      if AModule.StrictFloat then
        RequiredExtensions.Add('VK_KHR_shader_float_controls');
    end;
    Root.AddPair('strict_float', TJSONBool.Create(AModule.StrictFloat));
    if AModule.StrictFloat then
    begin
      Required.Add('shaderDenormPreserveFloat32'); Required.Add('shaderSignedZeroInfNanPreserveFloat32');
      Required.Add('shaderRoundingModeRTEFloat32');
      if stDouble in AModule.UsedTypes then
      begin
        Required.Add('shaderDenormPreserveFloat64'); Required.Add('shaderSignedZeroInfNanPreserveFloat64');
        Required.Add('shaderRoundingModeRTEFloat64');
      end;
    end;
    if AOptimize then Root.AddPair('optimization','O1-safe-integer') else Root.AddPair('optimization','O0');
    Root.AddPair('stage', 'compute');
    Root.AddPair('entry_point', AModule.EntryPointName);
    Root.AddPair('layout', 'std430');
    Root.AddPair('workgroup_memory_bytes', TJSONNumber.Create(AModule.SharedBytes));
    Root.AddPair('uses_workgroup_barrier', TJSONBool.Create(AModule.UsesWorkgroupBarrier));
    Images := TJSONArray.Create; Root.AddPair('images', Images);
    Textures := TJSONArray.Create; Root.AddPair('textures', Textures);
    Samplers := TJSONArray.Create; Root.AddPair('samplers', Samplers);
    Shared := TJSONArray.Create; Root.AddPair('shared', Shared);
    if ASources <> nil then
    begin
      Sources := TJSONArray.Create;
      Modules := TJSONArray.Create;
      Dependencies := TJSONArray.Create;
      Root.AddPair('sources', Sources);
      Root.AddPair('modules', Modules);
      Root.AddPair('source_dependencies', Dependencies);
      for SourceFile in ASources.Files do
      begin
        Item := TJSONObject.Create;
        Sources.AddElement(Item);
        Item.AddPair('id', TJSONNumber.Create(SourceFile.ID));
        Item.AddPair('path', SourceFile.DisplayPath);
        Item.AddPair('sha256', SourceFile.SHA256);
      end;
      for Document in ASources.Libraries do
      begin
        Item := TJSONObject.Create;
        Modules.AddElement(Item);
        Item.AddPair('name', Document.ModuleName);
        Item.AddPair('file_id', TJSONNumber.Create(Document.FileID));
      end;
      for Edge in ASources.Dependencies do
      begin
        Item := TJSONObject.Create;
        Dependencies.AddElement(Item);
        Item.AddPair('from', TJSONNumber.Create(Edge.FromID));
        Item.AddPair('to', TJSONNumber.Create(Edge.ToID));
        Item.AddPair('kind', Edge.Kind);
        Item.AddPair('line', TJSONNumber.Create(Edge.Position.Line));
        Item.AddPair('column', TJSONNumber.Create(Edge.Position.Column));
      end;
    end;
    LocalSize := TJSONArray.Create;
    Root.AddPair('local_size', LocalSize);
    for I := 0 to 2 do LocalSize.Add(AModule.LocalSize[I]);
    Types := TJSONArray.Create;
    Root.AddPair('types', Types);
    for Composite in AModule.Types do
      if Composite.ExternalLayout then
      begin
        Item := TJSONObject.Create;
        Types.AddElement(Item);
        Item.AddPair('id', TJSONNumber.Create(Composite.ID));
        Item.AddPair('name', Composite.Name);
        Item.AddPair('size', TJSONNumber.Create(Int64(Composite.Size)));
        Item.AddPair('alignment', TJSONNumber.Create(Int64(Composite.Alignment)));
        if Composite.Kind = ctRecord then
        begin
          Item.AddPair('kind', 'record');
          Item.AddPair('members', DescribeMembers(Composite));
        end
        else
        begin
          Item.AddPair('kind', 'array');
          Item.AddPair('length', TJSONNumber.Create(Int64(Composite.Length)));
          Item.AddPair('lower_bound', TJSONNumber.Create(0));
          Item.AddPair('array_stride', TJSONNumber.Create(Int64(Composite.Stride)));
          AddReference(Item, 'element_type', 'element_type_id', Composite.ElementType, Composite.ElementComposite);
          Item.AddPair('element_size', TJSONNumber.Create(Int64(TypeSize(Composite.ElementType, Composite.ElementComposite))));
          Item.AddPair('element_alignment', TJSONNumber.Create(Int64(TypeAlignment(Composite.ElementType, Composite.ElementComposite))));
        end;
      end;
    Buffers := TJSONArray.Create;
    Root.AddPair('buffers', Buffers);
    PushConstants := TJSONArray.Create;
    Root.AddPair('push_constants', PushConstants);
    for Variable in AModule.Resources do
    begin
      Item := TJSONObject.Create;
      Item.AddPair('name', Variable.Name);
      if Variable.Kind = vkShared then
      begin
        Shared.AddElement(Item);
        Item.AddPair('element_type', ShaderTypeName(Variable.Composite.ElementType));
        Item.AddPair('length', TJSONNumber.Create(Variable.Composite.Length));
        Item.AddPair('bytes', TJSONNumber.Create(Variable.Composite.Size));
        Continue;
      end;
      if Variable.Kind in [vkImage,vkTexture,vkSampler] then
      begin
        if Variable.Kind = vkImage then Images.AddElement(Item)
        else if Variable.Kind = vkTexture then Textures.AddElement(Item) else Samplers.AddElement(Item);
        Item.AddPair('set', TJSONNumber.Create(Variable.DescriptorSet));
        Item.AddPair('binding', TJSONNumber.Create(Variable.Binding));
        if Variable.Kind = vkImage then
        begin
          Item.AddPair('descriptor_type', 'storage_image');
          Item.AddPair('format', ImageFormatName(Variable.ImageFormat));
          Item.AddPair('vulkan_format', TJSONNumber.Create(ImageVulkanFormat(Variable.ImageFormat)));
          Item.AddPair('value_type', ShaderTypeName(ImagePixelType(Variable.ImageFormat)));
          case Variable.Access of baReadOnly: AccessName := 'read_only'; baWriteOnly: AccessName := 'write_only';
          else AccessName := 'read_write'; end;
          Item.AddPair('access', AccessName);
        end
        else if Variable.Kind = vkTexture then Item.AddPair('descriptor_type', 'sampled_image')
        else Item.AddPair('descriptor_type', 'sampler');
        Continue;
      end;
      if Variable.Kind = vkBuffer then
      begin
        Buffers.AddElement(Item);
        Item.AddPair('descriptor_type', 'storage_buffer');
        Item.AddPair('aliased', TJSONBool.Create(Variable.Aliased));
        Item.AddPair('set', TJSONNumber.Create(Int64(Variable.DescriptorSet)));
        Item.AddPair('binding', TJSONNumber.Create(Int64(Variable.Binding)));
        AddReference(Item, 'element_type', 'type_id', Variable.DataType, Variable.Composite);
        Item.AddPair('element_size', TJSONNumber.Create(Int64(TypeSize(Variable.DataType, Variable.Composite))));
        Item.AddPair('element_alignment', TJSONNumber.Create(Int64(TypeAlignment(Variable.DataType, Variable.Composite))));
        Item.AddPair('array_stride', TJSONNumber.Create(Int64(ArrayStride(Variable.DataType, Variable.Composite))));
        case Variable.Access of
          baReadOnly: AccessName := 'read_only';
          baWriteOnly: AccessName := 'write_only';
        else AccessName := 'read_write';
        end;
        Item.AddPair('access', AccessName);
      end
      else
      begin
        PushConstants.AddElement(Item);
        AddReference(Item, 'type', 'type_id', Variable.DataType, Variable.Composite);
        Item.AddPair('offset', TJSONNumber.Create(0));
        Item.AddPair('size', TJSONNumber.Create(Int64(Variable.Composite.Size)));
        Item.AddPair('alignment', TJSONNumber.Create(Int64(Variable.Composite.Alignment)));
        Item.AddPair('stage', 'compute');
        Item.AddPair('members', DescribeMembers(Variable.Composite));
      end;
    end;
    Result := Root.Format(2);
  finally
    Root.Free;
  end;
end;

end.
