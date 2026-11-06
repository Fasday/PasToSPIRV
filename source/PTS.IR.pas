unit PTS.IR;

interface

uses
  System.Generics.Collections,
  PTS.Types,
  PTS.Features,
  PTS.Diagnostics;

const
  MaxShaderParameters = 255;
  MaxSwitchLabels = 16383;

type
  TVariableKind = (vkLocal, vkBuffer, vkPushConstant, vkParameter, vkResult,
    vkShared, vkImage, vkTexture, vkSampler, vkConstant);
  TBufferAccess = (baReadOnly, baWriteOnly, baReadWrite);
  TParameterMode = (pmValue, pmConst, pmVar, pmOut);

  TShaderFunction = class;

  TShaderVariable = class
  public
    Name: string;
    Position: TSourcePosition;
    Kind: TVariableKind;
    DataType: TShaderType;
    Composite: TCompositeType;
    DescriptorSet: Cardinal;
    Binding: Cardinal;
    Access: TBufferAccess;
    Aliased: Boolean;
    Initialized: Boolean;
    ActiveFor: Boolean;
    ParameterMode: TParameterMode;
    ImageFormat: TImageFormat;
    // Locals/parameters/Result: the declaring function (non-owning).
    Owner: TShaderFunction;
    // Used by a nested routine: stored in Private (per-invocation) memory, which
    // is exact because shader functions are never recursive.
    Captured: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TExpressionKind = (ekConstant, ekLocal, ekBufferElement,
    ekInvocationID, ekUnary, ekBinary, ekConvert, ekCall, ekConstruct,
    ekComponent, ekIntrinsic, ekField, ekIndex, ekPushConstant, ekDefault,
    ekAtomic, ekImageLoad, ekImageStore, ekImageSize, ekSampleLevel, ekConstantArray,
    ekArrayLength,  // Length(RuntimeBuffer): OpArrayLength, Cardinal
    ekSwizzle,      // Left.XY..: MemberIndex = count, Bits = 2-bit component indices
    ekConditional,  // if Arguments[0] then Left else Right (only one branch evaluated)
    ekInSet,        // Left in [Arguments]: values or ekRange items, Left evaluated once
    ekRange);       // Left..Right inside ekInSet
  TAtomicKind = (akAdd, akExchange, akCompareExchange);
  TBarrierKind = (bkWorkgroup, bkBuffer, bkImage);
  TIntrinsic = (inMin, inMax, inAbs, inClamp, inDot, inSqrt,
    inSingleToBits, inBitsToSingle, inDoubleToBits, inBitsToDouble,
    inRoundEven, inRound, inTrunc, inFloor, inCeil, inIsNan, inIsInfinite,
    inLdexp, inFindMSB, inFindLSB, inArithmeticShiftRight,
    inOrd,   // Ord(Boolean) -> Integer 0/1
    inSqr);  // Sqr(X) = X * X with X evaluated once
  TOperator = (opNone, opNegate, opNot, opAdd, opSubtract, opMultiply,
    opDivide, opIntDivide, opModulo, opEqual, opNotEqual, opLess,
    opLessEqual, opGreater, opGreaterEqual, opAnd, opOr, opXor,
    opShiftLeft, opShiftRight);

  { Typed, owning expression tree: the initial intermediate representation.
    Variable/callee references are non-owning; the module/function owns them. }
  TExpression = class
  public
    Kind: TExpressionKind;
    DataType: TShaderType;
    Composite: TCompositeType;
    Depth: Integer;
    Position: TSourcePosition;
    Bits: UInt64;
    Variable: TShaderVariable;
    MemberIndex: Cardinal;
    ConstantIndex: Boolean;
    // True only for untyped integer literals/constants that may adapt implicitly.
    Adaptable: Boolean;
    ExplicitType: Boolean; // Casts also fix the type of unary/binary constant trees.
    // Boolean and/or: right operand evaluated only when needed ({$B-}, Delphi default).
    ShortCircuit: Boolean;
    Operation: TOperator;
    Left: TExpression;
    Right: TExpression;
    Callee: TShaderFunction;
    Arguments: TObjectList<TExpression>;
    Intrinsic: TIntrinsic;
    AtomicKind: TAtomicKind;
    Builtin: TInvocationBuiltin;
    Sampler: TShaderVariable;
    constructor Create;
    destructor Destroy; override;
  end;

  TStatementKind = (skBlock, skAssign, skIf, skWhile, skFor, skEvaluate, skBarrier,
    skReturn, skBreak, skContinue, skCase, skRepeat,
    skDeclare,     // inline var: Target, optional initializer Value
    skIncrement);  // Inc/Dec/Include/Exclude: Target := Target <Operation> Value, one address
  TStatement = class
  public
    Kind: TStatementKind;
    Position: TSourcePosition;
    Children: TObjectList<TStatement>;
    Target: TExpression;
    Value: TExpression;
    Condition: TExpression;
    ThenPart: TStatement;
    ElsePart: TStatement;
    Body: TStatement;
    Limit: TExpression;
    Descending: Boolean;
    Operation: TOperator; // skIncrement: opAdd, opSubtract, opOr (Include), opAnd (Exclude)
    BarrierKind: TBarrierKind;
    CaseLabels: TArray<TArray<UInt64>>;
    constructor Create;
    destructor Destroy; override;
  end;

  TShaderFunction = class
  public
    Name: string;
    ModuleName: string;
    Position: TSourcePosition;
    ReturnType: TShaderType;
    ReturnComposite: TCompositeType;
    Parameters: TObjectList<TShaderVariable>;
    Locals: TObjectList<TShaderVariable>;
    ResultVariable: TShaderVariable; // Non-owning; also in Locals.
    Body: TStatement;
    Index: Integer;                  // Position in TShaderModule.Functions (unique key).
    IsForward: Boolean;              // Declared with forward; body not parsed yet.
    IsOverload: Boolean;
    NextOverload: TShaderFunction;   // Non-owning chain of same-named overloads.
    Outer: TShaderFunction;          // Enclosing routine of a nested function.
    // Non-owning: variables of enclosing routines used here (directly or by calls),
    // and the summary used at call sites: read before written / written on return.
    Captures: TList<TShaderVariable>;
    CaptureReads: TList<TShaderVariable>;
    CaptureWrites: TList<TShaderVariable>;
    constructor Create;
    destructor Destroy; override;
  end;

  TShaderModule = class
  public
    Resources: TObjectList<TShaderVariable>;
    Types: TObjectList<TCompositeType>;
    Functions: TObjectList<TShaderFunction>;
    EntryPoint: TShaderFunction; // Non-owning; also in Functions.
    EntryPointName: string; // External SPIR-V name; the source procedure remains Main.
    LocalSize: array[0..2] of Cardinal;
    SharedBytes: Cardinal;
    UsesWorkgroupBarrier: Boolean;
    Extended: Boolean;
    Vulkan11: Boolean;
    StrictFloat: Boolean;
    UsedTypes: set of TShaderType;
    HasReferences: Boolean;
    Storage8, Storage16, Push8, Push16: Boolean;
    Constants: TObjectDictionary<TShaderVariable, TExpression>;
    ConstantOrder: TList<TShaderVariable>;
    constructor Create;
    destructor Destroy; override;
  end;

