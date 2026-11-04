unit PTS.FloatLiteral;

{$BOOLEVAL OFF}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

// Exact decimal -> IEEE binary32/binary64 conversion, rounded once to nearest-even.
// AText uses the lexer's real-literal grammar: digits [. digits] [e[+|-]digits].
// Returns False if the rounded magnitude is not finite.
function TryDecimalToSingleBits(const AText: string; out ABits: Cardinal): Boolean;
function TryDecimalToDoubleBits(const AText: string; out ABits: UInt64): Boolean;

implementation

uses
  System.SysUtils, System.Math;

type
  TBig = TArray<Cardinal>; // little-endian 32-bit limbs; zero is empty

const
  KeptDigits = 200; // Every binary32 midpoint has far fewer significant digits.

procedure Normalize(var A: TBig);
var
  L: Integer;
begin
  L := Length(A);
  while (L > 0) and (A[L - 1] = 0) do Dec(L);
  SetLength(A, L);
end;

function MulAddSmall(const A: TBig; AMul, AAdd: Cardinal): TBig;
var
  I: Integer;
  T, Carry: UInt64;
begin
  SetLength(Result, Length(A) + 1);
  Carry := AAdd;
  for I := 0 to High(A) do
  begin
    T := UInt64(A[I]) * AMul + Carry;
    Result[I] := Cardinal(T);
    Carry := T shr 32;
  end;
  Result[Length(A)] := Cardinal(Carry);
  Normalize(Result);
end;

function Pow10(N: Integer): TBig;
begin
  Result := TBig.Create(1);
  while N >= 9 do
  begin
    Result := MulAddSmall(Result, 1000000000, 0);
    Dec(N, 9);
  end;
  while N > 0 do
  begin
    Result := MulAddSmall(Result, 10, 0);
    Dec(N);
  end;
end;

function Mul(const A, B: TBig): TBig;
var
  I, J: Integer;
  T, Carry: UInt64;
begin
  if (Length(A) = 0) or (Length(B) = 0) then Exit(nil);
  SetLength(Result, Length(A) + Length(B));
  for I := 0 to High(Result) do Result[I] := 0;
  for I := 0 to High(A) do
  begin
    Carry := 0;
    for J := 0 to High(B) do
    begin
      T := UInt64(A[I]) * B[J] + Result[I + J] + Carry;
      Result[I + J] := Cardinal(T);
      Carry := T shr 32;
    end;
    Result[I + Length(B)] := Cardinal(Carry);
  end;
  Normalize(Result);
end;

function ShiftLeft(const A: TBig; ABits: Integer): TBig;
var
  Words, Rest, I: Integer;
begin
  if Length(A) = 0 then Exit(nil);
  Words := ABits div 32;
  Rest := ABits mod 32;
  SetLength(Result, Length(A) + Words + 1);
  for I := 0 to High(Result) do Result[I] := 0;
  for I := 0 to High(A) do
  begin
    Result[I + Words] := Result[I + Words] or (A[I] shl Rest);
    if Rest > 0 then Result[I + Words + 1] := A[I] shr (32 - Rest);
  end;
  Normalize(Result);
end;

function Compare(const A, B: TBig): Integer;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(Sign(Length(A) - Length(B)));
  for I := High(A) downto 0 do
    if A[I] <> B[I] then
      if A[I] > B[I] then Exit(1) else Exit(-1);
  Result := 0;
end;

function Subtract(const A, B: TBig): TBig;
var
  I: Integer;
  T, Borrow: Int64;
begin
  SetLength(Result, Length(A));
  Borrow := 0;
  for I := 0 to High(A) do
  begin
    T := Int64(A[I]) - Borrow;
    if I < Length(B) then T := T - B[I];
    if T < 0 then
    begin
      Inc(T, Int64(1) shl 32);
      Borrow := 1;
    end
    else
      Borrow := 0;
    Result[I] := Cardinal(T);
  end;
  Normalize(Result);
end;

function BitLength(const A: TBig): Integer;
var
  Top: Cardinal;
begin
  if Length(A) = 0 then Exit(0);
  Result := (Length(A) - 1) * 32;
  Top := A[High(A)];
  while Top <> 0 do
  begin
    Inc(Result);
    Top := Top shr 1;
  end;
end;

function TryDecimalToBits(const AText: string; AWide: Boolean; out ABits: UInt64): Boolean;
var
  P, IntStart, IntEnd, FracStart, FracEnd, First, I, K, Bit, Order: Integer;
  Digits: string;
  Exp10, E, D: Int64;
  Negative, Sticky: Boolean;
  N, Num0, Den0, Num, Den, Rest, Part: TBig;
  B, Chunk: Integer;
  M: UInt64;
  Precision, MinBit, MaxBit, ExponentShift, DigitBudget: Integer;
