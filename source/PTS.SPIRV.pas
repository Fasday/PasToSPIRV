unit PTS.SPIRV;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  PTS.Types,
  PTS.Layout,
  PTS.Features,
  PTS.Diagnostics,
  PTS.IR,
  PTS.References;

type
  { Direct SPIR-V writer: 1.0 by default, optional Vulkan12 profile uses 1.3. }
  TSPIRVWriter = class
  private
    FModule: TShaderModule;
    FNextID: Cardinal;
    FCapabilities: TList<Cardinal>;
    FExtensions: TList<Cardinal>;
    FImports: TList<Cardinal>;
    FMemoryModel: TList<Cardinal>;
    FEntryPoints: TList<Cardinal>;
    FDebug: TList<Cardinal>;
    FAnnotations: TList<Cardinal>;
    FGlobals: TList<Cardinal>;
    FCode: TList<Cardinal>;
    FTypes: array[TShaderType] of Cardinal;
    FBoolVectors: array[2..4] of Cardinal;
    FGLSL450: Cardinal;
    FPointers: TDictionary<UInt64, Cardinal>;
    FConstants: TDictionary<string, Cardinal>;
    FCompositeIDs: TDictionary<TCompositeType, Cardinal>;
    FNulls: TDictionary<Cardinal, Cardinal>;
    FVariables: TDictionary<TShaderVariable, Cardinal>;
    FFunctionIDs: TDictionary<TShaderFunction, Cardinal>;
    FFunctionTypes: TDictionary<string, Cardinal>;
    FInvocationID: Cardinal;
    FVectorType: Cardinal;
    FMainID: Cardinal;
    FCurrentLabel: Cardinal;
    FInvocationIDs: array[TInvocationBuiltin] of Cardinal;
    FImageTypes: array[TImageFormat] of Cardinal;
    FTextureType, FSamplerType, FSampledType: Cardinal;
    FResourceTypes: TDictionary<TShaderVariable, Cardinal>;
    // Workgroup storage must not carry Offset/ArrayStride (VUID-StandaloneSpirv-None-10684).
    FSharedTwins: TDictionary<TCompositeType, Cardinal>;
    FImageQueryUsed: Boolean;
    FTerminated: Boolean;
    FCurrentFunction: TShaderFunction;
    FBreakTargets, FContinueTargets: TStack<Cardinal>;
    FReferences: TDictionary<TShaderVariable, TReferenceBinding>;
    FInstances: TObjectList<TFunctionInstance>;
    FInstanceKeys: TDictionary<string, TFunctionInstance>;
    FInstance: TFunctionInstance;
    function Reference(E: TExpression): TReferenceBinding;
    function ReferencePointer(const B: TReferenceBinding; T: TShaderType; C: TCompositeType): Cardinal;
    function EmitReferenceCall(E: TExpression): Cardinal;
    function HasReferences(F: TShaderFunction): Boolean;
    function EmitShortCircuit(E: TExpression): Cardinal;
    function EmitConditional(E: TExpression): Cardinal;
    function EmitInSet(E: TExpression): Cardinal;
    function SharedTypeID(AVariable: TShaderVariable): Cardinal;
    function RebuildArray(ASource: Cardinal; AComposite: TCompositeType; ATargetType: Cardinal): Cardinal;
    function LoadOpaque(AVariable: TShaderVariable): Cardinal;
    function EmitGPUExpression(AExpression: TExpression): Cardinal;
    function NewID: Cardinal;
    procedure Emit(ASection: TList<Cardinal>; AOpcode: Word;
      const AOperands: array of Cardinal);
    procedure EmitString(ASection: TList<Cardinal>; AOpcode: Word;
      const APrefix: array of Cardinal; const AText: string;
      const ASuffix: array of Cardinal);
    procedure Name(AID: Cardinal; const AName: string);
    procedure EmitLabel(AID: Cardinal);
    function FunctionType(AFunction: TShaderFunction): Cardinal;
    function ParameterType(AParameter: TShaderVariable): Cardinal;
    function ValueTypeID(AType: TShaderType; AComposite: TCompositeType): Cardinal;
    function StorageClass(AExpression: TExpression): Cardinal;
    function PointerType(ATypeID, AStorageClass: Cardinal): Cardinal;
    function Constant(AType: TShaderType; ABits: UInt64): Cardinal;
    function BufferStorage: Cardinal;
    function BoolType(AType: TShaderType): Cardinal;
    function GLSL450: Cardinal;
    procedure DeclareTypes;
    procedure DeclareResources;
    procedure DeclareConstants;
    procedure DeclareCaptured;
    function AggregateConstant(E: TExpression): Cardinal;
    function EmitPointer(AExpression: TExpression): Cardinal;
    function EmitExpression(AExpression: TExpression): Cardinal;
    function BinaryOpcode(AOperation: TOperator; AType: TShaderType): Word;
    function EmitIntrinsic(AExpression: TExpression): Cardinal;
    function EmitNumericIntrinsic(AExpression: TExpression): Cardinal;
    procedure EmitStatement(AStatement: TStatement);
    procedure EmitFor(AStatement: TStatement);
    procedure EmitCase(AStatement: TStatement);
    procedure EmitRepeat(AStatement: TStatement);
    procedure Branch(ALabel: Cardinal);
    procedure EmitFunction(AFunction: TShaderFunction; AInstance: TFunctionInstance = nil);
  public
    constructor Create(AModule: TShaderModule);
    destructor Destroy; override;
    function Generate: TBytes;
  end;

implementation

uses PTS.ConstEval;

const
  { Opcode and enumerant values from Khronos SPIR-V headers. }
  SpvMagic = $07230203;
  SpvVersion10 = $00010000;
  StorageInput = 1;
  StorageUniform = 2;
  StorageFunction = 7;
  StoragePushConstant = 9;

constructor TSPIRVWriter.Create(AModule: TShaderModule);
begin
  inherited Create;
  FModule := AModule;
  FNextID := 1;
  FCapabilities := TList<Cardinal>.Create;
  FExtensions := TList<Cardinal>.Create;
  FImports := TList<Cardinal>.Create;
  FMemoryModel := TList<Cardinal>.Create;
  FEntryPoints := TList<Cardinal>.Create;
  FDebug := TList<Cardinal>.Create;
  FAnnotations := TList<Cardinal>.Create;
  FGlobals := TList<Cardinal>.Create;
  FCode := TList<Cardinal>.Create;
  FPointers := TDictionary<UInt64, Cardinal>.Create;
  FConstants := TDictionary<string, Cardinal>.Create;
  FCompositeIDs := TDictionary<TCompositeType, Cardinal>.Create;
  FNulls := TDictionary<Cardinal, Cardinal>.Create;
  FVariables := TDictionary<TShaderVariable, Cardinal>.Create;
  FResourceTypes := TDictionary<TShaderVariable, Cardinal>.Create;
  FSharedTwins := TDictionary<TCompositeType, Cardinal>.Create;
  FFunctionIDs := TDictionary<TShaderFunction, Cardinal>.Create;
  FFunctionTypes := TDictionary<string, Cardinal>.Create;
  FBreakTargets := TStack<Cardinal>.Create;
  FContinueTargets := TStack<Cardinal>.Create;
  FReferences := TDictionary<TShaderVariable, TReferenceBinding>.Create;
  FInstances := TObjectList<TFunctionInstance>.Create(True);
  FInstanceKeys := TDictionary<string, TFunctionInstance>.Create;
end;

destructor TSPIRVWriter.Destroy;
begin
  FBreakTargets.Free;
  FReferences.Free;
  FInstances.Free;
  FInstanceKeys.Free;
  FContinueTargets.Free;
  FFunctionTypes.Free;
  FFunctionIDs.Free;
  FVariables.Free;
  FResourceTypes.Free;
  FSharedTwins.Free;
  FConstants.Free;
  FNulls.Free;
  FCompositeIDs.Free;
  FPointers.Free;
  FCode.Free;
  FGlobals.Free;
  FAnnotations.Free;
  FDebug.Free;
  FEntryPoints.Free;
  FMemoryModel.Free;
  FImports.Free;
  FCapabilities.Free;
  FExtensions.Free;
  inherited;
end;

function TSPIRVWriter.NewID: Cardinal;
begin
  Result := FNextID;
  Inc(FNextID);
end;

procedure TSPIRVWriter.Emit(ASection: TList<Cardinal>; AOpcode: Word;
  const AOperands: array of Cardinal);
var
  Operand: Cardinal;
begin
  if Length(AOperands) > 65534 then
    raise EShaderError.Create(FModule.EntryPoint.Position,
      'SPIR-V instruction exceeds the 65535-word budget');
  ASection.Add((Cardinal(Length(AOperands) + 1) shl 16) or AOpcode);
  for Operand in AOperands do
    ASection.Add(Operand);
end;

procedure TSPIRVWriter.EmitString(ASection: TList<Cardinal>; AOpcode: Word;
  const APrefix: array of Cardinal; const AText: string;
  const ASuffix: array of Cardinal);
var
  Bytes: TBytes;
  Words: TArray<Cardinal>;
  I: Integer;
  WordValue: Cardinal;
begin
  Bytes := TEncoding.UTF8.GetBytes(AText);
  SetLength(Words, (Length(Bytes) + 4) div 4);
  for I := 0 to High(Bytes) do
    Words[I div 4] := Words[I div 4] or (Cardinal(Bytes[I]) shl ((I mod 4) * 8));
  ASection.Add((Cardinal(1 + Length(APrefix) + Length(Words) +
    Length(ASuffix)) shl 16) or AOpcode);
  for WordValue in APrefix do ASection.Add(WordValue);
  for WordValue in Words do ASection.Add(WordValue);
  for WordValue in ASuffix do ASection.Add(WordValue);
end;

procedure TSPIRVWriter.Name(AID: Cardinal; const AName: string);
begin
  EmitString(FDebug, 5, [AID], AName, []); // OpName
