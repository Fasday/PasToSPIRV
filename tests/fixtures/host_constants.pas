// Constant evaluation must give the same binary64/binary32 result on every host
// build of the compiler. An x87 FPU rounds these Double operations twice: A and B
// at its default 64-bit precision, C and D (subnormal results) even at 53 bits.
// The conversions I, J and K are what a Win32 host still leaves to the x87 FPU:
// I and K follow its rounding control, the range check of J its precision control.
// The expected bit patterns come from an exact rational oracle and are checked by
// tests/FloatStateCheck.dpr and tests/audit141.ps1.
const
  A = 1.4854755483461002e4d - 4.2187716994703840e-2d;      // 40CD035B4D466271
  B = 1.4101080086613573e-3d * 5.2316458742090209e-2d;      // 3F1356BEDC4E782B
  C = 5.6282025411760799e-152d * 4.2859508872164680e-158d;  // 0001BC0CF1AB87DD
  D = 4.9878855592737026e-181d / 1.2709313119764513e129d;   // 0000483ECF74B2E3
  E = 1.0d / 3.0d;                                          // 3FD5555555555555
  F = 1.0 / 3.0;                                            // 3EAAAAAB
  G = 0.1 * 0.3;                                            // 3CF5C290
  H = 1.0e-30 * 1.0e-10;                                    // 000116C2
  I = Single(0.1d);                                         // 3DCCCCCD
  J = Integer(-2147483648.5d) + 305419896;                  // 92345678
  K = Single(16777217.0d);                                  // 4B800000

var
  [Binding(0,0), WriteOnly] Doubles: array of Double;
  [Binding(0,1), WriteOnly] Singles: array of Single;
  [Binding(0,2), WriteOnly] Integers: array of Integer;

[Vulkan12]
procedure Main;
begin
  Doubles[0] := A;
  Doubles[1] := B;
  Doubles[2] := C;
  Doubles[3] := D;
  Doubles[4] := E;
  Singles[0] := F;
  Singles[1] := G;
  Singles[2] := H;
  Singles[3] := I;
  Singles[4] := K;
  Integers[0] := J;
end;
