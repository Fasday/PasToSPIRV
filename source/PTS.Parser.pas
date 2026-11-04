unit PTS.Parser;

{$BOOLEVAL OFF}

interface

uses
  System.Generics.Collections,
  PTS.Diagnostics,
  PTS.Types,
  PTS.Layout,
  PTS.Features,
  PTS.Source,
  PTS.IR,
  PTS.Lexer;

type
  TAttributes = record
    HasAny: Boolean;
    HasBinding: Boolean;
    DescriptorSet: Cardinal;
    Binding: Cardinal;
    HasAccess: Boolean;
    Access: TBufferAccess;
    HasPushConstant: Boolean;
    HasLocalSize: Boolean;
    HasShared: Boolean;
    HasVulkan12: Boolean;
    HasStrictFloat: Boolean;
    HasAliased: Boolean;
    LocalSize: array[0..2] of Cardinal;
  end;

  TParser = class
  private
    FLexer: TLexer;
    FToken: TToken;
    FModule: TShaderModule;
    FSymbols: TDictionary<string, TShaderVariable>;
    FLocalSymbols: TDictionary<string, TShaderVariable>;
    FFunctions: TDictionary<string, TShaderFunction>;
    FCurrentFunction: TShaderFunction;
    FNamedTypes: TDictionary<string, TTypeReference>;
    FDefiningType: string;
    FTypeDepth: Integer;
    FProgram: TSourceProgram; // Non-owning; strings in diagnostic positions are owned.
    FActiveLibrary: TSourceDocument;
    FDepth: Integer;
    FControlDepth: Integer;
    FLoopDepth: Integer;
    FLookahead: TToken;
    FHasLookahead: Boolean;
    FConstants: TDictionary<string, TExpression>;
    FConstantOwners: TDictionary<string, string>;
    FConstantStorage: TObjectList<TExpression>;
    FLocalConstants: TDictionary<string, TExpression>; // non-owning; lower-case names
    FLocalFunctions: TDictionary<string, TShaderFunction>; // nested routines in scope
    FScopes: TObjectList<TList<string>>;
    // Lower-case short export name -> qualified keys; avoids quadratic lookup.
    FShortNames: TObjectDictionary<string, TList<string>>;
    procedure RegisterExport(const AKey, AName: string);
    function ExportKeys(const AName: string): TArray<string>;
    procedure CheckConstantIndex(AIndex: TExpression; ALength: Int64);
    function CurrentOwner: string;
    function SymbolKey(const AOwner, AName: string): string;
    function ReadOwnerPrefix(ATypeContext: Boolean = False): string;
    function FindType(const AName, AOwner: string; out AReference: TTypeReference; AReportScope: Boolean = True): Boolean;
    function FindFunction(const AName, AOwner: string; out AFunction: TShaderFunction; AReportScope: Boolean = True): Boolean;
    function FindConstant(const AName, AOwner: string; out AExpression: TExpression; AReportScope: Boolean = True): Boolean;
    procedure ParseConstants;
    function ParseEnumeration(const ATypeName: string): TCompositeType;
    function ParseIn(ALeft: TExpression; const APosition: TSourcePosition): TExpression;
    function ParseSetConstructor: TExpression;
    function SetBit(AElement: TExpression; AComposite: TCompositeType): TExpression;
    procedure ParseConstantDeclaration(ALocal: Boolean; AStatement: Boolean = False);
    // Block scopes for inline var/const: names are removed when the block ends.
    procedure PushScope;
    procedure PopScope;
    procedure DeclareInScope(const ALowerName: string);
    function ParseInlineVar: TStatement;
    function DeclareLocal(const AName: TToken; AType: TShaderType; AComposite: TCompositeType): TShaderVariable;
    function ParseConstantInitializer(AType: TShaderType; AComposite: TCompositeType): TExpression;
    function PeekToken: TToken;
    procedure InitializeTables;
    procedure ParseLibraries;
    function ModuleVisible(const AName: string): Boolean;
    procedure Next;
    procedure Fail(const AMessage: string);
    function IsWord(const AWord: string): Boolean;
    procedure ExpectWord(const AWord: string);
    procedure Expect(AKind: TTokenKind; const ADescription: string);
    function ReadName(ADeclaration: Boolean = False): TToken;
    function ReadUInt: Cardinal;
    function ReadType(out AComposite: TCompositeType): TShaderType;
    procedure ParseTypes;
    procedure Select(var AExpression: TExpression);
    function ReadAttributes: TAttributes;
    procedure AddSymbol(AVariable: TShaderVariable);
    procedure ParseResource(const AAttributes: TAttributes);
    procedure ParseFunction(AEntryPoint: Boolean; const AAttributes: TAttributes; ANested: Boolean = False);
    procedure MarkCapture(AVariable: TShaderVariable; const APosition: TSourcePosition);
    procedure NoteCall(ACallee: TShaderFunction; const APosition: TSourcePosition);
    function EnclosingResult(ACallee: TShaderFunction): TShaderFunction;
    function ParseOverloadedCall(AHead: TShaderFunction): TExpression;
    procedure CheckCallGraph;
    procedure ParseParameters;
    procedure ParseLocals;
    function ParseBlock: TStatement;
    function ParseStatement: TStatement;
    function ParseControlledStatement: TStatement;
    function ParseFor: TStatement;
    function ParseCase: TStatement;
    function ParseRepeat: TStatement;
    function ParseExpression: TExpression;
    function ParseConditional: TExpression;
    function ParseAdditive: TExpression;
    function ParseMultiplicative: TExpression;
    function ParseUnary: TExpression;
    function ParsePrimary: TExpression;
    function ParseAtom: TExpression;
    function ParseConstruct(AType: TShaderType): TExpression;
    function ParseDefault: TExpression;
    function ParseBuiltin: TExpression;
    function MakeConstant(AType: TShaderType; ABits: UInt64; AAdaptable: Boolean;
      const APosition: TSourcePosition): TExpression;
    function ParseIntrinsic(AIntrinsic: TIntrinsic): TExpression;
    function ParseNumericIntrinsic(AIntrinsic: TIntrinsic): TExpression;
    function ParseAtomic: TExpression;
    function ParseImageOperation: TExpression;
    function ReadResource: TShaderVariable;
    function ParseReference(AForWrite: Boolean; const AOwner: string = ''): TExpression;
    procedure CheckWriteTarget(ATarget: TExpression);
    function ParseCall(ACallee: TShaderFunction): TExpression;
    function MakeBinary(AOperation: TOperator; ALeft, ARight: TExpression;
      const APosition: TSourcePosition): TExpression;
    procedure MakeOrdinalBinary(AResult: TExpression; AOperation: TOperator;
      const APosition: TSourcePosition);
    procedure Convert(var AExpression: TExpression; AType: TShaderType;
      AExplicit: Boolean = False; AComposite: TCompositeType = nil);
    procedure Splat(var AExpression: TExpression; ACount: Integer);
    procedure UnifyNumeric(var ALeft, ARight: TExpression; ABroadcast: Boolean = False);
    function Snapshot: TArray<Boolean>;
    procedure Restore(const AState: TArray<Boolean>);
    procedure EnterDepth;
    procedure LeaveDepth;
  public
    constructor Create(const ASource: string); overload;
    constructor Create(AProgram: TSourceProgram); overload;
    destructor Destroy; override;
    function Parse: TShaderModule;
  end;

implementation

uses
  System.SysUtils,
  System.Math,
  PTS.ConstEval,
  PTS.Names,
  PTS.Analysis,
  PTS.Profile,
  PTS.FloatLiteral;

const
  MaxResources = 4096;
  MaxFunctionVariables = 4096;
  MaxRoutineNesting = 32;
// Constant evaluation is shared with the conservative optional optimizer.


function TryIntrinsic(const AName: string; out AIntrinsic: TIntrinsic): Boolean;
const
  Names: array[TIntrinsic] of string = ('Min', 'Max', 'Abs', 'Clamp', 'Dot', 'Sqrt',
    'SingleToBits', 'BitsToSingle', 'DoubleToBits', 'BitsToDouble',
    'RoundEven', 'Round', 'Trunc', 'Floor', 'Ceil', 'IsNan', 'IsInfinite',
    'Ldexp', 'FindMSB', 'FindLSB', 'ArithmeticShiftRight', 'Ord', 'Sqr');
var
  Candidate: TIntrinsic;
begin
  for Candidate := Low(TIntrinsic) to High(TIntrinsic) do
    if SameText(AName, Names[Candidate]) then
    begin
      AIntrinsic := Candidate;
      Exit(True);
    end;
  AIntrinsic := inMin;
  Result := False;
end;

function TreeAdaptable(AExpression: TExpression): Boolean;
begin
  if AExpression.ExplicitType then Exit(False);
  case AExpression.Kind of
    ekConstant: Result := AExpression.Adaptable;
    ekUnary: Result := TreeAdaptable(AExpression.Left);
    ekBinary: Result := TreeAdaptable(AExpression.Left) and TreeAdaptable(AExpression.Right);
  else
    Result := False;
  end;
end;

// No calls, resource/memory reads that could fault, atomics or images: skipping
// it cannot be observed, so a short-circuit and/or may use OpLogicalAnd/Or.
function PureOperand(E: TExpression): Boolean;
var A: TExpression;
begin
  if E = nil then Exit(True);
  case E.Kind of
    ekConstant, ekDefault, ekInvocationID, ekPushConstant: Result := True;
    ekLocal: Result := E.Variable.Kind in [vkLocal, vkParameter, vkResult];
    ekIndex: Result := E.ConstantIndex and PureOperand(E.Left);
    ekUnary, ekBinary, ekConvert, ekComponent, ekField, ekConstruct, ekSwizzle,
    ekConditional, ekInSet, ekRange:
      begin
        // Integer div/mod by zero and out-of-range float->integer conversion are
        // undefined behavior in SPIR-V: such operands must really be skipped.
        if (E.Kind = ekBinary) and (E.Operation in [opIntDivide, opModulo]) then Exit(False);
        if (E.Kind = ekConvert) and IsFloatType(E.Left.DataType) and not IsFloatType(E.DataType) then Exit(False);
        if not (PureOperand(E.Left) and PureOperand(E.Right)) then Exit(False);
        for A in E.Arguments do if not PureOperand(A) then Exit(False);
        Result := True;
      end;
  else Result := False;
  end;
end;

function TryIntegerConstant(AExpression: TExpression; out AValue: Int64): Boolean;
begin
  Result := False;
  if not IsScalarIntegerType(AExpression.DataType) then Exit;
  if AExpression.Kind = ekConstant then
  begin
    if (AExpression.DataType = stUInt64) and (AExpression.Bits > UInt64(High(Int64))) then Exit;
    AValue := SignedValue(AExpression.Bits, AExpression.DataType);
    Exit(True);
  end;
  if (AExpression.Kind = ekUnary) and (AExpression.Operation = opNegate) and
    TryIntegerConstant(AExpression.Left, AValue) then
  begin
    AValue := -AValue;
    Exit(True);
  end;
end;

constructor TParser.Create(const ASource: string);
begin
  inherited Create;
  FLexer := TLexer.Create(ASource);
  InitializeTables;
end;

constructor TParser.Create(AProgram: TSourceProgram);
begin
  inherited Create;
  FProgram := AProgram;
  FLexer := TLexer.Create(AProgram.Root);
  InitializeTables;
end;

procedure TParser.InitializeTables;
begin
  FSymbols := TDictionary<string, TShaderVariable>.Create;
  FLocalSymbols := TDictionary<string, TShaderVariable>.Create;
  FFunctions := TDictionary<string, TShaderFunction>.Create;
  FNamedTypes := TDictionary<string, TTypeReference>.Create;
  FConstants := TDictionary<string, TExpression>.Create;
  FConstantOwners := TDictionary<string, string>.Create;
  FConstantStorage := TObjectList<TExpression>.Create(True);
  FLocalConstants := TDictionary<string, TExpression>.Create;
  FLocalFunctions := TDictionary<string, TShaderFunction>.Create;
  FScopes := TObjectList<TList<string>>.Create(True);
  FShortNames := TObjectDictionary<string, TList<string>>.Create([doOwnsValues]);
end;

procedure TParser.RegisterExport(const AKey, AName: string);
var
  Keys: TList<string>;
begin
  if not FShortNames.TryGetValue(LowerCase(AName), Keys) then
  begin
    Keys := TList<string>.Create;
    FShortNames.Add(LowerCase(AName), Keys);
  end;
  if not Keys.Contains(AKey) then Keys.Add(AKey);
end;

function TParser.ExportKeys(const AName: string): TArray<string>;
var
  Keys: TList<string>;
begin
  if FShortNames.TryGetValue(LowerCase(AName), Keys) then Result := Keys.ToArray
  else Result := nil;
end;

procedure TParser.CheckConstantIndex(AIndex: TExpression; ALength: Int64);
var
  Value: TConstantValue;
  Index: Int64;
begin
  // The same evaluator drives O1, so anything it may fold is checked here.
  if not EvaluateConstant(AIndex, Value) then Exit;
  if IsSignedInteger(Value.DataType) then Index := SignedValue(Value.Bits, Value.DataType)
  else
  begin
    if Value.Bits > UInt64(High(Int64)) then
      raise EShaderError.Create(AIndex.Position, 'Constant index is out of bounds');
    Index := Value.Bits;
  end;
  if Index < 0 then
    raise EShaderError.Create(AIndex.Position, 'Constant index is out of bounds (negative)');
  if (ALength >= 0) and (Index >= ALength) then
    raise EShaderError.Create(AIndex.Position, 'Constant array index is out of bounds');
end;

function TParser.CurrentOwner: string;
begin
  if FActiveLibrary = nil then Result := '@root' else Result := FActiveLibrary.ModuleName;
end;

function TParser.SymbolKey(const AOwner, AName: string): string;
begin
  if AOwner = '@root' then Result := '.' + LowerCase(AName)
  else Result := LowerCase(AOwner + '.' + AName);
end;

function TParser.PeekToken: TToken;
begin
  if not FHasLookahead then
  begin
    FLookahead := FLexer.Next;
    FHasLookahead := True;
  end;
  Result := FLookahead;
end;

function TParser.ReadOwnerPrefix(ATypeContext: Boolean): string;
var D: TSourceDocument;
begin
  Result := '';
  if (FProgram = nil) or (FToken.Kind <> tkIdentifier) then Exit;
  if not ATypeContext and (FLocalSymbols.ContainsKey(LowerCase(FToken.Text)) or
    FSymbols.ContainsKey(LowerCase(FToken.Text))) then Exit;
  if PeekToken.Kind <> tkDot then Exit;
  for D in FProgram.Libraries do
    if SameText(D.ModuleName, FToken.Text) then
    begin
      if not ModuleVisible(D.ModuleName) then Fail('Module is not visible; add it to uses');
      Result := D.ModuleName;
      Next; Expect(tkDot, '"."');
      if FToken.Kind <> tkIdentifier then Fail('Expected an exported identifier after module name');
      Exit;
    end;
end;

function TParser.FindType(const AName, AOwner: string; out AReference: TTypeReference; AReportScope: Boolean): Boolean;
var Key: string; Candidate: TTypeReference; Count: Integer; Seen: Boolean;
begin
  if AOwner <> '' then
  begin
    if (AOwner <> '@root') and not ModuleVisible(AOwner) then Fail('Module is not visible; add it to uses');
    Exit(FNamedTypes.TryGetValue(SymbolKey(AOwner, AName), AReference));
  end;
  if FNamedTypes.TryGetValue(SymbolKey(CurrentOwner, AName), AReference) then Exit(True);
  Count := 0; Seen := False;
  for Key in ExportKeys(AName) do
    if FNamedTypes.TryGetValue(Key, Candidate) then
    begin
      Seen := True;
      if ModuleVisible(Candidate.ModuleName) then begin AReference := Candidate; Inc(Count); end;
    end;
  if Count > 1 then Fail('Ambiguous type name; use Module.Type');
  if (Count = 0) and Seen and AReportScope then Fail('Type belongs to another module; add it to uses');
  Result := Count = 1;
end;

function TParser.FindFunction(const AName, AOwner: string; out AFunction: TShaderFunction; AReportScope: Boolean): Boolean;
var Key: string; Candidate: TShaderFunction; Count: Integer; Seen: Boolean;
begin
  if AOwner <> '' then
  begin
    if (AOwner <> '@root') and not ModuleVisible(AOwner) then Fail('Module is not visible; add it to uses');
    Exit(FFunctions.TryGetValue(SymbolKey(AOwner, AName), AFunction));
  end;
  if FLocalFunctions.TryGetValue(LowerCase(AName), AFunction) then Exit(True);
  if FFunctions.TryGetValue(SymbolKey(CurrentOwner, AName), AFunction) then Exit(True);
  Count := 0; Seen := False;
  for Key in ExportKeys(AName) do
    if FFunctions.TryGetValue(Key, Candidate) then
    begin
      Seen := True;
      if ModuleVisible(Candidate.ModuleName) then begin AFunction := Candidate; Inc(Count); end;
    end;
  if Count > 1 then Fail('Ambiguous function name; use Module.Function');
  if (Count = 0) and Seen and AReportScope then Fail('Function belongs to another module; add it to uses');
  Result := Count = 1;
end;

function TParser.FindConstant(const AName, AOwner: string; out AExpression: TExpression; AReportScope: Boolean): Boolean;
var Key: string; Candidate: TExpression; Count: Integer; Seen: Boolean;
begin
  if AOwner <> '' then
  begin
    if (AOwner <> '@root') and not ModuleVisible(AOwner) then Fail('Module is not visible; add it to uses');
    Exit(FConstants.TryGetValue(SymbolKey(AOwner, AName), AExpression));
  end;
  if FLocalConstants.TryGetValue(LowerCase(AName), AExpression) then Exit(True);
  if FConstants.TryGetValue(SymbolKey(CurrentOwner, AName), AExpression) then Exit(True);
  Count := 0; Seen := False;
  for Key in ExportKeys(AName) do
    if FConstants.TryGetValue(Key, Candidate) then
    begin
      Seen := True;
      if ModuleVisible(FConstantOwners[Key]) then begin AExpression := Candidate; Inc(Count); end;
    end;
  if Count > 1 then Fail('Ambiguous constant name; use Module.Constant');
  if (Count = 0) and Seen and AReportScope then Fail('Constant belongs to another module; add it to uses');
  Result := Count = 1;
end;

function TParser.ModuleVisible(const AName: string): Boolean;
var
  Name: string;
begin
  if FActiveLibrary = nil then Exit(True);
  if SameText(AName, FActiveLibrary.ModuleName) then Exit(True);
  for Name in FActiveLibrary.VisibleModules do if SameText(Name, AName) then Exit(True);
  Result := False;
end;

destructor TParser.Destroy;
begin
  FModule.Free;
  FShortNames.Free;
  FScopes.Free;
  FLocalFunctions.Free;
  FLocalConstants.Free;
  FConstantStorage.Free;
  FConstantOwners.Free;
  FConstants.Free;
  FFunctions.Free;
  FNamedTypes.Free;
  FLocalSymbols.Free;
  FSymbols.Free;
  FLexer.Free;
  inherited;
end;

procedure TParser.Next;
begin
  if FHasLookahead then begin FToken := FLookahead; FHasLookahead := False; end
  else FToken := FLexer.Next;
  if FToken.Kind = tkInclude then
    Fail('Includes require file compilation; use TShaderCompiler.CompileFile');
end;

procedure TParser.Fail(const AMessage: string);
begin
  raise EShaderError.Create(FToken.Position, AMessage);
end;

function TParser.IsWord(const AWord: string): Boolean;
begin
  Result := (FToken.Kind = tkIdentifier) and SameText(FToken.Text, AWord);
end;

procedure TParser.ExpectWord(const AWord: string);
begin
  if not IsWord(AWord) then
    Fail(Format('Expected "%s", found "%s"', [AWord, FToken.Text]));
  Next;
end;

procedure TParser.Expect(AKind: TTokenKind; const ADescription: string);
begin
  if FToken.Kind <> AKind then
    Fail(Format('Expected %s, found "%s"', [ADescription, FToken.Text]));
  Next;
end;

function TParser.ReadName(ADeclaration: Boolean): TToken;
const
  Reserved = '|begin|end|var|procedure|function|if|then|else|while|do|' +
    'array|of|record|integer|cardinal|single|boolean|true|false|div|mod|' +
    'and|or|xor|not|shl|shr|main|globalinvocationid|program|unit|module|uses|' +
    'type|const|out|result|default|for|to|downto|repeat|until|case|break|continue|exit|' +
    'atomicadd|atomicexchange|atomiccompareexchange|barrier|buffermemorybarrier|imagememorybarrier|' +
    'imageload|imagestore|imagesize|samplelevel|texture2d|sampler|';
var
  DataType: TShaderType;
  Intrinsic: TIntrinsic;
  Reference: TTypeReference;
  ImageFormat: TImageFormat;
  Builtin: TInvocationBuiltin;
begin
  if FToken.Kind <> tkIdentifier then
    Fail('Expected an identifier');
  if IsReservedIdentifier(FToken.Text) or (Pos('|' + LowerCase(FToken.Text) + '|', Reserved) <> 0) or
    TryShaderType(FToken.Text, DataType) or TryIntrinsic(FToken.Text, Intrinsic) or
    TryImageType(FToken.Text, ImageFormat) or TryBuiltin(FToken.Text, Builtin) or
    (not ADeclaration and FindType(FToken.Text, '', Reference, False)) then
    Fail(Format('"%s" is reserved', [FToken.Text]));
  Result := FToken;
  Next;