end;

procedure TSPIRVWriter.EmitLabel(AID: Cardinal);
begin
  Emit(FCode, 248, [AID]);
  FCurrentLabel := AID;
  FTerminated := False;
end;

procedure TSPIRVWriter.Branch(ALabel: Cardinal);
begin
  if FTerminated then Exit;
  Emit(FCode, 249, [ALabel]); FTerminated := True;
end;

function TSPIRVWriter.ParameterType(AParameter: TShaderVariable): Cardinal;
var Shape: TReferenceShape;
begin
  Result := ValueTypeID(AParameter.DataType, AParameter.Composite);
  if AParameter.ParameterMode in [pmVar, pmOut] then
  begin
    Shape := FInstance.Shapes[FCurrentFunction.Parameters.IndexOf(AParameter)];
    Result := PointerType(ValueTypeID(Shape.RootType, Shape.RootComposite), Shape.RootStorage);
  end;
end;

function TSPIRVWriter.FunctionType(AFunction: TShaderFunction): Cardinal;
var
  Key: string;
  Operands: TArray<Cardinal>;
  I: Integer;
  Step: TReferenceStep;
begin
  Operands := [ValueTypeID(AFunction.ReturnType, AFunction.ReturnComposite)];
  for I := 0 to AFunction.Parameters.Count - 1 do
  begin
    Operands := Operands + [ParameterType(AFunction.Parameters[I])];
    if (FInstance <> nil) and (FInstance.Shapes[I] <> nil) then
      for Step in FInstance.Shapes[I].Steps do if Step.Dynamic then
        Operands := Operands + [FTypes[Step.DataType]];
    if Length(Operands) > MaxShaderParameters + 1 then
      raise EShaderError.Create(AFunction.Position, 'Specialized function exceeds the SPIR-V 255-parameter budget');
  end;
  Key := '';
  for I := 0 to High(Operands) do Key := Key + ',' + IntToStr(Operands[I]);
  if not FFunctionTypes.TryGetValue(Key, Result) then
  begin
    Result := NewID;
    Operands := [Result] + Operands;
    Emit(FGlobals, 33, Operands); // OpTypeFunction (deduplicated by signature)
    FFunctionTypes.Add(Key, Result);
  end;
end;

function TSPIRVWriter.ValueTypeID(AType: TShaderType; AComposite: TCompositeType): Cardinal;
var
  Operands: TArray<Cardinal>;
  ElementID, LengthID: Cardinal;
  I: Integer;
begin
  if AType <> stComposite then Exit(FTypes[AType]);
  if FCompositeIDs.TryGetValue(AComposite, Result) then Exit;
  Result := NewID;
  if AComposite.Kind = ctArray then
  begin
    ElementID := ValueTypeID(AComposite.ElementType, AComposite.ElementComposite);
    LengthID := Constant(stCardinal, AComposite.Length);
    Emit(FGlobals, 28, [Result, ElementID, LengthID]);
    if AComposite.ExternalLayout then
      Emit(FAnnotations, 71, [Result, 6, AComposite.Stride]);
  end
  else
  begin
    SetLength(Operands, AComposite.Fields.Count + 1);
    Operands[0] := Result;
    for I := 0 to AComposite.Fields.Count - 1 do
    begin
      Operands[I + 1] := ValueTypeID(AComposite.Fields[I].DataType, AComposite.Fields[I].Composite);
      if AComposite.ExternalLayout then
        Emit(FAnnotations, 72, [Result, Cardinal(I), 35, AComposite.Fields[I].Offset]);
      EmitString(FDebug, 6, [Result, Cardinal(I)], AComposite.Fields[I].Name, []);
    end;
    Emit(FGlobals, 30, Operands);
  end;
  Name(Result, AComposite.Name);
  FCompositeIDs.Add(AComposite, Result);
end;

function TSPIRVWriter.SharedTypeID(AVariable: TShaderVariable): Cardinal;
var
  Composite: TCompositeType;
begin
  Composite := AVariable.Composite;
  if not Composite.ExternalLayout then Exit(ValueTypeID(AVariable.DataType, Composite));
  if not FSharedTwins.TryGetValue(Composite, Result) then
  begin
    // Shared arrays are one-dimensional scalar arrays (enforced by the parser).
    Result := NewID;
    Emit(FGlobals, 28, [Result, ValueTypeID(Composite.ElementType, nil),
      Constant(stCardinal, Composite.Length)]);
    Name(Result, Composite.Name + '_workgroup');
    FSharedTwins.Add(Composite, Result);
  end;
end;

function TSPIRVWriter.RebuildArray(ASource: Cardinal; AComposite: TCompositeType; ATargetType: Cardinal): Cardinal;
var
  Operands: TArray<Cardinal>;
  ElementType: Cardinal;
  I: Integer;
begin
  // Converts between the decorated and undecorated forms of the same array.
  ElementType := ValueTypeID(AComposite.ElementType, nil);
  SetLength(Operands, AComposite.Length + 2);
  Operands[0] := ATargetType;
  for I := 0 to Integer(AComposite.Length) - 1 do
  begin
    Operands[I + 2] := NewID;
    Emit(FCode, 81, [ElementType, Operands[I + 2], ASource, Cardinal(I)]);
  end;
  Result := NewID;
  Operands[1] := Result;
  Emit(FCode, 80, Operands);
end;

function TSPIRVWriter.BufferStorage: Cardinal;
begin
  if FModule.Extended then Result := 12 else Result := StorageUniform;
end;

function TSPIRVWriter.StorageClass(AExpression: TExpression): Cardinal;
var
  Binding: TReferenceBinding;
begin
  // A var/out parameter points into its root: Function, or Private when the
  // argument is a variable captured by a nested routine.
  if (AExpression.Kind = ekLocal) and FReferences.TryGetValue(AExpression.Variable, Binding) then
    Exit(Binding.Shape.RootStorage);
  case AExpression.Kind of
    ekLocal: if AExpression.Variable.Kind = vkShared then Result := 4
      else if (AExpression.Variable.Kind = vkConstant) or AExpression.Variable.Captured then Result := 6
      else Result := StorageFunction;
    ekBufferElement: Result := BufferStorage;
    ekPushConstant: Result := StoragePushConstant;
    ekField, ekIndex, ekComponent: Result := StorageClass(AExpression.Left);
  else
    raise EInvalidOpException.Create('Internal error: expression has no storage class');
  end;
end;

function TSPIRVWriter.PointerType(ATypeID, AStorageClass: Cardinal): Cardinal;
var
  Key: UInt64;
begin
  Key := (UInt64(AStorageClass) shl 32) or ATypeID;
  if not FPointers.TryGetValue(Key, Result) then
  begin
    Result := NewID;
    Emit(FGlobals, 32, [Result, AStorageClass, ATypeID]); // OpTypePointer
    FPointers.Add(Key, Result);
  end;
end;

function TSPIRVWriter.Constant(AType: TShaderType; ABits: UInt64): Cardinal;
var
  Key: string;
  Operands: TArray<Cardinal>;
  ComponentID: Cardinal;
  I: Integer;
begin
  if AType in [stEnum, stSet] then AType := stCardinal;
  Key := IntToStr(Ord(AType)) + ':' + IntToHex(ABits, 16);
  if not FConstants.TryGetValue(Key, Result) then
  begin
    Result := NewID;
    if ComponentCount(AType) > 1 then
    begin
      ComponentID := Constant(ComponentType(AType), ABits);
      SetLength(Operands, ComponentCount(AType) + 2);
      Operands[0] := FTypes[AType];
      Operands[1] := Result;
      for I := 2 to High(Operands) do Operands[I] := ComponentID;
      Emit(FGlobals, 44, Operands); // OpConstantComposite
    end
    else if AType = stBoolean then
    begin
      if ABits = 0 then
        Emit(FGlobals, 42, [FTypes[AType], Result]) // OpConstantFalse
      else
        Emit(FGlobals, 41, [FTypes[AType], Result]); // OpConstantTrue
    end
    else if ScalarBitWidth(AType) = 64 then
      Emit(FGlobals, 43, [FTypes[AType], Result, Cardinal(ABits), Cardinal(ABits shr 32)])
    else
      Emit(FGlobals, 43, [FTypes[AType], Result, Cardinal(ABits)]);
    FConstants.Add(Key, Result);
  end;
end;

function TSPIRVWriter.BoolType(AType: TShaderType): Cardinal;
begin
  if ComponentCount(AType) = 1 then Result := FTypes[stBoolean]
  else Result := FBoolVectors[ComponentCount(AType)];
end;

function TSPIRVWriter.GLSL450: Cardinal;
begin
  if FGLSL450 = 0 then
  begin
    FGLSL450 := NewID;
    EmitString(FImports, 11, [FGLSL450], 'GLSL.std.450', []);
  end;
  Result := FGLSL450;
end;

procedure TSPIRVWriter.DeclareTypes;
var
  DataType: TShaderType;
  I: Integer;
