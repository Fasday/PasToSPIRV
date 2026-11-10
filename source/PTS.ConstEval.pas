unit PTS.ConstEval;

{$BOOLEVAL OFF}
{$Q-}
{$R-}

interface

uses PTS.Types, PTS.IR;

type
  TConstantValue = record
    DataType: TShaderType;
    Bits: UInt64;
  end;

function EvaluateConstant(AExpression: TExpression; out AValue: TConstantValue): Boolean;
function HasFloat(E: TExpression): Boolean;
// For an untyped integer constant tree narrower than 64 bits: True when its
// width-specific result equals the mathematical value (no wraparound, no masked
// shift count, no width-dependent unsigned not/negative shr). Only such a value
// may be adapted to another integer type; a wrapped one must not silently widen.
function ExactNarrowConstant(AExpression: TExpression): Boolean;
procedure OptimizeConstants(AModule: TShaderModule);

implementation

uses System.SysUtils, System.Math, PTS.FloatLiteral, PTS.FloatEnvironment;

function AsFloat(const V: TConstantValue): Double;
var S: Single;
begin
  if V.DataType = stDouble then Move(V.Bits, Result, 8)
  else begin Move(V.Bits, S, 4); Result := S; end;
end;

// binary64/binary32 operations rounded once. Win32 code would use the x87 FPU,
// which rounds a Double result twice (a subnormal one even at 53-bit precision
// control): there the operations are SSE2 scalar instructions, as on other hosts.
{$IF Defined(MSWINDOWS) and Defined(CPUX86)}
  {$DEFINE PTS_SSE2_OPERATIONS}
{$ENDIF}

{$IFDEF PTS_SSE2_OPERATIONS}
procedure AddDouble(A, B, R: PDouble);
asm
        MOVSD   XMM0, QWORD PTR [EAX]
        ADDSD   XMM0, QWORD PTR [EDX]
        MOVSD   QWORD PTR [ECX], XMM0
end;

procedure SubtractDouble(A, B, R: PDouble);
asm
        MOVSD   XMM0, QWORD PTR [EAX]
        SUBSD   XMM0, QWORD PTR [EDX]
        MOVSD   QWORD PTR [ECX], XMM0
end;

procedure MultiplyDouble(A, B, R: PDouble);
asm
        MOVSD   XMM0, QWORD PTR [EAX]
        MULSD   XMM0, QWORD PTR [EDX]
        MOVSD   QWORD PTR [ECX], XMM0
end;

procedure DivideDouble(A, B, R: PDouble);
asm
        MOVSD   XMM0, QWORD PTR [EAX]
        DIVSD   XMM0, QWORD PTR [EDX]
        MOVSD   QWORD PTR [ECX], XMM0
end;

procedure AddSingle(A, B, R: PSingle);
asm
        MOVSS   XMM0, DWORD PTR [EAX]
        ADDSS   XMM0, DWORD PTR [EDX]
        MOVSS   DWORD PTR [ECX], XMM0
end;

procedure SubtractSingle(A, B, R: PSingle);
asm
        MOVSS   XMM0, DWORD PTR [EAX]
        SUBSS   XMM0, DWORD PTR [EDX]
        MOVSS   DWORD PTR [ECX], XMM0
end;

procedure MultiplySingle(A, B, R: PSingle);
asm
        MOVSS   XMM0, DWORD PTR [EAX]
        MULSS   XMM0, DWORD PTR [EDX]
        MOVSS   DWORD PTR [ECX], XMM0
end;

procedure DivideSingle(A, B, R: PSingle);
asm
        MOVSS   XMM0, DWORD PTR [EAX]
        DIVSS   XMM0, DWORD PTR [EDX]
        MOVSS   DWORD PTR [ECX], XMM0
end;
{$ENDIF}

// AOperation is opAdd, opSubtract, opMultiply or opDivide.
function DoubleOperation(AOperation: TOperator; X, Y: Double): Double;
begin
  {$IFDEF PTS_SSE2_OPERATIONS}
  case AOperation of
    opAdd: AddDouble(@X, @Y, @Result);
    opSubtract: SubtractDouble(@X, @Y, @Result);
    opMultiply: MultiplyDouble(@X, @Y, @Result);
  else
    DivideDouble(@X, @Y, @Result);
  end;
  {$ELSE}
  case AOperation of
    opAdd: Result := X + Y;
    opSubtract: Result := X - Y;
    opMultiply: Result := X * Y;
  else
    Result := X / Y;
  end;
  {$ENDIF}
