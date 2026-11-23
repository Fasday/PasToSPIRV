var
  [Binding(0, 0), ReadOnly] Values: array of Single4;
  [Binding(0, 1), WriteOnly] Results: array of Single4;

[LocalSize(1, 1, 1)]
procedure Main;
begin
  var X: Single4 := Values[0];
  var A: Single := Values[1].X;
  var B: Single := Values[1].Y;
  var C: Single := Values[1].Z;
  Results[0] := Fma(X, X, -X);
  Results[1] := Log2(X);
  Results[2] := Single4(Fma(A, B, C), A * B + C, Log2(X.W), 0.0);
end;