end;

function TParser.ReadUInt: Cardinal;
var
  E: TExpression;
  V: TConstantValue;
begin
  E := ParseExpression;
  try
    if not EvaluateConstant(E, V) or not IsScalarIntegerType(V.DataType) or
      (V.Bits > High(Cardinal)) or
      (IsSignedInteger(V.DataType) and (SignedValue(V.Bits, V.DataType) < 0)) then
      Fail('Expected a nonnegative 32-bit integer constant expression');
    Result := V.Bits;
  finally E.Free; end;
end;

function TParser.ReadType(out AComposite: TCompositeType): TShaderType;
var
  Reference: TTypeReference;
  Name: TToken;
  Field, Other: TTypeField;
  Upper: Cardinal;
  Owner: string;
  FirstField, I: Integer;
  FieldType: TShaderType;
  FieldComposite: TCompositeType;
  Lengths: TArray<Cardinal>;
  Inner, Dimension: TCompositeType;
begin
  Inc(FTypeDepth);
  try
    if FTypeDepth > 32 then Fail('Composite type nesting exceeds 32 levels');
    AComposite := nil;
    Owner := ReadOwnerPrefix(True);
    if (Owner = '') and (FToken.Kind = tkIdentifier) and TryShaderType(FToken.Text, Result) then
    begin
      Next;
      Exit;
    end;
    if FindType(FToken.Text, Owner, Reference) and
      (FToken.Kind = tkIdentifier) then
    begin
      if not ModuleVisible(Reference.ModuleName) then
        Fail('Type belongs to module ' + Reference.ModuleName + '; add it to uses');
      Result := Reference.DataType;
      AComposite := Reference.Composite;
      Next;
      Exit;
    end;
    if Owner <> '' then Fail('Unknown exported type in module ' + Owner);
    if IsWord('set') then
    begin
      // set of TEnum: a 32-bit mask, bit N = ordinal N (Delphi set layout from 0).
      Next;
      ExpectWord('of');
      if ReadType(AComposite) <> stEnum then Fail('Sets require an enumeration element type: set of TEnum');
      if EnumHigh(AComposite) > 31 then Fail('Set elements must have ordinal values 0..31');
      Exit(stSet);
    end;
    if FToken.Kind = tkLeftParen then
      Fail('Enumerations must be declared as named types in a type section');
    if not IsWord('record') and not IsWord('array') then
    begin
      if SameText(FToken.Text, FDefiningType) and (FDefiningType <> '') then
        Fail('Recursive or forward type references are not supported');
      Fail('Expected Integer, Cardinal, Single, Boolean, a numeric vector type or a declared aggregate type');
    end;
    Result := stComposite;
    AComposite := TCompositeType.Create;
    AComposite.ID := FModule.Types.Count;
    AComposite.Name := '$anonymous' + IntToStr(AComposite.ID);
    AComposite.Position := FToken.Position;
    FModule.Types.Add(AComposite);
    if IsWord('record') then
    begin
      AComposite.Kind := ctRecord;
      Next;
      while not IsWord('end') do
      begin
        // "A, B: T;" declares several fields of one type, in source order.
        FirstField := AComposite.Fields.Count;
        repeat
          Name := ReadName;
          for Other in AComposite.Fields do
            if SameText(Other.Name, Name.Text) then
              raise EShaderError.Create(Name.Position, 'Duplicate record field');
          Field := TTypeField.Create;
          AComposite.Fields.Add(Field);
          Field.Name := Name.Text;
          Field.Position := Name.Position;
          if AComposite.Fields.Count > 1024 then Fail('Records are limited to 1024 fields');
          if FToken.Kind <> tkComma then Break;
          Next;
        until False;
        Expect(tkColon, '":"');
        FieldType := ReadType(FieldComposite);
        for I := FirstField to AComposite.Fields.Count - 1 do
        begin
          AComposite.Fields[I].DataType := FieldType;
          AComposite.Fields[I].Composite := FieldComposite;
        end;
        Expect(tkSemicolon, '";"');
      end;
      if AComposite.Fields.Count = 0 then Fail('Records must not be empty');
      Next;
    end
    else
    begin
      AComposite.Kind := ctArray;
      Next;
      Expect(tkLeftBracket, '"[" for a static array');
      // array[0..A, 0..B] of T is array[0..A] of array[0..B] of T, as in Delphi.
      Lengths := nil;
      repeat
        if ReadUInt <> 0 then Fail('Static arrays must have a zero lower bound');
        Expect(tkDot, '".."');
        Expect(tkDot, '".."');
        Upper := ReadUInt;
        if Upper >= MaxStaticArrayLength then Fail('Static arrays are limited to 65536 elements');
        Lengths := Lengths + [Upper + 1];
        if FToken.Kind <> tkComma then Break;
        Next;
      until False;
      Expect(tkRightBracket, '"]"');
      ExpectWord('of');
      AComposite.Length := Lengths[0];
      Inner := AComposite;
      for I := 1 to High(Lengths) do
      begin
        Dimension := TCompositeType.Create;
        Dimension.ID := FModule.Types.Count;
        Dimension.Name := '$anonymous' + IntToStr(Dimension.ID);
        Dimension.Position := AComposite.Position;
        Dimension.Kind := ctArray;
        Dimension.Length := Lengths[I];
        FModule.Types.Add(Dimension);
        Inner.ElementType := stComposite;
        Inner.ElementComposite := Dimension;
        Inner := Dimension;
      end;
      Inner.ElementType := ReadType(Inner.ElementComposite);
      // Inner dimensions need their layout before the enclosing ones.
      for I := High(Lengths) downto 1 do
      begin
        Dimension := AComposite;
        for var J := 1 to I do Dimension := Dimension.ElementComposite;
        CalculateLayout(Dimension);
      end;
    end;
    CalculateLayout(AComposite);
  finally
    Dec(FTypeDepth);
  end;
end;

procedure TParser.ParseTypes;
var
  Name: TToken;
  Reference: TTypeReference;
  FirstID: Integer;
begin
  ExpectWord('type');
  if IsWord('var') or IsWord('const') or IsWord('type') or IsWord('function') or IsWord('procedure') or
    (FToken.Kind in [tkEOF, tkLeftBracket]) then
    Fail('Expected at least one type declaration');
  while not IsWord('var') and not IsWord('const') and not IsWord('type') and not IsWord('function') and
    not IsWord('procedure') and (FToken.Kind <> tkLeftBracket) and (FToken.Kind <> tkEOF) do
  begin
    if FNamedTypes.ContainsKey(SymbolKey(CurrentOwner, FToken.Text)) then Fail('Duplicate type name');
    if FFunctions.ContainsKey(SymbolKey(CurrentOwner, FToken.Text)) or FConstants.ContainsKey(SymbolKey(CurrentOwner, FToken.Text)) then Fail('Duplicate identifier for type name');
    Name := ReadName(True);
    Expect(tkEqual, '"="');
    FDefiningType := Name.Text;
    FirstID := FModule.Types.Count;
    if FToken.Kind = tkLeftParen then
    begin
      Reference.DataType := stEnum;
      Reference.Composite := ParseEnumeration(Name.Text);
    end
    else
      Reference.DataType := ReadType(Reference.Composite);
    if FActiveLibrary <> nil then Reference.ModuleName := FActiveLibrary.ModuleName
    else Reference.ModuleName := '';
    FDefiningType := '';
    if (Reference.Composite <> nil) and (Reference.Composite.ID >= FirstID) then
      if FActiveLibrary <> nil then Reference.Composite.Name := FActiveLibrary.ModuleName + '.' + Name.Text
      else Reference.Composite.Name := Name.Text;
    FNamedTypes.Add(SymbolKey(CurrentOwner, Name.Text), Reference);
    RegisterExport(SymbolKey(CurrentOwner, Name.Text), Name.Text);
    Expect(tkSemicolon, '";"');
  end;
end;

// TName = (A, B = 5, C): enumerators are constants of the new type in the
// enclosing module. Ordinals default to previous + 1, explicit values are
// nonnegative 32-bit constant expressions (Ord of earlier enumerators allowed).
function TParser.ParseEnumeration(const ATypeName: string): TCompositeType;
var
  Enumerator: TToken;
  Field: TTypeField;
  Value: Int64;
  E, C: TExpression;
  V: TConstantValue;
  Key, Owner: string;
begin
  Result := TCompositeType.Create;
  Result.ID := FModule.Types.Count;
  Result.Name := '$anonymous' + IntToStr(Result.ID);
  Result.Position := FToken.Position;
  Result.Kind := ctEnum;
  FModule.Types.Add(Result);
  if FActiveLibrary = nil then Owner := '' else Owner := FActiveLibrary.ModuleName;
  Expect(tkLeftParen, '"("');
  Value := 0;
  repeat
    Enumerator := ReadName(True);
    Key := SymbolKey(CurrentOwner, Enumerator.Text);
    if FConstants.ContainsKey(Key) or FNamedTypes.ContainsKey(Key) or FFunctions.ContainsKey(Key) or
      SameText(Enumerator.Text, ATypeName) or FSymbols.ContainsKey(LowerCase(Enumerator.Text)) then
      raise EShaderError.Create(Enumerator.Position, Format('Duplicate identifier "%s"', [Enumerator.Text]));
    if FToken.Kind = tkEqual then
    begin
      Next;
      E := ParseExpression;
      try
        if not EvaluateConstant(E, V) or not IsScalarIntegerType(V.DataType) then
          raise EShaderError.Create(E.Position, 'Expected an integer constant enumeration value');
        Value := SignedValue(V.Bits, V.DataType);
        if (V.DataType = stUInt64) and (V.Bits > UInt64(High(Int64))) then Value := -1;
      finally E.Free; end;
    end;
    if (Value < 0) or (Value > High(Integer)) then
      raise EShaderError.Create(Enumerator.Position, 'Enumeration values must be in 0..2147483647');
    if Result.Fields.Count >= 65536 then Fail('Enumerations are limited to 65536 values');
    Field := TTypeField.Create;
    Field.Name := Enumerator.Text;
    Field.Position := Enumerator.Position;
    Field.DataType := stEnum;
    Field.Composite := Result;
    Field.Offset := Cardinal(Value);
    Result.Fields.Add(Field);
    C := MakeConstant(stEnum, Cardinal(Value), False, Enumerator.Position);
    C.Composite := Result;
    FConstantStorage.Add(C);
    FConstants.Add(Key, C);
    RegisterExport(Key, Enumerator.Text);
    FConstantOwners.Add(Key, Owner);
    Inc(Value);
    if FToken.Kind <> tkComma then Break;
    Next;
  until False;
  Expect(tkRightParen, '")" after the enumeration values');
  Result.Length := Result.Fields.Count;
  Result.Size := 4;
  Result.Alignment := 4;
end;

procedure TParser.ParseConstants;
begin
  ExpectWord('const');
  if IsWord('type') or IsWord('var') or IsWord('function') or IsWord('procedure') or
    (FToken.Kind in [tkEOF, tkLeftBracket]) then Fail('Expected at least one constant declaration');
  while not IsWord('type') and not IsWord('var') and not IsWord('function') and not IsWord('procedure') and
    (FToken.Kind <> tkEOF) and (FToken.Kind <> tkLeftBracket) do
    ParseConstantDeclaration(False);
end;

// One "Name [: Type] = Value;". Global constants are module exports; local ones
// (function header const sections and inline const) are scoped by name only.
procedure TParser.ParseConstantDeclaration(ALocal: Boolean; AStatement: Boolean);
var
  Name: TToken;
  E: TExpression;
  V: TConstantValue;
  DataType: TShaderType;
  Composite: TCompositeType;
  Typed, Adaptable, InitializerAdaptable: Boolean;
  Key, Owner: string;
  Table: TShaderVariable;
  Existing: TExpression;
  Callee: TShaderFunction;
  Reference: TTypeReference;
  ValueComposite: TCompositeType;

  procedure Register(AExpression: TExpression);
  begin
    FConstantStorage.Add(AExpression);
    if ALocal then
    begin
      FLocalConstants.Add(LowerCase(Name.Text), AExpression);
      DeclareInScope(LowerCase(Name.Text));
      Exit;
    end;
    FConstants.Add(Key, AExpression);
    RegisterExport(Key, Name.Text);
    if FActiveLibrary = nil then Owner := '' else Owner := FActiveLibrary.ModuleName;
    FConstantOwners.Add(Key, Owner);
  end;

begin
  Name := ReadName(ALocal);
  if ALocal then
  begin
    // Local constants may not hide any visible identifier (no shadowing).
    if FLocalSymbols.ContainsKey(LowerCase(Name.Text)) or FSymbols.ContainsKey(LowerCase(Name.Text)) or
      FLocalConstants.ContainsKey(LowerCase(Name.Text)) or
      FindConstant(Name.Text, '', Existing, False) or FindFunction(Name.Text, '', Callee, False) or
      FindType(Name.Text, '', Reference, False) then
      raise EShaderError.Create(Name.Position, Format('Duplicate identifier "%s"; shadowing is not supported', [Name.Text]));
  end
  else
  begin
    Key := SymbolKey(CurrentOwner, Name.Text);
    if FConstants.ContainsKey(Key) or FNamedTypes.ContainsKey(Key) or FFunctions.ContainsKey(Key) then
      raise EShaderError.Create(Name.Position, 'Duplicate exported identifier');
  end;
  Typed := FToken.Kind = tkColon;
  DataType := stVoid;
  if Typed then
  begin
    Next; DataType := ReadType(Composite);
  end;
  Expect(tkEqual, '"="');
  // Arrays, records and vectors: a read-only constant table (Private storage).
  if Typed and ((DataType = stComposite) or (ComponentCount(DataType) > 1)) then
  begin
    E := ParseConstantInitializer(DataType, Composite);
    Table := TShaderVariable.Create;
    Table.Name := Name.Text; Table.Position := Name.Position;
    Table.Kind := vkConstant; Table.DataType := DataType; Table.Composite := Composite;
    Table.Access := baReadOnly;
    FModule.Constants.Add(Table, E);
    FModule.ConstantOrder.Add(Table);
    E := TExpression.Create; E.Kind := ekLocal;
    E.DataType := DataType; E.Composite := Composite; E.Variable := Table; E.Position := Name.Position;
    Register(E);
    if not AStatement then Expect(tkSemicolon, '";"');
    Exit;
  end;
  E := ParseExpression;
  try
    if not EvaluateConstant(E, V) then
      raise EShaderError.Create(Name.Position, 'Expected a defined scalar constant expression (no calls, reads or undefined arithmetic)');
    // Untyped integer constants behave like literals; typed ones keep their type.
    // A wrapped untyped initializer keeps its narrow type (1.0 behavior) and
    // must not be widened later as if it were the mathematical value.
    InitializerAdaptable := IsScalarIntegerType(V.DataType) and TreeAdaptable(E) and ExactNarrowConstant(E);
    if Typed and IsScalarIntegerType(V.DataType) and TreeAdaptable(E) and not InitializerAdaptable and
      (V.DataType <> DataType) and IsScalarIntegerType(DataType) then
      raise EShaderError.Create(Name.Position, Format(
        'Untyped constant expression wraps in %s before conversion to %s; use a typed operand',
        [ShaderTypeName(V.DataType), ShaderTypeName(DataType)]));
    Adaptable := not Typed and InitializerAdaptable;
    // Enumerations and sets keep their type identity.
    ValueComposite := E.Composite;
    if Typed then
    begin
      FreeAndNil(E); E := TExpression.Create;
      E.Kind := ekConstant; E.Position := Name.Position; E.DataType := V.DataType; E.Bits := V.Bits;
      E.Composite := ValueComposite;
      E.Adaptable := InitializerAdaptable;
      Convert(E, DataType, False, Composite);
      if not EvaluateConstant(E, V) then Fail('Invalid typed constant conversion');
      ValueComposite := Composite;
    end;
    FreeAndNil(E);
    E := TExpression.Create;
    E.Kind := ekConstant; E.Position := Name.Position; E.DataType := V.DataType; E.Bits := V.Bits;
    E.Composite := ValueComposite;
    E.Adaptable := Adaptable;
    Register(E);
    E := nil;
    if not AStatement then Expect(tkSemicolon, '";"');
  finally E.Free; end;
end;
function TParser.ParseConstantInitializer(AType: TShaderType; AComposite: TCompositeType): TExpression;
var
  I: Cardinal;
  V: TConstantValue;
  Field: TTypeField;
  Count: Integer;
  Value, Element: TExpression;
begin
  Count := ComponentCount(AType);
  if (AType <> stComposite) and (Count <= 1) then
  begin
    Result := ParseExpression;
    try
      Convert(Result, AType, False, AComposite);
      if not EvaluateConstant(Result, V) then Fail('Expected a defined constant element');
      FreeAndNil(Result); Result := TExpression.Create;
      Result.Kind := ekConstant; Result.DataType := V.DataType; Result.Composite := AComposite;
      Result.Bits := V.Bits;
      Exit;
    except Result.Free; raise; end;
  end;
  Result := TExpression.Create; Result.Kind := ekConstantArray;
  Result.Position := FToken.Position; Result.DataType := AType; Result.Composite := AComposite;
  try
    if (AType <> stComposite) and (FToken.Kind <> tkLeftParen) then
    begin
      // Single3(1, 2, 3) or Single3(0): a constructor whose arguments are constants.
      Value := ParseExpression;
      try
        Convert(Value, AType);
        if Value.Kind <> ekConstruct then
          raise EShaderError.Create(Value.Position, 'Expected a constant vector: (X, Y, ...) or a constructor of constants');
        for I := 0 to Count - 1 do
        begin
          if Value.Arguments.Count = 1 then Element := Value.Arguments[0]
          else Element := Value.Arguments[I];
          if not EvaluateConstant(Element, V) then
            raise EShaderError.Create(Element.Position, 'Expected a defined constant element');
          Result.Arguments.Add(MakeConstant(V.DataType, V.Bits, False, Element.Position));
        end;
      finally
        Value.Free;
      end;
    end
    else if AType <> stComposite then
    begin
      // Vector: (X, Y[, Z[, W]]).
      Expect(tkLeftParen, '"(" for a constant vector initializer');
      for I := 0 to Count - 1 do
      begin
        Result.Arguments.Add(ParseConstantInitializer(ComponentType(AType), nil));
        if Integer(I) + 1 < Count then Expect(tkComma, '"," between vector components');
      end;
      Expect(tkRightParen, '")" after the vector components');
    end
    else if AComposite.Kind = ctRecord then
    begin
      // Record: (Field: Value; ...) listing every field in declaration order, as in Delphi.
      Expect(tkLeftParen, '"(" for a constant record initializer');
      for I := 0 to AComposite.Fields.Count - 1 do
      begin
        Field := AComposite.Fields[I];
        if not IsWord(Field.Name) then
          Fail(Format('Expected field "%s": record constants list every field in declaration order', [Field.Name]));
        Next;
        Expect(tkColon, '":"');
        Result.Arguments.Add(ParseConstantInitializer(Field.DataType, Field.Composite));
        if Integer(I) + 1 < AComposite.Fields.Count then Expect(tkSemicolon, '";" between record fields')
        else if FToken.Kind = tkSemicolon then Next;
      end;
      Expect(tkRightParen, '")" after the record fields');
    end
    else
    begin
      if AComposite.Length > 65532 then Fail('A constant array dimension is limited to 65532 elements');
      Expect(tkLeftParen, '"(" for a constant array initializer');
      for I := 0 to AComposite.Length - 1 do
      begin
        Result.Arguments.Add(ParseConstantInitializer(AComposite.ElementType, AComposite.ElementComposite));
        if I + 1 < AComposite.Length then Expect(tkComma, '"," between constant array elements');
      end;
      Expect(tkRightParen, '")" after the exact number of array elements');
    end;
  except Result.Free; raise; end;
end;

function TParser.ReadAttributes: TAttributes;
var
  Name: string;
  I: Integer;