end;

function SingleOperation(AOperation: TOperator; X, Y: Single): Single;
begin
  {$IFDEF PTS_SSE2_OPERATIONS}
  case AOperation of
    opAdd: AddSingle(@X, @Y, @Result);
    opSubtract: SubtractSingle(@X, @Y, @Result);
    opMultiply: MultiplySingle(@X, @Y, @Result);
  else
    DivideSingle(@X, @Y, @Result);
  end;
  {$ELSE}
  case AOperation of
    opAdd: Result := X + Y;
    opSubtract: Result := X - Y;
    opMultiply: Result := X * Y;
  else
    Result := X / Y;
  end;
  {$ENDIF}
end;

function EvaluateDefined(AExpression: TExpression; out AValue: TConstantValue): Boolean;
var
  A, B, C: TConstantValue;
  Item: TExpression;
  X, Y, Z, Lower, Upper: Double;
  S: Single;
  I, J: Int64;
  U, V: UInt64;
  Flag: Boolean;
  ShiftCount: Integer;
  Text: string;
  SingleBits: Cardinal;
begin
  Result := False;
  AValue.DataType := AExpression.DataType;
  AValue.Bits := 0;
  if ComponentCount(AValue.DataType) <> 1 then Exit;
  if AExpression.Kind = ekConstant then
  begin
    AValue.Bits := AExpression.Bits;
    Exit(True);
  end;
  if (AExpression.Kind = ekIntrinsic) and (AExpression.Intrinsic in [inOrd, inSqr]) then
  begin
    if not EvaluateConstant(AExpression.Arguments[0], A) then Exit;
    if AExpression.Intrinsic = inOrd then
      AValue.Bits := A.Bits and 1
    else if A.DataType = stSingle then
    begin
      S := SingleOperation(opMultiply, Single(AsFloat(A)), Single(AsFloat(A)));
      if IsNan(S) or IsInfinite(S) then Exit;
      Move(S, AValue.Bits, 4);
    end
    else if A.DataType = stDouble then
    begin
      Z := DoubleOperation(opMultiply, AsFloat(A), AsFloat(A));
      if IsNan(Z) or IsInfinite(Z) then Exit;
      Move(Z, AValue.Bits, 8);
    end
    else AValue.Bits := (A.Bits * A.Bits) and IntegerMask(A.DataType);
    Exit(True);
  end;
  if AExpression.Kind = ekConditional then
  begin
    // Only the selected branch is ever evaluated.
    if not EvaluateConstant(AExpression.Arguments[0], A) then Exit;
    if A.Bits <> 0 then Exit(EvaluateConstant(AExpression.Left, AValue))
    else Exit(EvaluateConstant(AExpression.Right, AValue));
  end;
  if AExpression.Kind = ekInSet then
  begin
    if not EvaluateConstant(AExpression.Left, A) then Exit;
    Flag := False;
    for Item in AExpression.Arguments do
    begin
      if Item.Kind = ekRange then
      begin
        if not EvaluateConstant(Item.Left, B) or not EvaluateConstant(Item.Right, C) then Exit;
        if IsSignedInteger(A.DataType) then
          Flag := Flag or ((SignedValue(B.Bits, A.DataType) <= SignedValue(A.Bits, A.DataType)) and
            (SignedValue(A.Bits, A.DataType) <= SignedValue(C.Bits, A.DataType)))
        else Flag := Flag or ((B.Bits <= A.Bits) and (A.Bits <= C.Bits));
      end
      else
      begin
        if not EvaluateConstant(Item, B) then Exit;
        Flag := Flag or (B.Bits = A.Bits);
      end;
    end;
    AValue.Bits := Ord(Flag);
    Exit(True);
  end;
  if not (AExpression.Kind in [ekUnary, ekBinary, ekConvert]) then Exit;
  if not EvaluateConstant(AExpression.Left, A) then Exit;
  if AExpression.Kind = ekConvert then
  begin
    if IsFloatType(AValue.DataType) then
    begin
      if IsScalarIntegerType(A.DataType) then
      begin
        if IsSignedInteger(A.DataType) then Text := IntToStr(SignedValue(A.Bits, A.DataType))
        else Text := UIntToStr(A.Bits);
        Flag := (Length(Text) > 0) and (Text[1] = '-');
        if Flag then Delete(Text, 1, 1);
        if AValue.DataType = stSingle then
        begin
          if not TryDecimalToSingleBits(Text, SingleBits) then Exit;
          AValue.Bits := SingleBits;
          if Flag then AValue.Bits := AValue.Bits xor $80000000;
        end
        else
        begin
          if not TryDecimalToDoubleBits(Text, AValue.Bits) then Exit;
          if Flag then AValue.Bits := AValue.Bits xor $8000000000000000;
        end;
        Exit(True);
      end;
      if IsFloatType(A.DataType) then Z := AsFloat(A)
      else if IsSignedInteger(A.DataType) then Z := SignedValue(A.Bits, A.DataType)
      else Z := A.Bits;
      if AValue.DataType = stSingle then
      begin S := Z; if IsNan(S) or IsInfinite(S) then Exit; Move(S, AValue.Bits, 4); end
      else Move(Z, AValue.Bits, 8);
      if IsNan(Z) or IsInfinite(Z) then Exit;
    end
    else if IsFloatType(A.DataType) then
    begin
      X := AsFloat(A);
      if IsNan(X) or IsInfinite(X) then Exit;
      if IsSignedInteger(AValue.DataType) then
      begin
        Upper := IntPower(2, ScalarBitWidth(AValue.DataType) - 1);
        Lower := -Upper;
        if ScalarBitWidth(AValue.DataType) < 64 then
        begin if (X >= Upper) or (X <= Lower - 1.0) then Exit; end
        else if (X >= Upper) or (X < Lower) then Exit;
      end
      else if (X <= -1.0) or (X >= IntPower(2, ScalarBitWidth(AValue.DataType))) then Exit;
      if not IsSignedInteger(AValue.DataType) and (X >= 9223372036854775808.0) then
        AValue.Bits := UInt64(Trunc(X - 9223372036854775808.0)) or $8000000000000000
      else
      begin
        I := Trunc(X);
        Move(I, AValue.Bits, 8);
      end;
      AValue.Bits := AValue.Bits and IntegerMask(AValue.DataType);
    end
    else AValue.Bits := IntegerCastBits(A.Bits, A.DataType, AValue.DataType);
    Exit(True);
  end;
  if AExpression.Kind = ekUnary then
  begin
    if AExpression.Operation = opNot then
    begin
      if A.DataType = stBoolean then AValue.Bits := Ord(A.Bits = 0)
      else AValue.Bits := not A.Bits;
    end
    else if A.DataType = stSingle then AValue.Bits := A.Bits xor $80000000
    else if A.DataType = stDouble then AValue.Bits := A.Bits xor $8000000000000000
    else AValue.Bits := (UInt64(0) - A.Bits) and IntegerMask(A.DataType);
    if not IsFloatType(A.DataType) and (A.DataType <> stBoolean) then
      AValue.Bits := AValue.Bits and IntegerMask(A.DataType);
    Exit(True);
  end;
  if not EvaluateConstant(AExpression.Right, B) then Exit;
  if IsFloatType(A.DataType) then
  begin
    X := AsFloat(A); Y := AsFloat(B);
    case AExpression.Operation of
      opAdd, opSubtract, opMultiply: Z := DoubleOperation(AExpression.Operation, X, Y);
      opDivide: begin if Y = 0 then Exit; Z := DoubleOperation(opDivide, X, Y); end;
      opEqual: begin AValue.Bits := Ord(X = Y); Exit(True); end;
      opNotEqual: begin AValue.Bits := Ord(X <> Y); Exit(True); end;
      opLess: begin AValue.Bits := Ord(X < Y); Exit(True); end;
      opLessEqual: begin AValue.Bits := Ord(X <= Y); Exit(True); end;
      opGreater: begin AValue.Bits := Ord(X > Y); Exit(True); end;
      opGreaterEqual: begin AValue.Bits := Ord(X >= Y); Exit(True); end;
    else Exit;
    end;
    if IsNan(Z) or IsInfinite(Z) then Exit;
    if AValue.DataType = stSingle then
    begin
      // Retain binary32 operation semantics (especially division), not a Double
      // operation followed by a potentially double-rounded narrowing.
      S := SingleOperation(AExpression.Operation, Single(X), Single(Y));
      if IsNan(S) or IsInfinite(S) then Exit;
      Move(S, AValue.Bits, 4);
    end
    else Move(Z, AValue.Bits, 8);
    Exit(True);
  end;
  U := A.Bits; V := B.Bits;
  I := SignedValue(A.Bits, A.DataType); J := SignedValue(B.Bits, B.DataType);
  case AExpression.Operation of
    opAdd: AValue.Bits := (U + V) and IntegerMask(A.DataType);
    opSubtract: AValue.Bits := (U - V) and IntegerMask(A.DataType);
    opMultiply: AValue.Bits := (U * V) and IntegerMask(A.DataType);
    opIntDivide, opModulo:
      begin
        if V = 0 then Exit;
        if IsSignedInteger(A.DataType) then
        begin
          if (I = SignedValue(UInt64(1) shl (ScalarBitWidth(A.DataType) - 1), A.DataType)) and (J = -1) then Exit;
          if AExpression.Operation = opIntDivide then I := I div J else I := I mod J;
          Move(I, AValue.Bits, 8);
        end
        else if AExpression.Operation = opIntDivide then AValue.Bits := U div V
        else AValue.Bits := U mod V;
        AValue.Bits := AValue.Bits and IntegerMask(A.DataType);
      end;
    opAnd: AValue.Bits := A.Bits and B.Bits;
    opOr: AValue.Bits := A.Bits or B.Bits;
    opXor: AValue.Bits := A.Bits xor B.Bits;
    opShiftLeft:
      begin
        ShiftCount := Integer(B.Bits and UInt64(ScalarBitWidth(A.DataType) - 1));
        // Keep the host operation explicitly 32-bit. A UInt64 shift followed by
        // narrowing did not preserve masked-count semantics in the Win64 build.
        if ScalarBitWidth(A.DataType) <= 32 then AValue.Bits := Cardinal(A.Bits) shl ShiftCount
        else AValue.Bits := A.Bits shl ShiftCount;
        AValue.Bits := AValue.Bits and IntegerMask(A.DataType);
      end;
    opShiftRight:
      begin
        ShiftCount := Integer(B.Bits and UInt64(ScalarBitWidth(A.DataType) - 1));
        if ScalarBitWidth(A.DataType) <= 32 then AValue.Bits := Cardinal(A.Bits) shr ShiftCount
        else AValue.Bits := A.Bits shr ShiftCount;
      end;
    opEqual, opNotEqual, opLess, opLessEqual, opGreater, opGreaterEqual:
      begin
        Flag := False;
        if not IsSignedInteger(A.DataType) then
        begin
          case AExpression.Operation of
            opEqual: Flag := U = V;
            opNotEqual: Flag := U <> V;
            opLess: Flag := U < V;
            opLessEqual: Flag := U <= V;
            opGreater: Flag := U > V;
            opGreaterEqual: Flag := U >= V;
          end;
        end
        else case AExpression.Operation of
          opEqual: Flag := I = J;
          opNotEqual: Flag := I <> J;
          opLess: Flag := I < J;
          opLessEqual: Flag := I <= J;
          opGreater: Flag := I > J;
          opGreaterEqual: Flag := I >= J;
        end;
        AValue.Bits := Ord(Flag);
      end;
  else Exit;
  end;
  Result := True;
