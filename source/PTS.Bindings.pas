unit PTS.Bindings;

{$BOOLEVAL OFF}

interface

uses
  PTS.IR;

function GenerateBindings(AModule: TShaderModule; const AUnitName: string): string;
procedure ValidateUnitName(const AName: string);

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  PTS.Types,
  PTS.Layout;

type
  TBindingsWriter = class
  private
    FModule: TShaderModule;
    FText: TStringBuilder;
    FDone: TList<TCompositeType>;
    procedure Line(const AText: string = '');
    function HostType(AType: TShaderType; AComposite: TCompositeType): string;
    procedure DeclareType(AComposite: TCompositeType);
    procedure CheckSize(const AType: string; ASize: Cardinal);
  public
    constructor Create(AModule: TShaderModule);
    destructor Destroy; override;
    function Generate(const AUnitName: string): string;
  end;

procedure ValidateUnitName(const AName: string);
const
  Reserved = '|and|array|as|asm|begin|case|class|const|constructor|destructor|' +
    'default|dispinterface|div|do|downto|else|end|except|exports|file|finalization|' +
    'finally|for|function|goto|if|implementation|in|inherited|initialization|' +
    'inline|interface|is|label|library|mod|nil|not|object|of|on|operator|or|' +
    'out|packed|procedure|program|property|raise|record|repeat|resourcestring|' +
    'set|shl|shr|string|then|threadvar|to|try|type|unit|until|uses|var|while|with|xor|';
var
  I: Integer;
  DataType: TShaderType;
