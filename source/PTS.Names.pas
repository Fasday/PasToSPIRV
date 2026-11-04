unit PTS.Names;

interface

const
  MaxIdentifierLength = 127;

// Language keywords, built-in types/resources/built-ins and intrinsics.
// Shared by declarations, module names and imports.
function IsReservedIdentifier(const AName: string): Boolean;

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

end.