begin
  Result := Default(TAttributes);
  Result.Access := baReadWrite;
  while FToken.Kind = tkLeftBracket do
  begin
    Next;
    repeat
      if FToken.Kind <> tkIdentifier then
        Fail('Expected an attribute name');
      Name := LowerCase(FToken.Text);
      Next;
      Result.HasAny := True;
      if Name = 'binding' then
      begin
        if Result.HasBinding then
          Fail('Duplicate Binding attribute');
        Result.HasBinding := True;
        Expect(tkLeftParen, '"("');
        Result.DescriptorSet := ReadUInt;
        Expect(tkComma, '","');
        Result.Binding := ReadUInt;
        Expect(tkRightParen, '")"');
      end
      else if (Name = 'readonly') or (Name = 'writeonly') or (Name = 'readwrite') then
      begin
        if Result.HasAccess then
          Fail('Duplicate or conflicting buffer access attributes');
        Result.HasAccess := True;
        if Name = 'readonly' then
          Result.Access := baReadOnly
        else if Name = 'writeonly' then
          Result.Access := baWriteOnly
        else
          Result.Access := baReadWrite;
      end
      else if Name = 'pushconstant' then
      begin
        if Result.HasPushConstant then
          Fail('Duplicate PushConstant attribute');
        Result.HasPushConstant := True;
      end
      else if Name = 'shared' then
      begin
        if Result.HasShared then Fail('Duplicate Shared attribute');
        Result.HasShared := True;
      end
      else if Name = 'localsize' then
      begin
        if Result.HasLocalSize then
          Fail('Duplicate LocalSize attribute');
        Result.HasLocalSize := True;
        Expect(tkLeftParen, '"("');
        for I := 0 to 2 do
        begin
          Result.LocalSize[I] := ReadUInt;
          if (Result.LocalSize[I] = 0) or (Result.LocalSize[I] > 1024) then
            Fail('LocalSize dimensions must be in 1..1024');
          if I < 2 then
            Expect(tkComma, '","');
        end;
        Expect(tkRightParen, '")"');
        if UInt64(Result.LocalSize[0]) * Result.LocalSize[1] *
          Result.LocalSize[2] > 1024 then
          Fail('LocalSize must not exceed 1024 invocations per workgroup');
      end
      else if Name = 'vulkan12' then
      begin
        if Result.HasVulkan12 then Fail('Duplicate Vulkan12 attribute');
        Result.HasVulkan12 := True;
      end
      else if Name = 'strictfloat' then
      begin
        if Result.HasStrictFloat then Fail('Duplicate StrictFloat attribute');
        Result.HasStrictFloat := True;
      end
      else if Name = 'aliased' then
      begin
        if Result.HasAliased then Fail('Duplicate Aliased attribute');
        Result.HasAliased := True;
      end
      else
        Fail(Format('Unknown attribute "%s"', [Name]));
      if FToken.Kind <> tkComma then
        Break;
      Next;
    until False;
    Expect(tkRightBracket, '"]"');
  end;
end;

procedure TParser.AddSymbol(AVariable: TShaderVariable);
var
  Key: string;
  ShaderFunction: TShaderFunction;
  ConstantExpression: TExpression;
begin
  Key := LowerCase(AVariable.Name);
  // The routine being declared is registered after its heading.
  if (FCurrentFunction <> nil) and (AVariable.Kind = vkParameter) and SameText(AVariable.Name, FCurrentFunction.Name) or
    FSymbols.ContainsKey(Key) or FLocalSymbols.ContainsKey(Key) or
    FindFunction(AVariable.Name, '', ShaderFunction, False) or FindConstant(AVariable.Name, '', ConstantExpression, False) then
    raise EShaderError.Create(AVariable.Position,
      Format('Duplicate identifier "%s"; shadowing is not supported', [AVariable.Name]));
  if AVariable.Kind in [vkLocal, vkParameter, vkResult] then
    FLocalSymbols.Add(Key, AVariable)
  else
    FSymbols.Add(Key, AVariable);
end;

procedure TParser.ParseResource(const AAttributes: TAttributes);
var
  Name: TToken;
  Variable, Other: TShaderVariable;
begin
  if FModule.Resources.Count >= MaxResources then
    Fail(Format('Shader resources are limited to %d', [MaxResources]));
  if AAttributes.HasLocalSize then
    Fail('LocalSize is only valid on procedure Main');
  if AAttributes.HasVulkan12 or AAttributes.HasStrictFloat then
    Fail('Vulkan12/StrictFloat are only valid on procedure Main');
  Name := ReadName;
  Variable := TShaderVariable.Create;
  FModule.Resources.Add(Variable);
  Variable.Name := Name.Text;
  Variable.Position := Name.Position;
  if AAttributes.HasPushConstant then
    Variable.Kind := vkPushConstant
  else
    Variable.Kind := vkBuffer;
  AddSymbol(Variable);
  Expect(tkColon, '":"');
  if AAttributes.HasPushConstant then
  begin
    if AAttributes.HasBinding or AAttributes.HasAccess then
      Fail('Push constants cannot have Binding or access attributes');
    for Other in FModule.Resources do
      if (Other <> Variable) and (Other.Kind = vkPushConstant) then
        Fail('Only one push-constant block is supported');
    Variable.DataType := ReadType(Variable.Composite);
    if (Variable.DataType <> stComposite) or (Variable.Composite.Kind <> ctRecord) then
      Fail('Push constants require a record type');
    if Variable.Composite.Size > 128 then
      Fail('Push constants are limited to 128 bytes in this version');
  end
  else
  begin
    if AAttributes.HasShared then
    begin
      if AAttributes.HasBinding or AAttributes.HasAccess then Fail('Shared variables cannot have bindings or access attributes');
      Variable.Kind := vkShared;
      Variable.Access := baReadWrite;
      Variable.DataType := ReadType(Variable.Composite);
      if (Variable.DataType <> stComposite) or (Variable.Composite.Kind <> ctArray) or
        not (Variable.Composite.ElementType in [stInteger, stCardinal, stSingle]) then
        Fail('Shared memory requires a static one-dimensional array of Integer, Cardinal or Single');
      Inc(FModule.SharedBytes, Variable.Composite.Size);
      if FModule.SharedBytes > 16384 then Fail('Shared memory exceeds the portable 16 KiB compiler limit');
    end
    else if TryImageType(FToken.Text, Variable.ImageFormat) then
    begin
      Variable.Kind := vkImage; Variable.DataType := ImagePixelType(Variable.ImageFormat);
      Variable.Access := AAttributes.Access;
      Next;
    end
    else if IsWord('Texture2D') then
    begin
      Variable.Kind := vkTexture; Variable.DataType := stSingle4;
      if AAttributes.HasAccess and (AAttributes.Access <> baReadOnly) then Fail('Texture2D is read-only');
      Variable.Access := baReadOnly; Next;
    end
    else if IsWord('Sampler') then
    begin
      Variable.Kind := vkSampler;
      if AAttributes.HasAccess then Fail('Sampler cannot have buffer access attributes');
      Next;
    end
    else
    begin
    if not AAttributes.HasBinding then
      Fail('Storage buffers require [Binding(descriptorSet, binding)]');
    Variable.DescriptorSet := AAttributes.DescriptorSet;
    Variable.Binding := AAttributes.Binding;
    Variable.Access := AAttributes.Access;
    ExpectWord('array');
    ExpectWord('of');
    Variable.DataType := ReadType(Variable.Composite);
    if Variable.DataType = stBoolean then
      Fail('Boolean is not supported in GPU resource layouts; use Cardinal');
    for Other in FModule.Resources do
      if (Other <> Variable) and (Other.Kind = vkBuffer) and
        (Other.DescriptorSet = Variable.DescriptorSet) and
        (Other.Binding = Variable.Binding) then
        Fail('Duplicate descriptor set and binding');
    end;
  end;
  if AAttributes.HasShared and AAttributes.HasPushConstant then Fail('Shared and PushConstant conflict');
  if Variable.Kind in [vkBuffer, vkImage, vkTexture, vkSampler] then
  begin
    if not AAttributes.HasBinding then Fail('GPU descriptors require Binding(set, binding)');
    Variable.DescriptorSet := AAttributes.DescriptorSet; Variable.Binding := AAttributes.Binding;
    for Other in FModule.Resources do
      if (Other <> Variable) and (Other.Kind in [vkBuffer,vkImage,vkTexture,vkSampler]) and
        (Other.DescriptorSet = Variable.DescriptorSet) and (Other.Binding = Variable.Binding) then
        Fail('Duplicate descriptor set and binding');
  end;
  if Variable.Kind in [vkBuffer, vkPushConstant] then RequireExternalLayout(Variable.DataType, Variable.Composite);
  if AAttributes.HasAliased then
  begin
    if Variable.Kind <> vkBuffer then Fail('Aliased is only valid on storage buffers');
    Variable.Aliased := True;
  end;
  Expect(tkSemicolon, '";"');
end;

procedure TParser.ParseParameters;
var
  Name: TToken;
  Parameter: TShaderVariable;
  Group: TList<TShaderVariable>;
  DataType: TShaderType;
  Composite: TCompositeType;
  Mode: TParameterMode;
begin
  Expect(tkLeftParen, '"("');
  Group := TList<TShaderVariable>.Create;
  try
    if FToken.Kind <> tkRightParen then
      repeat
        Mode := pmValue;
        if IsWord('var') then Mode := pmVar
        else if IsWord('out') then Mode := pmOut
        else if IsWord('const') then Mode := pmConst;
        if Mode <> pmValue then Next;
        Group.Clear;
        repeat
          Name := ReadName;
          if FCurrentFunction.Parameters.Count >= MaxShaderParameters then
            Fail('Functions are limited to 255 parameters by the portable SPIR-V profile');
          if FCurrentFunction.Locals.Count + FCurrentFunction.Parameters.Count >= MaxFunctionVariables then
            Fail(Format('A function is limited to %d parameters and local variables', [MaxFunctionVariables]));
          Parameter := TShaderVariable.Create;
          FCurrentFunction.Parameters.Add(Parameter);
          Parameter.Name := Name.Text;
          Parameter.Position := Name.Position;
          Parameter.Kind := vkParameter;
          Parameter.Owner := FCurrentFunction;
          Parameter.ParameterMode := Mode;
          Parameter.Initialized := Mode <> pmOut;
          AddSymbol(Parameter);
          Group.Add(Parameter);
          if FToken.Kind <> tkComma then
            Break;
          Next;
        until False;
        Expect(tkColon, '":"');
        DataType := ReadType(Composite);
        for Parameter in Group do
        begin
          Parameter.DataType := DataType;
          Parameter.Composite := Composite;
        end;
        if FToken.Kind <> tkSemicolon then
          Break;
        Next;
      until False;
    Expect(tkRightParen, '")"');
  finally
    Group.Free;
  end;
end;

function SameParameterTypes(A, B: TShaderFunction): Boolean;
var I: Integer;
begin
  if A.Parameters.Count <> B.Parameters.Count then Exit(False);
  for I := 0 to A.Parameters.Count - 1 do
    if (A.Parameters[I].DataType <> B.Parameters[I].DataType) or
      (A.Parameters[I].Composite <> B.Parameters[I].Composite) then Exit(False);
  Result := True;
end;

function SameHeading(A, B: TShaderFunction): Boolean;
var I: Integer;
begin
  if not SameParameterTypes(A, B) or (A.ReturnType <> B.ReturnType) or
    (A.ReturnComposite <> B.ReturnComposite) then Exit(False);
  for I := 0 to A.Parameters.Count - 1 do
    if (A.Parameters[I].ParameterMode <> B.Parameters[I].ParameterMode) or
      not SameText(A.Parameters[I].Name, B.Parameters[I].Name) then Exit(False);
  Result := True;
end;

function InOverloadChain(AHead, AFunction: TShaderFunction): Boolean;
begin
  while AHead <> nil do
  begin
    if AHead = AFunction then Exit(True);
    AHead := AHead.NextOverload;
  end;
  Result := False;
end;

// Header, directives (forward/overload) and body of a routine. Nested routines
// (ANested) are declared in the header of the current function: they see its
// earlier parameters, locals and constants, and are visible only inside it.
procedure TParser.ParseFunction(AEntryPoint: Boolean; const AAttributes: TAttributes; ANested: Boolean);
var
  Name: TToken;
  ShaderFunction, Existing, Target, Candidate, Last, SavedFunction, Global: TShaderFunction;
  Variable: TShaderVariable;
  I: Integer;
  IsProcedure, IsForwardDecl, IsOverloadDecl, Registered, Bare: Boolean;
  Key, LowerName: string;
  SavedSymbols: TDictionary<string, TShaderVariable>;
  SavedConstants: TDictionary<string, TExpression>;
  SavedFunctions: TDictionary<string, TShaderFunction>;
  Pair: TPair<string, TShaderVariable>;
  Reference: TTypeReference;
  ConstantExpression: TExpression;
begin
  IsProcedure := IsWord('procedure');
  if AEntryPoint then
  begin
    if AAttributes.HasBinding or AAttributes.HasAccess or AAttributes.HasPushConstant or AAttributes.HasShared or AAttributes.HasAliased then
      Fail('Only LocalSize is valid on procedure Main');
    ExpectWord('procedure');
    Name := FToken;
    ExpectWord('Main');
    Name.Text := 'Main';
    FModule.Extended := AAttributes.HasVulkan12;
    FModule.StrictFloat := AAttributes.HasStrictFloat;
    if AAttributes.HasLocalSize then
      for I := 0 to 2 do
        FModule.LocalSize[I] := AAttributes.LocalSize[I];
  end
  else
  begin
    if AAttributes.HasAny then
      Fail('Attributes are not supported on helper functions');
    if IsProcedure then ExpectWord('procedure') else ExpectWord('function');
    Name := ReadName(True);
  end;
  LowerName := LowerCase(Name.Text);
  Key := SymbolKey(CurrentOwner, Name.Text);
  Existing := nil;
  if ANested then
  begin
    // No shadowing: a nested routine name must not hide any visible identifier.
    if FLocalSymbols.ContainsKey(LowerName) or FLocalConstants.ContainsKey(LowerName) or
      FSymbols.ContainsKey(LowerName) or FindType(Name.Text, '', Reference, False) or
      FindConstant(Name.Text, '', ConstantExpression, False) then
      raise EShaderError.Create(Name.Position, Format('Duplicate identifier "%s"; shadowing is not supported', [Name.Text]));
    if not FLocalFunctions.TryGetValue(LowerName, Existing) and FindFunction(Name.Text, '', Global, False) then
      raise EShaderError.Create(Name.Position, Format('Duplicate identifier "%s"; shadowing is not supported', [Name.Text]));
  end
  else
  begin
    if FSymbols.ContainsKey(LowerName) or FNamedTypes.ContainsKey(Key) or FConstants.ContainsKey(Key) then
      raise EShaderError.Create(Name.Position, Format('Duplicate identifier "%s"', [Name.Text]));
    FFunctions.TryGetValue(Key, Existing);
    if AEntryPoint and (Existing <> nil) then
      raise EShaderError.Create(Name.Position, Format('Duplicate identifier "%s"', [Name.Text]));
  end;
  SavedFunction := FCurrentFunction;
  SavedSymbols := nil; SavedConstants := nil; SavedFunctions := nil;
  if ANested then
  begin
    I := 1;
    Global := SavedFunction;
    while Global.Outer <> nil do
    begin
      Inc(I);
      Global := Global.Outer;
    end;
    if I > MaxRoutineNesting then
      raise EShaderError.Create(Name.Position, Format('Nested routines are limited to %d levels', [MaxRoutineNesting]));
  end;
  if ANested then
  begin
    SavedSymbols := TDictionary<string, TShaderVariable>.Create(FLocalSymbols);
    SavedConstants := TDictionary<string, TExpression>.Create(FLocalConstants);
    SavedFunctions := TDictionary<string, TShaderFunction>.Create(FLocalFunctions);
  end;
  ShaderFunction := TShaderFunction.Create;
  Registered := False;
  ShaderFunction.Name := Name.Text;
  if FActiveLibrary <> nil then ShaderFunction.ModuleName := FActiveLibrary.ModuleName;
  ShaderFunction.Position := Name.Position;
  if ANested then ShaderFunction.Outer := SavedFunction;
  FCurrentFunction := ShaderFunction;
  if not ANested then
  begin
    FLocalSymbols.Clear;
    FLocalConstants.Clear;
    FLocalFunctions.Clear;
  end;
  FScopes.Clear;
  try
    try
      // "function F;" completes a single forward declaration without repeating it.
      Bare := not AEntryPoint and (Existing <> nil) and Existing.IsForward and (Existing.NextOverload = nil) and
        (FToken.Kind = tkSemicolon) and (IsProcedure = (Existing.ReturnType = stVoid));
      if AEntryPoint then
      begin
        ShaderFunction.ReturnType := stVoid;
      end
      else if not Bare then
      begin
        if FToken.Kind = tkLeftParen then
          ParseParameters;
        if not IsProcedure then
        begin
          Expect(tkColon, '":" before function return type');
          ShaderFunction.ReturnType := ReadType(ShaderFunction.ReturnComposite);
          Variable := TShaderVariable.Create;
          ShaderFunction.Locals.Add(Variable);
          ShaderFunction.ResultVariable := Variable;
          Variable.Name := 'Result';
          Variable.Position := Name.Position;
          Variable.Kind := vkResult;
          Variable.Owner := ShaderFunction;
          Variable.DataType := ShaderFunction.ReturnType;
          Variable.Composite := ShaderFunction.ReturnComposite;
          // A nested function's Result hides the enclosing function's Result.
          FLocalSymbols.Remove('result');
          AddSymbol(Variable);
        end
        else ShaderFunction.ReturnType := stVoid;
      end;
      Expect(tkSemicolon, '";"');
      IsForwardDecl := False;
      IsOverloadDecl := False;
      while not AEntryPoint and (IsWord('forward') or IsWord('overload')) do
      begin
        if IsWord('forward') then
        begin
          if IsForwardDecl then Fail('Duplicate forward directive');
          IsForwardDecl := True;
        end
        else
        begin
          if IsOverloadDecl then Fail('Duplicate overload directive');
          IsOverloadDecl := True;
        end;
        Next;
        Expect(tkSemicolon, '";"');
      end;
      // Call summaries of captured variables need the body before the first call.
      if ANested and IsForwardDecl then
        raise EShaderError.Create(Name.Position, 'Nested routines cannot be forward-declared');
      // Match an earlier declaration of the same name: complete a forward
      // declaration or add an overload (every version marked overload).
      Target := nil;
      Last := nil;
      Candidate := Existing;
      while Candidate <> nil do
      begin
        if Bare or SameParameterTypes(Candidate, ShaderFunction) then
        begin
          if not Candidate.IsForward or IsForwardDecl then
          begin
            if IsOverloadDecl and Candidate.IsOverload then
              raise EShaderError.Create(Name.Position, Format('Overload "%s" with these parameter types already exists', [Name.Text]));
            raise EShaderError.Create(Name.Position, Format('Duplicate identifier "%s"', [Name.Text]));
          end;
          if not Bare and not SameHeading(Candidate, ShaderFunction) then
            raise EShaderError.Create(Name.Position, Format('Declaration of "%s" differs from its forward declaration', [Name.Text]));
          Target := Candidate;
          Break;
        end;
        Last := Candidate;
        Candidate := Candidate.NextOverload;
      end;
      if (Existing <> nil) and (Target = nil) and (not IsOverloadDecl or not Existing.IsOverload) then
      begin
        if Existing.IsForward and not IsForwardDecl then
          raise EShaderError.Create(Name.Position, Format('Declaration of "%s" differs from its forward declaration', [Name.Text]));
        raise EShaderError.Create(Name.Position, Format(
          'Duplicate identifier "%s"; mark every version with overload', [Name.Text]));
      end;
      if Target <> nil then
      begin
        // Callers already reference the forward declaration: continue with it.
        FreeAndNil(ShaderFunction);
        ShaderFunction := Target;
        FCurrentFunction := Target;
        Target.IsForward := False;
        if ANested then
        begin
          FLocalSymbols.Clear;
          for Pair in SavedSymbols do FLocalSymbols.Add(Pair.Key, Pair.Value);
          if Target.ResultVariable <> nil then FLocalSymbols.Remove('result');
        end
        else FLocalSymbols.Clear;
        for Variable in Target.Parameters do AddSymbol(Variable);
        if Target.ResultVariable <> nil then AddSymbol(Target.ResultVariable);
      end
      else
      begin
        ShaderFunction.Index := FModule.Functions.Count;
        FModule.Functions.Add(ShaderFunction);
        Registered := True;
        ShaderFunction.IsForward := IsForwardDecl;
        ShaderFunction.IsOverload := IsOverloadDecl;
        if Last <> nil then Last.NextOverload := ShaderFunction
        else if ANested then
        begin
          FLocalFunctions.AddOrSetValue(LowerName, ShaderFunction);
          SavedFunctions.AddOrSetValue(LowerName, ShaderFunction);
        end
        else
        begin
          FFunctions.Add(Key, ShaderFunction);
          RegisterExport(Key, Name.Text);
        end;
        if AEntryPoint then FModule.EntryPoint := ShaderFunction;
      end;
      if IsForwardDecl then Exit;
      while IsWord('var') or IsWord('const') or IsWord('function') or IsWord('procedure') do
        ParseLocals;
      ShaderFunction.Body := ParseBlock;
      Expect(tkSemicolon, '";"');
      CheckDefiniteAssignment(ShaderFunction);
    except
      if not Registered and (ShaderFunction <> nil) and not FModule.Functions.Contains(ShaderFunction) then
        ShaderFunction.Free;
      raise;
    end;
  finally
    FCurrentFunction := SavedFunction;
    FScopes.Clear;
    if ANested then
    begin
      FLocalSymbols.Clear;
      for Pair in SavedSymbols do FLocalSymbols.Add(Pair.Key, Pair.Value);
      FLocalConstants.Clear;
      for var C in SavedConstants do FLocalConstants.Add(C.Key, C.Value);
      FLocalFunctions.Clear;
      for var F in SavedFunctions do FLocalFunctions.Add(F.Key, F.Value);
      SavedSymbols.Free;
      SavedConstants.Free;
      SavedFunctions.Free;
    end
    else
    begin
      FLocalSymbols.Clear;
      FLocalConstants.Clear;
      FLocalFunctions.Clear;
    end;
  end;