begin
  for DataType := Low(TShaderType) to stSingle4 do
    FTypes[DataType] := NewID;
  Emit(FGlobals, 19, [FTypes[stVoid]]);
  Emit(FGlobals, 21, [FTypes[stInteger], 32, 1]);
  Emit(FGlobals, 21, [FTypes[stCardinal], 32, 0]);
  Emit(FGlobals, 22, [FTypes[stSingle], 32]);
  Emit(FGlobals, 20, [FTypes[stBoolean]]);
  // Width conversion from unsigned to signed needs an unsigned intermediate
  // followed by OpBitcast: OpUConvert requires an unsigned result type.
  if (stInt64 in FModule.UsedTypes) or (stUInt64 in FModule.UsedTypes) then
  begin
    Emit(FCapabilities, 17, [11]);
    FTypes[stInt64] := NewID; FTypes[stUInt64] := NewID;
    Emit(FGlobals, 21, [FTypes[stInt64], 64, 1]);
    Emit(FGlobals, 21, [FTypes[stUInt64], 64, 0]);
  end;
  for DataType := stByte to stDouble do
    if (DataType in FModule.UsedTypes) and not (DataType in [stInt64, stUInt64]) then
    begin
      FTypes[DataType] := NewID;
      if DataType = stDouble then
      begin
        Emit(FCapabilities, 17, [10]);
        Emit(FGlobals, 22, [FTypes[DataType], 64]);
      end
      else
      begin
        if DataType = stByte then Emit(FCapabilities, 17, [39])
        else Emit(FCapabilities, 17, [22]);
        Emit(FGlobals, 21, [FTypes[DataType], Cardinal(ScalarBitWidth(DataType)), Cardinal(Ord(IsSignedInteger(DataType)))]);
      end;
    end;
  for DataType := stInteger2 to stSingle4 do
    Emit(FGlobals, 23, [FTypes[DataType], FTypes[ComponentType(DataType)],
      Cardinal(ComponentCount(DataType))]);
  FVectorType := FTypes[stCardinal3];
  // Enumerations and sets are 32-bit unsigned words.
  FTypes[stEnum] := FTypes[stCardinal];
  FTypes[stSet] := FTypes[stCardinal];
  for I := 2 to 4 do
  begin
    FBoolVectors[I] := NewID;
    Emit(FGlobals, 23, [FBoolVectors[I], FTypes[stBoolean], Cardinal(I)]);
  end;
end;

procedure TSPIRVWriter.DeclareResources;
var
  Variable: TShaderVariable;
  ArrayType, StructType, PointerID, VariableID: Cardinal;
  UserType: Cardinal;
  B: TInvocationBuiltin;
begin
  for B := Low(TInvocationBuiltin) to High(TInvocationBuiltin) do
  begin
    PointerID := PointerType(FTypes[BuiltinType(B)], StorageInput);
    VariableID := NewID; FInvocationIDs[B] := VariableID;
    Emit(FGlobals, 59, [PointerID, VariableID, StorageInput]);
    Emit(FAnnotations, 71, [VariableID, 11, BuiltinDecoration(B)]);
    Name(VariableID, BuiltinName(B));
  end;
  FInvocationID := FInvocationIDs[biGlobalInvocationID];
  for Variable in FModule.Resources do
  begin
    if Variable.Kind = vkShared then
    begin
      PointerID := PointerType(SharedTypeID(Variable), 4);
      VariableID := NewID; FVariables.Add(Variable, VariableID);
      Emit(FGlobals, 59, [PointerID, VariableID, 4]); Name(VariableID, Variable.Name);
      Continue;
    end;
    if Variable.Kind in [vkImage,vkTexture,vkSampler] then
    begin
      if Variable.Kind = vkImage then
      begin
        UserType := FImageTypes[Variable.ImageFormat];
        if UserType = 0 then
        begin
          UserType := NewID; FImageTypes[Variable.ImageFormat] := UserType;
          Emit(FGlobals, 25, [UserType, FTypes[ComponentType(ImagePixelType(Variable.ImageFormat))], 1, 0, 0, 0, 2, ImageSPIRVFormat(Variable.ImageFormat)]);
        end;
      end
      else if Variable.Kind = vkTexture then
      begin
        if FTextureType = 0 then
        begin
          FTextureType := NewID;
          Emit(FGlobals, 25, [FTextureType, FTypes[stSingle], 1, 0, 0, 0, 1, 0]);
          FSampledType := NewID; Emit(FGlobals, 27, [FSampledType, FTextureType]);
        end;
        UserType := FTextureType;
      end
      else
      begin
        if FSamplerType = 0 then begin FSamplerType := NewID; Emit(FGlobals, 26, [FSamplerType]); end;
        UserType := FSamplerType;
      end;
      PointerID := PointerType(UserType, 0);
      VariableID := NewID; FVariables.Add(Variable, VariableID); FResourceTypes.Add(Variable, UserType);
      Emit(FGlobals, 59, [PointerID, VariableID, 0]);
      Emit(FAnnotations, 71, [VariableID, 34, Variable.DescriptorSet]);
      Emit(FAnnotations, 71, [VariableID, 33, Variable.Binding]);
      if Variable.Kind = vkImage then
      begin
        if Variable.Access = baReadOnly then Emit(FAnnotations, 71, [VariableID, 24]);
        if Variable.Access = baWriteOnly then Emit(FAnnotations, 71, [VariableID, 25]);
      end;
      Name(VariableID, Variable.Name); Continue;
    end;
    StructType := NewID;
    if Variable.Kind = vkBuffer then
    begin
      ArrayType := NewID;
      UserType := ValueTypeID(Variable.DataType, Variable.Composite);
      Emit(FGlobals, 29, [ArrayType, UserType]);
      Emit(FAnnotations, 71, [ArrayType, 6, ArrayStride(Variable.DataType, Variable.Composite)]);
      Emit(FGlobals, 30, [StructType, ArrayType]);
      if FModule.Extended then Emit(FAnnotations, 71, [StructType, 2])
      else Emit(FAnnotations, 71, [StructType, 3]);
      Emit(FAnnotations, 72, [StructType, 0, 35, 0]); // member Offset 0
      if Variable.Access = baReadOnly then
        Emit(FAnnotations, 72, [StructType, 0, 24]) // NonWritable
      else if Variable.Access = baWriteOnly then
        Emit(FAnnotations, 72, [StructType, 0, 25]); // NonReadable
      PointerID := PointerType(StructType, BufferStorage);
    end
    else
    begin
      UserType := ValueTypeID(Variable.DataType, Variable.Composite);
      Emit(FGlobals, 30, [StructType, UserType]);
      Emit(FAnnotations, 72, [StructType, 0, 35, 0]);
      Emit(FAnnotations, 71, [StructType, 2]); // Block
      PointerID := PointerType(StructType, StoragePushConstant);
    end;
    Name(StructType, Variable.Name + '_Block');
    VariableID := NewID;
    FVariables.Add(Variable, VariableID);
    Name(VariableID, Variable.Name);
    if Variable.Kind = vkBuffer then
    begin
      Emit(FGlobals, 59, [PointerID, VariableID, BufferStorage]);
      Emit(FAnnotations, 71, [VariableID, 34, Variable.DescriptorSet]);
      Emit(FAnnotations, 71, [VariableID, 33, Variable.Binding]);
      if Variable.Aliased then Emit(FAnnotations, 71, [VariableID, 20]);
    end
    else
      Emit(FGlobals, 59, [PointerID, VariableID, StoragePushConstant]);
  end;
end;

function TSPIRVWriter.AggregateConstant(E: TExpression): Cardinal;
var Operands: TArray<Cardinal>; I: Integer;
begin
  if E.Kind = ekConstant then Exit(Constant(E.DataType, E.Bits));
  Result := NewID;
  Operands := [ValueTypeID(E.DataType, E.Composite), Result];
  for I := 0 to E.Arguments.Count - 1 do Operands := Operands + [AggregateConstant(E.Arguments[I])];
  Emit(FGlobals, 44, Operands);
end;

// Locals and value parameters used by nested routines: one Private variable
// each (functions are not recursive, so at most one activation exists).
procedure TSPIRVWriter.DeclareCaptured;
var
  F: TShaderFunction;
  V: TShaderVariable;
  ID: Cardinal;
begin
  for F in FModule.Functions do
    for V in F.Parameters.ToArray + F.Locals.ToArray do
      if V.Captured then
      begin
        ID := NewID;
        Emit(FGlobals, 59, [PointerType(ValueTypeID(V.DataType, V.Composite), 6), ID, 6]);
        Name(ID, F.Name + '.' + V.Name);
        FVariables.Add(V, ID);
      end;
end;

procedure TSPIRVWriter.DeclareConstants;
var V: TShaderVariable; ID, Value, PointerID: Cardinal;
begin
  for V in FModule.ConstantOrder do
  begin
    Value := AggregateConstant(FModule.Constants[V]);
    PointerID := PointerType(ValueTypeID(V.DataType, V.Composite), 6);
    ID := NewID; FVariables.Add(V, ID);
    Emit(FGlobals, 59, [PointerID, ID, 6, Value]); Name(ID, V.Name);
  end;
end;

function TSPIRVWriter.EmitPointer(AExpression: TExpression): Cardinal;
var
  IndexID, PointerID, ZeroID: Cardinal;
begin
  case AExpression.Kind of
    ekComponent, ekField, ekIndex:
      begin
        PointerID := PointerType(ValueTypeID(AExpression.DataType, AExpression.Composite), StorageClass(AExpression));
        // Source order: outer base (and its index side effects) before this index.
        ZeroID := EmitPointer(AExpression.Left);
        if AExpression.Kind = ekIndex then IndexID := EmitExpression(AExpression.Right)
        else IndexID := Constant(stCardinal, AExpression.MemberIndex);
        Result := NewID;
        Emit(FCode, 65, [PointerID, Result, ZeroID, IndexID]);
      end;
    ekLocal:
      Result := FVariables[AExpression.Variable];
    ekBufferElement:
      begin
        IndexID := EmitExpression(AExpression.Left);
        PointerID := PointerType(ValueTypeID(AExpression.DataType, AExpression.Composite), BufferStorage);
        ZeroID := Constant(stCardinal, 0);
        Result := NewID;
        Emit(FCode, 65, [PointerID, Result,
          FVariables[AExpression.Variable], ZeroID, IndexID]);
      end;
    ekPushConstant:
      begin
        PointerID := PointerType(ValueTypeID(AExpression.DataType, AExpression.Composite), StoragePushConstant);
        IndexID := Constant(stCardinal, 0);
        Result := NewID;
        Emit(FCode, 65, [PointerID, Result,
          FVariables[AExpression.Variable], IndexID]);
      end;
  else
    raise EInvalidOpException.Create('Internal error: expression has no address');
  end;
