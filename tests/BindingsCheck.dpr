program BindingsCheck;

{$APPTYPE CONSOLE}
{$RANGECHECKS ON}

uses
  System.SysUtils,
  LayoutBindings in '..\build\tests\bindings\LayoutBindings.pas';

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then raise EInvalidOpException.Create(AMessage);
end;

var
  Item: TPTS_Buffer_InputData_Element;
  Params: TPTS_Push_Params;
  Vectors: array[0..1] of TPTS_Buffer_VectorData_Element;
begin
  PTS_ValidateLayouts;
  Check(SizeOf(Item) = 64, 'TItem stride');
  Check(NativeUInt(@Item.F_Weight) - NativeUInt(@Item) = 12, 'vec3 followed by scalar');
  Check(NativeUInt(@Item.F_Samples) - NativeUInt(@Item) = 16, 'nested array offset');
  Check(NativeUInt(@Item.F_Samples[1]) - NativeUInt(@Item.F_Samples[0]) = 16, 'vec3 array stride');
  Check(NativeUInt(@Item.F_Tag) - NativeUInt(@Item) = 48, 'field after nested array');
  Check(SizeOf(Params) = 48, 'push block size');
  Check(NativeUInt(@Params.F_Offset) - NativeUInt(@Params) = 16, 'push vector alignment');
  Check(NativeUInt(@Params.F_Extra) - NativeUInt(@Params) = 28, 'push scalar packing');
  Check(NativeUInt(@Params.F_Factors) - NativeUInt(@Params) = 32, 'push array offset');
  Check(SizeOf(Params.F_Factors[0]) = 8, 'std430 vec2 array stride');
  Check(SizeOf(Vectors[0]) = 16, 'runtime vector3 slot');
  Check(SizeOf(Vectors[0].Value) = 12, 'vector3 value size');
  Check(NativeUInt(@Vectors[1]) - NativeUInt(@Vectors[0]) = 16, 'host vector3 stride');
  Writeln('PASS: generated Delphi sizes, offsets, array slots and resource aliases.');
end.