begin
  if (AName = '') or not CharInSet(AName[1], ['A'..'Z', 'a'..'z', '_']) then
    raise EArgumentException.Create('Bindings filename must be a simple Delphi unit identifier');
  for I := 2 to Length(AName) do
    if not CharInSet(AName[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      raise EArgumentException.Create('Bindings filename must be a simple Delphi unit identifier');
  if Pos('|' + LowerCase(AName) + '|', Reserved) <> 0 then
    raise EArgumentException.Create('Bindings unit name is a reserved Delphi word');
  // 1.1 scalar names (Byte, Double, ...) were valid unit names before; keep them valid.
  if SameText(AName, 'System') or (TryShaderType(AName, DataType) and not (DataType in [stByte..stDouble])) or
    SameText(Copy(AName, 1, 4), 'PTS_') or SameText(Copy(AName, 1, 5), 'TPTS_') or
    SameText(Copy(AName, 1, 6), 'PTPTS_') then
    raise EArgumentException.Create('Bindings unit name conflicts with a builtin or generated identifier');
end;

constructor TBindingsWriter.Create(AModule: TShaderModule);
begin
  inherited Create;
  FModule := AModule;
  FText := TStringBuilder.Create;
  FDone := TList<TCompositeType>.Create;
end;

destructor TBindingsWriter.Destroy;
begin
  FDone.Free;
  FText.Free;
  inherited;
end;

procedure TBindingsWriter.Line(const AText: string);
begin
  FText.Append(AText).AppendLine;
end;

function TBindingsWriter.HostType(AType: TShaderType; AComposite: TCompositeType): string;
begin
  if AType = stComposite then Result := 'TPTS_Type' + IntToStr(AComposite.ID)
  else if ComponentCount(AType) > 1 then Result := 'TPTS_' + ShaderTypeName(AType)
  // Qualified: a generated unit may itself be named Byte, Word, Double, etc.
  else Result := 'System.' + ShaderTypeName(AType);
end;

procedure TBindingsWriter.DeclareType(AComposite: TCompositeType);
var
  Field: TTypeField;
  Name, Element: string;
  Cursor, Padding: Cardinal;
  PadIndex: Integer;
begin
  if FDone.Contains(AComposite) then Exit;
  if AComposite.Kind = ctArray then
  begin
    if AComposite.ElementComposite <> nil then DeclareType(AComposite.ElementComposite);
    Element := HostType(AComposite.ElementType, AComposite.ElementComposite);
  end
  else
    for Field in AComposite.Fields do
      if Field.Composite <> nil then DeclareType(Field.Composite);
  Name := HostType(stComposite, AComposite);
  Line('  // ' + AComposite.Name + ': std430, size ' + IntToStr(AComposite.Size) +
    ', alignment ' + IntToStr(AComposite.Alignment));
  if AComposite.Kind = ctArray then
  begin
    Padding := AComposite.Stride - TypeSize(AComposite.ElementType, AComposite.ElementComposite);
    if Padding > 0 then
    begin
      Line('  ' + Name + 'Slot = packed record');
      Line('    Value: ' + Element + ';');
      Line('    PTS_Padding: array[0..' + IntToStr(Padding - 1) + '] of System.Byte;');
      Line('  end;');
      Element := Name + 'Slot';
    end;
    Line('  ' + Name + ' = array[0..' + IntToStr(AComposite.Length - 1) + '] of ' + Element + ';');
  end
  else
  begin
    Line('  ' + Name + ' = packed record');
    Cursor := 0;
    PadIndex := 0;
    for Field in AComposite.Fields do
    begin
      if Field.Offset > Cursor then
      begin
        Line('    PTS_Pad' + IntToStr(PadIndex) + ': array[0..' +
          IntToStr(Field.Offset - Cursor - 1) + '] of System.Byte;');
        Inc(PadIndex);
      end;
      Line('    F_' + Field.Name + ': ' + HostType(Field.DataType, Field.Composite) + ';');
      Cursor := Field.Offset + TypeSize(Field.DataType, Field.Composite);
    end;
    if AComposite.Size > Cursor then
      Line('    PTS_TailPadding: array[0..' + IntToStr(AComposite.Size - Cursor - 1) + '] of System.Byte;');
    Line('  end;');
    Line('  P' + Name + ' = ^' + Name + ';');
  end;
  Line;
  FDone.Add(AComposite);
end;

procedure TBindingsWriter.CheckSize(const AType: string; ASize: Cardinal);
begin
  Line('  if System.SizeOf(' + AType + ') <> ' + IntToStr(ASize) + ' then');
  Line('    raise System.SysUtils.EInvalidOpException.Create(''' + AType + ' size does not match std430'');');
end;

function TBindingsWriter.Generate(const AUnitName: string): string;
var
  DataType: TShaderType;
  Composite: TCompositeType;
  Field: TTypeField;
  Variable: TShaderVariable;
  Name, Element, Prefix: string;
  Width, I: Integer;
  Padding: Cardinal;
const
  Components: array[0..3] of string = ('X', 'Y', 'Z', 'W');
begin
  ValidateUnitName(AUnitName);
  Line('unit ' + AUnitName + ';');
  Line;
  Line('// Generated by PasToSPIRV. Do not edit. External ABI: std430.');
  Line('// Packed layouts fix offsets, NOT the alignment of a containing allocation.');
  Line('// Use the buffer Element aliases: a vector3 array element needs a padded slot.');
  Line('interface');
  Line;
  Line('type');
  for DataType := stInteger2 to stSingle4 do
  begin
    Line('  ' + HostType(DataType, nil) + ' = packed record');
    Width := ComponentCount(DataType);
    for I := 0 to Width - 1 do Line('    ' + Components[I] + ': System.' + ShaderTypeName(ComponentType(DataType)) + ';');
    Line('  end;');
  end;
  Line;
  for Composite in FModule.Types do
    if Composite.ExternalLayout then DeclareType(Composite);
  for Variable in FModule.Resources do
  begin
    if not (Variable.Kind in [vkBuffer,vkPushConstant]) then Continue;
    Element := HostType(Variable.DataType, Variable.Composite);
    if Variable.Kind = vkBuffer then
    begin
      Name := 'TPTS_Buffer_' + Variable.Name + '_Element';
      Padding := ArrayStride(Variable.DataType, Variable.Composite) - TypeSize(Variable.DataType, Variable.Composite);
      if Padding > 0 then
      begin
        Line('  ' + Name + ' = packed record');
        Line('    Value: ' + Element + ';');
        Line('    PTS_Padding: array[0..' + IntToStr(Padding - 1) + '] of System.Byte;');
        Line('  end;');
      end
      else Line('  ' + Name + ' = ' + Element + ';');
    end
    else Line('  TPTS_Push_' + Variable.Name + ' = ' + Element + ';');
  end;
  Line;
  Line('const');
  Line('  PTS_LayoutVersion = 2;');
  for Composite in FDone do
  begin
    Prefix := 'PTS_Type' + IntToStr(Composite.ID);
    Line('  ' + Prefix + '_Size = ' + IntToStr(Composite.Size) + ';');
    Line('  ' + Prefix + '_Alignment = ' + IntToStr(Composite.Alignment) + ';');
    if Composite.Kind = ctArray then
    begin
      Line('  ' + Prefix + '_Stride = ' + IntToStr(Composite.Stride) + ';');
      Line('  ' + Prefix + '_Length = ' + IntToStr(Composite.Length) + ';');
    end
    else
      for Field in Composite.Fields do
        Line('  ' + Prefix + '_F_' + Field.Name + '_Offset = ' + IntToStr(Field.Offset) + ';');
  end;
  for Variable in FModule.Resources do
  begin
    if Variable.Kind in [vkInput, vkOutput] then
      Continue;
    if Variable.Kind in [vkImage,vkTexture,vkSampler] then
    begin
      Prefix := 'PTS_Descriptor_' + Variable.Name;
      Line('  ' + Prefix + '_Set = ' + IntToStr(Variable.DescriptorSet) + ';');
      Line('  ' + Prefix + '_Binding = ' + IntToStr(Variable.Binding) + ';');
      Continue;
    end;
    if Variable.Kind = vkShared then
    begin
      Line('  PTS_Shared_' + Variable.Name + '_Bytes = ' + IntToStr(Variable.Composite.Size) + ';');
      Continue;
    end;
    if Variable.Kind = vkBuffer then
    begin
      Prefix := 'PTS_Buffer_' + Variable.Name;
      Line('  ' + Prefix + '_Set = ' + IntToStr(Variable.DescriptorSet) + ';');
      Line('  ' + Prefix + '_Binding = ' + IntToStr(Variable.Binding) + ';');
      Line('  ' + Prefix + '_Stride = ' + IntToStr(ArrayStride(Variable.DataType, Variable.Composite)) + ';');
      Line('  ' + Prefix + '_ElementSize = ' + IntToStr(TypeSize(Variable.DataType, Variable.Composite)) + ';');
    end
    else
    begin
      Prefix := 'PTS_Push_' + Variable.Name;
      Line('  ' + Prefix + '_Size = ' + IntToStr(TypeSize(Variable.DataType, Variable.Composite)) + ';');
    end;
    Line('  ' + Prefix + '_Alignment = ' + IntToStr(TypeAlignment(Variable.DataType, Variable.Composite)) + ';');
  end;
  Line;
  Line('procedure PTS_ValidateLayouts;');
  Line;
  Line('implementation');
  Line;
  Line('uses System.SysUtils;');
  Line;
  Line('procedure PTS_ValidateLayouts;');
  Line('begin');
  for DataType := stInteger2 to stSingle4 do CheckSize(HostType(DataType, nil), TypeSize(DataType, nil));
  for Composite in FDone do
  begin
    Name := HostType(stComposite, Composite);
    CheckSize(Name, Composite.Size);
    if Composite.Kind = ctRecord then
      for Field in Composite.Fields do
      begin
        // Taking an address calculates a field offset; no memory is dereferenced.
        Line('  if System.NativeUInt(@P' + Name + '(nil)^.F_' + Field.Name + ') <> ' + IntToStr(Field.Offset) + ' then');
        Line('    raise System.SysUtils.EInvalidOpException.Create(''' + Name + '.' + Field.Name + ' offset mismatch'');');
      end
    else if Composite.Stride > TypeSize(Composite.ElementType, Composite.ElementComposite) then
      CheckSize(Name + 'Slot', Composite.Stride);
  end;
  for Variable in FModule.Resources do
    if Variable.Kind = vkBuffer then
      CheckSize('TPTS_Buffer_' + Variable.Name + '_Element', ArrayStride(Variable.DataType, Variable.Composite))
    else if Variable.Kind = vkPushConstant then CheckSize('TPTS_Push_' + Variable.Name, TypeSize(Variable.DataType, Variable.Composite));
  Line('end;');
  Line;
  Line('end.');
  Result := FText.ToString;
end;

function GenerateBindings(AModule: TShaderModule; const AUnitName: string): string;
var
  Writer: TBindingsWriter;
begin
  Writer := TBindingsWriter.Create(AModule);
  try
    Result := Writer.Generate(AUnitName);
  finally
    Writer.Free;
  end;
end;

end.
