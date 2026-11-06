unit PTS.Names;

interface

const
  MaxIdentifierLength = 127;

// Language keywords, built-in types/resources/built-ins and intrinsics.
// Shared by declarations, module names and imports.
function IsReservedIdentifier(const AName: string): Boolean;

// External SPIR-V name, independent of Pascal keywords and case-insensitive
// symbol lookup. Accept a bounded ASCII identifier and preserve its case.
procedure ValidateEntryPointName(const AName: string);

implementation

uses
  System.SysUtils, PTS.Types, PTS.Features;

const
  Reserved = '|begin|end|var|procedure|function|if|then|else|while|do|' +
    'array|of|record|integer|cardinal|single|boolean|true|false|div|mod|' +
    'and|or|xor|not|shl|shr|main|program|unit|module|uses|' +
    'type|const|out|result|default|for|to|downto|repeat|until|case|break|continue|exit|' +
    'atomicadd|atomicexchange|atomiccompareexchange|barrier|buffermemorybarrier|imagememorybarrier|' +
    'imageload|imagestore|imagesize|samplelevel|texture2d|sampler|' +
    'min|max|abs|clamp|dot|sqrt|singletobits|bitstosingle|doubletobits|bitstodouble|' +
    'roundeven|round|trunc|floor|ceil|isnan|isinfinite|ldexp|findmsb|findlsb|arithmeticshiftright|' +
    'ord|sqr|odd|succ|pred|inc|dec|low|high|length|sizeof|include|exclude|';

function IsReservedIdentifier(const AName: string): Boolean;
var
  DataType: TShaderType;
  Format: TImageFormat;
  Builtin: TInvocationBuiltin;
begin
  Result := (Pos('|' + LowerCase(AName) + '|', Reserved) <> 0) or
    TryShaderType(AName, DataType) or TryImageType(AName, Format) or TryBuiltin(AName, Builtin);
end;

procedure ValidateEntryPointName(const AName: string);
var
  I: Integer;
begin
  if (Length(AName) = 0) or (Length(AName) > MaxIdentifierLength) then
    raise EArgumentException.Create('Entry-point name must contain 1..127 ASCII identifier characters');
  for I := 1 to Length(AName) do
    if not (CharInSet(AName[I], ['a'..'z', 'A'..'Z', '_']) or
      ((I > 1) and CharInSet(AName[I], ['0'..'9']))) then
      raise EArgumentException.Create('Entry-point name must be an ASCII identifier: [A-Za-z_][A-Za-z0-9_]*');
end;

end.