end;

function TSPIRVWriter.BinaryOpcode(AOperation: TOperator; AType: TShaderType): Word;
begin
  AType := ComponentType(AType);
  case AOperation of
    opAdd: if IsFloatType(AType) then Exit(129) else Exit(128);
    opSubtract: if IsFloatType(AType) then Exit(131) else Exit(130);
    opMultiply: if IsFloatType(AType) then Exit(133) else Exit(132);
    opDivide: Exit(136);
    opIntDivide: if IsSignedInteger(AType) then Exit(135) else Exit(134);
    opModulo: if IsSignedInteger(AType) then Exit(138) else Exit(137);
    opAnd: if AType = stBoolean then Exit(167) else Exit(199);
    opOr: if AType = stBoolean then Exit(166) else Exit(197);
    opXor: if AType = stBoolean then Exit(165) else Exit(198);
    opShiftLeft: Exit(196);
    opShiftRight: Exit(194); // Pascal shr is logical, including signed operands.
    opEqual:
      case AType of
        stSingle, stDouble: Exit(180);
        stBoolean: Exit(164);
      else Exit(170);
      end;
    opNotEqual:
      case AType of
        stSingle, stDouble: Exit(183);
        stBoolean: Exit(165);
      else Exit(171);
      end;
    opLess:
      case AType of
        stSingle, stDouble: Exit(184);
        stInteger, stInt64: Exit(177);
      else Exit(176);
      end;
    opLessEqual:
      case AType of
        stSingle, stDouble: Exit(188);
        stInteger, stInt64: Exit(179);
      else Exit(178);
      end;
    opGreater:
      case AType of
        stSingle, stDouble: Exit(186);
        stInteger, stInt64: Exit(173);
      else Exit(172);
      end;
    opGreaterEqual:
      case AType of
        stSingle, stDouble: Exit(190);
        stInteger, stInt64: Exit(175);
      else Exit(174);
      end;
  end;
  raise EInvalidOpException.Create('Internal error: unsupported binary operation');
end;

function TSPIRVWriter.EmitExpression(AExpression: TExpression): Cardinal;
var
  LeftID, RightID, PointerID, MaskID, ComparisonID, TypeID: Cardinal;
  Opcode: Word;
  SourceType: TShaderType;
  UnsignedType: TShaderType;
  Operands: TArray<Cardinal>;
  I: Integer;
begin
  case AExpression.Kind of
    ekConstant:
      Exit(Constant(AExpression.DataType, AExpression.Bits));
    ekLocal, ekBufferElement, ekPushConstant:
      begin
        PointerID := EmitPointer(AExpression);
        Result := NewID;
        if (AExpression.Kind = ekLocal) and (AExpression.Variable.Kind = vkShared) and
          (SharedTypeID(AExpression.Variable) <> ValueTypeID(AExpression.DataType, AExpression.Composite)) then
        begin
          Emit(FCode, 61, [SharedTypeID(AExpression.Variable), Result, PointerID]);
          Result := RebuildArray(Result, AExpression.Composite,
            ValueTypeID(AExpression.DataType, AExpression.Composite));
        end
        else
          Emit(FCode, 61, [ValueTypeID(AExpression.DataType, AExpression.Composite), Result, PointerID]);
      end;
    ekField, ekIndex:
      begin
        TypeID := ValueTypeID(AExpression.DataType, AExpression.Composite);
        if ExpressionIsAddressable(AExpression) then
        begin
          PointerID := EmitPointer(AExpression);
          Result := NewID;
          Emit(FCode, 61, [TypeID, Result, PointerID]);
        end
        else
        begin
          LeftID := EmitExpression(AExpression.Left);
          Result := NewID;
          Emit(FCode, 81, [TypeID, Result, LeftID, AExpression.MemberIndex]);
        end;
      end;
    ekDefault:
      begin
        TypeID := ValueTypeID(AExpression.DataType, AExpression.Composite);
        if not FNulls.TryGetValue(TypeID, Result) then
        begin
          Result := NewID;
          Emit(FGlobals, 46, [TypeID, Result]);
          FNulls.Add(TypeID, Result);
        end;
      end;
    ekInvocationID:
      begin
        Result := NewID;
        Emit(FCode, 61, [FTypes[AExpression.DataType], Result, FInvocationIDs[AExpression.Builtin]]);
      end;
    ekComponent:
      begin
        LeftID := EmitExpression(AExpression.Left);
        Result := NewID;
        Emit(FCode, 81, [FTypes[AExpression.DataType], Result, LeftID, AExpression.MemberIndex]);
      end;
    ekSwizzle:
      begin
        LeftID := EmitExpression(AExpression.Left);
        Result := NewID;
        Operands := [FTypes[AExpression.DataType], Result, LeftID, LeftID];
        for I := 0 to Integer(AExpression.MemberIndex) - 1 do
          Operands := Operands + [Cardinal(AExpression.Bits shr (2 * I)) and 3];
        Emit(FCode, 79, Operands); // OpVectorShuffle
      end;
    ekConditional:
      Result := EmitConditional(AExpression);
    ekInSet:
      Result := EmitInSet(AExpression);
    ekConstruct:
      begin
        SetLength(Operands, ComponentCount(AExpression.DataType) + 2);
        Operands[0] := ValueTypeID(AExpression.DataType, AExpression.Composite);
        Result := NewID;
        Operands[1] := Result;
        if AExpression.Arguments.Count = 1 then
        begin
          LeftID := EmitExpression(AExpression.Arguments[0]);
          for I := 2 to High(Operands) do Operands[I] := LeftID;
        end
        else
          for I := 0 to AExpression.Arguments.Count - 1 do
            Operands[I + 2] := EmitExpression(AExpression.Arguments[I]);
        Emit(FCode, 80, Operands);
      end;
    ekUnary:
      begin
        LeftID := EmitExpression(AExpression.Left);
        Result := NewID;
        if (AExpression.Operation = opNegate) and not IsFloatType(AExpression.DataType) then
        begin
          // 0 - X, not OpSNegate: a tested driver optimized SNegate as no-signed-wrap,
          // breaking defined wraparound (-Low(Integer) div N, -Low(Integer) < 0).
          Emit(FCode, 130, [FTypes[AExpression.DataType], Result,
            Constant(AExpression.DataType, 0), LeftID]);
          Exit;
        end;
        if AExpression.Operation = opNegate then Opcode := 127
        else if AExpression.DataType = stBoolean then Opcode := 168 else Opcode := 200;
        Emit(FCode, Opcode, [FTypes[AExpression.DataType], Result, LeftID]);
      end;
    ekBinary:
      begin
        if AExpression.ShortCircuit then Exit(EmitShortCircuit(AExpression));
        LeftID := EmitExpression(AExpression.Left);
        RightID := EmitExpression(AExpression.Right);
        if AExpression.Operation in [opShiftLeft, opShiftRight] then
        begin
          MaskID := NewID;
          Emit(FCode, 199, [FTypes[AExpression.Right.DataType], MaskID,
            RightID, Constant(AExpression.Right.DataType, ScalarBitWidth(AExpression.Left.DataType) - 1)]);
          RightID := MaskID;
        end;
        Opcode := BinaryOpcode(AExpression.Operation, AExpression.Left.DataType);
        if (AExpression.DataType = stBoolean) and (ComponentCount(AExpression.Left.DataType) > 1) then
        begin
          ComparisonID := NewID;
          Emit(FCode, Opcode, [BoolType(AExpression.Left.DataType), ComparisonID, LeftID, RightID]);
          Result := NewID;
          if AExpression.Operation = opEqual then Opcode := 155 else Opcode := 154;
          Emit(FCode, Opcode, [FTypes[stBoolean], Result, ComparisonID]); // All / Any
        end
        else
        begin
          Result := NewID;
          Emit(FCode, Opcode, [FTypes[AExpression.DataType], Result, LeftID, RightID]);
        end;
        if IsFloatType(AExpression.DataType) and
          (AExpression.Operation in [opAdd, opSubtract, opMultiply, opDivide]) then
          Emit(FAnnotations, 71, [Result, 42]); // NoContraction
      end;
    ekConvert:
      begin
        LeftID := EmitExpression(AExpression.Left);
        // Enum/set <-> Cardinal (and set retyping) share one SPIR-V type.
        if FTypes[AExpression.Left.DataType] = FTypes[AExpression.DataType] then Exit(LeftID);
        SourceType := ComponentType(AExpression.Left.DataType);
        if IsFloatType(AExpression.DataType) then
        begin
          if IsFloatType(SourceType) then Opcode := 115
          else if IsSignedInteger(SourceType) then Opcode := 111 else Opcode := 112;
        end
        else if IsFloatType(SourceType) then
        begin
          if IsSignedInteger(AExpression.DataType) then Opcode := 110 else Opcode := 109;
        end
        else if ScalarBitWidth(SourceType) <> ScalarBitWidth(AExpression.DataType) then
        begin
          if not IsSignedInteger(SourceType) and IsSignedInteger(AExpression.DataType) then
          begin
            if ScalarBitWidth(AExpression.DataType) = 64 then UnsignedType := stUInt64 else UnsignedType := stCardinal;
            RightID := NewID;
            Emit(FCode, 113, [FTypes[UnsignedType], RightID, LeftID]);
            Result := NewID;
            Emit(FCode, 124, [FTypes[AExpression.DataType], Result, RightID]);
            Exit;
          end;
          if IsSignedInteger(SourceType) then Opcode := 114 else Opcode := 113;
        end
        else Opcode := 124;
        Result := NewID;
        Emit(FCode, Opcode, [FTypes[AExpression.DataType], Result, LeftID]);
      end;
    ekCall:
      begin
        if HasReferences(AExpression.Callee) then Exit(EmitReferenceCall(AExpression));
        SetLength(Operands, AExpression.Arguments.Count + 3);
        Operands[0] := ValueTypeID(AExpression.DataType, AExpression.Composite);
        Result := NewID;
        Operands[1] := Result;
        Operands[2] := FFunctionIDs[AExpression.Callee];
        for I := 0 to AExpression.Arguments.Count - 1 do
          if AExpression.Callee.Parameters[I].ParameterMode in [pmVar, pmOut] then
            Operands[I + 3] := EmitPointer(AExpression.Arguments[I])
          else Operands[I + 3] := EmitExpression(AExpression.Arguments[I]);
        Emit(FCode, 57, Operands); // OpFunctionCall
      end;
    ekIntrinsic:
      Result := EmitIntrinsic(AExpression);
    ekArrayLength:
      begin
        Result := NewID;
        Emit(FCode, 68, [FTypes[stCardinal], Result, FVariables[AExpression.Variable], 0]); // OpArrayLength
      end;
    ekAtomic, ekImageLoad, ekImageStore, ekImageSize, ekSampleLevel:
      Result := EmitGPUExpression(AExpression);
  else
    raise EInvalidOpException.Create('Internal error: unsupported expression');
  end;