end;

{$Q+}
{$R+}
// Mathematical value of a narrow (<= 32-bit) integer tree; Int64 overflow checks
// raise for intermediate values that cannot be represented exactly.
function ExactValue(E: TExpression; out AValue: Int64): Boolean;
var
  A, B: Int64;
  Width: Integer;
begin
  Result := False;
  AValue := 0;
  if not IsScalarIntegerType(E.DataType) or (ScalarBitWidth(E.DataType) >= 64) then Exit;
  Width := ScalarBitWidth(E.DataType);
  case E.Kind of
    ekConstant:
      begin
        if IsSignedInteger(E.DataType) then AValue := SignedValue(E.Bits, E.DataType)
        else AValue := Int64(E.Bits and IntegerMask(E.DataType));
        Exit(True);
      end;
    ekUnary:
      begin
        if not ExactValue(E.Left, A) then Exit;
        if E.Operation = opNegate then AValue := -A
        else if IsSignedInteger(E.DataType) then AValue := -A - 1 // not, in two's complement
        else Exit; // unsigned not depends on the width
      end;
    ekBinary:
      begin
        if not ExactValue(E.Left, A) or not ExactValue(E.Right, B) then Exit;
        case E.Operation of
          opAdd: AValue := A + B;
          opSubtract: AValue := A - B;
          opMultiply: AValue := A * B;
          opIntDivide, opModulo:
            begin
              if B = 0 then Exit;
              if E.Operation = opIntDivide then AValue := A div B else AValue := A mod B;
            end;
          opAnd: AValue := A and B;
          opOr: AValue := A or B;
          opXor: AValue := A xor B;
          opShiftLeft:
            begin
              if (B < 0) or (B >= Width) then Exit;
              AValue := A * (Int64(1) shl B);
            end;
          opShiftRight:
            begin
              if (A < 0) or (B < 0) or (B >= Width) then Exit;
              AValue := A shr B;
            end;
        else Exit;
        end;
      end;
  else Exit;
  end;
  Result := True;