begin
  if AWide then
  begin
    Precision := 53; MinBit := -1074; MaxBit := 971; ExponentShift := 52; DigitBudget := 1200;
  end
  else
  begin
    Precision := 24; MinBit := -149; MaxBit := 104; ExponentShift := 23; DigitBudget := KeptDigits;
  end;
  ABits := 0;
  P := 1;
  IntStart := P;
  while (P <= Length(AText)) and CharInSet(AText[P], ['0'..'9']) do Inc(P);
  IntEnd := P;
  FracStart := P;
  FracEnd := P;
  if (P <= Length(AText)) and (AText[P] = '.') then
  begin
    Inc(P);
    FracStart := P;
    while (P <= Length(AText)) and CharInSet(AText[P], ['0'..'9']) do Inc(P);
    FracEnd := P;
  end;
  Exp10 := 0;
  if (P <= Length(AText)) and CharInSet(AText[P], ['e', 'E']) then
  begin
    Inc(P);
    Negative := False;
    if (P <= Length(AText)) and CharInSet(AText[P], ['+', '-']) then
    begin
      Negative := AText[P] = '-';
      Inc(P);
    end;
    while (P <= Length(AText)) and CharInSet(AText[P], ['0'..'9']) do
    begin
      // Saturate: anything this large is decided by the magnitude checks.
      if Exp10 < 1000000000000 then Exp10 := Exp10 * 10 + (Ord(AText[P]) - Ord('0'));
      Inc(P);
    end;
    if Negative then Exp10 := -Exp10;
  end;
  if P <= Length(AText) then
    raise EArgumentException.Create('Internal error: malformed real literal');

  Digits := Copy(AText, IntStart, IntEnd - IntStart) + Copy(AText, FracStart, FracEnd - FracStart);
  First := 1;
  while (First <= Length(Digits)) and (Digits[First] = '0') do Inc(First);
  if First > Length(Digits) then Exit(True); // exact zero, whatever the exponent
  Digits := Copy(Digits, First, MaxInt);
  E := Exp10 - (FracEnd - FracStart);
  Sticky := False;
  if Length(Digits) > DigitBudget then
  begin
    for I := DigitBudget + 1 to Length(Digits) do
      if Digits[I] <> '0' then
      begin
        Sticky := True;
        Break;
      end;
    Inc(E, Length(Digits) - DigitBudget);
    SetLength(Digits, DigitBudget);
  end;
  D := Length(Digits) + E; // 10^(D-1) <= value < 10^D
  if AWide then
  begin
    if D > 310 then Exit(False);
    if D < -324 then Exit(True);
  end
  else
  begin
    if D > 40 then Exit(False);
    if D < -46 then Exit(True);
  end;

  N := nil;
  I := 1;
  while I <= Length(Digits) do
  begin
    K := Min(9, Length(Digits) - I + 1);
    Chunk := StrToInt(Copy(Digits, I, K));
    N := MulAddSmall(Mul(N, Pow10(K)), 1, Chunk);
    Inc(I, K);
  end;
  if E >= 0 then
  begin
    Num0 := Mul(N, Pow10(E));
    Den0 := TBig.Create(1);
  end
  else
  begin
    Num0 := N;
    Den0 := Pow10(-E);
  end;

  B := Max(BitLength(Num0) - BitLength(Den0) - Precision, MinBit);
  repeat
    if B < 0 then
    begin
      Num := ShiftLeft(Num0, -B);
      Den := Den0;
    end
    else
    begin
      Num := Num0;
      Den := ShiftLeft(Den0, B);
    end;
    M := 0;
    Rest := Num;
    for Bit := Precision + 1 downto 0 do
    begin
      Part := ShiftLeft(Den, Bit);
      if Compare(Rest, Part) >= 0 then
      begin
        Rest := Subtract(Rest, Part);
        M := M or (UInt64(1) shl Bit);
      end;
    end;
    if Compare(Rest, Den) >= 0 then
      raise EInvalidOpException.Create('Internal error: real literal quotient overflow');
    if M < (UInt64(1) shl Precision) then Break;
    Inc(B);
  until False;

  Order := Compare(ShiftLeft(Rest, 1), Den);
  if (Order > 0) or ((Order = 0) and (Sticky or Odd(M))) then Inc(M);
  if M = (UInt64(1) shl Precision) then
  begin
    M := UInt64(1) shl (Precision - 1);
    Inc(B);
  end;
  if B > MaxBit then Exit(False);
  ABits := (UInt64(B - MinBit) shl ExponentShift) + M;
  Result := True;
end;

function TryDecimalToSingleBits(const AText: string; out ABits: Cardinal): Boolean;
var Bits: UInt64;
begin
  Result := TryDecimalToBits(AText, False, Bits);
  ABits := Cardinal(Bits);
end;

function TryDecimalToDoubleBits(const AText: string; out ABits: UInt64): Boolean;
begin
  Result := TryDecimalToBits(AText, True, ABits);
end;

end.