end;
function TParser.DeclareLocal(const AName: TToken; AType: TShaderType; AComposite: TCompositeType): TShaderVariable;
begin
  if FCurrentFunction.Locals.Count + FCurrentFunction.Parameters.Count >= MaxFunctionVariables then
    raise EShaderError.Create(AName.Position,
      Format('A function is limited to %d parameters and local variables', [MaxFunctionVariables]));
  Result := TShaderVariable.Create;
  FCurrentFunction.Locals.Add(Result);
  Result.Name := AName.Text;
  Result.Position := AName.Position;
  Result.Kind := vkLocal;
  Result.Owner := FCurrentFunction;
  Result.DataType := AType;
  Result.Composite := AComposite;
  AddSymbol(Result);
  DeclareInScope(LowerCase(AName.Text));
end;

// Header sections: var lists ("A, B: T;") and const declarations, in any order.
procedure TParser.ParseLocals;
var
  Names: TList<TToken>;
  Name: TToken;
  DataType: TShaderType;
  Composite: TCompositeType;

  function SectionEnd: Boolean;
  begin
    Result := IsWord('begin') or IsWord('var') or IsWord('const') or IsWord('function') or IsWord('procedure');
  end;

begin
  Names := TList<TToken>.Create;
  try
    while IsWord('var') or IsWord('const') or IsWord('function') or IsWord('procedure') do
    begin
      if IsWord('function') or IsWord('procedure') then
      begin
        ParseFunction(False, Default(TAttributes), True);
        Continue;
      end;
      if IsWord('const') then
      begin
        Next;
        if SectionEnd then
          Fail('Expected at least one local constant declaration');
        repeat ParseConstantDeclaration(True);
        until SectionEnd;
        Continue;
      end;
      Next;
      if SectionEnd then
        Fail('Expected at least one local variable declaration');
      while not SectionEnd do
      begin
        Names.Clear;
        repeat
          Name := ReadName;
          for var Other in Names do
            if SameText(Other.Text, Name.Text) then
              raise EShaderError.Create(Name.Position,
                Format('Duplicate identifier "%s"; shadowing is not supported', [Name.Text]));
          Names.Add(Name);
          if FToken.Kind <> tkComma then Break;
          Next;
        until False;
        Expect(tkColon, '":"');
        DataType := ReadType(Composite);
        for Name in Names do DeclareLocal(Name, DataType, Composite);
        Expect(tkSemicolon, '";"');
      end;
    end;
  finally
    Names.Free;
  end;
end;
procedure TParser.PushScope;
begin
  FScopes.Add(TList<string>.Create);
end;

procedure TParser.PopScope;
var
  Name: string;
begin
  for Name in FScopes.Last do
  begin
    FLocalSymbols.Remove(Name);
    FLocalConstants.Remove(Name);
  end;
  FScopes.Delete(FScopes.Count - 1);
end;

procedure TParser.DeclareInScope(const ALowerName: string);
begin
  if FScopes.Count > 0 then FScopes.Last.Add(ALowerName);
end;

// Inline declaration in a statement list: "var X: T;", "var X: T := E;",
// "var X := E;" (type inferred) or "const K [: T] = E;". Visible to the end of
// the enclosing block. Without an initializer the variable starts uninitialized
// on every execution of the declaration (also in a loop body).
function TParser.ParseInlineVar: TStatement;
var
  Name: TToken;
  DataType: TShaderType;
  Composite: TCompositeType;
  Value: TExpression;
  Variable: TShaderVariable;
begin
  Result := TStatement.Create;
  Result.Kind := skBlock;
  Result.Position := FToken.Position;
  try
    if IsWord('const') then
    begin
      Next;
      ParseConstantDeclaration(True, True);
      Exit;
    end;
    ExpectWord('var');
    Name := ReadName;
    DataType := stVoid;
    Composite := nil;
    Value := nil;
    try
      if FToken.Kind = tkColon then
      begin
        Next;
        DataType := ReadType(Composite);
      end;
      if FToken.Kind = tkAssign then
      begin
        Next;
        Value := ParseExpression;
        if DataType = stVoid then
        begin
          if Value.DataType in [stVoid] then
            raise EShaderError.Create(Value.Position, 'Cannot infer an inline variable type from a procedure call');
          if (Value.DataType = stSet) and (Value.Composite = nil) then
            raise EShaderError.Create(Value.Position, 'Cannot infer a set type from []; declare the variable type');
          DataType := Value.DataType;
          Composite := Value.Composite;
        end
        else
          Convert(Value, DataType, False, Composite);
      end
      else if DataType = stVoid then
        Fail('An inline variable needs a type or an initializer');
      Variable := DeclareLocal(Name, DataType, Composite);
      Result.Kind := skDeclare;
      Result.Target := TExpression.Create;
      Result.Target.Kind := ekLocal;
      Result.Target.Position := Name.Position;
      Result.Target.Variable := Variable;
      Result.Target.DataType := DataType;
      Result.Target.Composite := Composite;
      Result.Value := Value;
      Value := nil;
    finally
      Value.Free;
    end;
    // The ";" is consumed by the enclosing statement list.
  except
    Result.Free;
    raise;
  end;
end;
procedure TParser.EnterDepth;
begin
  Inc(FDepth);
  if FDepth > 128 then
    Fail('Shader nesting limit exceeded');
end;

procedure TParser.LeaveDepth;
begin
  Dec(FDepth);
end;

function TParser.Snapshot: TArray<Boolean>;
var
  I: Integer;
begin
  SetLength(Result, FCurrentFunction.Locals.Count);
  for I := 0 to FCurrentFunction.Locals.Count - 1 do
    Result[I] := FCurrentFunction.Locals[I].Initialized;
end;

procedure TParser.Restore(const AState: TArray<Boolean>);
var
  I: Integer;
begin
  for I := 0 to FCurrentFunction.Locals.Count - 1 do
    // Inline declarations may add locals after the snapshot: they start uninitialized.
    FCurrentFunction.Locals[I].Initialized := (I < Length(AState)) and AState[I];
end;

function StateAt(const AState: TArray<Boolean>; AIndex: Integer): Boolean;
begin
  Result := (AIndex < Length(AState)) and AState[AIndex];
end;

function TParser.ParseBlock: TStatement;
begin
  Result := TStatement.Create;
  Result.Kind := skBlock;
  Result.Position := FToken.Position;
  try
    ExpectWord('begin');
    PushScope;
    try
      while not IsWord('end') do
      begin
        if FToken.Kind = tkSemicolon then
        begin
          Next;
          Continue;
        end;
        Result.Children.Add(ParseStatement);
        if not IsWord('end') then
          Expect(tkSemicolon, '";"');
      end;
    finally
      PopScope;
    end;
    ExpectWord('end');
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ParseStatement: TStatement;
var
  BeforeState, ThenState, ElseState: TArray<Boolean>;
  I: Integer;
  Callee: TShaderFunction;
  Owner: string;
  Base, Element: TExpression;
begin
  EnterDepth;
  try
    if IsWord('begin') then
      Exit(ParseBlock);
    if IsWord('for') then
      Exit(ParseFor);
    if IsWord('var') or IsWord('const') then
      Exit(ParseInlineVar);
    if IsWord('case') then Exit(ParseCase);
    if IsWord('repeat') then Exit(ParseRepeat);
    Result := TStatement.Create;
    Result.Position := FToken.Position;
    try
      if IsWord('Inc') or IsWord('Dec') or IsWord('Include') or IsWord('Exclude') then
      begin
        // Inc(X [, N]) / Dec(X [, N]) / Include(S, E) / Exclude(S, E):
        // the address of the variable is evaluated once.
        Result.Kind := skIncrement;
        Result.Descending := IsWord('Dec');
        if IsWord('Inc') then Result.Operation := opAdd
        else if IsWord('Dec') then Result.Operation := opSubtract
        else if IsWord('Include') then Result.Operation := opOr
        else Result.Operation := opAnd;
        Next;
        Expect(tkLeftParen, '"("');
        Result.Target := ParseReference(True);
        Base := Result.Target;
        while Base.Kind in [ekField, ekIndex, ekComponent] do Base := Base.Left;
        if (Base.Kind = ekBufferElement) and (Base.Variable.Access = baWriteOnly) then
          raise EShaderError.Create(Result.Target.Position, 'Inc/Dec/Include/Exclude read the variable: cannot use a WriteOnly buffer');
        if Result.Operation in [opOr, opAnd] then
        begin
          if Result.Target.DataType <> stSet then
            raise EShaderError.Create(Result.Target.Position, 'Include/Exclude require a set variable');
          Expect(tkComma, '","');
          Element := ParseExpression;
          try Convert(Element, stEnum, False, Result.Target.Composite); except Element.Free; raise; end;
          // Value = [E] (Include) or not [E] (Exclude), combined with or/and.
          Result.Value := SetBit(Element, Result.Target.Composite);
          if Result.Operation = opAnd then
          begin
            Element := TExpression.Create;
            Element.Kind := ekUnary; Element.Operation := opNot; Element.Position := Result.Value.Position;
            Element.DataType := stSet; Element.Composite := Result.Target.Composite;
            Element.Left := Result.Value; Element.Depth := Result.Value.Depth + 1;
            Result.Value := Element;
          end;
        end
        else
        begin
          if not IsOrdinalType(Result.Target.DataType) then
            raise EShaderError.Create(Result.Target.Position, 'Inc/Dec require a scalar integer or enumeration variable');
          if FToken.Kind = tkComma then
          begin
            Next;
            Result.Value := ParseExpression;
          end
          else
            Result.Value := MakeConstant(stInteger, 1, True, Result.Target.Position);
          if Result.Target.DataType = stEnum then Convert(Result.Value, stCardinal)
          else Convert(Result.Value, Result.Target.DataType);
        end;
        Expect(tkRightParen, '")"');
      end
      else if IsWord('Exit') then
      begin
        Result.Kind := skReturn;
        Next;
        if FToken.Kind = tkLeftParen then
        begin
          Next;
          if FToken.Kind <> tkRightParen then
          begin
            if FCurrentFunction.ReturnType = stVoid then Fail('Procedures cannot return a value');
            Result.Value := ParseExpression;
            Convert(Result.Value, FCurrentFunction.ReturnType, False, FCurrentFunction.ReturnComposite);
          end;
          Expect(tkRightParen, '")"');
        end;
      end
      else if IsWord('Break') or IsWord('Continue') then
      begin
        if FLoopDepth = 0 then Fail('Break/Continue require an enclosing loop');
        if IsWord('Break') then Result.Kind := skBreak else Result.Kind := skContinue;
        Next;
      end
      else if IsWord('AtomicAdd') or IsWord('AtomicExchange') or IsWord('AtomicCompareExchange') then
      begin
        Result.Kind := skEvaluate; Result.Value := ParseAtomic;
      end
      else if IsWord('ImageStore') then
      begin
        Result.Kind := skEvaluate; Result.Value := ParseImageOperation;
      end
      else if IsWord('Barrier') or IsWord('BufferMemoryBarrier') or IsWord('ImageMemoryBarrier') then
      begin
        if (FCurrentFunction = nil) or (FCurrentFunction <> FModule.EntryPoint) then Fail('Barriers are only available in Main');
        Result.Kind := skBarrier;
        if IsWord('Barrier') then
        begin
          if FControlDepth <> 0 then Fail('Barrier must be unconditional, outside if/while/for');
          Result.BarrierKind := bkWorkgroup; FModule.UsesWorkgroupBarrier := True;
        end
        else if IsWord('BufferMemoryBarrier') then Result.BarrierKind := bkBuffer
        else Result.BarrierKind := bkImage;
        Next;
        if FToken.Kind = tkLeftParen then begin Next; Expect(tkRightParen, '")"'); end;
      end
      else if IsWord('if') then
      begin
        Result.Kind := skIf;
        Next;
        Result.Condition := ParseExpression;
        if Result.Condition.DataType <> stBoolean then
          Fail('An if condition must have type Boolean');
        ExpectWord('then');
        BeforeState := Snapshot;
        Result.ThenPart := ParseControlledStatement;
        ThenState := Snapshot;
        Restore(BeforeState);
        if IsWord('else') then
        begin
          Next;
          Result.ElsePart := ParseControlledStatement;
        end;
        ElseState := Snapshot;
        for I := 0 to FCurrentFunction.Locals.Count - 1 do
          FCurrentFunction.Locals[I].Initialized := StateAt(ThenState, I) and StateAt(ElseState, I);
      end
      else if IsWord('while') then
      begin
        Result.Kind := skWhile;
        Next;
        Result.Condition := ParseExpression;
        if Result.Condition.DataType <> stBoolean then
          Fail('A while condition must have type Boolean');
        ExpectWord('do');
        BeforeState := Snapshot;
        Inc(FLoopDepth);
        try Result.Body := ParseControlledStatement; finally Dec(FLoopDepth); end;
        ElseState := Snapshot;
        for I := 0 to FCurrentFunction.Locals.Count - 1 do
          FCurrentFunction.Locals[I].Initialized := StateAt(BeforeState, I) and StateAt(ElseState, I);
      end
      else
      begin
        Owner := ReadOwnerPrefix;
        // Inside F, "F := ..." and "F.Field := ..." write the result, not a call.
        if (PeekToken.Kind <> tkAssign) and not FLocalSymbols.ContainsKey(LowerCase(FToken.Text)) and
          FindFunction(FToken.Text, Owner, Callee, False) and
          ((EnclosingResult(Callee) = nil) or not (PeekToken.Kind in [tkDot, tkLeftBracket])) then
        begin
          Result.Kind := skEvaluate;
          Result.Value := ParseCall(Callee);
          Exit;
        end;
        Result.Kind := skAssign;
        Result.Target := ParseReference(True, Owner);
        Expect(tkAssign, '":="');
        Result.Value := ParseExpression;
        Convert(Result.Value, Result.Target.DataType, False, Result.Target.Composite);
        if Result.Target.Kind = ekLocal then
          Result.Target.Variable.Initialized := True;
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    LeaveDepth;
  end;
end;

function TParser.ParseControlledStatement: TStatement;
begin
  Inc(FControlDepth);
  PushScope; // an inline declaration as a lone branch/body ends with it
  try Result := ParseStatement; finally PopScope; Dec(FControlDepth); end;
end;

function TParser.ParseFor: TStatement;
var
  Counter: TShaderVariable;
  BeforeState, BodyState: TArray<Boolean>;
  I: Integer;
  Name: TToken;
  CounterType: TShaderType;
  CounterComposite: TCompositeType;
  Scoped: Boolean;
begin
  Result := TStatement.Create;
  Result.Kind := skFor;
  Result.Position := FToken.Position;
  Scoped := False;
  try
    ExpectWord('for');
    if IsWord('var') then
    begin
      // for var I [: T] := First to Last do — the counter exists only in the loop.
      Next;
      Name := ReadName;
      CounterType := stVoid;
      CounterComposite := nil;
      if FToken.Kind = tkColon then
      begin
        Next;
        CounterType := ReadType(CounterComposite);
      end;
      Expect(tkAssign, '":="');
      Result.Value := ParseExpression;
      if CounterType = stVoid then
      begin
        CounterType := Result.Value.DataType;
        CounterComposite := Result.Value.Composite;
      end;
      if not IsOrdinalType(CounterType) then
        raise EShaderError.Create(Name.Position, 'A for-loop counter must be a local integer variable');
      PushScope;
      Scoped := True;
      Counter := DeclareLocal(Name, CounterType, CounterComposite);
      Result.Target := TExpression.Create;
      Result.Target.Kind := ekLocal;
      Result.Target.Position := Name.Position;
      Result.Target.Variable := Counter;
      Result.Target.DataType := CounterType;
    end
    else
    begin
      Result.Target := ParseReference(True);
      if (Result.Target.Kind <> ekLocal) or (Result.Target.Variable.Kind <> vkLocal) or
        not IsOrdinalType(Result.Target.DataType) then
        raise EShaderError.Create(Result.Target.Position,
          'A for-loop counter must be a local Integer or Cardinal variable (or another integer or enumeration type)');
      Counter := Result.Target.Variable;
      if Counter.Captured then
        raise EShaderError.Create(Result.Target.Position,
          'A for-loop counter cannot be a variable shared with a nested routine');
      Expect(tkAssign, '":="');
      Result.Value := ParseExpression;
    end;
    Convert(Result.Value, Counter.DataType, False, Counter.Composite);
    if IsWord('to') then
      Result.Descending := False
    else if IsWord('downto') then
      Result.Descending := True
    else
      Fail('Expected to or downto in for loop');
    Next;
    Result.Limit := ParseExpression;
    Convert(Result.Limit, Counter.DataType, False, Counter.Composite);
    ExpectWord('do');
    BeforeState := Snapshot;
    Counter.Initialized := True;
    Counter.ActiveFor := True;
    try
      Inc(FLoopDepth);
      try Result.Body := ParseControlledStatement; finally Dec(FLoopDepth); end;
      BodyState := Snapshot;
    finally
      Counter.ActiveFor := False;
    end;
    for I := 0 to FCurrentFunction.Locals.Count - 1 do
      FCurrentFunction.Locals[I].Initialized := StateAt(BeforeState, I) and StateAt(BodyState, I);
    // Like Pascal, the control variable is not a usable result of the loop.
    Counter.Initialized := False;
    if Scoped then
    begin
      Scoped := False;
      PopScope;
    end;
  except
    if Scoped then PopScope;
    Result.Free;
    raise;
  end;
end;

function TParser.ParseRepeat: TStatement;
begin
  Result := TStatement.Create;
  Result.Kind := skRepeat; Result.Position := FToken.Position;
  Result.Body := TStatement.Create; Result.Body.Kind := skBlock;
  try
    Next; Inc(FLoopDepth); Inc(FControlDepth);
    // Inline declarations of the body are not visible in the until condition.
    PushScope;
    try
      while not IsWord('until') do
      begin
        if FToken.Kind = tkSemicolon then begin Next; Continue; end;
        Result.Body.Children.Add(ParseStatement);
        if not IsWord('until') then Expect(tkSemicolon, '";"');
      end;
    finally PopScope; Dec(FLoopDepth); Dec(FControlDepth); end;
    Next; Result.Condition := ParseExpression;
    if Result.Condition.DataType <> stBoolean then Fail('Until condition must be Boolean');
  except Result.Free; raise; end;
end;

function TParser.ParseCase: TStatement;
var
  E: TExpression;
  V: TConstantValue;
  Labels: TList<UInt64>;
  RangeEnd: TConstantValue;
  Arms: TList<TArray<UInt64>>;
  Seen: TDictionary<UInt64, Boolean>;
begin
  Result := TStatement.Create; Result.Kind := skCase; Result.Position := FToken.Position;
  Seen := TDictionary<UInt64, Boolean>.Create;
  Labels := TList<UInt64>.Create;
  Arms := TList<TArray<UInt64>>.Create;
  try
    try
      Next; Result.Condition := ParseExpression;
      if not IsOrdinalType(Result.Condition.DataType) then Fail('Case selector must be a scalar integer or enumeration');
      ExpectWord('of');
      while not IsWord('end') and not IsWord('else') do
      begin
        Labels.Clear;
        repeat
          E := ParseExpression;
          try
            Convert(E, Result.Condition.DataType, False, Result.Condition.Composite);
            if not EvaluateConstant(E, V) then Fail('Case labels must be defined integer constants');
            RangeEnd := V;
            if (FToken.Kind = tkDot) and (PeekToken.Kind = tkDot) then
            begin
              // Range label Low..High: expanded into individual OpSwitch literals.
              Next; Next;
              FreeAndNil(E);
              E := ParseExpression;
              Convert(E, Result.Condition.DataType, False, Result.Condition.Composite);
              if not EvaluateConstant(E, RangeEnd) then Fail('Case labels must be defined integer constants');
              if (IsSignedInteger(V.DataType) and (SignedValue(V.Bits, V.DataType) > SignedValue(RangeEnd.Bits, V.DataType))) or
                (not IsSignedInteger(V.DataType) and (V.Bits > RangeEnd.Bits)) then
                Fail('Case range low bound exceeds high bound');
            end;
            repeat
              if Seen.ContainsKey(V.Bits) then Fail('Duplicate case label');
              if Seen.Count >= MaxSwitchLabels then Fail('Case labels exceed the SPIR-V switch budget (16383 pairs)');
              Seen.Add(V.Bits, True); Labels.Add(V.Bits);
              if V.Bits = RangeEnd.Bits then Break;
              V.Bits := (V.Bits + 1) and IntegerMask(V.DataType);
            until False;
          finally E.Free; end;
          if FToken.Kind <> tkComma then Break;
          Next;
        until False;
        Expect(tkColon, '":"');
        Inc(FControlDepth);
        PushScope;
        try Result.Children.Add(ParseStatement); finally PopScope; Dec(FControlDepth); end;
        Arms.Add(Labels.ToArray);
        if FToken.Kind = tkSemicolon then Next
        else if not IsWord('end') and not IsWord('else') then Fail('Expected semicolon between case arms');
      end;
      if IsWord('else') then
      begin
        Next; Result.ElsePart := TStatement.Create; Result.ElsePart.Kind := skBlock;
        Inc(FControlDepth);
        PushScope;
        try
          while not IsWord('end') do
          begin
            if FToken.Kind = tkSemicolon then begin Next; Continue; end;
            Result.ElsePart.Children.Add(ParseStatement);
            if not IsWord('end') then Expect(tkSemicolon, '";"');
          end;
        finally PopScope; Dec(FControlDepth); end;
      end;
      ExpectWord('end');
      Result.CaseLabels := Arms.ToArray;
    except Result.Free; raise; end;
  finally Arms.Free; Labels.Free; Seen.Free; end;