end;

// A and B: B only if A; A or B: B only if not A. Structured selection + OpPhi.
function TSPIRVWriter.EmitShortCircuit(E: TExpression): Cardinal;
var
  LeftID, RightID, LeftLabel, RightLabel, RightEnd, MergeLabel: Cardinal;
begin
  LeftID := EmitExpression(E.Left);
  LeftLabel := FCurrentLabel;
  RightLabel := NewID;
  MergeLabel := NewID;
  Emit(FCode, 247, [MergeLabel, 0]); // OpSelectionMerge
  if E.Operation = opAnd then
    Emit(FCode, 250, [LeftID, RightLabel, MergeLabel])
  else
    Emit(FCode, 250, [LeftID, MergeLabel, RightLabel]);
  EmitLabel(RightLabel);
  RightID := EmitExpression(E.Right);
  RightEnd := FCurrentLabel; // the right operand may itself contain branches
  Emit(FCode, 249, [MergeLabel]);
  EmitLabel(MergeLabel);
  Result := NewID;
  // From the left block the result equals the left operand (False for and, True for or).
  Emit(FCode, 245, [FTypes[stBoolean], Result, LeftID, LeftLabel, RightID, RightEnd]);
end;

// if C then A else B. Pure scalar/vector branches: OpSelect (SPIR-V 1.0 needs a
// condition with the result's component count). Otherwise only the selected
// branch runs: structured selection + OpPhi (also for aggregates).
function TSPIRVWriter.EmitConditional(E: TExpression): Cardinal;
var
  ConditionID, ThenID, ElseID, ThenLabel, ElseLabel, ThenEnd, ElseEnd, MergeLabel, Splat: Cardinal;
  TypeID: Cardinal;
  Operands: TArray<Cardinal>;
  I: Integer;
begin
  TypeID := ValueTypeID(E.DataType, E.Composite);
  ConditionID := EmitExpression(E.Arguments[0]);
  if not E.ShortCircuit then
  begin
    ThenID := EmitExpression(E.Left);
    ElseID := EmitExpression(E.Right);
    if ComponentCount(E.DataType) > 1 then
    begin
      Splat := NewID;
      Operands := [BoolType(E.DataType), Splat];
      for I := 1 to ComponentCount(E.DataType) do Operands := Operands + [ConditionID];
      Emit(FCode, 80, Operands);
      ConditionID := Splat;
    end;
    Result := NewID;
    Emit(FCode, 169, [TypeID, Result, ConditionID, ThenID, ElseID]); // OpSelect
    Exit;
  end;
  ThenLabel := NewID;
  ElseLabel := NewID;
  MergeLabel := NewID;
  Emit(FCode, 247, [MergeLabel, 0]);
  Emit(FCode, 250, [ConditionID, ThenLabel, ElseLabel]);
  EmitLabel(ThenLabel);
  ThenID := EmitExpression(E.Left);
  ThenEnd := FCurrentLabel;
  Emit(FCode, 249, [MergeLabel]);
  EmitLabel(ElseLabel);
  ElseID := EmitExpression(E.Right);
  ElseEnd := FCurrentLabel;
  Emit(FCode, 249, [MergeLabel]);
  EmitLabel(MergeLabel);
  Result := NewID;
  Emit(FCode, 245, [TypeID, Result, ThenID, ThenEnd, ElseID, ElseEnd]);
end;

// X in [A, B..C]: X once, then every item left to right (as a Delphi set
// constructor), compared by value; no 32-element limit.
function TSPIRVWriter.EmitInSet(E: TExpression): Cardinal;
var
  ValueID, LowID, HighID, TestID, LowTest, HighTest, Combined: Cardinal;
  Item: TExpression;
  T: TShaderType;
begin
  ValueID := EmitExpression(E.Left);
  T := E.Left.DataType;
  Result := Constant(stBoolean, 0);
  for Item in E.Arguments do
  begin
    if Item.Kind = ekRange then
    begin
      LowID := EmitExpression(Item.Left);
      HighID := EmitExpression(Item.Right);
      LowTest := NewID;
      Emit(FCode, BinaryOpcode(opLessEqual, T), [FTypes[stBoolean], LowTest, LowID, ValueID]);
      HighTest := NewID;
      Emit(FCode, BinaryOpcode(opLessEqual, T), [FTypes[stBoolean], HighTest, ValueID, HighID]);
      TestID := NewID;
      Emit(FCode, 167, [FTypes[stBoolean], TestID, LowTest, HighTest]); // OpLogicalAnd
    end
    else
    begin
      LowID := EmitExpression(Item);
      TestID := NewID;
      Emit(FCode, BinaryOpcode(opEqual, T), [FTypes[stBoolean], TestID, ValueID, LowID]);
    end;
    Combined := NewID;
    Emit(FCode, 166, [FTypes[stBoolean], Combined, Result, TestID]); // OpLogicalOr
    Result := Combined;
  end;
end;

function TSPIRVWriter.HasReferences(F: TShaderFunction): Boolean;
var P: TShaderVariable;
begin
  for P in F.Parameters do if P.ParameterMode in [pmVar, pmOut] then Exit(True);
  Result := False;
end;

function TSPIRVWriter.Reference(E: TExpression): TReferenceBinding;
var Step: TReferenceStep; Existing: TReferenceBinding;
begin
  if E.Kind = ekLocal then
  begin
    Result := Default(TReferenceBinding);
    if FReferences.TryGetValue(E.Variable, Existing) then
    begin
      Result.RootID := Existing.RootID; Result.Shape := Existing.Shape.Clone;
      Result.Indices := Copy(Existing.Indices);
    end
    else
    begin
      Result.RootID := FVariables[E.Variable];
      Result.Shape := TReferenceShape.Create;
      Result.Shape.RootType := E.DataType; Result.Shape.RootComposite := E.Composite;
      Result.Shape.RootStorage := StorageClass(E);
    end;
    Exit;
  end;
  Result := Reference(E.Left);
  try
    Step := Default(TReferenceStep);
    if (E.Kind = ekIndex) and (not E.ConstantIndex or HasFloat(E.Right)) then
    begin
      Step.Dynamic := True; Step.DataType := E.Right.DataType;
      Result.Indices := Result.Indices + [EmitExpression(E.Right)];
    end
    else Step.Index := E.MemberIndex;
    Result.Shape.Steps := Result.Shape.Steps + [Step];
  except Result.Shape.Free; raise; end;
end;

function TSPIRVWriter.ReferencePointer(const B: TReferenceBinding; T: TShaderType; C: TCompositeType): Cardinal;
var Operands: TArray<Cardinal>; Step: TReferenceStep; I: Integer;
begin
  if Length(B.Shape.Steps) = 0 then Exit(B.RootID);
  Result := NewID; I := 0;
  Operands := [PointerType(ValueTypeID(T, C), B.Shape.RootStorage), Result, B.RootID];
  for Step in B.Shape.Steps do
    if Step.Dynamic then begin Operands := Operands + [B.Indices[I]]; Inc(I); end
    else Operands := Operands + [Constant(stCardinal, Step.Index)];
  Emit(FCode, 65, Operands);
end;

function TSPIRVWriter.EmitReferenceCall(E: TExpression): Cardinal;
var
  Candidate, Instance: TFunctionInstance;
  B: TReferenceBinding;
  Step: TReferenceStep;
  Operands: TArray<Cardinal>;
  Key: string;
  I: Integer;
begin
  Candidate := TFunctionInstance.Create;
  try
    Candidate.ShaderFunction := E.Callee;
    SetLength(Candidate.Shapes, E.Arguments.Count);
    Key := IntToStr(E.Callee.Index); // overloads and nested routines may share names
    Result := NewID;
    Operands := [ValueTypeID(E.DataType, E.Composite), Result, 0];
    for I := 0 to E.Arguments.Count - 1 do
      if E.Callee.Parameters[I].ParameterMode in [pmVar, pmOut] then
      begin
        B := Reference(E.Arguments[I]);
        Candidate.Shapes[I] := B.Shape;
        Key := Key + '|' + IntToStr(ValueTypeID(B.Shape.RootType, B.Shape.RootComposite)) + 's' + IntToStr(B.Shape.RootStorage);
        for Step in B.Shape.Steps do
          if Step.Dynamic then Key := Key + ',d' + IntToStr(Ord(Step.DataType))
          else Key := Key + ',c' + IntToStr(Step.Index);
        Operands := Operands + [B.RootID] + B.Indices;
      end
      else Operands := Operands + [EmitExpression(E.Arguments[I])];
    if Length(Operands) > MaxShaderParameters + 3 then
      raise EShaderError.Create(E.Position, 'Specialized call exceeds the SPIR-V 255-parameter budget');
    if not FInstanceKeys.TryGetValue(Key, Instance) then
    begin
      if FInstances.Count >= 4096 then raise EShaderError.Create(E.Position, 'Reference specializations exceed 4096');
      Candidate.ID := NewID; Instance := Candidate;
      FInstances.Add(Candidate); FInstanceKeys.Add(Key, Candidate); Candidate := nil;
      Name(Instance.ID, E.Callee.Name + '__ref' + IntToStr(FInstances.Count));
    end;
    Operands[2] := Instance.ID;
    Emit(FCode, 57, Operands);
  finally Candidate.Free; end;
