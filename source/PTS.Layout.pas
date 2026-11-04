unit PTS.Layout;

interface

uses
  PTS.Types;

const
  MaxStaticArrayLength = 65536;
  MaxCompositeSize = 16 * 1024 * 1024;

function TypeSize(AType: TShaderType; AComposite: TCompositeType): Cardinal;
function TypeAlignment(AType: TShaderType; AComposite: TCompositeType): Cardinal;
function ArrayStride(AType: TShaderType; AComposite: TCompositeType): Cardinal;
procedure CalculateLayout(AComposite: TCompositeType);
procedure RequireExternalLayout(AType: TShaderType; AComposite: TCompositeType);

implementation

uses
  System.SysUtils,
  System.Math,
  PTS.Diagnostics;

function AlignUp(AValue, AAlignment: UInt64): UInt64;
begin
  Result := (AValue + AAlignment - 1) and not (AAlignment - 1);
end;

function TypeSize(AType: TShaderType; AComposite: TCompositeType): Cardinal;
begin
  if AType = stComposite then Exit(AComposite.Size);
  Result := Cardinal(ComponentCount(AType) * (ScalarBitWidth(AType) div 8));
end;

function TypeAlignment(AType: TShaderType; AComposite: TCompositeType): Cardinal;
begin
  if AType = stComposite then Exit(AComposite.Alignment);
  case ComponentCount(AType) of
    1: Result := ScalarBitWidth(AType) div 8;
    2: Result := 2 * Cardinal(ScalarBitWidth(AType) div 8);
    3, 4: Result := 4 * Cardinal(ScalarBitWidth(AType) div 8);
  else
    raise EArgumentException.Create('Internal error: type has no value layout');
  end;
end;

function ArrayStride(AType: TShaderType; AComposite: TCompositeType): Cardinal;
begin
  Result := Cardinal(AlignUp(TypeSize(AType, AComposite), TypeAlignment(AType, AComposite)));
end;

procedure CalculateLayout(AComposite: TCompositeType);
var
  Field: TTypeField;
  Cursor: UInt64;
begin
  AComposite.Depth := 1;
  if AComposite.Kind = ctArray then
  begin
    if AComposite.ElementComposite <> nil then
      AComposite.Depth := AComposite.ElementComposite.Depth + 1;
    AComposite.Alignment := TypeAlignment(AComposite.ElementType, AComposite.ElementComposite);
    AComposite.Stride := ArrayStride(AComposite.ElementType, AComposite.ElementComposite);
    Cursor := UInt64(AComposite.Stride) * AComposite.Length;
  end
  else
  begin
    Cursor := 0;
    AComposite.Alignment := 1;
    for Field in AComposite.Fields do
    begin
      if Field.Composite <> nil then
        AComposite.Depth := Max(AComposite.Depth, Field.Composite.Depth + 1);
      AComposite.Alignment := Max(AComposite.Alignment, TypeAlignment(Field.DataType, Field.Composite));
      Cursor := AlignUp(Cursor, TypeAlignment(Field.DataType, Field.Composite));
      if Cursor > MaxCompositeSize then
        raise EShaderError.Create(AComposite.Position, 'Composite layout exceeds 16 MiB');
      Field.Offset := Cardinal(Cursor);
      Inc(Cursor, TypeSize(Field.DataType, Field.Composite));
    end;
    Cursor := AlignUp(Cursor, AComposite.Alignment);
  end;
  if AComposite.Depth > 32 then
    raise EShaderError.Create(AComposite.Position, 'Composite type nesting exceeds 32 levels');
  if Cursor > MaxCompositeSize then
    raise EShaderError.Create(AComposite.Position, 'Composite layout exceeds 16 MiB');
  AComposite.Size := Cardinal(Cursor);
end;

// Boolean, enumerations and sets have no host layout (Delphi sizes depend on
// $Z/$MINENUMSIZE and the set range); resources store them as Cardinal.
procedure CheckLayoutScalar(AType: TShaderType; const APosition: TSourcePosition);
begin
  if AType = stBoolean then
    raise EShaderError.Create(APosition, 'Boolean is not supported in GPU resource layouts; use Cardinal');
  if AType in [stEnum, stSet] then
    raise EShaderError.Create(APosition,
      'Enumerations and sets are not supported in GPU resource layouts; store Cardinal and cast');
end;

procedure RequireExternalLayout(AType: TShaderType; AComposite: TCompositeType);
var
  Field: TTypeField;
begin
  CheckLayoutScalar(AType, TSourcePosition.Create(1, 1));
  if AType <> stComposite then Exit;
  if AComposite.ExternalLayout then Exit;
  if AComposite.Kind = ctArray then
  begin
    CheckLayoutScalar(AComposite.ElementType, AComposite.Position);
    RequireExternalLayout(AComposite.ElementType, AComposite.ElementComposite);
  end
  else
    for Field in AComposite.Fields do
    begin
      CheckLayoutScalar(Field.DataType, Field.Position);
      RequireExternalLayout(Field.DataType, Field.Composite);
    end;
  AComposite.ExternalLayout := True;
end;

end.
