type TLookup = array[0..3] of Int64;
const Lookup: TLookup = (7, -3, 1234567890123, -9223372036854775808);
var
  [Binding(0,0),ReadOnly] Input: array of UInt64;
  [Binding(0,1),ReadOnly] Reals: array of Double;
  [Binding(0,2),ReadWrite] Bytes: array of Byte;
  [Binding(0,3),ReadWrite] Words: array of Word;
  [Binding(0,4),WriteOnly] Output: array of UInt64;

[Vulkan12, StrictFloat, LocalSize(64,1,1)]
procedure Main;
var I: Cardinal; O: Cardinal; U: UInt64; S: Int64; D: Double; F: Single;
begin
  I := GlobalInvocationID.X; O := I * 28;
  U := Input[I]; S := Int64(U); D := Reals[I];
  Output[O] := U + $FEDCBA9876543210;
  Output[O+1] := U - UInt64(123456789);
  Output[O+2] := U * UInt64(4294967297);
  Output[O+3] := U div UInt64(7);
  Output[O+4] := U mod UInt64(7);
  Output[O+5] := U shr I;
  Output[O+6] := U shl I;
  Output[O+7] := UInt64(S div Int64(7));
  Output[O+8] := UInt64(S mod Int64(7));
  Output[O+9] := UInt64(S shr I);
  Output[O+10] := UInt64(ArithmeticShiftRight(S, I));
  if U > $8000000000000000 then Output[O+11] := 1 else Output[O+11] := 0;
  if S < 0 then Output[O+12] := 1 else Output[O+12] := 0;
  Output[O+13] := UInt64(Round(D));
  Output[O+14] := UInt64(Trunc(D));
  Output[O+15] := UInt64(Floor(D));
  Output[O+16] := UInt64(Ceil(D));
  Output[O+17] := DoubleToBits(RoundEven(D));
  Output[O+18] := DoubleToBits(D + 0.125d);
  Output[O+19] := DoubleToBits(D * 2.0d);
  Output[O+20] := DoubleToBits(Ldexp(D, -3));
  Output[O+21] := UInt64(FindMSB(Cardinal(U)));
  Output[O+22] := UInt64(FindLSB(Cardinal(U)));
  Output[O+23] := UInt64(Lookup[I and 3]);
  Bytes[I] := Byte(Cardinal(Bytes[I]) + I);
  Words[I] := Word(Cardinal(Words[I]) xor (I * 257));
  Output[O+24] := UInt64(Bytes[I]);
  Output[O+25] := UInt64(Words[I]);
  F := BitsToSingle(Cardinal(U));
  Output[O+26] := UInt64(SingleToBits(F));
  if IsNan(D) or IsInfinite(D) then Output[O+27] := 1 else Output[O+27] := 0;
end;