end;

function TSPIRVWriter.LoadOpaque(AVariable: TShaderVariable): Cardinal;
begin
  Result := NewID;
  Emit(FCode, 61, [FResourceTypes[AVariable], Result, FVariables[AVariable]]);
end;

function TSPIRVWriter.EmitGPUExpression(AExpression: TExpression): Cardinal;
var
  PointerID, ScopeID, ZeroID, A, B, Image, SamplerID, Sampled, Coordinate, Lod: Cardinal;
  Opcode: Word;
begin
  if AExpression.Kind = ekAtomic then
  begin
    PointerID := EmitPointer(AExpression.Left);
    if StorageClass(AExpression.Left) = 4 then ScopeID := Constant(stCardinal, 2)
    else ScopeID := Constant(stCardinal, 1);
    ZeroID := Constant(stCardinal, 0);
    A := EmitExpression(AExpression.Arguments[0]); Result := NewID;
    case AExpression.AtomicKind of
      akAdd: Opcode := 234;
      akExchange: Opcode := 229;
    else Opcode := 230;
    end;
    if AExpression.AtomicKind = akCompareExchange then
    begin
      B := EmitExpression(AExpression.Arguments[1]);
      Emit(FCode, Opcode, [FTypes[AExpression.DataType], Result, PointerID, ScopeID, ZeroID, ZeroID, B, A]);
    end
    else Emit(FCode, Opcode, [FTypes[AExpression.DataType], Result, PointerID, ScopeID, ZeroID, A]);
    Exit;
  end;
  Image := LoadOpaque(AExpression.Variable);
  if AExpression.Kind = ekImageSize then
  begin
    if not FImageQueryUsed then begin Emit(FCapabilities, 17, [50]); FImageQueryUsed := True; end;
    Result := NewID; Emit(FCode, 104, [FTypes[stInteger2], Result, Image]); Exit;
  end;
  Coordinate := EmitExpression(AExpression.Arguments[0]);
  if AExpression.Kind = ekImageStore then
  begin
    A := EmitExpression(AExpression.Arguments[1]);
    Emit(FCode, 99, [Image, Coordinate, A]); Exit(0);
  end;
  if AExpression.Kind = ekSampleLevel then
  begin
    SamplerID := LoadOpaque(AExpression.Sampler); Sampled := NewID;
    Emit(FCode, 86, [FSampledType, Sampled, Image, SamplerID]);
    Lod := EmitExpression(AExpression.Arguments[1]); Result := NewID;
    Emit(FCode, 88, [FTypes[stSingle4], Result, Sampled, Coordinate, 2, Lod]); Exit;
  end;
  Result := NewID;
  Emit(FCode, 98, [FTypes[AExpression.DataType], Result, Image, Coordinate]);
end;

function TSPIRVWriter.EmitIntrinsic(AExpression: TExpression): Cardinal;
var
  ArgumentIDs: TArray<Cardinal>;
  Operands: TArray<Cardinal>;
  I: Integer;
  Base: TShaderType;
  Instruction, NegativeID, ConditionID: Cardinal;
begin
  if AExpression.Intrinsic >= inSingleToBits then Exit(EmitNumericIntrinsic(AExpression));
  SetLength(ArgumentIDs, AExpression.Arguments.Count);
  for I := 0 to High(ArgumentIDs) do
    ArgumentIDs[I] := EmitExpression(AExpression.Arguments[I]);
  Base := ComponentType(AExpression.DataType);
  if AExpression.Intrinsic = inDot then
  begin
    Result := NewID;
    Emit(FCode, 148, [FTypes[stSingle], Result, ArgumentIDs[0], ArgumentIDs[1]]);
    Emit(FAnnotations, 71, [Result, 42]); // NoContraction; reduction order is not fixed.
    Exit;
  end;
  if AExpression.Intrinsic = inAbs then
  begin
    if IsIntegerType(Base) and not IsSignedInteger(Base) then Exit(ArgumentIDs[0]);
    if IsSignedInteger(Base) then
    begin
      NegativeID := NewID;
      // ISub, not SNegate: see the unary minus note (driver no-wrap assumption).
      Emit(FCode, 130, [FTypes[AExpression.DataType], NegativeID,
        Constant(AExpression.DataType, 0), ArgumentIDs[0]]);
      ConditionID := NewID;
      Emit(FCode, 177, [BoolType(AExpression.DataType), ConditionID, ArgumentIDs[0],
        Constant(AExpression.DataType, 0)]);
      Result := NewID;
      Emit(FCode, 169, [FTypes[AExpression.DataType], Result, ConditionID,
        NegativeID, ArgumentIDs[0]]);
      Exit;
    end;
  end;
  case AExpression.Intrinsic of
    inMin:
      if IsFloatType(Base) then Instruction := 79
      else if not IsSignedInteger(Base) then Instruction := 38 else Instruction := 39;
    inMax:
      if IsFloatType(Base) then Instruction := 80
      else if not IsSignedInteger(Base) then Instruction := 41 else Instruction := 42;
    inClamp:
      if IsFloatType(Base) then Instruction := 81
      else if not IsSignedInteger(Base) then Instruction := 44 else Instruction := 45;
    inAbs: Instruction := 4;
    inSqrt: Instruction := 31;
  else
    raise EInvalidOpException.Create('Internal error: unsupported intrinsic');
  end;
  SetLength(Operands, Length(ArgumentIDs) + 4);
  Operands[0] := FTypes[AExpression.DataType];
  Result := NewID;
  Operands[1] := Result;
  Operands[2] := GLSL450;
  Operands[3] := Instruction;
  for I := 0 to High(ArgumentIDs) do Operands[I + 4] := ArgumentIDs[I];
  Emit(FCode, 12, Operands);
end;

function TSPIRVWriter.EmitNumericIntrinsic(AExpression: TExpression): Cardinal;
var
  A, B, Rounded, LowID, HighID, Condition, C1, C2, Yes, No, Merge, Valid, Invalid: Cardinal;
  T: TShaderType;
  Instruction: Cardinal;
  D: Double;
  S: Single;
  Bits: UInt64;
begin
  A := EmitExpression(AExpression.Arguments[0]);
  T := AExpression.Arguments[0].DataType;
  Result := NewID;
  case AExpression.Intrinsic of
    inSingleToBits, inBitsToSingle, inDoubleToBits, inBitsToDouble:
      begin Emit(FCode, 124, [FTypes[AExpression.DataType], Result, A]); Exit; end;
    inIsNan, inIsInfinite:
      begin
        if AExpression.Intrinsic = inIsNan then Instruction := 156 else Instruction := 157;
        Emit(FCode, Instruction, [FTypes[stBoolean], Result, A]); Exit;
      end;
    inOrd:
      begin
        Emit(FCode, 169, [FTypes[stInteger], Result, A, Constant(stInteger, 1), Constant(stInteger, 0)]);
        Exit;
      end;
    inSqr:
      begin
        if IsFloatType(T) then
        begin
          Emit(FCode, 133, [FTypes[T], Result, A, A]);
          Emit(FAnnotations, 71, [Result, 42]); // NoContraction
        end
        else Emit(FCode, 132, [FTypes[T], Result, A, A]);
        Exit;
      end;
    inArithmeticShiftRight:
      begin
        B := EmitExpression(AExpression.Arguments[1]);
        Condition := NewID;
        Emit(FCode, 199, [FTypes[AExpression.Arguments[1].DataType], Condition, B,
          Constant(AExpression.Arguments[1].DataType, ScalarBitWidth(T) - 1)]);
        Emit(FCode, 195, [FTypes[T], Result, A, Condition]); Exit;
      end;
    inRound, inTrunc, inFloor, inCeil:
      begin
        case AExpression.Intrinsic of
          inRound: Instruction := 2;
          inFloor: Instruction := 8;
          inCeil: Instruction := 9;
        else Instruction := 3;
        end;
        Rounded := NewID;
        Emit(FCode, 12, [FTypes[T], Rounded, GLSL450, Instruction, A]);
        if AExpression.DataType = stInt64 then D := 9223372036854775808.0 else D := 2147483648.0;
        Bits := 0;
        if T = stDouble then Move(D, Bits, 8) else begin S := D; Move(S, Bits, 4); end;
        HighID := Constant(T, Bits);
        if T = stDouble then Bits := Bits xor $8000000000000000 else Bits := Bits xor $80000000;
        LowID := Constant(T, Bits);
        C1 := NewID; C2 := NewID; Condition := NewID;
        Emit(FCode, 190, [FTypes[stBoolean], C1, Rounded, LowID]);
        Emit(FCode, 184, [FTypes[stBoolean], C2, Rounded, HighID]);
        Emit(FCode, 167, [FTypes[stBoolean], Condition, C1, C2]);
        Yes := NewID; No := NewID; Merge := NewID;
        Emit(FCode, 247, [Merge, 0]); Emit(FCode, 250, [Condition, Yes, No]);
        EmitLabel(Yes); Valid := NewID;
        Emit(FCode, 110, [FTypes[AExpression.DataType], Valid, Rounded]);
        Emit(FCode, 249, [Merge]);
        EmitLabel(No);
        Invalid := Constant(AExpression.DataType, UInt64(1) shl (ScalarBitWidth(AExpression.DataType) - 1));
        Emit(FCode, 249, [Merge]); EmitLabel(Merge);
        Emit(FCode, 245, [FTypes[AExpression.DataType], Result, Valid, Yes, Invalid, No]); Exit;
      end;
    inRoundEven: Instruction := 2;
    inLdexp: Instruction := 53;
    inFindMSB: if IsSignedInteger(T) then Instruction := 74 else Instruction := 75;
    inFindLSB: Instruction := 73;
  else raise EInvalidOpException.Create('Internal error: numeric intrinsic');
  end;
  if AExpression.Arguments.Count = 2 then
  begin
    B := EmitExpression(AExpression.Arguments[1]);
    Emit(FCode, 12, [FTypes[AExpression.DataType], Result, GLSL450, Instruction, A, B]);
  end
  else Emit(FCode, 12, [FTypes[AExpression.DataType], Result, GLSL450, Instruction, A]);
