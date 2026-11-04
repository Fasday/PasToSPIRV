unit PTS.Features;

interface

uses PTS.Types;

type
  TImageFormat = (imR32UInt, imR32Int, imRGBA32Float, imRGBA8);
  TInvocationBuiltin = (biGlobalInvocationID, biLocalInvocationID,
    biLocalInvocationIndex, biWorkgroupID, biNumWorkgroups);

function TryImageType(const AName: string; out AFormat: TImageFormat): Boolean;
function ImageTypeName(AFormat: TImageFormat): string;
function ImagePixelType(AFormat: TImageFormat): TShaderType;
function ImageFormatName(AFormat: TImageFormat): string;
function ImageSPIRVFormat(AFormat: TImageFormat): Cardinal;
function ImageVulkanFormat(AFormat: TImageFormat): Cardinal;
function TryBuiltin(const AName: string; out ABuiltin: TInvocationBuiltin): Boolean;
function BuiltinName(ABuiltin: TInvocationBuiltin): string;
function BuiltinType(ABuiltin: TInvocationBuiltin): TShaderType;
function BuiltinDecoration(ABuiltin: TInvocationBuiltin): Cardinal;

implementation

uses System.SysUtils;

function ImageTypeName(AFormat: TImageFormat): string;
const Names: array[TImageFormat] of string = ('Image2D_R32UInt','Image2D_R32Int','Image2D_RGBA32Float','Image2D_RGBA8');
begin Result := Names[AFormat]; end;
function TryImageType(const AName: string; out AFormat: TImageFormat): Boolean;
var F: TImageFormat;
begin
  for F := Low(TImageFormat) to High(TImageFormat) do
    if SameText(AName, ImageTypeName(F)) then begin AFormat := F; Exit(True); end;
  Result := False;
end;
function ImagePixelType(AFormat: TImageFormat): TShaderType;
begin
  case AFormat of imR32UInt: Result := stCardinal4; imR32Int: Result := stInteger4;
  else Result := stSingle4; end;
end;
function ImageFormatName(AFormat: TImageFormat): string;
const N: array[TImageFormat] of string = ('R32_UINT','R32_SINT','R32G32B32A32_SFLOAT','R8G8B8A8_UNORM');
begin Result := N[AFormat]; end;
function ImageSPIRVFormat(AFormat: TImageFormat): Cardinal;
const N: array[TImageFormat] of Cardinal = (33,24,1,4);
begin Result := N[AFormat]; end;
function ImageVulkanFormat(AFormat: TImageFormat): Cardinal;
const N: array[TImageFormat] of Cardinal = (98,99,109,37);
begin Result := N[AFormat]; end;
function BuiltinName(ABuiltin: TInvocationBuiltin): string;
const N: array[TInvocationBuiltin] of string = ('GlobalInvocationID','LocalInvocationID','LocalInvocationIndex','WorkgroupID','NumWorkgroups');
begin Result := N[ABuiltin]; end;
function TryBuiltin(const AName: string; out ABuiltin: TInvocationBuiltin): Boolean;
var B: TInvocationBuiltin;
begin
  for B := Low(TInvocationBuiltin) to High(TInvocationBuiltin) do
    if SameText(AName, BuiltinName(B)) then begin ABuiltin := B; Exit(True); end;
  Result := False;
end;
function BuiltinType(ABuiltin: TInvocationBuiltin): TShaderType;
begin
  if ABuiltin = biLocalInvocationIndex then Result := stCardinal else Result := stCardinal3;
end;
function BuiltinDecoration(ABuiltin: TInvocationBuiltin): Cardinal;
const N: array[TInvocationBuiltin] of Cardinal = (28,27,29,26,24);
begin Result := N[ABuiltin]; end;

end.