end;

procedure TParser.Convert(var AExpression: TExpression; AType: TShaderType;
  AExplicit: Boolean; AComposite: TCompositeType);
var
  Node: TExpression;
  Allowed: Boolean;
  V: TConstantValue;
  Negative, Fits: Boolean;
begin
  if (AType = stComposite) or (AExpression.DataType = stComposite) then
  begin
    if (AType = AExpression.DataType) and (AExpression.Composite = AComposite) then Exit;
    raise EShaderError.Create(AExpression.Position, Format('Cannot convert %s to %s',
      [TypeReferenceName(AExpression.DataType, AExpression.Composite), TypeReferenceName(AType, AComposite)]));
  end;
  // An if expression converts branch by branch, so untyped literals still adapt.
  if (AExpression.Kind = ekConditional) and not AExplicit and
    ((AExpression.DataType <> AType) or (AExpression.Composite <> AComposite)) then
  begin
    Convert(AExpression.Left, AType, False, AComposite);
    Convert(AExpression.Right, AType, False, AComposite);
    AExpression.DataType := AType;
    AExpression.Composite := AComposite;
    Exit;
  end;
  if (AType in [stEnum, stSet]) or (AExpression.DataType in [stEnum, stSet]) then
  begin
    if (AType = AExpression.DataType) and (AExpression.Composite = AComposite) then Exit;
    // [] is compatible with every set type.
    if (AType = stSet) and (AExpression.DataType = stSet) and (AExpression.Composite = nil) and
      (AExpression.Kind = ekConstant) then
    begin
      AExpression.Composite := AComposite;
      Exit;
    end;
    // Explicit casts between integers and enumerations/sets keep the bits
    // (TMode(I), Integer(M), TModes(Mask), Cardinal(S)); nothing else converts.
    if not AExplicit or
      not ((IsScalarIntegerType(AExpression.DataType) and (AType in [stEnum, stSet])) or
        ((AExpression.DataType in [stEnum, stSet]) and IsScalarIntegerType(AType)) or
        ((AExpression.DataType = AType) and (AType in [stEnum, stSet]))) then
      raise EShaderError.Create(AExpression.Position, Format('Cannot convert %s to %s',
        [TypeReferenceName(AExpression.DataType, AExpression.Composite), TypeReferenceName(AType, AComposite)]));
    if AExpression.Kind = ekConstant then
    begin
      AExpression.Bits := IntegerCastBits(AExpression.Bits, AExpression.DataType, AType);
      AExpression.DataType := AType;
      AExpression.Composite := AComposite;
      AExpression.Adaptable := False;
      AExpression.ExplicitType := True;
      Exit;
    end;
    if AExpression.Depth >= 128 then
      raise EShaderError.Create(AExpression.Position, 'Expression nesting limit exceeded');
    Node := TExpression.Create;
    Node.Kind := ekConvert;
    Node.Position := AExpression.Position;
    Node.DataType := AType;
    Node.Composite := AComposite;
    Node.ExplicitType := True;
    Node.Depth := AExpression.Depth + 1;
    Node.Left := AExpression;
    AExpression := Node;
    Exit;
  end;
  // An explicit cast fixes the type; only untyped literals/constants adapt.
  if AExplicit then
  begin
    AExpression.Adaptable := False;
    AExpression.ExplicitType := True;
  end;
  if AExpression.DataType = AType then
    Exit;
  if not AExplicit and IsScalarIntegerType(AType) and IsScalarIntegerType(AExpression.DataType) and
    TreeAdaptable(AExpression) and EvaluateConstant(AExpression, V) then
  begin
    if not ExactNarrowConstant(AExpression) then
      raise EShaderError.Create(AExpression.Position, Format(
        'Untyped constant expression wraps in %s before conversion to %s; ' +
        'use a typed operand, for example %s(...)',
        [ShaderTypeName(AExpression.DataType), ShaderTypeName(AType), ShaderTypeName(AType)]));
    Negative := IsSignedInteger(V.DataType) and (SignedValue(V.Bits, V.DataType) < 0);
    if Negative then
      Fits := IsSignedInteger(AType) and
        (SignedValue(V.Bits, V.DataType) >= SignedValue(UInt64(1) shl (ScalarBitWidth(AType) - 1), AType))
    else if IsSignedInteger(AType) then Fits := V.Bits <= (UInt64(1) shl (ScalarBitWidth(AType) - 1)) - 1
    else Fits := V.Bits <= IntegerMask(AType);
    if Fits then
    begin
      Node := TExpression.Create;
      Node.Kind := ekConstant; Node.Position := AExpression.Position; Node.DataType := AType;
      Node.Bits := IntegerCastBits(V.Bits, V.DataType, AType);
      // Still an untyped literal value: it may adapt again (guarded by exactness).
      Node.Adaptable := True;
      AExpression.Free; AExpression := Node; Exit;
    end;
  end;
  Allowed := IsNumericType(AExpression.DataType) and IsNumericType(AType) and
    (ComponentCount(AExpression.DataType) = ComponentCount(AType));
  if not AExplicit then
    Allowed := Allowed and IsFloatType(AType) and
      not ((ComponentType(AExpression.DataType) = stDouble) and (ComponentType(AType) = stSingle));
  if (AExpression.Kind = ekConstant) and IsScalarIntegerType(AExpression.DataType)
    and IsScalarIntegerType(AType) then
  begin
    if AExplicit then
    begin
      AExpression.Bits := IntegerCastBits(AExpression.Bits, AExpression.DataType, AType);
      AExpression.DataType := AType;
      AExpression.Adaptable := False;
      Exit;
    end;
  end;
  if not Allowed then
    raise EShaderError.Create(AExpression.Position,
      Format('Cannot convert %s to %s; use an explicit numeric cast where valid',
      [ShaderTypeName(AExpression.DataType), ShaderTypeName(AType)]));
  if AExpression.Depth >= 128 then
    raise EShaderError.Create(AExpression.Position, 'Expression nesting limit exceeded');
  Node := TExpression.Create;
  Node.Kind := ekConvert;
  Node.Position := AExpression.Position;
  Node.DataType := AType;
  Node.Depth := AExpression.Depth + 1;
  Node.Left := AExpression;
  AExpression := Node;
end;

procedure TParser.Splat(var AExpression: TExpression; ACount: Integer);
var
  Node: TExpression;
begin
  if ComponentCount(AExpression.DataType) = ACount then
    Exit;
  if AExpression.DataType in [stByte, stWord, stInt64, stUInt64, stDouble] then
    raise EShaderError.Create(AExpression.Position, 'Extended scalar types do not support vector broadcasting');
  if (ComponentCount(AExpression.DataType) <> 1) or not IsNumericType(AExpression.DataType) then
    raise EShaderError.Create(AExpression.Position, 'Only a numeric scalar can be broadcast to a vector');
  if AExpression.Depth >= 128 then
    raise EShaderError.Create(AExpression.Position, 'Expression nesting limit exceeded');
  Node := TExpression.Create;
  Node.Kind := ekConstruct;
  Node.DataType := VectorType(AExpression.DataType, ACount);
  Node.Position := AExpression.Position;
  Node.Depth := AExpression.Depth + 1;
  Node.Arguments.Add(AExpression);
  AExpression := Node;
end;

procedure TParser.UnifyNumeric(var ALeft, ARight: TExpression; ABroadcast: Boolean);
var
  FloatType: TShaderType;
  Wider: TShaderType;
begin
  if not IsNumericType(ALeft.DataType) or not IsNumericType(ARight.DataType) then
    raise EShaderError.Create(ALeft.Position, 'Expected numeric operands');
  if ABroadcast and (ComponentCount(ALeft.DataType) <> ComponentCount(ARight.DataType)) then
  begin
    if ComponentCount(ALeft.DataType) = 1 then
    begin
      if (ALeft.Kind = ekConstant) and IsScalarIntegerType(ALeft.DataType) and
        IsIntegerType(ARight.DataType) then
        Convert(ALeft, ComponentType(ARight.DataType));
      Splat(ALeft, ComponentCount(ARight.DataType));
    end
    else if ComponentCount(ARight.DataType) = 1 then
    begin
      if (ARight.Kind = ekConstant) and IsScalarIntegerType(ARight.DataType) and
        IsIntegerType(ALeft.DataType) then
        Convert(ARight, ComponentType(ALeft.DataType));
      Splat(ARight, ComponentCount(ALeft.DataType));
    end;
  end;
  if ComponentCount(ALeft.DataType) <> ComponentCount(ARight.DataType) then
    raise EShaderError.Create(ALeft.Position, 'Operands must have matching vector widths');
  if ALeft.DataType = ARight.DataType then
    Exit;
  // Preserve 32-bit rules, but do not let operand order select a narrower type
  // when both integer constants are untyped and one has a wider representation.
  if IsScalarIntegerType(ALeft.DataType) and IsScalarIntegerType(ARight.DataType) and
    TreeAdaptable(ALeft) and TreeAdaptable(ARight) and
    (ScalarBitWidth(ALeft.DataType) <> ScalarBitWidth(ARight.DataType)) then
  begin
    if ScalarBitWidth(ALeft.DataType) > ScalarBitWidth(ARight.DataType) then Wider := ALeft.DataType
    else Wider := ARight.DataType;
    Convert(ALeft, Wider); Convert(ARight, Wider); Exit;
  end;
  if IsFloatType(ALeft.DataType) or IsFloatType(ARight.DataType) then
  begin
    if (ALeft.DataType = stDouble) or (ARight.DataType = stDouble) then
    begin
      if ComponentCount(ALeft.DataType) <> 1 then
        raise EShaderError.Create(ALeft.Position, 'Double currently supports scalar operations only');
      FloatType := stDouble;
    end
    else FloatType := VectorType(stSingle, ComponentCount(ALeft.DataType));
    Convert(ALeft, FloatType);
    Convert(ARight, FloatType);
  end
  else if (ALeft.Kind = ekConstant) and ALeft.Adaptable and
    (not ((ARight.Kind = ekConstant) and ARight.Adaptable) or
      (ALeft.Bits <= (UInt64(1) shl (ScalarBitWidth(ALeft.DataType) - 1)) - 1)) then
    Convert(ALeft, ARight.DataType)
  else
    Convert(ARight, ALeft.DataType);
end;

// Enumerations: comparisons only. Sets: + (union), * (intersection), - (difference),
// = <>, <= (subset), >= (superset); [] adapts to the other operand.
procedure TParser.MakeOrdinalBinary(AResult: TExpression; AOperation: TOperator;
  const APosition: TSourcePosition);
var
  L, R, Inner, Negated, Swap: TExpression;
begin
  if (AResult.Left.DataType = stSet) and (AResult.Right.DataType = stSet) then
  begin
    if AResult.Left.Composite = nil then Convert(AResult.Left, stSet, False, AResult.Right.Composite)
    else if AResult.Right.Composite = nil then Convert(AResult.Right, stSet, False, AResult.Left.Composite);
  end;
  if (AResult.Left.DataType <> AResult.Right.DataType) or (AResult.Left.Composite <> AResult.Right.Composite) then
    raise EShaderError.Create(APosition, Format('Incompatible types: %s and %s',
      [TypeReferenceName(AResult.Left.DataType, AResult.Left.Composite),
       TypeReferenceName(AResult.Right.DataType, AResult.Right.Composite)]));
  if AResult.Left.DataType = stEnum then
  begin
    if not (AOperation in [opEqual, opNotEqual, opLess, opLessEqual, opGreater, opGreaterEqual]) then
      raise EShaderError.Create(APosition, 'Enumerations support comparisons only; use Ord(...) for arithmetic');
    AResult.DataType := stBoolean;
    Exit;
  end;
  AResult.Composite := AResult.Left.Composite;
  case AOperation of
    opAdd: begin AResult.Operation := opOr; AResult.DataType := stSet; end;
    opMultiply: begin AResult.Operation := opAnd; AResult.DataType := stSet; end;
    opEqual, opNotEqual: begin AResult.DataType := stBoolean; AResult.Composite := nil; end;
    opSubtract, opLessEqual, opGreaterEqual:
      begin
        // A - B = A and not B; A <= B is (A - B) = []; A >= B is (B - A) = [].
        L := AResult.Left; R := AResult.Right;
        AResult.Left := nil; AResult.Right := nil;
        if AOperation = opGreaterEqual then begin Swap := L; L := R; R := Swap; end;
        Negated := TExpression.Create;
        Negated.Kind := ekUnary; Negated.Operation := opNot; Negated.Position := APosition;
        Negated.DataType := stSet; Negated.Composite := R.Composite; Negated.Left := R;
        Negated.Depth := R.Depth + 1;
        if AOperation = opSubtract then
        begin
          AResult.Operation := opAnd; AResult.DataType := stSet;
          AResult.Left := L; AResult.Right := Negated;
          Exit;
        end;
        Inner := TExpression.Create;
        Inner.Kind := ekBinary; Inner.Operation := opAnd; Inner.Position := APosition;
        Inner.DataType := stSet; Inner.Composite := L.Composite;
        Inner.Left := L; Inner.Right := Negated;
        Inner.Depth := Max(L.Depth, Negated.Depth) + 1;
        AResult.Left := Inner;
        AResult.Right := MakeConstant(stSet, 0, False, APosition);
        AResult.Right.Composite := Inner.Composite;
        AResult.Operation := opEqual;
        AResult.DataType := stBoolean;
        AResult.Composite := nil;
      end;
  else
    raise EShaderError.Create(APosition, 'Set operators are + - * = <> <= >= and in');
  end;
end;

function TParser.MakeBinary(AOperation: TOperator; ALeft, ARight: TExpression;
  const APosition: TSourcePosition): TExpression;
begin
  Result := TExpression.Create;
  Result.Kind := ekBinary;
  Result.Position := APosition;
  Result.Operation := AOperation;
  Result.Left := ALeft;
  Result.Right := ARight;
  try
    if (ALeft.DataType in [stEnum, stSet]) or (ARight.DataType in [stEnum, stSet]) then
    begin
      MakeOrdinalBinary(Result, AOperation, APosition);
      Result.Depth := Max(Result.Left.Depth, Result.Right.Depth) + 1;
      if Result.Depth > 128 then
        raise EShaderError.Create(APosition, 'Expression nesting limit exceeded');
      Exit;
    end;
    case AOperation of
      opShiftLeft, opShiftRight:
      begin
        if not IsIntegerType(ALeft.DataType) or not IsIntegerType(ARight.DataType) then
          raise EShaderError.Create(APosition, 'Shift operands must be integers');
        if ComponentCount(Result.Right.DataType) = 1 then
          Splat(Result.Right, ComponentCount(Result.Left.DataType));
        if ComponentCount(Result.Left.DataType) <> ComponentCount(Result.Right.DataType) then
          raise EShaderError.Create(APosition, 'Shift operands must have matching vector widths');
      end;
      opAnd, opOr, opXor:
        if not ((ALeft.DataType = stBoolean) and (ARight.DataType = stBoolean)) then
        begin
          if not IsIntegerType(ALeft.DataType) or not IsIntegerType(ARight.DataType) then
            raise EShaderError.Create(APosition, 'Expected two Boolean or two integer operands');
          UnifyNumeric(Result.Left, Result.Right, True);
        end;
      opEqual, opNotEqual:
        if not ((ALeft.DataType = stBoolean) and (ARight.DataType = stBoolean)) then
          UnifyNumeric(Result.Left, Result.Right);
      opDivide:
        begin
          UnifyNumeric(Result.Left, Result.Right, True);
          if Result.Left.DataType <> stDouble then
            Convert(Result.Left, VectorType(stSingle, ComponentCount(Result.Left.DataType)));
          Convert(Result.Right, Result.Left.DataType);
        end;
      opLess, opLessEqual, opGreater, opGreaterEqual:
        begin
          if (ComponentCount(ALeft.DataType) > 1) or (ComponentCount(ARight.DataType) > 1) then
            raise EShaderError.Create(APosition, 'Ordered comparisons require scalar operands; compare vector components');
          UnifyNumeric(Result.Left, Result.Right);
        end;
    else
      UnifyNumeric(Result.Left, Result.Right, True);
      if (AOperation in [opIntDivide, opModulo]) and
        not IsIntegerType(Result.Left.DataType) then
        raise EShaderError.Create(APosition, 'div and mod require integer operands');
    end;
    if AOperation in [opEqual, opNotEqual, opLess, opLessEqual, opGreater, opGreaterEqual] then
      Result.DataType := stBoolean
    else
      Result.DataType := Result.Left.DataType;
    Result.Depth := Max(Result.Left.Depth, Result.Right.Depth) + 1;
    if Result.Depth > 128 then
      raise EShaderError.Create(APosition, 'Expression nesting limit exceeded');
  except
    Result.Free;
    raise;
  end;
end;

// [E]: a one-element set of E's enumeration (1 shl Ord(E)). Owns AElement.
function TParser.SetBit(AElement: TExpression; AComposite: TCompositeType): TExpression;
var
  Index: TExpression;
  Position: TSourcePosition;
begin
  Position := AElement.Position;
  Index := AElement;
  Convert(Index, stCardinal, True);
  Result := MakeBinary(opShiftLeft, MakeConstant(stCardinal, 1, False, Position), Index, Position);
  Convert(Result, stSet, True, AComposite);
end;

// X in [A, B..C] compares X with every item (integers or enumerations, any range);
// X in S tests bit Ord(X) of a set value. Owns ALeft.
function TParser.ParseIn(ALeft: TExpression; const APosition: TSourcePosition): TExpression;
var
  Item, Range, Mask, Bit: TExpression;
begin
  if not IsOrdinalType(ALeft.DataType) then
  begin
    ALeft.Free;
    raise EShaderError.Create(APosition, 'in requires an integer or enumeration value on the left');
  end;
  if FToken.Kind = tkLeftBracket then
  begin
    Result := TExpression.Create;
    Result.Kind := ekInSet;
    Result.Position := APosition;
    Result.DataType := stBoolean;
    Result.Left := ALeft;
    Result.Depth := ALeft.Depth + 1;
    try
      Next;
      if FToken.Kind <> tkRightBracket then
        repeat
          if Result.Arguments.Count >= MaxSwitchLabels then Fail('Too many set constructor items');
          Item := ParseExpression;
          try Convert(Item, ALeft.DataType, False, ALeft.Composite); except Item.Free; raise; end;
          if (FToken.Kind = tkDot) and (PeekToken.Kind = tkDot) then
          begin
            Next; Next;
            Range := TExpression.Create;
            Range.Kind := ekRange; Range.Position := Item.Position;
            Range.DataType := Item.DataType; Range.Composite := Item.Composite;
            Range.Left := Item;
            Result.Arguments.Add(Range);
            Range.Right := ParseExpression;
            Convert(Range.Right, ALeft.DataType, False, ALeft.Composite);
            Range.Depth := Max(Range.Left.Depth, Range.Right.Depth) + 1;
            Item := Range;
          end
          else Result.Arguments.Add(Item);
          Result.Depth := Max(Result.Depth, Item.Depth + 1);
          if Result.Depth > 128 then Fail('Expression nesting limit exceeded');
          if FToken.Kind <> tkComma then Break;
          Next;
        until False;
      Expect(tkRightBracket, '"]"');
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;
  Mask := nil;
  try
    if ALeft.DataType <> stEnum then
      Fail('Integer membership needs a set constructor: X in [A, B..C]');
    Mask := ParseAdditive;
    if Mask.DataType <> stSet then
      raise EShaderError.Create(Mask.Position, 'in expects a set or a set constructor on the right');
    Convert(Mask, stSet, False, ALeft.Composite);
    Convert(Mask, stCardinal, True);
  except
    ALeft.Free;
    Mask.Free;
    raise;
  end;
  // ((1 shl Ord(X)) and S) <> 0: X is evaluated before S, left to right.
  Bit := SetBit(ALeft, ALeft.Composite);
  Convert(Bit, stCardinal, True);
  Result := MakeBinary(opAnd, Bit, Mask, APosition);
  Result := MakeBinary(opNotEqual, Result, MakeConstant(stCardinal, 0, False, APosition), APosition);
end;

// [A, B..C] with enumeration elements: a set value (bit mask). Outside "in",
// integer constructors are not values because there is no integer set type.
function TParser.ParseSetConstructor: TExpression;
var
  Position: TSourcePosition;
  Composite: TCompositeType;
  Item, UpperItem, LowerItem, Part, Ones: TExpression;
