program FloatLiteralCheck;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes,
  PTS.FloatLiteral in '..\source\PTS.FloatLiteral.pas';

var
  Lines: TStringList;
  Line, Text, Expected, Actual: string;
  Tab, Failures, Checked: Integer;
  Bits: Cardinal;
begin
  Lines := TStringList.Create;
  try
    try
      if ParamCount <> 1 then raise EArgumentException.Create('Usage: FloatLiteralCheck vectors.txt');
      Lines.LoadFromFile(ParamStr(1), TEncoding.ASCII);
      Failures := 0;
      Checked := 0;
      for Line in Lines do
      begin
        if Line = '' then Continue;
        Tab := Pos(#9, Line);
        Text := Copy(Line, 1, Tab - 1);
        Expected := Copy(Line, Tab + 1, MaxInt);
        if TryDecimalToSingleBits(Text, Bits) then Actual := IntToHex(Bits, 8) else Actual := 'inf';
        Inc(Checked);
        if Actual <> Expected then
        begin
          Inc(Failures);
          if Failures <= 10 then Writeln(ErrOutput, Text, ': expected ', Expected, ', got ', Actual);
        end;
      end;
      if Failures > 0 then raise EInvalidOpException.CreateFmt('%d of %d literal conversions differ', [Failures, Checked]);
      Writeln('PASS: ', Checked, ' correctly rounded decimal -> binary32 literal conversions.');
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Lines.Free;
  end;
end.
