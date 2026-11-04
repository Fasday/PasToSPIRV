unit PTS.Types;

interface

uses
  System.Generics.Collections,
  PTS.Diagnostics;

type
  TShaderType = (stVoid, stInteger, stCardinal, stSingle, stBoolean,
    stInteger2, stInteger3, stInteger4, stCardinal2, stCardinal3, stCardinal4,
    stSingle2, stSingle3, stSingle4, stByte, stWord, stInt64, stUInt64, stDouble,
    // Enumeration value (Composite = ctEnum descriptor) and set of such an
    // enumeration (Composite = element enum, nil for the untyped []); both are
    // 32-bit unsigned words in SPIR-V and have no external layout.
    stEnum, stSet,
    stComposite);

  TCompositeType = class;
  TTypeReference = record
    DataType: TShaderType;
    Composite: TCompositeType;
    ModuleName: string;
  end;
  // ctEnum: Fields are the enumerators (Name, Offset = ordinal value).
  TCompositeKind = (ctRecord, ctArray, ctEnum);

  TTypeField = class
  public
    Name: string;
    Position: TSourcePosition;
    DataType: TShaderType;
    Composite: TCompositeType;
    Offset: Cardinal;
  end;

  TCompositeType = class
  public
    ID: Integer;
    Name: string;
    Position: TSourcePosition;
    Kind: TCompositeKind;
    Fields: TObjectList<TTypeField>;
    ElementType: TShaderType;
    ElementComposite: TCompositeType;
    Length: Cardinal;
    Size: Cardinal;
    Alignment: Cardinal;
    Stride: Cardinal;
    Depth: Cardinal;
    ExternalLayout: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

function ShaderTypeName(AType: TShaderType): string;
function TryShaderType(const AName: string; out AType: TShaderType): Boolean;
function ComponentType(AType: TShaderType): TShaderType;
function ComponentCount(AType: TShaderType): Integer;
function VectorType(ABase: TShaderType; ACount: Integer): TShaderType;
function IsIntegerType(AType: TShaderType): Boolean;
function IsScalarIntegerType(AType: TShaderType): Boolean;
function IsNumericType(AType: TShaderType): Boolean;
function IsFloatType(AType: TShaderType): Boolean;
function IsSignedInteger(AType: TShaderType): Boolean;
function ScalarBitWidth(AType: TShaderType): Integer;
function IntegerMask(AType: TShaderType): UInt64;
function SignedValue(ABits: UInt64; AType: TShaderType): Int64;
function IntegerCastBits(ABits: UInt64; ASource, ATarget: TShaderType): UInt64;
function TypeReferenceName(AType: TShaderType; AComposite: TCompositeType): string;
// Integers and enumerations (Ord, Succ/Pred, case, for, sets).
function IsOrdinalType(AType: TShaderType): Boolean;
function EnumLow(AComposite: TCompositeType): Cardinal;
function EnumHigh(AComposite: TCompositeType): Cardinal;

implementation

uses
  System.SysUtils;

function ShaderTypeName(AType: TShaderType): string;
const
  Names: array[TShaderType] of string = ('Void', 'Integer', 'Cardinal',
    'Single', 'Boolean', 'Integer2', 'Integer3', 'Integer4', 'Cardinal2',
    'Cardinal3', 'Cardinal4', 'Single2', 'Single3', 'Single4', 'Byte', 'Word',
    'Int64', 'UInt64', 'Double', '<enum>', '<set>', '<aggregate>');
begin
  Result := Names[AType];
end;

function TryShaderType(const AName: string; out AType: TShaderType): Boolean;
var
  Candidate: TShaderType;
begin
  for Candidate := stInteger to stDouble do
    if SameText(AName, ShaderTypeName(Candidate)) then
    begin
      AType := Candidate;
      Exit(True);
    end;
  AType := stVoid;
  Result := False;
end;

function ComponentType(AType: TShaderType): TShaderType;
begin
  case AType of
    stComposite: Result := stVoid;
    stInteger2..stInteger4: Result := stInteger;
    stCardinal2..stCardinal4: Result := stCardinal;
    stSingle2..stSingle4: Result := stSingle;
  else
    Result := AType;
  end;