end;

procedure TSPIRVWriter.EmitStatement(AStatement: TStatement);
var
  Child: TStatement;
  ValueID, PointerID, ConditionID: Cardinal;
  ThenLabel, ElseLabel, MergeLabel, HeaderLabel, BodyLabel, ContinueLabel, TestLabel: Cardinal;
  I: Integer;
begin
  if FTerminated then Exit;
  case AStatement.Kind of
    skReturn:
      begin
        if FCurrentFunction.ReturnType = stVoid then Emit(FCode, 253, [])
        else
        begin
          if AStatement.Value <> nil then ValueID := EmitExpression(AStatement.Value)
          else
          begin
            ValueID := NewID;
            Emit(FCode, 61, [ValueTypeID(FCurrentFunction.ReturnType, FCurrentFunction.ReturnComposite),
              ValueID, FVariables[FCurrentFunction.ResultVariable]]);
          end;
          Emit(FCode, 254, [ValueID]);
        end;
        FTerminated := True;
      end;
    skBreak: Branch(FBreakTargets.Peek);
    skContinue: Branch(FContinueTargets.Peek);
    skCase: EmitCase(AStatement);
    skRepeat: EmitRepeat(AStatement);
    skIncrement:
      begin
        PointerID := EmitPointer(AStatement.Target);
        ConditionID := NewID; // current value
        Emit(FCode, 61, [FTypes[AStatement.Target.DataType], ConditionID, PointerID]);
        ValueID := EmitExpression(AStatement.Value);
        ThenLabel := NewID; // result
        Emit(FCode, BinaryOpcode(AStatement.Operation, AStatement.Target.DataType),
          [FTypes[AStatement.Target.DataType], ThenLabel, ConditionID, ValueID]);
        Emit(FCode, 62, [PointerID, ThenLabel]);
      end;
    skDeclare:
      if AStatement.Value <> nil then
      begin
        PointerID := EmitPointer(AStatement.Target);
        ValueID := EmitExpression(AStatement.Value);
        Emit(FCode, 62, [PointerID, ValueID]);
      end;
    skEvaluate: EmitExpression(AStatement.Value);
    skBarrier:
      case AStatement.BarrierKind of
        bkWorkgroup: Emit(FCode, 224, [Constant(stCardinal,2), Constant(stCardinal,2), Constant(stCardinal,264)]);
        bkBuffer: Emit(FCode, 225, [Constant(stCardinal,1), Constant(stCardinal,72)]);
        bkImage: Emit(FCode, 225, [Constant(stCardinal,1), Constant(stCardinal,2056)]);
      end;
    skBlock:
      for Child in AStatement.Children do
        EmitStatement(Child);
    skAssign:
      if AStatement.Target.Kind = ekSwizzle then
      begin
        // V.ZX := W stores each selected component separately (no read-modify-write,
        // so WriteOnly buffers behave like single-component writes).
        PointerID := EmitPointer(AStatement.Target.Left);
        ValueID := EmitExpression(AStatement.Value);
        for I := 0 to Integer(AStatement.Target.MemberIndex) - 1 do
        begin
          ConditionID := NewID;
          Emit(FCode, 81, [FTypes[ComponentType(AStatement.Value.DataType)], ConditionID, ValueID, Cardinal(I)]);
          ThenLabel := NewID;
          Emit(FCode, 65, [PointerType(FTypes[ComponentType(AStatement.Value.DataType)], StorageClass(AStatement.Target.Left)),
            ThenLabel, PointerID, Constant(stCardinal, Cardinal(AStatement.Target.Bits shr (2 * I)) and 3)]);
          Emit(FCode, 62, [ThenLabel, ConditionID]);
        end;
      end
      else
      begin
        PointerID := EmitPointer(AStatement.Target);
        ValueID := EmitExpression(AStatement.Value);
        if (AStatement.Target.Kind = ekLocal) and (AStatement.Target.Variable.Kind = vkShared) and
          (SharedTypeID(AStatement.Target.Variable) <>
           ValueTypeID(AStatement.Target.DataType, AStatement.Target.Composite)) then
          ValueID := RebuildArray(ValueID, AStatement.Target.Composite,
            SharedTypeID(AStatement.Target.Variable));
        Emit(FCode, 62, [PointerID, ValueID]);
      end;
    skIf:
      begin
        ConditionID := EmitExpression(AStatement.Condition);
        ThenLabel := NewID;
        MergeLabel := NewID;
        if Assigned(AStatement.ElsePart) then ElseLabel := NewID else ElseLabel := MergeLabel;
        Emit(FCode, 247, [MergeLabel, 0]);
        Emit(FCode, 250, [ConditionID, ThenLabel, ElseLabel]);
        EmitLabel(ThenLabel);
        EmitStatement(AStatement.ThenPart);
        Branch(MergeLabel);
        if Assigned(AStatement.ElsePart) then
        begin
          EmitLabel(ElseLabel);
          EmitStatement(AStatement.ElsePart);
          Branch(MergeLabel);
        end;
        EmitLabel(MergeLabel);
      end;
    skWhile:
      begin
        HeaderLabel := NewID;
        BodyLabel := NewID;
        ContinueLabel := NewID;
        MergeLabel := NewID;
        TestLabel := NewID;
        Emit(FCode, 249, [HeaderLabel]);
        EmitLabel(HeaderLabel);
        Emit(FCode, 246, [MergeLabel, ContinueLabel, 0]);
        Emit(FCode, 249, [TestLabel]);
        EmitLabel(TestLabel);
        ConditionID := EmitExpression(AStatement.Condition);
        Emit(FCode, 250, [ConditionID, BodyLabel, MergeLabel]);
        EmitLabel(BodyLabel);
        FBreakTargets.Push(MergeLabel); FContinueTargets.Push(ContinueLabel);
        try EmitStatement(AStatement.Body); finally FBreakTargets.Pop; FContinueTargets.Pop; end;
        Branch(ContinueLabel);
        EmitLabel(ContinueLabel);
        Emit(FCode, 249, [HeaderLabel]);
        EmitLabel(MergeLabel);
      end;
    skFor:
      EmitFor(AStatement);
  end;
end;

procedure TSPIRVWriter.EmitFor(AStatement: TStatement);
var
  CounterType: TShaderType;
  PointerID, StartID, LimitID, InitialConditionID, EntryLabel: Cardinal;
  HeaderLabel, BodyLabel, ContinueLabel, MergeLabel, ActiveID, NextActiveID: Cardinal;
  CurrentID, NextID, PreservedID: Cardinal;
  Comparison: TOperator;
  StepOpcode: Word;
begin
  CounterType := AStatement.Target.DataType;
  PointerID := EmitPointer(AStatement.Target);
  // Both bounds are evaluated exactly once, before assigning the counter.
  StartID := EmitExpression(AStatement.Value);
  LimitID := EmitExpression(AStatement.Limit);
  Emit(FCode, 62, [PointerID, StartID]);
  if AStatement.Descending then
  begin
    Comparison := opGreaterEqual;
    StepOpcode := 130; // OpISub
  end
  else
  begin
    Comparison := opLessEqual;
    StepOpcode := 128; // OpIAdd
  end;
  InitialConditionID := NewID;
  Emit(FCode, BinaryOpcode(Comparison, CounterType),
    [FTypes[stBoolean], InitialConditionID, StartID, LimitID]);
  EntryLabel := FCurrentLabel;
  HeaderLabel := NewID;
  BodyLabel := NewID;
  ContinueLabel := NewID;
  MergeLabel := NewID;
  ActiveID := NewID;
  NextActiveID := NewID;
  Emit(FCode, 249, [HeaderLabel]);
  EmitLabel(HeaderLabel);
  Emit(FCode, 245, [FTypes[stBoolean], ActiveID, InitialConditionID, EntryLabel,
    NextActiveID, ContinueLabel]); // OpPhi
  Emit(FCode, 246, [MergeLabel, ContinueLabel, 0]);
  Emit(FCode, 250, [ActiveID, BodyLabel, MergeLabel]);
  EmitLabel(BodyLabel);
  FBreakTargets.Push(MergeLabel); FContinueTargets.Push(ContinueLabel);
  try EmitStatement(AStatement.Body); finally FBreakTargets.Pop; FContinueTargets.Pop; end;
  Branch(ContinueLabel);
  EmitLabel(ContinueLabel);
  CurrentID := NewID;
  Emit(FCode, 61, [FTypes[CounterType], CurrentID, PointerID]);
  // Stop on the final iteration, not by comparing an overflowed next counter.
  Emit(FCode, 171, [FTypes[stBoolean], NextActiveID, CurrentID, LimitID]);
  NextID := NewID;
  Emit(FCode, StepOpcode, [FTypes[CounterType], NextID, CurrentID,
    Constant(CounterType, 1)]);
  PreservedID := NewID;
  Emit(FCode, 169, [FTypes[CounterType], PreservedID, NextActiveID, NextID, CurrentID]);
  Emit(FCode, 62, [PointerID, PreservedID]);
  Emit(FCode, 249, [HeaderLabel]);
  EmitLabel(MergeLabel);
