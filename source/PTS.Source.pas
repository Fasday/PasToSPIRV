unit PTS.Source;

{$BOOLEVAL OFF}

interface

uses
  System.Generics.Collections,
  PTS.Diagnostics;

type
  TSourceText = record
    FileName: string;
    Text: string;
    class function Create(const AFileName, AText: string): TSourceText; static;
  end;

  TSourceLine = record
    FileName: string;
    Line: Integer;
  end;

  TSourceDocument = class
  public
    Text: string;
    FileName: string;
    Origins: TArray<TSourceLine>;
    ModuleName: string;
    VisibleModules: TArray<string>; // Transitive, dependency declarations only.
    FileID: Integer;
    constructor Create(const AText, AFileName: string);
    function Position(ALine, AColumn: Integer): TSourcePosition;
  end;

  TSourceFile = class
  public
    ID: Integer;
    FullPath: string; // Diagnostic/resolution only; never serialized verbatim.
    DisplayPath: string;
    SHA256: string;
    Raw: TSourceDocument;
    destructor Destroy; override;
  end;

  TSourceDependency = record
    FromID: Integer;
    ToID: Integer;
    Kind: string;
    Position: TSourcePosition;
  end;

  TSourceProgram = class
  public
    Root: TSourceDocument;
    Libraries: TObjectList<TSourceDocument>; // Dependency order, each module once.
    Files: TObjectList<TSourceFile>;         // First-discovery order.
    Dependencies: TList<TSourceDependency>;
    constructor Create;
    destructor Destroy; override;
  end;

implementation

uses
  System.SysUtils;

class function TSourceText.Create(const AFileName, AText: string): TSourceText;
begin
  Result.FileName := AFileName;
  Result.Text := AText;
end;

constructor TSourceDocument.Create(const AText, AFileName: string);
var
  Lines: TArray<string>;
  I: Integer;
begin
  inherited Create;
  Text := StringReplace(StringReplace(AText, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]);
  if (Text <> '') and (Text[1] = #$FEFF) then Delete(Text, 1, 1);
  FileName := AFileName;
  Lines := Text.Split([#10], TStringSplitOptions.None);
  SetLength(Origins, Length(Lines));
  for I := 0 to High(Origins) do
  begin
    Origins[I].FileName := AFileName;
    Origins[I].Line := I + 1;
  end;
end;

function TSourceDocument.Position(ALine, AColumn: Integer): TSourcePosition;
begin
  if (ALine > 0) and (ALine <= Length(Origins)) then
    Result := TSourcePosition.Create(Origins[ALine - 1].Line, AColumn, Origins[ALine - 1].FileName)
  else
    Result := TSourcePosition.Create(ALine, AColumn, FileName);
end;

destructor TSourceFile.Destroy;
begin
  Raw.Free;
  inherited;
end;

constructor TSourceProgram.Create;
begin
  inherited;
  Libraries := TObjectList<TSourceDocument>.Create(True);
  Files := TObjectList<TSourceFile>.Create(True);
  Dependencies := TList<TSourceDependency>.Create;
end;

destructor TSourceProgram.Destroy;
begin
  Dependencies.Free;
  Root.Free;
  Libraries.Free;
  Files.Free;
  inherited;
end;

end.
