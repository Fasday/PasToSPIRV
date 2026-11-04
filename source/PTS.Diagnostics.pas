unit PTS.Diagnostics;

interface

uses
  System.SysUtils;

type
  TSourcePosition = record
    Line: Integer;
    Column: Integer;
    FileName: string;
    class function Create(ALine, AColumn: Integer; const AFileName: string = ''): TSourcePosition; static;
  end;

  EShaderError = class(Exception)
  private
    FPosition: TSourcePosition;
  public
    constructor Create(const APosition: TSourcePosition; const AMessage: string);
    property Position: TSourcePosition read FPosition;
  end;

implementation

class function TSourcePosition.Create(ALine, AColumn: Integer; const AFileName: string): TSourcePosition;
begin
  Result.Line := ALine;
  Result.Column := AColumn;
  Result.FileName := AFileName;
end;

constructor EShaderError.Create(const APosition: TSourcePosition;
  const AMessage: string);
begin
  inherited Create(AMessage);
  FPosition := APosition;
end;

end.