begin
  Position := FToken.Position;
  Next;
  Composite := nil;
  Result := nil;
  try
    if FToken.Kind <> tkRightBracket then
      repeat
        Item := ParseExpression;
        try
          if Item.DataType <> stEnum then
            raise EShaderError.Create(Item.Position,
              'Set constructors need enumeration elements (integer lists are supported with in)');
          if Composite = nil then
          begin
            Composite := Item.Composite;
            if EnumHigh(Composite) > 31 then
              raise EShaderError.Create(Item.Position, 'Set elements must have ordinal values 0..31');
          end
          else Convert(Item, stEnum, False, Composite);
        except Item.Free; raise; end;
        if (FToken.Kind = tkDot) and (PeekToken.Kind = tkDot) then
        begin
          Next; Next;
          LowerItem := Item;
          UpperItem := nil;
          try
            UpperItem := ParseExpression;
            Convert(UpperItem, stEnum, False, Composite);
            Convert(LowerItem, stCardinal, True);
            Convert(UpperItem, stCardinal, True);
          except LowerItem.Free; UpperItem.Free; raise; end;
          // Bits Lo..Hi: (not 0 shl Lo) and (not 0 shr (31 - Hi)); empty when Lo > Hi.
          Ones := MakeConstant(stCardinal, $FFFFFFFF, False, Position);
          Part := MakeBinary(opShiftLeft, Ones, LowerItem, Position);
          try
            UpperItem := MakeBinary(opSubtract, MakeConstant(stCardinal, 31, False, Position), UpperItem, Position);
          except Part.Free; raise; end;
          try
            UpperItem := MakeBinary(opShiftRight, MakeConstant(stCardinal, $FFFFFFFF, False, Position), UpperItem, Position);
          except Part.Free; raise; end;
          Part := MakeBinary(opAnd, Part, UpperItem, Position);
          Convert(Part, stSet, True, Composite);
        end
        else Part := SetBit(Item, Composite);
        if Result = nil then Result := Part
        else
        begin
          Ones := Result;
          Result := nil;
          Result := MakeBinary(opAdd, Ones, Part, Position);
        end;
        if FToken.Kind <> tkComma then Break;
        Next;
      until False;
    Expect(tkRightBracket, '"]"');
    if Result = nil then
      Result := MakeConstant(stSet, 0, False, Position); // [] adapts to any set type
  except
    Result.Free;
    raise;
  end;
end;

// Delphi 13: if C then A else B. Only the selected branch is evaluated; the type
// is the common type of both branches (numeric promotion as in other operators).
function TParser.ParseConditional: TExpression;
var
  Position: TSourcePosition;
  Condition: TExpression;
begin
  Position := FToken.Position;
  // else-if chains recurse here without passing through ParseUnary.
  EnterDepth;
  ExpectWord('if');
  Result := TExpression.Create;
  Result.Kind := ekConditional;
  Result.Position := Position;
  try
    Condition := ParseExpression;
    Result.Arguments.Add(Condition);
    if Condition.DataType <> stBoolean then
      raise EShaderError.Create(Condition.Position, 'An if expression condition must have type Boolean');
    ExpectWord('then');
    Result.Left := ParseExpression;
    ExpectWord('else');
    Result.Right := ParseExpression;
    if (Result.Left.DataType = stVoid) or (Result.Right.DataType = stVoid) then
      raise EShaderError.Create(Position, 'Both branches of an if expression need a value');
    if (Result.Left.DataType = Result.Right.DataType) and (Result.Left.Composite = Result.Right.Composite) then
    else if IsNumericType(Result.Left.DataType) and IsNumericType(Result.Right.DataType) then
      UnifyNumeric(Result.Left, Result.Right)
    else if (Result.Left.DataType = stSet) and (Result.Right.DataType = stSet) then
    begin
      // [] adapts to the other set type.
      if Result.Left.Composite = nil then Convert(Result.Left, stSet, False, Result.Right.Composite)
      else Convert(Result.Right, stSet, False, Result.Left.Composite);
    end
    else
      raise EShaderError.Create(Position, Format('Incompatible types in if expression: %s and %s',
        [TypeReferenceName(Result.Left.DataType, Result.Left.Composite),
         TypeReferenceName(Result.Right.DataType, Result.Right.Composite)]));
    Result.DataType := Result.Left.DataType;
    Result.Composite := Result.Left.Composite;
    // Pure scalar/vector branches may use OpSelect; otherwise branch + OpPhi.
    Result.ShortCircuit := (Result.DataType = stComposite) or
      not (PureOperand(Result.Left) and PureOperand(Result.Right));
    Result.Depth := Max(Max(Result.Left.Depth, Result.Right.Depth), Condition.Depth) + 1;
    if Result.Depth > 128 then
      raise EShaderError.Create(Position, 'Expression nesting limit exceeded');
    LeaveDepth;
  except
    LeaveDepth;
    Result.Free;
    raise;
  end;
end;

function TParser.ParseExpression: TExpression;
var
  Operation: TOperator;
  Position: TSourcePosition;
  Right: TExpression;
  Negated: Boolean;
begin
  if IsWord('if') then Exit(ParseConditional);
  Result := ParseAdditive;
  try
    // X in S, and Delphi 13 X not in S (relational precedence).
    if IsWord('in') or (IsWord('not') and (PeekToken.Kind = tkIdentifier) and SameText(PeekToken.Text, 'in')) then
    begin
      Negated := IsWord('not');
      Position := FToken.Position;
      if Negated then Next;
      Next;
      Right := Result;
      Result := nil;
      Result := ParseIn(Right, Position);
      if Negated then
      begin
        Right := Result;
        Result := TExpression.Create;
        Result.Kind := ekUnary; Result.Operation := opNot; Result.Position := Position;
        Result.DataType := stBoolean; Result.Left := Right; Result.Depth := Right.Depth + 1;
      end;
      Exit;
    end;
    Operation := opNone;
    case FToken.Kind of
      tkEqual: Operation := opEqual;
      tkNotEqual: Operation := opNotEqual;
      tkLess: Operation := opLess;
      tkLessEqual: Operation := opLessEqual;
      tkGreater: Operation := opGreater;
      tkGreaterEqual: Operation := opGreaterEqual;
    end;
    if Operation <> opNone then
    begin
      Position := FToken.Position;
      Next;
      Right := ParseAdditive;
      { MakeBinary owns both operands, including on a type error. }
      var Left := Result;
      Result := nil;
      Result := MakeBinary(Operation, Left, Right, Position);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ParseAdditive: TExpression;
var
  Operation: TOperator;
  Position: TSourcePosition;
  Left, Right: TExpression;
  Complete: Boolean;
begin
  Result := ParseMultiplicative;
  try
    while True do
    begin
      Operation := opNone;
      if FToken.Kind = tkPlus then Operation := opAdd
      else if FToken.Kind = tkMinus then Operation := opSubtract
      else if IsWord('or') then Operation := opOr
      else if IsWord('xor') then Operation := opXor;
      if Operation = opNone then Break;
      Position := FToken.Position;
      Complete := FToken.CompleteBoolEval;
      Next;
      Right := ParseMultiplicative;
      Left := Result;
      Result := nil;
      Result := MakeBinary(Operation, Left, Right, Position);
      Result.ShortCircuit := (Operation = opOr) and (Result.DataType = stBoolean) and not Complete and
        not PureOperand(Result.Right);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ParseMultiplicative: TExpression;
var
  Operation: TOperator;
  Position: TSourcePosition;
  Left, Right: TExpression;
  Complete: Boolean;
begin
  Result := ParseUnary;
  try
    while True do
    begin
      Operation := opNone;
      if FToken.Kind = tkStar then Operation := opMultiply
      else if FToken.Kind = tkSlash then Operation := opDivide
      else if IsWord('div') then Operation := opIntDivide
      else if IsWord('mod') then Operation := opModulo
      else if IsWord('and') then Operation := opAnd
      else if IsWord('shl') then Operation := opShiftLeft
      else if IsWord('shr') then Operation := opShiftRight;
      if Operation = opNone then Break;
      Position := FToken.Position;
      Complete := FToken.CompleteBoolEval;
      Next;
      Right := ParseUnary;
      Left := Result;
      Result := nil;
      Result := MakeBinary(Operation, Left, Right, Position);
      Result.ShortCircuit := (Operation = opAnd) and (Result.DataType = stBoolean) and not Complete and
        not PureOperand(Result.Right);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ParseUnary: TExpression;
var
  Operation: TOperator;
  Position: TSourcePosition;
begin
  EnterDepth;
  try
    Operation := opNone;
    Position := FToken.Position;
    if FToken.Kind = tkPlus then
    begin
      Next;
      Result := ParseUnary;
      if not IsNumericType(Result.DataType) then
      begin
        Result.Free;
        raise EShaderError.Create(Position, 'Unary + requires a numeric operand');
      end;
      Exit;
    end;
    if FToken.Kind = tkMinus then Operation := opNegate
    else if IsWord('not') then Operation := opNot;
    if Operation = opNone then
      Exit(ParsePrimary);
    Next;
    Result := TExpression.Create;
    Result.Kind := ekUnary;
    Result.Position := Position;
    Result.Operation := Operation;
    try
      Result.Left := ParseUnary;
      if (Operation = opNegate) and (Result.Left.Kind = ekConstant) and
        TreeAdaptable(Result.Left) and
        (Result.Left.DataType = stCardinal) and (Result.Left.Bits = $80000000) then
      begin
        Result.Kind := ekConstant;
        Result.DataType := stInteger;
        Result.Bits := $80000000;
        Result.Adaptable := True;
        FreeAndNil(Result.Left);
        Exit;
      end;
      Result.DataType := Result.Left.DataType;
      if (Operation = opNegate) and (Result.Left.Kind = ekConstant) and
        TreeAdaptable(Result.Left) and
        (Result.Left.DataType = stUInt64) and (Result.Left.Bits = $8000000000000000) then
      begin
        Result.Kind := ekConstant; Result.DataType := stInt64;
        Result.Bits := $8000000000000000; Result.Adaptable := True;
        FreeAndNil(Result.Left); Exit;
      end;
      Result.Depth := Result.Left.Depth + 1;
      if Result.Depth > 128 then
        raise EShaderError.Create(Position, 'Expression nesting limit exceeded');
      if (Operation = opNegate) and not (IsSignedInteger(Result.DataType) or IsFloatType(Result.DataType)) then
        raise EShaderError.Create(Position, 'Unary - requires Integer or Single');
      if (Operation = opNot) and not (IsIntegerType(Result.DataType) or (Result.DataType = stBoolean)) then
        raise EShaderError.Create(Position, 'not requires an integer or Boolean');
    except
      Result.Free;
      raise;
    end;
  finally
    LeaveDepth;
  end;
end;

function TParser.ParseConstruct(AType: TShaderType): TExpression;
var
  Arguments: TArray<TExpression>;
  Position: TSourcePosition;
  Count, I, Width: Integer;
begin
  Result := nil;
  SetLength(Arguments, 4);
  Count := 0;
  Width := ComponentCount(AType);
  Position := FToken.Position;
  try
    try
      Next;
      Expect(tkLeftParen, '"(" after type name');
      if FToken.Kind <> tkRightParen then
        repeat
          if Count = Length(Arguments) then
            Fail('Vector constructors support at most four arguments');
          Arguments[Count] := ParseExpression;
          Inc(Count);
          if FToken.Kind <> tkComma then Break;
          Next;
        until False;
      Expect(tkRightParen, '")"');
      if (Count <> 1) and (Count <> Width) then
        raise EShaderError.Create(Position, Format('%s constructor expects 1 or %d arguments',
          [ShaderTypeName(AType), Width]));
      if (Count = 1) and ((Width = 1) or (ComponentCount(Arguments[0].DataType) > 1)) then
      begin
        Convert(Arguments[0], AType, True);
        Result := Arguments[0];
        Arguments[0] := nil;
      end
      else
      begin
        Result := TExpression.Create;
        Result.Kind := ekConstruct;
        Result.Position := Position;
        Result.DataType := AType;
        for I := 0 to Count - 1 do
        begin
          Convert(Arguments[I], ComponentType(AType), True);
          Result.Depth := Max(Result.Depth, Arguments[I].Depth + 1);
          Result.Arguments.Add(Arguments[I]);
          Arguments[I] := nil;
        end;
        if Result.Depth > 128 then
          raise EShaderError.Create(Position, 'Expression nesting limit exceeded');
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    for I := 0 to High(Arguments) do Arguments[I].Free;
  end;
end;

function TParser.ParseIntrinsic(AIntrinsic: TIntrinsic): TExpression;
var
  Arguments: TArray<TExpression>;
  Arity, I, Width: Integer;
  Name: string;
  HasFloat: Boolean;
  FloatBase: TShaderType;
begin
  if AIntrinsic >= inSingleToBits then Exit(ParseNumericIntrinsic(AIntrinsic));
  case AIntrinsic of
    inAbs, inSqrt: Arity := 1;
    inMin, inMax, inDot: Arity := 2;
  else
    Arity := 3;
  end;
  SetLength(Arguments, Arity);
  Name := FToken.Text;
  Result := TExpression.Create;
  Result.Kind := ekIntrinsic;
  Result.Intrinsic := AIntrinsic;
  Result.Position := FToken.Position;
  try
    try
      Next;
      Expect(tkLeftParen, '"(" after intrinsic name');
      for I := 0 to Arity - 1 do
      begin
        if FToken.Kind = tkRightParen then
          Fail(Format('%s expects %d arguments', [Name, Arity]));
        Arguments[I] := ParseExpression;
        if I < Arity - 1 then
        begin
          if FToken.Kind <> tkComma then
            Fail(Format('%s expects %d arguments', [Name, Arity]));
          Next;
        end;
      end;
      if FToken.Kind = tkComma then
        Fail(Format('%s expects %d arguments', [Name, Arity]));
      Expect(tkRightParen, '")"');
      case AIntrinsic of
        inMin, inMax:
          UnifyNumeric(Arguments[0], Arguments[1], True);
        inClamp:
          begin
            HasFloat := False;
            FloatBase := stSingle;
            Width := 1;
            for I := 0 to 2 do
            begin
              if not IsNumericType(Arguments[I].DataType) then
                raise EShaderError.Create(Result.Position, 'Clamp requires numeric operands');
              HasFloat := HasFloat or IsFloatType(Arguments[I].DataType);
              if Arguments[I].DataType = stDouble then FloatBase := stDouble;
              Width := Max(Width, ComponentCount(Arguments[I].DataType));
            end;
            if HasFloat then
            begin
              if (FloatBase = stDouble) and (Width <> 1) then Fail('Double currently supports scalar operations only');
              for I := 0 to 2 do
              begin
                if ComponentCount(Arguments[I].DataType) = 1 then Splat(Arguments[I], Width);
                Convert(Arguments[I], VectorType(FloatBase, Width));
              end;
            end
            else
            begin
              UnifyNumeric(Arguments[0], Arguments[1], True);
              UnifyNumeric(Arguments[0], Arguments[2], True);
              UnifyNumeric(Arguments[1], Arguments[2], True);
            end;
            // Signedness must never depend on argument order.
            if (Arguments[0].DataType <> Arguments[1].DataType) or
              (Arguments[0].DataType <> Arguments[2].DataType) then
              raise EShaderError.Create(Result.Position,
                'Clamp arguments must have one common numeric type; use explicit casts');
          end;
        inAbs:
          if not IsNumericType(Arguments[0].DataType) then
            raise EShaderError.Create(Result.Position, 'Abs requires a numeric value');
        inDot:
          begin
            Width := ComponentCount(Arguments[0].DataType);
            if (Width < 2) or (Width <> ComponentCount(Arguments[1].DataType)) or
              not IsNumericType(Arguments[0].DataType) or not IsNumericType(Arguments[1].DataType) then
              raise EShaderError.Create(Result.Position, 'Dot requires two numeric vectors of the same width');
            Convert(Arguments[0], VectorType(stSingle, Width));
            Convert(Arguments[1], VectorType(stSingle, Width));
          end;
        inSqrt:
          begin
            if not IsNumericType(Arguments[0].DataType) then
              raise EShaderError.Create(Result.Position, 'Sqrt requires a numeric value');
            if Arguments[0].DataType <> stDouble then
              Convert(Arguments[0], VectorType(stSingle, ComponentCount(Arguments[0].DataType)));
          end;
      end;
      if AIntrinsic = inDot then Result.DataType := stSingle
      else Result.DataType := Arguments[0].DataType;
      for I := 0 to Arity - 1 do
      begin
        Result.Depth := Max(Result.Depth, Arguments[I].Depth + 1);
        Result.Arguments.Add(Arguments[I]);
        Arguments[I] := nil;
      end;
      if Result.Depth > 128 then
        raise EShaderError.Create(Result.Position, 'Expression nesting limit exceeded');
    except
      Result.Free;
      raise;
    end;
  finally
    for I := 0 to High(Arguments) do Arguments[I].Free;
  end;
end;

function TParser.ParseNumericIntrinsic(AIntrinsic: TIntrinsic): TExpression;
var
  A: TExpression;
  Count, I: Integer;
  T: TShaderType;
begin
  Result := TExpression.Create;
  Result.Kind := ekIntrinsic; Result.Intrinsic := AIntrinsic; Result.Position := FToken.Position;
  try
    Next; Expect(tkLeftParen, '"("');
    if AIntrinsic in [inLdexp, inArithmeticShiftRight] then Count := 2 else Count := 1;
    for I := 0 to Count - 1 do
    begin
      A := ParseExpression; Result.Arguments.Add(A);
      Result.Depth := Max(Result.Depth, A.Depth + 1);
      if I < Count - 1 then Expect(tkComma, '","');
    end;
    Expect(tkRightParen, '")"');
    T := Result.Arguments[0].DataType;
    Result.DataType := T;
    case AIntrinsic of
      inSingleToBits:
        begin if T <> stSingle then Fail('SingleToBits requires Single'); Result.DataType := stCardinal; end;
      inBitsToSingle:
        begin if T <> stCardinal then Fail('BitsToSingle requires Cardinal'); Result.DataType := stSingle; end;
      inDoubleToBits:
        begin if T <> stDouble then Fail('DoubleToBits requires Double'); Result.DataType := stUInt64; end;
      inBitsToDouble:
        begin if T <> stUInt64 then Fail('BitsToDouble requires UInt64'); Result.DataType := stDouble; end;
      inFindMSB, inFindLSB:
        begin
          if not (T in [stInteger, stCardinal]) then Fail('FindMSB/FindLSB require Integer or Cardinal');
          Result.DataType := stInteger;
        end;
      inArithmeticShiftRight:
        begin
          if not IsSignedInteger(T) or (ComponentCount(T) <> 1) then Fail('ArithmeticShiftRight requires a signed scalar');
          if not IsScalarIntegerType(Result.Arguments[1].DataType) then Fail('Shift count must be an integer');
        end;
      inOrd:
        if T = stBoolean then Result.DataType := stInteger
        else if IsScalarIntegerType(T) then
        begin
          // Ord of an integer is the value itself, with its type.
          A := Result.Arguments.Extract(Result.Arguments[0]);
          FreeAndNil(Result);
          Exit(A);
        end
        else if T = stEnum then
        begin
          // Ord of an enumeration value: its ordinal as Integer.
          A := Result.Arguments.Extract(Result.Arguments[0]);
          FreeAndNil(Result);
          Convert(A, stInteger, True);
          Exit(A);
        end
        else Fail('Ord requires a Boolean, integer or enumeration value');
      inSqr:
        if not IsNumericType(T) then Fail('Sqr requires a numeric value');
    else
      if not (T in [stSingle, stDouble]) then Fail('Floating intrinsic requires scalar Single or Double');
      case AIntrinsic of
        inRound, inTrunc: Result.DataType := stInt64;
        inFloor, inCeil: Result.DataType := stInteger;
        inIsNan, inIsInfinite: Result.DataType := stBoolean;
        inLdexp: if Result.Arguments[1].DataType <> stInteger then Fail('Ldexp exponent must be Integer');
      end;
    end;
    if Result.Depth > 128 then Fail('Expression nesting limit exceeded');
  except Result.Free; raise; end;
end;

procedure TParser.Select(var AExpression: TExpression);
var
  Node: TExpression;
  ParentType: TCompositeType;
  I, Component: Integer;
  Found: Boolean;
  IndexConstant: TConstantValue;
  Letters, Alphabet: string;
  Swizzle: UInt64;
