unit PTS.Graphics;

interface

uses PTS.IR;

procedure CheckGraphics(AModule: TShaderModule);

implementation

uses
  System.SysUtils, System.Generics.Collections, PTS.Types, PTS.Features, PTS.Diagnostics;

procedure CheckGraphics(AModule: TShaderModule);
var
  F: TShaderFunction;
  V: TShaderVariable;
  HasPosition: Boolean;
  DiscardCache: TDictionary<TShaderFunction, Boolean>;
  Outputs: TList<TShaderVariable>;

  procedure Fail(const MessageText: string);
  begin
    raise EShaderError.Create(AModule.EntryPoint.Position, MessageText);
  end;

  function Discards(S: TStatement): Boolean; forward;

  function ExpressionDiscards(E: TExpression): Boolean;
  var
    A: TExpression;
    Value: Boolean;
  begin
    if E = nil then
      Exit(False);
    if E.Kind = ekCall then
    begin
      if not DiscardCache.TryGetValue(E.Callee, Value) then
      begin
        Value := Discards(E.Callee.Body);
        DiscardCache.Add(E.Callee, Value);
      end;
      if Value then
        Exit(True);
    end;
    if ExpressionDiscards(E.Left) or ExpressionDiscards(E.Right) then
      Exit(True);
    for A in E.Arguments do
      if ExpressionDiscards(A) then
        Exit(True);
    Result := False;
  end;

  function Discards(S: TStatement): Boolean;
  var
    C: TStatement;
  begin
    if S = nil then
      Exit(False);
    if S.Kind = skDiscard then
      Exit(True);
    if ExpressionDiscards(S.Value) or ExpressionDiscards(S.Target) or
      ExpressionDiscards(S.Condition) or ExpressionDiscards(S.Limit) then
      Exit(True);
    if Discards(S.ThenPart) or Discards(S.ElsePart) or Discards(S.Body) then
      Exit(True);
    for C in S.Children do
      if Discards(C) then
        Exit(True);
    Result := False;
  end;

  procedure Expression(E: TExpression);
  var
    A: TExpression;
  begin
    if E = nil then
      Exit;
    if (E.Kind = ekInvocationID) and (AModule.Stage <> ssCompute) then
      Fail('Compute invocation built-ins are unavailable in graphics stages');
    if (E.Kind = ekIntrinsic) and (E.Intrinsic in [inDdxFine, inDdyFine]) then
    begin
      if AModule.Stage <> ssFragment then
        Fail('Fine derivatives require a fragment stage');
      AModule.UsesDerivatives := True;
    end;
    Expression(E.Left);
    Expression(E.Right);
    for A in E.Arguments do
      Expression(A);
  end;

  procedure Statement(S: TStatement; InInterlock: Boolean);
  var
    C: TStatement;
  begin
    if S = nil then
      Exit;
    if (S.Kind = skDiscard) and (AModule.Stage <> ssFragment) then
      Fail('Discard requires a fragment stage');
    if InInterlock and (S.Kind in [skDiscard, skReturn]) then
      Fail('Interlock blocks cannot terminate an invocation or return');
    if InInterlock and (ExpressionDiscards(S.Value) or ExpressionDiscards(S.Target) or
      ExpressionDiscards(S.Condition) or ExpressionDiscards(S.Limit)) then
      Fail('An Interlock block cannot call a function that may Discard');
    if S.Kind = skInterlock then
      InInterlock := True;
    Expression(S.Value);
    Expression(S.Target);
    Expression(S.Condition);
    Expression(S.Limit);
    Statement(S.ThenPart, InInterlock);
    Statement(S.ElsePart, InInterlock);
    Statement(S.Body, InInterlock);
    for C in S.Children do
      Statement(C, InInterlock);
  end;

  procedure RequireOutputs(const State: TArray<Boolean>);
  var
    I: Integer;
  begin
    for I := 0 to Outputs.Count - 1 do
      if not State[I] then
        Fail('Stage output "' + Outputs[I].Name + '" may be unwritten');
  end;

  function Assignments(S: TStatement; var State: TArray<Boolean>): Boolean;
  var
    A, B: TArray<Boolean>;
    AliveA, AliveB: Boolean;
    C: TStatement;
    I, Index: Integer;
  begin
    Result := True;
    if S = nil then
      Exit;
    case S.Kind of
      skBlock:
        for C in S.Children do
          if not Assignments(C, State) then
            Exit(False);
      skAssign:
        if S.Target.Kind = ekLocal then
        begin
          Index := Outputs.IndexOf(S.Target.Variable);
          if Index >= 0 then
            State[Index] := True;
        end;
      skReturn:
        begin
          RequireOutputs(State);
          Exit(False);
        end;
      skDiscard:
        Exit(False);
      skIf:
        begin
          A := Copy(State);
          B := Copy(State);
          AliveA := Assignments(S.ThenPart, A);
          AliveB := Assignments(S.ElsePart, B);
          if not AliveA and not AliveB then
            Exit(False);
          if not AliveA then
            State := B
          else if not AliveB then
            State := A
          else
            for I := 0 to High(State) do
              State[I] := A[I] and B[I];
        end;
      skInterlock:
        Result := Assignments(S.Body, State);
      skFor, skWhile, skRepeat:
        begin
          // A loop may not establish an output after it (including Break paths).
          A := Copy(State);
          Assignments(S.Body, A);
        end;
      skCase:
        begin
          A := Copy(State);
          AliveA := Assignments(S.ElsePart, A);
          for C in S.Children do
          begin
            B := Copy(State);
            AliveB := Assignments(C, B);
            if AliveB then
            begin
              if not AliveA then
                A := B
              else
                for I := 0 to High(A) do
                  A[I] := A[I] and B[I];
              AliveA := True;
            end;
          end;
          State := A;
          Result := AliveA;
        end;
    end;
  end;

