unit PTS.Profile;

interface

uses PTS.IR;

procedure CheckProfile(AModule: TShaderModule);

implementation

uses PTS.Types, PTS.Diagnostics;

function HasType(T: TShaderType; C: TCompositeType; Wanted: TShaderType): Boolean;
  var F: TTypeField;
  begin
    if T <> stComposite then Exit(T = Wanted);
    if C.Kind = ctArray then Exit(HasType(C.ElementType, C.ElementComposite, Wanted));
    for F in C.Fields do if HasType(F.DataType, F.Composite, Wanted) then Exit(True);
    Result := False;
  end;
  function HasReturn(S: TStatement): Boolean;
  var C: TStatement;
  begin
    if S = nil then Exit(False);
    if S.Kind = skReturn then Exit(True);
    if HasReturn(S.ThenPart) or HasReturn(S.ElsePart) or HasReturn(S.Body) then Exit(True);
    for C in S.Children do if HasReturn(C) then Exit(True);
    Result := False;
  end;

procedure CheckProfile(AModule: TShaderModule);
  procedure MarkType(T: TShaderType; C: TCompositeType);
  var F: TTypeField;
  begin
    if T = stComposite then
    begin
      if C.Kind = ctArray then MarkType(C.ElementType, C.ElementComposite)
      else for F in C.Fields do MarkType(F.DataType, F.Composite);
    end
    else Include(AModule.UsedTypes, ComponentType(T));
  end;
  procedure Expression(E: TExpression);
  var A: TExpression;
  begin
    if E = nil then Exit;
    MarkType(E.DataType, E.Composite);
    Expression(E.Left); Expression(E.Right);
    for A in E.Arguments do Expression(A);
  end;
  procedure Statement(S: TStatement);
  var C: TStatement;
  begin
    if S = nil then Exit;
    Expression(S.Target); Expression(S.Value); Expression(S.Condition); Expression(S.Limit);
    Statement(S.ThenPart); Statement(S.ElsePart); Statement(S.Body);
    for C in S.Children do Statement(C);
  end;
var F: TShaderFunction; V: TShaderVariable; T: TShaderType;
begin
  for V in AModule.Resources do
  begin
    MarkType(V.DataType, V.Composite);
    if V.Kind = vkBuffer then
    begin
      AModule.Storage8 := AModule.Storage8 or HasType(V.DataType, V.Composite, stByte);
      AModule.Storage16 := AModule.Storage16 or HasType(V.DataType, V.Composite, stWord);
    end;
    if V.Kind = vkPushConstant then
    begin
      AModule.Push8 := AModule.Push8 or HasType(V.DataType, V.Composite, stByte);
      AModule.Push16 := AModule.Push16 or HasType(V.DataType, V.Composite, stWord);
    end;
  end;
  if AModule.UsesWorkgroupBarrier and HasReturn(AModule.EntryPoint.Body) then
    raise EShaderError.Create(AModule.EntryPoint.Position, 'Main cannot Exit when using a workgroup Barrier');
  for V in AModule.Constants.Keys do MarkType(V.DataType, V.Composite);
  for F in AModule.Functions do
  begin
    MarkType(F.ReturnType, F.ReturnComposite);
    for V in F.Parameters do
    begin
      MarkType(V.DataType, V.Composite);
      if V.ParameterMode in [pmVar, pmOut] then AModule.HasReferences := True;
    end;
    for V in F.Locals do MarkType(V.DataType, V.Composite);
    Statement(F.Body);
  end;
  if not AModule.Extended then
  begin
    for T in [stByte, stWord, stInt64, stUInt64, stDouble] do
      if T in AModule.UsedTypes then
        raise EShaderError.Create(AModule.EntryPoint.Position, ShaderTypeName(T) + ' requires [Vulkan12] on Main');
    if AModule.StrictFloat or AModule.HasReferences then
      raise EShaderError.Create(AModule.EntryPoint.Position, 'StrictFloat and var/out parameters require [Vulkan12]');
  end;
end;

end.