end;
{$Q-}
{$R-}

function ExactNarrowConstant(AExpression: TExpression): Boolean;
var
  Exact: Int64;
  Wrapped: TConstantValue;
begin
  if ScalarBitWidth(AExpression.DataType) >= 64 then Exit(True);
  try
    if not ExactValue(AExpression, Exact) or not EvaluateConstant(AExpression, Wrapped) then Exit(False);
  except
    // Compilation continues: the RTL may have reloaded the process FP defaults.
    on E: EIntOverflow do
    begin
      PinCompilerFloatEnvironment;
      Exit(False);
    end;
    on E: ERangeError do
    begin
      PinCompilerFloatEnvironment;
      Exit(False);
    end;
  end;
  if IsSignedInteger(Wrapped.DataType) then Result := SignedValue(Wrapped.Bits, Wrapped.DataType) = Exact
  else Result := (Exact >= 0) and (UInt64(Exact) = (Wrapped.Bits and IntegerMask(Wrapped.DataType)));
end;

function EvaluateConstant(AExpression: TExpression; out AValue: TConstantValue): Boolean;
begin
  try
    Result := EvaluateDefined(AExpression, AValue);
  except
    on E: EMathError do
    begin
      PinCompilerFloatEnvironment;
      Result := False;
    end;
  end;
