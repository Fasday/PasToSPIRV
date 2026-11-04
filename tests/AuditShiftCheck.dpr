program AuditShiftCheck;
{$APPTYPE CONSOLE}
uses
  System.SysUtils,
  PTS.ConstEval in '..\source\PTS.ConstEval.pas',
  PTS.FloatLiteral in '..\source\PTS.FloatLiteral.pas',
  PTS.IR in '..\source\PTS.IR.pas',
  PTS.Types in '..\source\PTS.Types.pas',
  PTS.Features in '..\source\PTS.Features.pas',
  PTS.Diagnostics in '..\source\PTS.Diagnostics.pas';
var
  E: TExpression;
  Value: TConstantValue;
  Count: Cardinal;
  U: UInt64;
begin
  U := 1;
  for Count in [Cardinal(31),Cardinal(63),Cardinal(127),Cardinal(255),Cardinal($7FFFFFFF),Cardinal($FFFFFFFF)] do
  begin
    E := TExpression.Create;
    try
      E.Kind := ekBinary; E.DataType := stInteger; E.Operation := opShiftLeft;
      E.Left := TExpression.Create; E.Left.Kind := ekConstant; E.Left.DataType := stInteger; E.Left.Bits := 1;
      E.Right := TExpression.Create; E.Right.Kind := ekConstant; E.Right.DataType := stInteger; E.Right.Bits := Count;
      if not EvaluateConstant(E,Value) then raise Exception.Create('Not a constant');
      Writeln(IntToHex(Count,8), ' mask=',Count and 31,' direct=',IntToHex(Cardinal((U shl (Count and 31)) and $FFFFFFFF),8),
        ' evaluator=',IntToHex(Value.Bits,8));
      if Value.Bits <> $80000000 then raise EInvalidOpException.Create('Masked left-shift constant evaluation differs');
      E.Operation := opShiftRight; E.Left.Bits := $FFFFFFFF;
      if not EvaluateConstant(E,Value) or (Value.Bits <> 1) then
        raise EInvalidOpException.Create('Masked logical right-shift constant evaluation differs');
    finally E.Free; end;
  end;
  Writeln('PASS: 32-bit shifts for masked large counts.');
end.