function ExpressionIsAddressable(AExpression: TExpression): Boolean;

implementation

function ExpressionIsAddressable(AExpression: TExpression): Boolean;
begin
  case AExpression.Kind of
    ekLocal, ekBufferElement, ekPushConstant: Result := True;
    ekField, ekIndex, ekComponent: Result := ExpressionIsAddressable(AExpression.Left);
    // A swizzle is written component by component; it has no single address.
  else
    Result := False;
  end;
end;

constructor TShaderVariable.Create;
begin
  inherited;
end;

destructor TShaderVariable.Destroy;
begin
  inherited;
end;

constructor TExpression.Create;
begin
  inherited Create;
  Depth := 1;
  Arguments := TObjectList<TExpression>.Create(True);
end;

destructor TExpression.Destroy;
begin
  Arguments.Free;
  Right.Free;
  Left.Free;
  inherited;
end;

constructor TStatement.Create;
begin
  inherited;
  Children := TObjectList<TStatement>.Create(True);
end;

destructor TStatement.Destroy;
begin
  Limit.Free;
  Body.Free;
  ElsePart.Free;
  ThenPart.Free;
  Condition.Free;
  Value.Free;
  Target.Free;
  Children.Free;
  inherited;
end;

constructor TShaderFunction.Create;
begin
  inherited Create;
  Parameters := TObjectList<TShaderVariable>.Create(True);
  Locals := TObjectList<TShaderVariable>.Create(True);
  Captures := TList<TShaderVariable>.Create;
  CaptureReads := TList<TShaderVariable>.Create;
  CaptureWrites := TList<TShaderVariable>.Create;
end;

destructor TShaderFunction.Destroy;
begin
  CaptureWrites.Free;
  CaptureReads.Free;
  Captures.Free;
  Body.Free;
  Locals.Free;
  Parameters.Free;
  inherited;
end;

constructor TShaderModule.Create;
begin
  inherited;
  EntryPointName := 'Main';
  Resources := TObjectList<TShaderVariable>.Create(True);
  Types := TObjectList<TCompositeType>.Create(True);
  Functions := TObjectList<TShaderFunction>.Create(True);
  Constants := TObjectDictionary<TShaderVariable, TExpression>.Create([doOwnsKeys, doOwnsValues]);
  ConstantOrder := TList<TShaderVariable>.Create;
  LocalSize[0] := 64;
  LocalSize[1] := 1;
  LocalSize[2] := 1;
end;

destructor TShaderModule.Destroy;
begin
  ConstantOrder.Free;
  Constants.Free;
  Functions.Free;
  Resources.Free;
  Types.Free;
  inherited;
end;

end.