end;

function HasFloat(E: TExpression): Boolean;
var A: TExpression;
begin
  if E = nil then Exit(False);
  Result := IsFloatType(E.DataType);
  if Result then Exit;
  if HasFloat(E.Left) or HasFloat(E.Right) then Exit(True);
  for A in E.Arguments do if HasFloat(A) then Exit(True);
end;

procedure Fold(var E: TExpression);
var
  V: TConstantValue;
  A: TExpression;
  I: Integer;
begin
  if E = nil then Exit;
  Fold(E.Left); Fold(E.Right);
  E.Arguments.OwnsObjects := False;
  try
    for I := 0 to E.Arguments.Count - 1 do
    begin
      A := E.Arguments[I]; Fold(A); E.Arguments[I] := A;
    end;
  finally E.Arguments.OwnsObjects := True; end;
  // Never fold floating-point, resource reads, calls or undefined arithmetic.
  if not HasFloat(E) and EvaluateConstant(E, V) and (E.Kind <> ekConstant) then
  begin
    FreeAndNil(E.Left); FreeAndNil(E.Right); E.Arguments.Clear;
    E.Kind := ekConstant; E.DataType := V.DataType; E.Bits := V.Bits; E.Depth := 1;
  end;
end;

procedure OptimizeStatement(S: TStatement);
var Child: TStatement;
begin
  if S = nil then Exit;
  // Lvalue addresses remain addresses. Their index subexpressions may be left alone.
  Fold(S.Value); Fold(S.Condition); Fold(S.Limit);
  for Child in S.Children do OptimizeStatement(Child);
  OptimizeStatement(S.ThenPart); OptimizeStatement(S.ElsePart); OptimizeStatement(S.Body);
end;

procedure OptimizeConstants(AModule: TShaderModule);
var F: TShaderFunction;
begin
  for F in AModule.Functions do OptimizeStatement(F.Body);
end;

end.