end;

procedure TSPIRVWriter.EmitCase(AStatement: TStatement);
var
  Selector, Merge, Default: Cardinal;
  Labels, Operands: TArray<Cardinal>;
  I: Integer;
  V: UInt64;
begin
  Selector := EmitExpression(AStatement.Condition);
  Merge := NewID;
  if AStatement.ElsePart = nil then Default := Merge else Default := NewID;
  SetLength(Labels, AStatement.Children.Count);
  Operands := [Selector, Default];
  for I := 0 to High(Labels) do
  begin
    Labels[I] := NewID;
    for V in AStatement.CaseLabels[I] do
    begin
      Operands := Operands + [Cardinal(V)];
      if ScalarBitWidth(AStatement.Condition.DataType) = 64 then Operands := Operands + [Cardinal(V shr 32)];
      Operands := Operands + [Labels[I]];
    end;
  end;
  Emit(FCode, 247, [Merge, 0]); Emit(FCode, 251, Operands);
  for I := 0 to High(Labels) do
  begin
    EmitLabel(Labels[I]); EmitStatement(AStatement.Children[I]); Branch(Merge);
  end;
  if AStatement.ElsePart <> nil then
  begin EmitLabel(Default); EmitStatement(AStatement.ElsePart); Branch(Merge); end;
  EmitLabel(Merge);
end;

procedure TSPIRVWriter.EmitRepeat(AStatement: TStatement);
var Header, Body, ContinueLabel, Merge, Condition: Cardinal;
begin
  Header := NewID; Body := NewID; ContinueLabel := NewID; Merge := NewID;
  Branch(Header); EmitLabel(Header);
  Emit(FCode, 246, [Merge, ContinueLabel, 0]); Emit(FCode, 249, [Body]);
  EmitLabel(Body);
  FBreakTargets.Push(Merge); FContinueTargets.Push(ContinueLabel);
  try EmitStatement(AStatement.Body); finally FBreakTargets.Pop; FContinueTargets.Pop; end;
  Branch(ContinueLabel); EmitLabel(ContinueLabel);
  Condition := EmitExpression(AStatement.Condition);
  Emit(FCode, 250, [Condition, Merge, Header]); EmitLabel(Merge);
end;

procedure TSPIRVWriter.EmitFunction(AFunction: TShaderFunction; AInstance: TFunctionInstance);
var
  PointerID, VariableID, ResultID: Cardinal;
  Variable: TShaderVariable;
  ParameterIDs: TArray<Cardinal>;
  I: Integer;
  ID: Cardinal;
  B: TReferenceBinding;
  Step: TReferenceStep;
begin
  FCurrentFunction := AFunction;
  FInstance := AInstance; FReferences.Clear;
  // Captured variables are module-scope Private storage (DeclareCaptured).
  for Variable in AFunction.Parameters do if not Variable.Captured then FVariables.Remove(Variable);
  for Variable in AFunction.Locals do if not Variable.Captured then FVariables.Remove(Variable);
  if AInstance = nil then ID := FFunctionIDs[AFunction] else ID := AInstance.ID;
  Emit(FCode, 54, [ValueTypeID(AFunction.ReturnType, AFunction.ReturnComposite), ID, 0,
    FunctionType(AFunction)]);
  SetLength(ParameterIDs, AFunction.Parameters.Count);
  for I := 0 to AFunction.Parameters.Count - 1 do
  begin
    ParameterIDs[I] := NewID;
    Emit(FCode, 55, [ParameterType(AFunction.Parameters[I]), ParameterIDs[I]]);
    Name(ParameterIDs[I], AFunction.Parameters[I].Name + '_value');
    if AFunction.Parameters[I].ParameterMode in [pmVar, pmOut] then
    begin
      B := Default(TReferenceBinding); B.RootID := ParameterIDs[I]; B.Shape := AInstance.Shapes[I];
      for Step in B.Shape.Steps do if Step.Dynamic then
      begin
        ID := NewID; Emit(FCode, 55, [FTypes[Step.DataType], ID]); B.Indices := B.Indices + [ID];
      end;
      FReferences.Add(AFunction.Parameters[I], B);
    end;
  end;
  EmitLabel(NewID);
  // All Function OpVariables must precede stores or other instructions.
  for Variable in AFunction.Parameters do
  begin
    if (Variable.ParameterMode in [pmVar, pmOut]) or Variable.Captured then
    begin
      Continue;
    end;
    PointerID := PointerType(ValueTypeID(Variable.DataType, Variable.Composite), StorageFunction);
    VariableID := NewID;
    FVariables.Add(Variable, VariableID);
    Name(VariableID, Variable.Name);
    Emit(FCode, 59, [PointerID, VariableID, StorageFunction]);
  end;
  for Variable in AFunction.Locals do
  begin
    if Variable.Captured then Continue;
    PointerID := PointerType(ValueTypeID(Variable.DataType, Variable.Composite), StorageFunction);
    VariableID := NewID;
    FVariables.Add(Variable, VariableID);
    Name(VariableID, Variable.Name);
    Emit(FCode, 59, [PointerID, VariableID, StorageFunction]);
  end;
  for I := 0 to AFunction.Parameters.Count - 1 do
    if AFunction.Parameters[I].ParameterMode in [pmVar, pmOut] then
    begin
      Variable := AFunction.Parameters[I];
      FVariables.Add(Variable, ReferencePointer(FReferences[Variable], Variable.DataType, Variable.Composite));
    end
    else
      Emit(FCode, 62, [FVariables[AFunction.Parameters[I]], ParameterIDs[I]]);
  EmitStatement(AFunction.Body);
  if not FTerminated then
  if AFunction.ReturnType = stVoid then
    Emit(FCode, 253, [])
  else
  begin
    ResultID := NewID;
    Emit(FCode, 61, [ValueTypeID(AFunction.ReturnType, AFunction.ReturnComposite), ResultID,
      FVariables[AFunction.ResultVariable]]);
    Emit(FCode, 254, [ResultID]); // OpReturnValue
  end;
  Emit(FCode, 56, []);
end;

function TSPIRVWriter.Generate: TBytes;
var
  ShaderFunction: TShaderFunction;
  FunctionID: Cardinal;
  Words: TList<Cardinal>;
  I: Integer;
begin
  Emit(FCapabilities, 17, [1]); // Capability Shader
  if FModule.Storage8 or FModule.Push8 then
  begin
    EmitString(FExtensions, 10, [], 'SPV_KHR_8bit_storage', []);
    if FModule.Storage8 then Emit(FCapabilities, 17, [4448]);
    if FModule.Push8 then Emit(FCapabilities, 17, [4450]);
  end;
  if FModule.Storage16 or FModule.Push16 then
  begin
    if FModule.Storage16 then Emit(FCapabilities, 17, [4433]);
    if FModule.Push16 then Emit(FCapabilities, 17, [4435]);
  end;
  if FModule.StrictFloat then
  begin
    EmitString(FExtensions, 10, [], 'SPV_KHR_float_controls', []);
    Emit(FCapabilities, 17, [4464]); Emit(FCapabilities, 17, [4466]); Emit(FCapabilities, 17, [4467]);
  end;
  Emit(FMemoryModel, 14, [0, 1]); // MemoryModel Logical GLSL450
  DeclareTypes;
  DeclareResources;
  DeclareConstants;
  DeclareCaptured;
  for ShaderFunction in FModule.Functions do
  begin
    if HasReferences(ShaderFunction) then Continue;
    FunctionID := NewID;
    FFunctionIDs.Add(ShaderFunction, FunctionID);
    if ShaderFunction.ModuleName <> '' then Name(FunctionID, ShaderFunction.ModuleName + '.' + ShaderFunction.Name)
    else Name(FunctionID, ShaderFunction.Name);
  end;
  FMainID := FFunctionIDs[FModule.EntryPoint];
  EmitString(FEntryPoints, 15, [5, FMainID], 'Main', FInvocationIDs);
  if FModule.StrictFloat then
  begin
    Emit(FEntryPoints, 16, [FMainID, 4459, 32]);
    Emit(FEntryPoints, 16, [FMainID, 4461, 32]);
    Emit(FEntryPoints, 16, [FMainID, 4462, 32]);
    if stDouble in FModule.UsedTypes then
    begin
      Emit(FEntryPoints, 16, [FMainID, 4459, 64]);
      Emit(FEntryPoints, 16, [FMainID, 4461, 64]);
      Emit(FEntryPoints, 16, [FMainID, 4462, 64]);
    end;
  end;
  Emit(FEntryPoints, 16, [FMainID, 17, FModule.LocalSize[0],
    FModule.LocalSize[1], FModule.LocalSize[2]]);
  for ShaderFunction in FModule.Functions do
    if not HasReferences(ShaderFunction) then EmitFunction(ShaderFunction);
  I := 0;
  while I < FInstances.Count do
  begin
    EmitFunction(FInstances[I].ShaderFunction, FInstances[I]); Inc(I);
  end;
  Words := TList<Cardinal>.Create;
  try
    Words.Add(SpvMagic);
    if FModule.Extended then Words.Add($00010300) else Words.Add(SpvVersion10);
    Words.Add(0); // Unregistered generator; do not impersonate another tool.
    Words.Add(FNextID);
    Words.Add(0);
    Words.AddRange(FCapabilities);
    Words.AddRange(FExtensions);
    Words.AddRange(FImports);
    Words.AddRange(FMemoryModel);
    Words.AddRange(FEntryPoints);
    Words.AddRange(FDebug);
    Words.AddRange(FAnnotations);
    Words.AddRange(FGlobals);
    Words.AddRange(FCode);
    SetLength(Result, Words.Count * SizeOf(Cardinal));
    Move(Words.List[0], Result[0], Length(Result));
  finally
    Words.Free;
  end;
end;

end.