end;

function ComponentCount(AType: TShaderType): Integer;
begin
  if AType in [stVoid, stComposite] then
    Result := 0
  else if (AType < stInteger2) or (AType > stSingle4) then
    Result := 1
  else
    Result := (Ord(AType) - Ord(stInteger2)) mod 3 + 2;
end;

function VectorType(ABase: TShaderType; ACount: Integer): TShaderType;
var
  First: TShaderType;
begin
  if ACount = 1 then
    Exit(ABase);
  if (ACount < 2) or (ACount > 4) then
    raise EArgumentException.Create('Internal error: invalid vector width');
  case ABase of
    stInteger: First := stInteger2;
    stCardinal: First := stCardinal2;
    stSingle: First := stSingle2;
  else
    raise EArgumentException.Create('Internal error: invalid vector component type');
  end;
  Result := TShaderType(Ord(First) + ACount - 2);
end;

function IsIntegerType(AType: TShaderType): Boolean;
begin
  Result := ComponentType(AType) in [stInteger, stCardinal, stByte, stWord, stInt64, stUInt64];
end;

function IsScalarIntegerType(AType: TShaderType): Boolean;
begin
  Result := AType in [stInteger, stCardinal, stByte, stWord, stInt64, stUInt64];
end;

function IsNumericType(AType: TShaderType): Boolean;
begin
  Result := IsIntegerType(AType) or IsFloatType(AType);
end;

function IsFloatType(AType: TShaderType): Boolean;
begin
  Result := ComponentType(AType) in [stSingle, stDouble];
end;

function IsSignedInteger(AType: TShaderType): Boolean;
begin
  Result := ComponentType(AType) in [stInteger, stInt64];
end;

function ScalarBitWidth(AType: TShaderType): Integer;
begin
  case ComponentType(AType) of
    stByte: Result := 8;
    stWord: Result := 16;
    stInt64, stUInt64, stDouble: Result := 64;
  else Result := 32;
  end;
end;

function IntegerMask(AType: TShaderType): UInt64;
begin
  if ScalarBitWidth(AType) = 64 then Result := High(UInt64)
  else Result := (UInt64(1) shl ScalarBitWidth(AType)) - 1;
end;

function SignedValue(ABits: UInt64; AType: TShaderType): Int64;
begin
  ABits := ABits and IntegerMask(AType);
  if IsSignedInteger(AType) and (ABits and (UInt64(1) shl (ScalarBitWidth(AType) - 1)) <> 0) then
    ABits := ABits or not IntegerMask(AType);
  Move(ABits, Result, SizeOf(Result));
end;

function IntegerCastBits(ABits: UInt64; ASource, ATarget: TShaderType): UInt64;
var
  Signed: Int64;
begin
  if IsSignedInteger(ASource) then
  begin
    Signed := SignedValue(ABits, ASource);
    Move(Signed, ABits, SizeOf(ABits));
  end;
  Result := ABits and IntegerMask(ATarget);
end;

function TypeReferenceName(AType: TShaderType; AComposite: TCompositeType): string;
begin
  if AType in [stComposite, stEnum] then Result := AComposite.Name
  else if AType = stSet then
  begin
    if AComposite = nil then Result := '[]' else Result := 'set of ' + AComposite.Name;
  end
  else Result := ShaderTypeName(AType);
end;

function IsOrdinalType(AType: TShaderType): Boolean;
begin
  Result := IsScalarIntegerType(AType) or (AType = stEnum);
end;

function EnumLow(AComposite: TCompositeType): Cardinal;
var Field: TTypeField;
begin
  Result := High(Cardinal);
  for Field in AComposite.Fields do if Field.Offset < Result then Result := Field.Offset;
end;

function EnumHigh(AComposite: TCompositeType): Cardinal;
var Field: TTypeField;
begin
  Result := 0;
  for Field in AComposite.Fields do if Field.Offset > Result then Result := Field.Offset;
end;

constructor TCompositeType.Create;
begin
  inherited Create;
  Fields := TObjectList<TTypeField>.Create(True);
end;

destructor TCompositeType.Destroy;
begin
  Fields.Free;
  inherited;
end;

end.