var
  State: TArray<Boolean>;
begin
  DiscardCache := TDictionary<TShaderFunction, Boolean>.Create;
  Outputs := TList<TShaderVariable>.Create;
  try
    if (AModule.Stage <> ssCompute) and (AModule.HasLocalSize or
      AModule.UsesWorkgroupBarrier or (AModule.SharedBytes <> 0)) then
      Fail('Graphics stages cannot use LocalSize, shared memory or workgroup Barrier');
    if AModule.PixelInterlock <> AModule.UsesInterlock then
      Fail('PixelInterlockOrdered requires exactly one Interlock block in Main');
    if AModule.PixelInterlock and (AModule.Stage <> ssFragment) then
      Fail('PixelInterlockOrdered requires a fragment stage');
    HasPosition := False;
    for V in AModule.Resources do
      if V.Kind in [vkInput, vkOutput] then
      begin
        if AModule.Stage = ssCompute then
          Fail('Stage interfaces require Vertex or Fragment');
        if V.Kind = vkOutput then
          Outputs.Add(V);
        if V.GraphicsBuiltin <> gbNone then
        begin
          case V.GraphicsBuiltin of
            gbPosition, gbPointSize:
              if (AModule.Stage <> ssVertex) or (V.Kind <> vkOutput) then
                Fail('Position and PointSize are vertex outputs');
            gbFragCoord, gbFrontFacing:
              if (AModule.Stage <> ssFragment) or (V.Kind <> vkInput) then
                Fail('FragCoord and FrontFacing are fragment inputs');
            gbFragDepth:
              if (AModule.Stage <> ssFragment) or (V.Kind <> vkOutput) then
                Fail('FragDepth is a fragment output');
            gbVertexIndex, gbInstanceIndex:
              if (AModule.Stage <> ssVertex) or (V.Kind <> vkInput) then
                Fail('VertexIndex and InstanceIndex are vertex inputs');
          end;
          HasPosition := HasPosition or (V.GraphicsBuiltin = gbPosition);
        end
        else if ((AModule.Stage = ssVertex) and (V.Kind = vkInput)) or
          ((AModule.Stage = ssFragment) and (V.Kind = vkOutput)) then
        begin
          if V.Interpolation <> ipSmooth then
            Fail('Interpolation belongs on vertex outputs or fragment inputs');
        end
        else if (ComponentType(V.DataType) in [stInteger, stCardinal]) and (V.Interpolation <> ipFlat) then
          Fail('Integer varyings require Flat interpolation');
      end;
    if (AModule.Stage = ssVertex) and not HasPosition then
      Fail('Vertex shaders require a Position output');
    for F in AModule.Functions do
      Statement(F.Body, False);
    SetLength(State, Outputs.Count);
    if Assignments(AModule.EntryPoint.Body, State) then
      RequireOutputs(State);
  finally
    Outputs.Free;
    DiscardCache.Free;
  end;
end;

end.
