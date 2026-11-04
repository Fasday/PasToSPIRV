program DoubleLiteralCheck;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes,
  PTS.FloatLiteral in '..\source\PTS.FloatLiteral.pas';

var
  Lines: TStringList;
  Line, Text, Expected: string;
  P, Count: Integer;
  Bits, Want: UInt64;
  Valid: Boolean;
begin
  try
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(ParamStr(1), TEncoding.ASCII);
      Count := 0;
      for Line in Lines do
      begin
        P := Pos(#9, Line); Text := Copy(Line, 1, P-1); Expected := Copy(Line, P+1, MaxInt);
        Valid := TryDecimalToDoubleBits(Text, Bits);
        if Expected = 'overflow' then
        begin if Valid then raise Exception.Create('Accepted Double overflow'); end
        else
        begin
          Want := StrToUInt64('$' + Expected);
          if not Valid or (Bits <> Want) then
            raise Exception.CreateFmt('Double literal mismatch case %d: %s instead of %s', [Count, IntToHex(Bits,16), Expected]);
        end;
        Inc(Count);
      end;
      Writeln('PASS: ', Count, ' exact binary64 literals against independent Fraction oracle.');
    finally Lines.Free; end;
  except on E: Exception do begin Writeln(ErrOutput, E.Message); ExitCode := 2; end; end;
end.