begin
  while FToken.Kind in [tkDot, tkLeftBracket] do
  begin
    if (FToken.Kind = tkDot) and (PeekToken.Kind = tkDot) then Break;
    Node := TExpression.Create;
    Node.Position := AExpression.Position;
    Node.Left := AExpression;
    AExpression := Node;
    ParentType := Node.Left.Composite;
    if FToken.Kind = tkDot then
    begin
      Next;
      if (Node.Left.DataType = stComposite) and (ParentType.Kind = ctRecord) then
      begin
        Node.Kind := ekField;
        Found := False;
        for I := 0 to ParentType.Fields.Count - 1 do
          if (FToken.Kind = tkIdentifier) and SameText(ParentType.Fields[I].Name, FToken.Text) then
          begin
            Node.MemberIndex := Cardinal(I);
            Node.DataType := ParentType.Fields[I].DataType;
            Node.Composite := ParentType.Fields[I].Composite;
            Found := True;
            Break;
          end;
        if not Found then Fail('Unknown record field');
        Next;
      end
      else
      begin
        // One component (.X) or a swizzle (.XY, .ZYX, .RGBA): one letter set per selector.
        if ComponentCount(Node.Left.DataType) <= 1 then Fail('Component selection requires a vector');
        if FToken.Kind <> tkIdentifier then Fail('Expected vector components (X, Y, Z, W or R, G, B, A)');
        Letters := UpperCase(FToken.Text);
        if Length(Letters) > 4 then Fail('A swizzle selects at most four components');
        if CharInSet(Letters[1], ['R', 'G', 'B', 'A']) then Alphabet := 'RGBA' else Alphabet := 'XYZW';
        Swizzle := 0;
        for I := 1 to Length(Letters) do
        begin
          Component := Pos(Letters[I], Alphabet);
          if Component = 0 then
            Fail('Expected vector components from one set: X, Y, Z, W or R, G, B, A');
          if Component > ComponentCount(Node.Left.DataType) then
            Fail(Format('Component "%s" is not available in %s', [Letters[I], ShaderTypeName(Node.Left.DataType)]));
          Swizzle := Swizzle or (UInt64(Component - 1) shl (2 * (I - 1)));
        end;
        Next;
        if Length(Letters) = 1 then
        begin
          Node.Kind := ekComponent;
          Node.DataType := ComponentType(Node.Left.DataType);
          Node.MemberIndex := Swizzle;
        end
        else
        begin
          Node.Kind := ekSwizzle;
          Node.DataType := VectorType(ComponentType(Node.Left.DataType), Length(Letters));
          Node.MemberIndex := Length(Letters);
          Node.Bits := Swizzle;
        end;
      end;
    end
    else
    begin
      if (Node.Left.DataType <> stComposite) or (ParentType.Kind <> ctArray) then
        Fail('Indexing requires a static array');
      Node.Kind := ekIndex;
      Node.DataType := ParentType.ElementType;
      Node.Composite := ParentType.ElementComposite;
      Next;
      Node.Right := ParseExpression;
      if not IsScalarIntegerType(Node.Right.DataType) then
        Fail('Array indices must have type Integer or Cardinal');
      // A[I, J] is A[I][J]: the comma continues with the next dimension.
      if FToken.Kind = tkComma then FToken.Kind := tkLeftBracket
      else Expect(tkRightBracket, '"]"');
      CheckConstantIndex(Node.Right, ParentType.Length);
      Node.ConstantIndex := EvaluateConstant(Node.Right, IndexConstant);
      if Node.ConstantIndex then Node.MemberIndex := IndexConstant.Bits;
      if not ExpressionIsAddressable(Node.Left) and not Node.ConstantIndex then
        Fail('Dynamic indexing requires an addressable array variable');
    end;
    Node.Depth := Node.Left.Depth + 1;
    if Node.Right <> nil then Node.Depth := Max(Node.Depth, Node.Right.Depth + 1);
    if Node.Depth > 128 then Fail('Expression nesting limit exceeded');
  end;
end;

function TParser.ParsePrimary: TExpression;
begin
  Result := ParseAtom;
  try
    Select(Result);
  except
    Result.Free;
    raise;
  end;
end;

function TParser.MakeConstant(AType: TShaderType; ABits: UInt64; AAdaptable: Boolean;
  const APosition: TSourcePosition): TExpression;
begin
  Result := TExpression.Create;
  Result.Kind := ekConstant;
  Result.Position := APosition;
  Result.DataType := AType;
  Result.Bits := ABits;
  Result.Adaptable := AAdaptable;
end;

function HasBooleanLayout(AType: TShaderType; AComposite: TCompositeType): Boolean;
var Field: TTypeField;
begin
  if AType in [stBoolean, stEnum, stSet] then Exit(True);
  if AType <> stComposite then Exit(False);
  if AComposite.Kind = ctArray then Exit(HasBooleanLayout(AComposite.ElementType, AComposite.ElementComposite));
  for Field in AComposite.Fields do
    if HasBooleanLayout(Field.DataType, Field.Composite) then Exit(True);
  Result := False;
end;

// Low/High/Length/SizeOf take a type or an expression whose static type is used
// (the expression is not evaluated, as in Delphi). Odd/Succ/Pred are rewritten
// to ordinary integer arithmetic, so they fold like any constant expression.
function TParser.ParseBuiltin: TExpression;
var
  Name: string;
  Position: TSourcePosition;
  DataType: TShaderType;
  Composite: TCompositeType;
  Argument, One, Left: TExpression;
  Reference: TTypeReference;
  Variable: TShaderVariable;
  Owner: string;
  IsType: Boolean;
begin
  Name := LowerCase(FToken.Text);
  Position := FToken.Position;
  Next;
  Expect(tkLeftParen, '"(" after ' + Name);
  if (Name = 'odd') or (Name = 'succ') or (Name = 'pred') then
  begin
    Argument := ParseExpression;
    try
      Expect(tkRightParen, '")"');
      if (Argument.DataType = stEnum) and (Name <> 'odd') then
      begin
        // Succ/Pred of an enumeration: the next/previous ordinal (no range check).
        Composite := Argument.Composite;
        Left := Argument;
        Argument := nil;
        Convert(Left, stCardinal, True);
        if Name = 'succ' then
          Result := MakeBinary(opAdd, Left, MakeConstant(stCardinal, 1, False, Position), Position)
        else
          Result := MakeBinary(opSubtract, Left, MakeConstant(stCardinal, 1, False, Position), Position);
        Convert(Result, stEnum, True, Composite);
        Exit;
      end;
      if not IsScalarIntegerType(Argument.DataType) then
        raise EShaderError.Create(Position, Name + ' requires a scalar integer value');
      One := MakeConstant(Argument.DataType, 1, False, Position);
      // MakeBinary owns (and on error frees) both operands.
      Left := Argument;
      Argument := nil;
      if Name = 'odd' then
      begin
        Result := MakeBinary(opAnd, Left, One, Position);
        Result := MakeBinary(opNotEqual, Result, MakeConstant(Result.DataType, 0, False, Position), Position);
      end
      else if Name = 'succ' then
        Result := MakeBinary(opAdd, Left, One, Position)
      else
        Result := MakeBinary(opSubtract, Left, One, Position);
    except
      Argument.Free;
      raise;
    end;
    Exit;
  end;
  // Length(Buffer): runtime length of a storage buffer array.
  if (Name = 'length') and (FToken.Kind = tkIdentifier) and (PeekToken.Kind = tkRightParen) and
    not FLocalSymbols.ContainsKey(LowerCase(FToken.Text)) and
    FSymbols.TryGetValue(LowerCase(FToken.Text), Variable) and (Variable.Kind = vkBuffer) then
  begin
    if FCurrentFunction = nil then Fail('Length of a runtime buffer is not a constant');
    Next;
    Expect(tkRightParen, '")"');
    Result := TExpression.Create;
    Result.Kind := ekArrayLength;
    Result.Position := Position;
    Result.Variable := Variable;
    Result.DataType := stCardinal;
    Exit;
  end;
  Composite := nil;
  IsType := False;
  if (FToken.Kind = tkIdentifier) and not FLocalSymbols.ContainsKey(LowerCase(FToken.Text)) and
    not FSymbols.ContainsKey(LowerCase(FToken.Text)) then
  begin
    if TryShaderType(FToken.Text, DataType) then
    begin
      IsType := True;
      Next;
    end
    else
    begin
      Owner := ReadOwnerPrefix(True);
      if FindType(FToken.Text, Owner, Reference, False) then
      begin
        IsType := True;
        DataType := Reference.DataType;
        Composite := Reference.Composite;
        Next;
      end
      else if Owner <> '' then Fail('Unknown exported type in module ' + Owner);
    end;
  end;
  if not IsType then
  begin
    Argument := ParseExpression;
    DataType := Argument.DataType;
    Composite := Argument.Composite;
    Argument.Free; // only the static type is used; the expression is not evaluated
  end;
  Expect(tkRightParen, '")"');
  if Name = 'sizeof' then
  begin
    if (DataType = stVoid) or HasBooleanLayout(DataType, Composite) then
      raise EShaderError.Create(Position, 'SizeOf requires a type with a std430 layout (no Boolean, enumerations or sets)');
    Exit(MakeConstant(stInteger, TypeSize(DataType, Composite), True, Position));
  end;
  if (DataType = stComposite) and (Composite.Kind = ctArray) then
  begin
    if Name = 'low' then Exit(MakeConstant(stInteger, 0, True, Position));
    if Name = 'high' then Exit(MakeConstant(stInteger, Composite.Length - 1, True, Position));
    Exit(MakeConstant(stInteger, Composite.Length, True, Position));
  end;
  if (Name <> 'length') and (DataType = stEnum) then
  begin
    // Low/High of an enumeration (type or value): its smallest/largest enumerator.
    if Name = 'low' then Result := MakeConstant(stEnum, EnumLow(Composite), False, Position)
    else Result := MakeConstant(stEnum, EnumHigh(Composite), False, Position);
    Result.Composite := Composite;
    Exit;
  end;
  if (Name <> 'length') and IsScalarIntegerType(DataType) then
  begin
    // Low/High of an integer type or value: a typed constant of that type.
    if Name = 'low' then
    begin
      if IsSignedInteger(DataType) then
        Exit(MakeConstant(DataType, UInt64(1) shl (ScalarBitWidth(DataType) - 1), False, Position));
      Exit(MakeConstant(DataType, 0, False, Position));
    end;
    if IsSignedInteger(DataType) then
      Exit(MakeConstant(DataType, (UInt64(1) shl (ScalarBitWidth(DataType) - 1)) - 1, False, Position));
    Exit(MakeConstant(DataType, IntegerMask(DataType), False, Position));
  end;
  raise EShaderError.Create(Position, Name + ' requires a static array, an integer type or (Length) a storage buffer');
end;

function TParser.ParseDefault: TExpression;
begin
  Result := TExpression.Create;
  Result.Kind := ekDefault;
  Result.Position := FToken.Position;
  try
    ExpectWord('Default');
    Expect(tkLeftParen, '"("');
    Result.DataType := ReadType(Result.Composite);
    Expect(tkRightParen, '")"');
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ParseAtom: TExpression;
var
  Number: UInt64;
  LiteralBits: Cardinal;
  CastType: TShaderType;
  Intrinsic: TIntrinsic;
  Reference: TTypeReference;
  Owner: string;
  ConstantExpression: TExpression;
  Callee: TShaderFunction;
  Position: TSourcePosition;
  Field: TTypeField;
begin
  if FToken.Kind = tkLeftParen then
  begin
    Next;
    Result := ParseExpression;
    try
      Expect(tkRightParen, '")"');
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;
  if IsWord('Default') then Exit(ParseDefault);
  if FToken.Kind = tkLeftBracket then Exit(ParseSetConstructor);
  if IsWord('if') then
    Fail('An if expression inside an operand must be parenthesized: (if C then A else B)');
  if IsWord('Low') or IsWord('High') or IsWord('Length') or IsWord('SizeOf') or
    IsWord('Odd') or IsWord('Succ') or IsWord('Pred') then Exit(ParseBuiltin);
  if IsWord('AtomicAdd') or IsWord('AtomicExchange') or IsWord('AtomicCompareExchange') then Exit(ParseAtomic);
  if IsWord('ImageLoad') or IsWord('ImageSize') or IsWord('SampleLevel') then Exit(ParseImageOperation);
  Owner := ReadOwnerPrefix;
  if (Owner = '') and (FFunctions.ContainsKey(SymbolKey(CurrentOwner, FToken.Text)) or
    FNamedTypes.ContainsKey(SymbolKey(CurrentOwner, FToken.Text)) or FConstants.ContainsKey(SymbolKey(CurrentOwner, FToken.Text))) then
    Owner := CurrentOwner;
  if (Owner = '') and (FToken.Kind = tkIdentifier) and TryShaderType(FToken.Text, CastType) then
    Exit(ParseConstruct(CastType));
  if (FToken.Kind = tkIdentifier) and not FLocalSymbols.ContainsKey(LowerCase(FToken.Text)) and
    FindType(FToken.Text, Owner, Reference, False) then
  begin
    if FindFunction(FToken.Text, Owner, Callee, False) or FindConstant(FToken.Text, Owner, ConstantExpression, False) then
      Fail('Ambiguous exported identifier; use a module qualifier');
    if Reference.DataType in [stEnum, stSet] then
    begin
      Position := FToken.Position;
      Next;
      // TMode.Value: an enumerator qualified by its type.
      if (Reference.DataType = stEnum) and (FToken.Kind = tkDot) then
      begin
        Next;
        for Field in Reference.Composite.Fields do
          if IsWord(Field.Name) then
          begin
            Result := MakeConstant(stEnum, Field.Offset, False, Position);
            Result.Composite := Reference.Composite;
            Next;
            Exit;
          end;
        Fail(Format('"%s" is not a value of %s', [FToken.Text, Reference.Composite.Name]));
      end;
      // TMode(I), TModes(Mask): explicit ordinal casts.
      Expect(tkLeftParen, '"(" for a type cast');
      Result := ParseExpression;
      try
        Expect(tkRightParen, '")"');
        Convert(Result, Reference.DataType, True, Reference.Composite);
      except
        Result.Free;
        raise;
      end;
      Exit;
    end;
    if Reference.DataType = stComposite then
      Fail('Aggregate constructors are not supported; use Default(Type)');
    Exit(ParseConstruct(Reference.DataType));
  end;
  if (FToken.Kind = tkIdentifier) and not FLocalSymbols.ContainsKey(LowerCase(FToken.Text)) and
    FindConstant(FToken.Text, Owner, ConstantExpression, False) then
  begin
    if FindFunction(FToken.Text, Owner, Callee, False) then Fail('Ambiguous exported identifier; use a module qualifier');
    Result := TExpression.Create;
    Result.Kind := ConstantExpression.Kind; Result.Position := FToken.Position;
    Result.DataType := ConstantExpression.DataType; Result.Bits := ConstantExpression.Bits;
    Result.Composite := ConstantExpression.Composite; Result.Variable := ConstantExpression.Variable;
    Result.Adaptable := ConstantExpression.Adaptable;
    Next; Exit;
  end;
  if (Owner = '') and (FToken.Kind = tkIdentifier) and TryIntrinsic(FToken.Text, Intrinsic) then
    Exit(ParseIntrinsic(Intrinsic));
  if (Owner <> '') and (IsWord('true') or IsWord('false')) then
    Fail('Boolean literals are not module exports');
  if not ((FToken.Kind in [tkInteger, tkReal, tkDouble]) or IsWord('true') or IsWord('false')) then
  begin
    if not FLocalSymbols.ContainsKey(LowerCase(FToken.Text)) and not FSymbols.ContainsKey(LowerCase(FToken.Text)) and
      not FindFunction(FToken.Text, Owner, Callee, False) then
    begin
      FindType(FToken.Text, Owner, Reference); FindConstant(FToken.Text, Owner, ConstantExpression);
    end;
    Exit(ParseReference(False, Owner));
  end;
  Result := TExpression.Create;
  Result.Kind := ekConstant;
  Result.Position := FToken.Position;
  try
    if FToken.Kind = tkInteger then
    begin
      if not TryStrToUInt64(FToken.Text, Number) then
        Fail('Integer literal exceeds 64 bits');
      Result.Bits := Number;
      Result.Adaptable := True;
      if Number <= UInt64(High(Integer)) then
        Result.DataType := stInteger
      else if Number <= High(Cardinal) then Result.DataType := stCardinal
      else if Number <= UInt64(High(Int64)) then Result.DataType := stInt64
      else Result.DataType := stUInt64;
    end
    else if FToken.Kind = tkDouble then
    begin
      if not TryDecimalToDoubleBits(Copy(FToken.Text, 1, Length(FToken.Text) - 1), Result.Bits) then
        Fail('Real literal is outside the finite Double range');
      Result.DataType := stDouble;
    end
    else if FToken.Kind = tkReal then
    begin
      // One exact, correctly rounded decimal -> binary32 step (no Double detour).
      if not TryDecimalToSingleBits(FToken.Text, LiteralBits) then
        Fail('Real literal is outside the finite Single range');
      Result.DataType := stSingle;
      Result.Bits := LiteralBits;
    end
    else
    begin
      Result.DataType := stBoolean;
      Result.Bits := Ord(IsWord('true'));
    end;
    Next;
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ReadResource: TShaderVariable;
begin
  if FCurrentFunction = nil then Fail('Constant expressions cannot read GPU resources');
  if (FToken.Kind <> tkIdentifier) or not FSymbols.TryGetValue(LowerCase(FToken.Text), Result) then
    Fail('Expected a shader resource name');
  Next;
end;

function TParser.ParseAtomic: TExpression;
var
  Base: TExpression;
  Argument: TExpression;
  Count, I: Integer;
begin
  if (FCurrentFunction = nil) or (FCurrentFunction <> FModule.EntryPoint) then Fail('Atomics are only available in Main');
  Result := TExpression.Create;
  Result.Kind := ekAtomic; Result.Position := FToken.Position;
  if IsWord('AtomicAdd') then Result.AtomicKind := akAdd
  else if IsWord('AtomicExchange') then Result.AtomicKind := akExchange
  else Result.AtomicKind := akCompareExchange;
  try
    Next; Expect(tkLeftParen, '"("');
    Result.Left := ParseReference(True);
    if not (Result.Left.DataType in [stInteger, stCardinal]) then Fail('Atomic target must be scalar Integer or Cardinal');
    Base := Result.Left;
    while Base.Kind in [ekField,ekIndex,ekComponent] do Base := Base.Left;
    if (Base.Variable = nil) or not (Base.Variable.Kind in [vkBuffer,vkShared]) then
      Fail('Atomic target must be a ReadWrite storage buffer or shared array');
    if (Base.Variable.Kind = vkBuffer) and (Base.Variable.Access <> baReadWrite) then
      Fail('Atomic read-modify-write requires ReadWrite access');
    Result.DataType := Result.Left.DataType;
    Count := 1; if Result.AtomicKind = akCompareExchange then Count := 2;
    for I := 0 to Count - 1 do
    begin
      Expect(tkComma, '","'); Argument := ParseExpression;
      try Convert(Argument, Result.DataType); except Argument.Free; raise; end;
      Result.Arguments.Add(Argument);
    end;
    Expect(tkRightParen, '")"');
    Result.Depth := Result.Left.Depth + 1;
    for Argument in Result.Arguments do Result.Depth := Max(Result.Depth, Argument.Depth + 1);
    if Result.Depth > 128 then Fail('Expression nesting limit exceeded');
  except Result.Free; raise; end;
end;

function TParser.ParseImageOperation: TExpression;
var
  Name: string;
  Argument: TExpression;
begin
  Result := TExpression.Create; Result.Position := FToken.Position;
  Name := LowerCase(FToken.Text);
  try
    Next; Expect(tkLeftParen, '"("');
    Result.Variable := ReadResource;
    if Name = 'samplelevel' then
    begin
      if Result.Variable.Kind <> vkTexture then Fail('SampleLevel requires Texture2D');
      Result.Kind := ekSampleLevel; Result.DataType := stSingle4;
      Expect(tkComma, '","'); Result.Sampler := ReadResource;
      if Result.Sampler.Kind <> vkSampler then Fail('Expected a Sampler resource');
      Expect(tkComma, '","'); Argument := ParseExpression;
      try Convert(Argument, stSingle2); except Argument.Free; raise; end;
      Result.Arguments.Add(Argument);
      Expect(tkComma, '","'); Argument := ParseExpression;
      try Convert(Argument, stSingle); except Argument.Free; raise; end;
      Result.Arguments.Add(Argument);
    end
    else
    begin
      if Result.Variable.Kind <> vkImage then Fail('Image operations require a typed storage image');
      if Name = 'imagesize' then begin Result.Kind := ekImageSize; Result.DataType := stInteger2; end
      else
      begin
        Expect(tkComma, '","'); Argument := ParseExpression;
        Result.Arguments.Add(Argument);
        if not (Argument.DataType in [stInteger2,stCardinal2]) then Fail('Image coordinates must be Integer2 or Cardinal2');
        if Name = 'imageload' then
        begin
          if Result.Variable.Access = baWriteOnly then Fail('Cannot load a WriteOnly image');
          Result.Kind := ekImageLoad; Result.DataType := ImagePixelType(Result.Variable.ImageFormat);
        end
        else
        begin
          if Result.Variable.Access = baReadOnly then Fail('Cannot store a ReadOnly image');
          Result.Kind := ekImageStore; Result.DataType := stVoid;
          Expect(tkComma, '","'); Argument := ParseExpression;
          try Convert(Argument, ImagePixelType(Result.Variable.ImageFormat)); except Argument.Free; raise; end;
          Result.Arguments.Add(Argument);
        end;
      end;
    end;
    Expect(tkRightParen, '")"');
    for Argument in Result.Arguments do Result.Depth := Max(Result.Depth, Argument.Depth + 1);
    if Result.Depth > 128 then Fail('Expression nesting limit exceeded');
  except Result.Free; raise; end;
end;

// var/out arguments: writable function-local lvalues of exactly the parameter type.
procedure CheckReferenceArgument(AArgument: TExpression; AParameter: TShaderVariable);
var Base: TExpression;
begin
  Base := AArgument;
  while Base.Kind in [ekField, ekIndex, ekComponent] do Base := Base.Left;
  if (Base.Kind <> ekLocal) or not (Base.Variable.Kind in [vkLocal, vkParameter, vkResult]) then
    raise EShaderError.Create(AArgument.Position, 'var/out arguments must be writable function-local lvalues, not resources');
  if (AArgument.DataType <> AParameter.DataType) or (AArgument.Composite <> AParameter.Composite) then
    raise EShaderError.Create(AArgument.Position, 'var/out argument type must match exactly');
end;

function ConstantFits(const AValue: TConstantValue; AType: TShaderType): Boolean;
begin
  if IsSignedInteger(AValue.DataType) and (SignedValue(AValue.Bits, AValue.DataType) < 0) then
    Result := IsSignedInteger(AType) and
      (SignedValue(AValue.Bits, AValue.DataType) >= SignedValue(UInt64(1) shl (ScalarBitWidth(AType) - 1), AType))
  else if IsSignedInteger(AType) then Result := AValue.Bits <= (UInt64(1) shl (ScalarBitWidth(AType) - 1)) - 1
  else Result := AValue.Bits <= IntegerMask(AType);
end;

// Overload resolution cost of passing AArgument to AParameter: 0 exact type,
// 1 adapted untyped integer constant (or []), 2 implicit conversion to Single
// components, 3 to Double; -1 not acceptable (the same rules as assignment).
function ConversionCost(AArgument: TExpression; AParameter: TShaderVariable): Integer;
var
  S, T: TShaderType;
  V: TConstantValue;
begin
  S := AArgument.DataType;
  T := AParameter.DataType;
  if (S = T) and (AArgument.Composite = AParameter.Composite) then Exit(0);
  if AParameter.ParameterMode in [pmVar, pmOut] then Exit(-1);
  if (S in [stComposite, stEnum, stSet]) or (T in [stComposite, stEnum, stSet]) then
  begin
    if (S = stSet) and (T = stSet) and (AArgument.Composite = nil) and (AArgument.Kind = ekConstant) then Exit(1);
    Exit(-1);
  end;
  if IsScalarIntegerType(S) and IsScalarIntegerType(T) then
  begin
    if TreeAdaptable(AArgument) and EvaluateConstant(AArgument, V) and ExactNarrowConstant(AArgument) and
      ConstantFits(V, T) then Exit(1);
    Exit(-1);
  end;
  if IsNumericType(S) and IsNumericType(T) and (ComponentCount(S) = ComponentCount(T)) and IsFloatType(T) and
    not ((ComponentType(S) = stDouble) and (ComponentType(T) = stSingle)) then
  begin
    if ComponentType(T) = stSingle then Exit(2);
    Exit(3);
  end;
  Result := -1;
end;

// A call to a nested routine reads/writes variables of enclosing routines:
// the caller tracks them too (unless it owns them).
procedure TParser.NoteCall(ACallee: TShaderFunction; const APosition: TSourcePosition);
var V: TShaderVariable;
begin
  for V in ACallee.Captures do MarkCapture(V, APosition);
end;

// Arguments are parsed first (as references where all candidates of that
// position agree on var/out), then the unique best overload is selected:
// one whose per-argument costs are not worse than any other viable overload.
function TParser.ParseOverloadedCall(AHead: TShaderFunction): TExpression;
var
  Arguments: TList<TExpression>;
  Viable: TList<TShaderFunction>;
  Costs: TList<TArray<Integer>>;
  Candidate, Best: TShaderFunction;
  Position: TSourcePosition;
  Known, ByReference, Acceptable, Dominates: Boolean;
  Cost: TArray<Integer>;
  Argument: TExpression;
  I, J, K: Integer;
begin
  Position := FToken.Position;
  Next;
  Result := nil;
  Arguments := TList<TExpression>.Create;
  Viable := TList<TShaderFunction>.Create;
  Costs := TList<TArray<Integer>>.Create;
  try
    try
      if FToken.Kind = tkLeftParen then
      begin
        Next;
        if FToken.Kind <> tkRightParen then
          repeat
            I := Arguments.Count;
            Known := False;
            ByReference := False;
            Candidate := AHead;
            while Candidate <> nil do
            begin
              if Candidate.Parameters.Count > I then
              begin
                if not Known then
                begin
                  ByReference := Candidate.Parameters[I].ParameterMode in [pmVar, pmOut];
                  Known := True;
                end
                else if ByReference <> (Candidate.Parameters[I].ParameterMode in [pmVar, pmOut]) then
                  Fail(Format('Overloads of "%s" differ in var/out for argument %d; the call is ambiguous',
                    [AHead.Name, I + 1]));
              end;
              Candidate := Candidate.NextOverload;
            end;
            if not Known then Fail(Format('Too many arguments for "%s"', [AHead.Name]));
            if ByReference then Arguments.Add(ParseReference(True))
            else Arguments.Add(ParseExpression);
            if FToken.Kind <> tkComma then Break;
            Next;
          until False;
        Expect(tkRightParen, '")"');
      end;
      Candidate := AHead;
      while Candidate <> nil do
      begin
        if Candidate.Parameters.Count = Arguments.Count then
        begin
          SetLength(Cost, Arguments.Count);
          Acceptable := True;
          for I := 0 to Arguments.Count - 1 do
          begin
            Cost[I] := ConversionCost(Arguments[I], Candidate.Parameters[I]);
            if Cost[I] < 0 then Acceptable := False;
          end;
          if Acceptable then
          begin
            Viable.Add(Candidate);
            Costs.Add(Copy(Cost));
          end;
        end;
        Candidate := Candidate.NextOverload;
      end;
      if Viable.Count = 0 then
        raise EShaderError.Create(Position, Format('No overload of "%s" accepts these %d arguments',
          [AHead.Name, Arguments.Count]));
      Best := nil;
      for I := 0 to Viable.Count - 1 do
      begin
        Dominates := True;
        for J := 0 to Viable.Count - 1 do
          if I <> J then
            for K := 0 to Arguments.Count - 1 do
              if Costs[I][K] > Costs[J][K] then Dominates := False;
        if Dominates then
        begin
          if Best <> nil then Best := nil else Best := Viable[I];
          if Best = nil then Break;
        end;
      end;
      if Best = nil then
        raise EShaderError.Create(Position, Format('Ambiguous call to overloaded "%s"; use explicit casts', [AHead.Name]));
      if Best = FCurrentFunction then
        raise EShaderError.Create(Position, 'Recursion is not supported in shader functions');
      Result := TExpression.Create;
      Result.Kind := ekCall;
      Result.Position := Position;
      Result.Callee := Best;
      Result.DataType := Best.ReturnType;
      Result.Composite := Best.ReturnComposite;
      for I := 0 to Arguments.Count - 1 do
      begin
        Argument := Arguments[I];
        Arguments[I] := nil;
        try
          if Best.Parameters[I].ParameterMode in [pmVar, pmOut] then
            CheckReferenceArgument(Argument, Best.Parameters[I])
          else Convert(Argument, Best.Parameters[I].DataType, False, Best.Parameters[I].Composite);
        except
          Argument.Free;
          raise;
        end;
        Result.Arguments.Add(Argument);
        Result.Depth := Max(Result.Depth, Argument.Depth + 1);
      end;
      if Result.Depth > 128 then Fail('Expression nesting limit exceeded');
      NoteCall(Best, Position);
    except
      Result.Free;
      raise;
    end;
  finally
    for Argument in Arguments do Argument.Free;
    Arguments.Free;
    Viable.Free;
    Costs.Free;
  end;
end;

function TParser.ParseCall(ACallee: TShaderFunction): TExpression;
var
  Argument: TExpression;
  I: Integer;
begin
  if ACallee = FModule.EntryPoint then Fail('Entry point Main cannot be called');
  if ACallee.NextOverload <> nil then Exit(ParseOverloadedCall(ACallee));
  Result := TExpression.Create;
  Result.Kind := ekCall;
  Result.Position := FToken.Position;
  Result.Callee := ACallee;
  Result.DataType := ACallee.ReturnType;
  Result.Composite := ACallee.ReturnComposite;
  try
    if ACallee = FCurrentFunction then
      Fail('Recursion is not supported in shader functions');
    Next;
    if FToken.Kind <> tkLeftParen then
    begin
      // As in Delphi, a parameterless function/procedure may be called without ().
      if ACallee.Parameters.Count <> 0 then
        Fail(Format('Function "%s" expects %d arguments; use F(...)', [ACallee.Name, ACallee.Parameters.Count]));
      NoteCall(ACallee, Result.Position);
      Exit;
    end;
    Next;
    I := 0;
    if FToken.Kind <> tkRightParen then
      repeat
        if I >= ACallee.Parameters.Count then
          Fail(Format('Too many arguments for function "%s"', [ACallee.Name]));
        if ACallee.Parameters[I].ParameterMode in [pmVar, pmOut] then
          Argument := ParseReference(True)
        else Argument := ParseExpression;
        try
          if ACallee.Parameters[I].ParameterMode in [pmVar, pmOut] then
            CheckReferenceArgument(Argument, ACallee.Parameters[I])
          else Convert(Argument, ACallee.Parameters[I].DataType, False, ACallee.Parameters[I].Composite);
        except
          Argument.Free;
          raise;
        end;
        Result.Arguments.Add(Argument);
        Result.Depth := Max(Result.Depth, Argument.Depth + 1);
        if Result.Depth > 128 then
          Fail('Expression nesting limit exceeded');
        Inc(I);
        if FToken.Kind <> tkComma then
          Break;
        Next;
      until False;
    Expect(tkRightParen, '")"');
    if I <> ACallee.Parameters.Count then
      raise EShaderError.Create(Result.Position,
        Format('Function "%s" expects %d arguments, got %d',
        [ACallee.Name, ACallee.Parameters.Count, I]));
    NoteCall(ACallee, Result.Position);
  except
    Result.Free;
    raise;
  end;
end;

function TParser.ParseReference(AForWrite: Boolean; const AOwner: string): TExpression;
var
  Variable: TShaderVariable;
  Callee: TShaderFunction;
  Name: TToken;
  Owner: string;
  ConstantExpression: TExpression;
  Builtin: TInvocationBuiltin;
begin
  if FToken.Kind <> tkIdentifier then
    Fail('Expected a variable, literal or parenthesized expression');
  Owner := AOwner;
  if Owner = '' then Owner := ReadOwnerPrefix;
  Name := FToken;
  if AForWrite and FindConstant(Name.Text, Owner, ConstantExpression, False) then Fail('Constants are read-only');
  if IsWord('Main') then
    Fail('Entry point Main cannot be called');
  if not FLocalSymbols.ContainsKey(LowerCase(Name.Text)) and
    FindFunction(Name.Text, Owner, Callee) then
  begin
    if AForWrite then
    begin
      // Delphi: inside function F (also in its nested routines), "F := Value"
      // assigns the result of F (same as Result).
      Callee := EnclosingResult(Callee);
      if Callee = nil then
        Fail('Functions must be called as expressions; cannot assign to a function');
      MarkCapture(Callee.ResultVariable, Name.Position);
      Result := TExpression.Create;
      try
        Result.Kind := ekLocal;
        Result.Position := Name.Position;
        Result.Variable := Callee.ResultVariable;
        Result.DataType := Result.Variable.DataType;
        Result.Composite := Result.Variable.Composite;
        Next;
        Select(Result);
        CheckWriteTarget(Result);
      except
        Result.Free;
        raise;
      end;
      Exit;
    end;
    Exit(ParseCall(Callee));
  end;
  // A consumed qualifier is a namespace boundary, never a hint to retry locals,
  // shader resources or invocation built-ins under the same short name.
  if Owner <> '' then Fail('Unknown exported value in module ' + Owner);
  Result := TExpression.Create;
  Result.Position := Name.Position;
  try
    if TryBuiltin(FToken.Text, Builtin) then
    begin
      if FCurrentFunction = nil then Fail('Constant expressions cannot read GPU built-ins');
      if AForWrite then
        Fail('GlobalInvocationID is read-only');
      Next;
      Result.Kind := ekInvocationID;
      Result.Builtin := Builtin;
      Result.DataType := BuiltinType(Builtin);
      Exit;
    end;
    if not FLocalSymbols.TryGetValue(LowerCase(Name.Text), Variable) and
      not FSymbols.TryGetValue(LowerCase(Name.Text), Variable) then
      Fail(Format('Unknown identifier "%s"; functions must be declared before use', [Name.Text]));
    // Top-level constant contexts (attributes, bounds, const) have no function.
    if FCurrentFunction = nil then
      Fail('Constant expressions cannot read variables or GPU resources');
    Result.Variable := Variable;
    Result.DataType := Variable.DataType;
    Result.Composite := Variable.Composite;
    if Variable.Kind in [vkLocal, vkParameter, vkResult] then MarkCapture(Variable, Name.Position);
    Next;
    case Variable.Kind of
      vkShared: Result.Kind := ekLocal;
      vkImage, vkTexture, vkSampler: Fail('Opaque resources require ImageLoad/ImageStore/ImageSize/SampleLevel');
      vkLocal, vkParameter, vkResult:
        begin
          Result.Kind := ekLocal;
          if AForWrite and Variable.ActiveFor then
            raise EShaderError.Create(Name.Position, 'Cannot assign to an active for-loop counter');
          if AForWrite and (Variable.Kind = vkParameter) and (Variable.ParameterMode = pmConst) then
            Fail('Const parameters are read-only');
        end;
      vkBuffer:
        begin
          Result.Kind := ekBufferElement;
          if AForWrite and (Variable.Access = baReadOnly) then
            raise EShaderError.Create(Name.Position, 'Cannot write to a ReadOnly buffer');
          if not AForWrite and (Variable.Access = baWriteOnly) then
            raise EShaderError.Create(Name.Position, 'Cannot read from a WriteOnly buffer');
          Expect(tkLeftBracket, '"["');
          Result.Left := ParseExpression;
          Result.Depth := Result.Left.Depth + 1;
          if Result.Depth > 128 then
            Fail('Expression nesting limit exceeded');
          if not IsScalarIntegerType(Result.Left.DataType) then
            Fail('Buffer indices must have type Integer or Cardinal');
          CheckConstantIndex(Result.Left, -1);
          if FToken.Kind = tkComma then FToken.Kind := tkLeftBracket
          else Expect(tkRightBracket, '"]"');
        end;
      vkPushConstant:
        begin
          Result.Kind := ekPushConstant;
          if AForWrite then
            raise EShaderError.Create(Name.Position, 'Push constants are read-only');
        end;
    end;
    if AForWrite then
    begin
      Select(Result);
      CheckWriteTarget(Result);
    end;
  except
    Result.Free;
    raise;
  end;
end;

// The function (current or enclosing) named by ACallee whose Result "Name := V"
// assigns, or nil.
function TParser.EnclosingResult(ACallee: TShaderFunction): TShaderFunction;
begin
  Result := FCurrentFunction;
  while Result <> nil do
  begin
    if (Result.ResultVariable <> nil) and InOverloadChain(ACallee, Result) then Exit;
    Result := Result.Outer;
  end;
end;

// A variable of an enclosing routine used inside a nested one. It lives in
// Private memory; every routine between the user and the owner tracks it for
// definite assignment at its calls.
procedure TParser.MarkCapture(AVariable: TShaderVariable; const APosition: TSourcePosition);
var
  F: TShaderFunction;
begin
  if (AVariable.Owner = nil) or (AVariable.Owner = FCurrentFunction) then Exit;
  if (AVariable.Kind = vkParameter) and (AVariable.ParameterMode in [pmVar, pmOut]) then
    raise EShaderError.Create(APosition, Format(
      'A nested routine cannot use var/out parameter "%s" of an enclosing routine; pass it as an argument',
      [AVariable.Name]));
  if AVariable.ActiveFor then
    raise EShaderError.Create(APosition, 'An active for-loop counter cannot be used by a nested routine');
  AVariable.Captured := True;
  F := FCurrentFunction;
  while (F <> nil) and (F <> AVariable.Owner) do
  begin
    if not F.Captures.Contains(AVariable) then F.Captures.Add(AVariable);
    F := F.Outer;
  end;
end;

// A swizzle may only be the outermost selector of an assignment target
// (V.XY := ...); writes through a swizzled value have no storage.
procedure TParser.CheckWriteTarget(ATarget: TExpression);
var
  Node: TExpression;
  Seen: Cardinal;
  I: Integer;
  Component: Cardinal;
begin
  Node := ATarget;
  if Node.Kind = ekSwizzle then
  begin
    Seen := 0;
    for I := 0 to Integer(Node.MemberIndex) - 1 do
    begin
      Component := Cardinal(Node.Bits shr (2 * I)) and 3;
      if Seen and (1 shl Component) <> 0 then
        raise EShaderError.Create(Node.Position, 'A swizzle assignment cannot repeat a component');
      Seen := Seen or (1 shl Component);
    end;
    Node := Node.Left;
  end;
  while Node.Kind in [ekField, ekIndex, ekComponent, ekSwizzle] do
  begin
    if Node.Kind = ekSwizzle then
      raise EShaderError.Create(Node.Position, 'Cannot write through a swizzle; select components of the variable');
    Node := Node.Left;
  end;
end;

procedure TParser.ParseLibraries;
var
  Document: TSourceDocument;
  Attributes: TAttributes;
begin
  if FProgram = nil then Exit;
  Attributes := Default(TAttributes);
  for Document in FProgram.Libraries do
  begin
    FActiveLibrary := Document;
    FreeAndNil(FLexer);
    FLexer := TLexer.Create(Document);
    FHasLookahead := False;
    Next;
    while IsWord('type') or IsWord('const') do
      if IsWord('type') then ParseTypes else ParseConstants;
    while IsWord('function') or (IsWord('procedure') and not SameText(PeekToken.Text, 'Main')) do ParseFunction(False, Attributes);
    if FToken.Kind <> tkEOF then
      Fail('Modules may only declare types and functions or constants; resources and Main belong to the shader');
  end;
  FActiveLibrary := nil;
  FreeAndNil(FLexer);
  FLexer := TLexer.Create(FProgram.Root);
  FHasLookahead := False;
end;

// Every forward declaration needs a definition, and forward declarations must
// not create recursion (SPIR-V for Vulkan forbids it): the call graph is acyclic.
procedure TParser.CheckCallGraph;
var
  State: TDictionary<TShaderFunction, Integer>; // 1 = on the current path, 2 = done
  Path: TList<TShaderFunction>;

  procedure CollectExpression(E: TExpression; ACalls: TList<TShaderFunction>);
  var A: TExpression;
  begin
    if E = nil then Exit;
    if (E.Kind = ekCall) and not ACalls.Contains(E.Callee) then ACalls.Add(E.Callee);
    CollectExpression(E.Left, ACalls);
    CollectExpression(E.Right, ACalls);
    for A in E.Arguments do CollectExpression(A, ACalls);
  end;

  procedure CollectStatement(S: TStatement; ACalls: TList<TShaderFunction>);
  var C: TStatement;
  begin
    if S = nil then Exit;
    CollectExpression(S.Target, ACalls); CollectExpression(S.Value, ACalls);
    CollectExpression(S.Condition, ACalls); CollectExpression(S.Limit, ACalls);
    CollectStatement(S.ThenPart, ACalls); CollectStatement(S.ElsePart, ACalls); CollectStatement(S.Body, ACalls);
    for C in S.Children do CollectStatement(C, ACalls);
  end;

  procedure Visit(F: TShaderFunction);
  var
    Calls: TList<TShaderFunction>;
    G: TShaderFunction;
    Cycle: string;
    I: Integer;
  begin
    State.AddOrSetValue(F, 1);
    Path.Add(F);
    Calls := TList<TShaderFunction>.Create;
    try
      CollectStatement(F.Body, Calls);
      for G in Calls do
      begin
        if State.ContainsKey(G) and (State[G] = 1) then
        begin
          Cycle := '';
          for I := Path.IndexOf(G) to Path.Count - 1 do Cycle := Cycle + Path[I].Name + ' -> ';
          raise EShaderError.Create(G.Position, 'Recursion is not supported in shader functions: ' + Cycle + G.Name);
        end;
        if not State.ContainsKey(G) then Visit(G);
      end;
    finally
      Calls.Free;
    end;
    Path.Delete(Path.Count - 1);
    State[F] := 2;
  end;

var
  F: TShaderFunction;
begin
  for F in FModule.Functions do
    if F.IsForward then
      raise EShaderError.Create(F.Position, Format('Forward declaration of "%s" has no definition', [F.Name]));
  State := TDictionary<TShaderFunction, Integer>.Create;
  Path := TList<TShaderFunction>.Create;
  try
    for F in FModule.Functions do
      if not State.ContainsKey(F) then Visit(F);
  finally
    Path.Free;
    State.Free;
  end;
end;

function TParser.Parse: TShaderModule;
var
  Attributes: TAttributes;
begin
  FModule := TShaderModule.Create;
  ParseLibraries;
  Next;
  if IsWord('uses') or IsWord('module') then
    Fail('Modules require file compilation; use TShaderCompiler.CompileFile');
  while IsWord('type') or IsWord('const') do
    if IsWord('type') then ParseTypes else ParseConstants;
  Attributes := Default(TAttributes);
  if IsWord('var') then
  begin
    Next;
    while not IsWord('procedure') and not IsWord('function') do
    begin
      Attributes := ReadAttributes;
      if IsWord('procedure') or IsWord('function') then
        Break;
      ParseResource(Attributes);
      Attributes := Default(TAttributes);
    end;
    if FModule.Resources.Count = 0 then
      Fail('Expected at least one resource declaration after var');
  end
  else
    Attributes := ReadAttributes;
  while IsWord('function') or (IsWord('procedure') and not SameText(PeekToken.Text, 'Main')) do
  begin
    ParseFunction(False, Attributes);
    Attributes := ReadAttributes;
  end;
  ParseFunction(True, Attributes);
  Expect(tkEOF, 'end of file');
  CheckCallGraph;
  CheckProfile(FModule);
  Result := FModule;
  FModule := nil;
end;

end.
