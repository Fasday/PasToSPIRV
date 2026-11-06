unit PTS.FlowAnalysis;

// Must-initialization over a structured CFG. Meet is intersection, including
// actual loop back-edges, Exit, Break and Continue. Unreachable code is still
// parsed/type-checked, but does not contribute assignments or require reads.

interface

uses PTS.IR;

function NeedsFlowAnalysis(F: TShaderFunction): Boolean;
procedure CheckFlowAssignment(F: TShaderFunction);

implementation

uses System.SysUtils, System.Generics.Collections, PTS.Diagnostics;

type
  TBits = TArray<Boolean>;
  TNodeKind = (nkStatement, nkCondition, nkForInit, nkForStep, nkForKill, nkEnd, nkEmpty);
  TNode = class
    Kind: TNodeKind;
    S: TStatement;
    Pred, Succ: TList<Integer>;
    State: TBits;
    Reachable: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;
  TFlow = class
    F: TShaderFunction;
    Variables: TList<TShaderVariable>;
    Nodes: TObjectList<TNode>;
    Initial: TBits;
    Entry: Integer;
    // Captured variables definitely assigned at every reachable return.
    Writes: TBits;
    AnyReturn: Boolean;
    function Node(K: TNodeKind; S: TStatement): Integer;
    procedure Edge(A, B: Integer);
    function Build(S: TStatement; Next, BreakTo, ContinueTo: Integer): Integer;
    procedure ReadVar(V: TShaderVariable; const State: TBits; const Pos: TSourcePosition; Check: Boolean);
    procedure Expr(E: TExpression; var State: TBits; Check: Boolean);
    procedure Address(E: TExpression; var State: TBits; NeedValue, Check: Boolean);
    procedure Transfer(N: TNode; var State: TBits; Check: Boolean);
    procedure Returns(S: TStatement; const State: TBits; Check: Boolean);
    procedure Mark(V: TShaderVariable; var State: TBits; Value: Boolean = True);
    procedure Run;
    constructor Create(AFunction: TShaderFunction);
    destructor Destroy; override;
  end;

function NeedsFlowAnalysis(F: TShaderFunction): Boolean;
  function E(X: TExpression): Boolean;
  var A: TExpression; P: TShaderVariable;
  begin
    if X = nil then Exit(False);
    if X.Kind = ekCall then
    begin
      if X.Callee.Captures.Count > 0 then Exit(True);
      for P in X.Callee.Parameters do if P.ParameterMode in [pmVar, pmOut] then Exit(True);
    end;
    if E(X.Left) or E(X.Right) then Exit(True);
    for A in X.Arguments do if E(A) then Exit(True);
    Result := False;
  end;
  function S(X: TStatement): Boolean;
  var C: TStatement;
  begin
    if X = nil then Exit(False);
    if X.Kind in [skReturn, skBreak, skContinue, skCase, skRepeat, skDeclare, skIncrement,
      skDiscard, skInterlock] then
      Exit(True);
    if E(X.Value) or E(X.Target) or E(X.Condition) or E(X.Limit) then Exit(True);
    if S(X.ThenPart) or S(X.ElsePart) or S(X.Body) then Exit(True);
    for C in X.Children do if S(C) then Exit(True);
    Result := False;
  end;
var P: TShaderVariable;
begin
  for P in F.Parameters do if P.ParameterMode in [pmVar, pmOut] then Exit(True);
  // Nested routines and their callers need call summaries of captured variables.
  if F.Captures.Count > 0 then Exit(True);
  Result := S(F.Body);
end;

constructor TNode.Create;
begin
  inherited; Pred := TList<Integer>.Create; Succ := TList<Integer>.Create;
end;
destructor TNode.Destroy;
begin
  Pred.Free; Succ.Free; inherited;
end;
constructor TFlow.Create(AFunction: TShaderFunction);
var V: TShaderVariable;
begin
  inherited Create; F := AFunction;
  Nodes := TObjectList<TNode>.Create(True);
  Variables := TList<TShaderVariable>.Create;
  for V in F.Parameters do Variables.Add(V);
  for V in F.Locals do Variables.Add(V);
  // Variables of enclosing routines: their state at entry is unknown; reads
  // before a write become requirements of every call (CaptureReads).
  for V in F.Captures do Variables.Add(V);
end;
destructor TFlow.Destroy;
begin
  Variables.Free; Nodes.Free; inherited;
end;
function TFlow.Node(K: TNodeKind; S: TStatement): Integer;
var N: TNode;
begin
  if Nodes.Count >= 65536 then raise EShaderError.Create(F.Position, 'Control-flow graph exceeds 65536 nodes');
  Result := Nodes.Count; N := TNode.Create; N.Kind := K; N.S := S; Nodes.Add(N);
end;
procedure TFlow.Edge(A, B: Integer);
begin
  if B < 0 then Exit;
  if not Nodes[A].Succ.Contains(B) then begin Nodes[A].Succ.Add(B); Nodes[B].Pred.Add(A); end;
end;
function TFlow.Build(S: TStatement; Next, BreakTo, ContinueTo: Integer): Integer;
var I, Head, Step, Kill, Body: Integer;
begin
  if S = nil then Exit(Next);
  if S.Kind = skBlock then
  begin
    Result := Next;
    for I := S.Children.Count - 1 downto 0 do Result := Build(S.Children[I], Result, BreakTo, ContinueTo);
    Exit;
  end;
  case S.Kind of
    skIf:
      begin
        Result := Node(nkCondition, S);
        Edge(Result, Build(S.ThenPart, Next, BreakTo, ContinueTo));
        Edge(Result, Build(S.ElsePart, Next, BreakTo, ContinueTo));
      end;
    skCase:
      begin
        Result := Node(nkCondition, S);
        for I := 0 to S.Children.Count - 1 do Edge(Result, Build(S.Children[I], Next, BreakTo, ContinueTo));
        Edge(Result, Build(S.ElsePart, Next, BreakTo, ContinueTo));
      end;
    skWhile:
      begin
        Head := Node(nkCondition, S);
        Edge(Head, Build(S.Body, Head, Next, Head)); Edge(Head, Next); Result := Head;
      end;
    skRepeat:
      begin
        Head := Node(nkCondition, S);
        Body := Build(S.Body, Head, Next, Head);
        Edge(Head, Body); Edge(Head, Next); Result := Body;
      end;
    skFor:
      begin
        Kill := Node(nkForKill, S); Edge(Kill, Next);
        Head := Node(nkEmpty, S);
        Step := Node(nkForStep, S); Edge(Step, Head);
        Edge(Head, Build(S.Body, Step, Kill, Step)); Edge(Head, Kill);
        Result := Node(nkForInit, S); Edge(Result, Head);
      end;
    skReturn, skDiscard:
      Result := Node(nkStatement, S);
    skInterlock:
      Result := Build(S.Body, Next, BreakTo, ContinueTo);
    skBreak: begin Result := Node(nkEmpty, S); Edge(Result, BreakTo); end;
    skContinue: begin Result := Node(nkEmpty, S); Edge(Result, ContinueTo); end;
  else Result := Node(nkStatement, S); Edge(Result, Next);
  end;
end;
procedure TFlow.Mark(V: TShaderVariable; var State: TBits; Value: Boolean);
var I: Integer;
begin
  I := Variables.IndexOf(V); if I >= 0 then State[I] := Value;
end;
procedure TFlow.ReadVar(V: TShaderVariable; const State: TBits; const Pos: TSourcePosition; Check: Boolean);
var I: Integer;
begin
  if not Check then Exit;
  I := Variables.IndexOf(V);
  if (I >= 0) and not State[I] then
  begin
    if V.Owner <> F then
    begin
      if not F.CaptureReads.Contains(V) then F.CaptureReads.Add(V);
      Exit;
    end;
    raise EShaderError.Create(Pos, 'Local value "' + V.Name + '" may be uninitialized; aggregates require whole-value initialization');
  end;
end;
procedure TFlow.Address(E: TExpression; var State: TBits; NeedValue, Check: Boolean);
begin
  if E.Kind in [ekField, ekIndex, ekComponent, ekSwizzle] then
  begin
    Address(E.Left, State, True, Check); Expr(E.Right, State, Check);
  end
  else if E.Kind = ekLocal then
  begin
    if NeedValue then ReadVar(E.Variable, State, E.Position, Check);
  end
  else Expr(E.Left, State, Check);
end;
procedure TFlow.Expr(E: TExpression; var State: TBits; Check: Boolean);
var A: TExpression; I: Integer; P: TShaderVariable; Skipped: TBits;
begin
  if E = nil then Exit;
  if E.Kind = ekCall then
  begin
    for I := 0 to E.Arguments.Count - 1 do
    begin
      P := E.Callee.Parameters[I]; A := E.Arguments[I];
      // Capturing a whole-variable reference evaluates an address, not its value.
      // A later value argument may initialize it before the callee is entered.
      if P.ParameterMode in [pmVar, pmOut] then Address(A, State, False, Check)
      else Expr(A, State, Check);
    end;
    for I := 0 to E.Arguments.Count - 1 do
      if (E.Callee.Parameters[I].ParameterMode = pmVar) and (E.Arguments[I].Kind = ekLocal) then
        ReadVar(E.Arguments[I].Variable, State, E.Arguments[I].Position, Check);
    // A nested callee reads/writes variables of enclosing routines.
    for P in E.Callee.CaptureReads do
    begin
      I := Variables.IndexOf(P);
      if Check and (I >= 0) and not State[I] then
      begin
        if P.Owner <> F then
        begin
          if not F.CaptureReads.Contains(P) then F.CaptureReads.Add(P);
        end
        else
          raise EShaderError.Create(E.Position, 'Nested routine "' + E.Callee.Name + '" reads "' + P.Name +
            '", which may be uninitialized here');
      end;
    end;
    for P in E.Callee.CaptureWrites do Mark(P, State);
    for I := 0 to E.Arguments.Count - 1 do
      if (E.Callee.Parameters[I].ParameterMode = pmOut) and (E.Arguments[I].Kind = ekLocal) then
        Mark(E.Arguments[I].Variable, State);
    Exit;
  end;
  if E.Kind = ekLocal then ReadVar(E.Variable, State, E.Position, Check);
  if E.Kind = ekConditional then
  begin
    // Only one branch runs: assignments (out arguments) in a branch are conditional.
    Expr(E.Arguments[0], State, Check);
    Skipped := Copy(State);
    Expr(E.Left, State, Check);
    Expr(E.Right, Skipped, Check);
    for I := 0 to High(State) do State[I] := State[I] and Skipped[I];
    Exit;
  end;
  if (E.Kind = ekBinary) and E.ShortCircuit then
  begin
    // The right operand may be skipped: out-initializations in it are conditional.
    Expr(E.Left, State, Check);
    Skipped := Copy(State);
    Expr(E.Right, State, Check);
    for I := 0 to High(State) do State[I] := State[I] and Skipped[I];
    Exit;
  end;
  Expr(E.Left, State, Check); Expr(E.Right, State, Check);
  for A in E.Arguments do Expr(A, State, Check);
end;
procedure TFlow.Returns(S: TStatement; const State: TBits; Check: Boolean);
var P: TShaderVariable; I: Integer;
begin
  if Check then
  begin
    AnyReturn := True;
    for I := 0 to Variables.Count - 1 do
      if Variables[I].Owner <> F then Writes[I] := Writes[I] and State[I];
  end;
  for P in F.Parameters do if P.ParameterMode = pmOut then ReadVar(P, State, F.Position, Check);
  if (F.ResultVariable <> nil) and ((S = nil) or (S.Value = nil)) then
  begin
    if Check and not State[Variables.IndexOf(F.ResultVariable)] then
      raise EShaderError.Create(F.Position, 'Function "' + F.Name + '" may return an uninitialized Result');
  end;
end;
procedure TFlow.Transfer(N: TNode; var State: TBits; Check: Boolean);
var S: TStatement;
begin
  S := N.S;
  case N.Kind of
    nkCondition: Expr(S.Condition, State, Check);
    nkForInit:
      begin Expr(S.Value, State, Check); Expr(S.Limit, State, Check); Mark(S.Target.Variable, State); end;
    nkForStep: ReadVar(S.Target.Variable, State, S.Position, Check);
    nkForKill: Mark(S.Target.Variable, State, False);
    nkEnd: Returns(nil, State, Check);
    nkStatement:
      case S.Kind of
        skAssign:
          begin
            // Addresses are evaluated before the RHS (including index side effects).
            Address(S.Target, State, False, Check); Expr(S.Value, State, Check);
            if S.Target.Kind = ekLocal then Mark(S.Target.Variable, State);
          end;
        skEvaluate: Expr(S.Value, State, Check);
        skReturn: begin Expr(S.Value, State, Check); Returns(S, State, Check); end;
        skIncrement:
          begin
            Address(S.Target, State, True, Check); // reads the current value
            Expr(S.Value, State, Check);
          end;
        skDeclare:
          // Each execution of an inline declaration starts a fresh variable.
          if S.Value <> nil then
          begin
            Expr(S.Value, State, Check);
            Mark(S.Target.Variable, State);
          end
          else Mark(S.Target.Variable, State, False);
      end;
  end;
end;
procedure TFlow.Run;
var
  Q: TQueue<Integer>;
  Queued: TArray<Boolean>;
  InState, OutState: TBits;
  I, J, K, EndNode: Integer;
  Changed: Boolean;
begin
  EndNode := Node(nkEnd, nil);
  Entry := Build(F.Body, EndNode, -1, -1);
  SetLength(Initial, Variables.Count);
  for I := 0 to Variables.Count - 1 do
    Initial[I] := (Variables[I].Kind = vkParameter) and (Variables[I].ParameterMode <> pmOut) and
      (Variables[I].Owner = F);
  SetLength(Writes, Variables.Count);
  for I := 0 to Variables.Count - 1 do Writes[I] := True;
  AnyReturn := False;
  F.CaptureReads.Clear;
  F.CaptureWrites.Clear;
  Q := TQueue<Integer>.Create;
  try
    Q.Enqueue(Entry); Nodes[Entry].Reachable := True;
    while Q.Count > 0 do
    begin
      I := Q.Dequeue;
      for J in Nodes[I].Succ do if not Nodes[J].Reachable then
      begin Nodes[J].Reachable := True; Q.Enqueue(J); end;
    end;
    SetLength(Queued, Nodes.Count);
    for I := 0 to Nodes.Count - 1 do
    begin
      SetLength(Nodes[I].State, Variables.Count);
      for J := 0 to Variables.Count - 1 do Nodes[I].State[J] := True;
      if Nodes[I].Reachable then begin Q.Enqueue(I); Queued[I] := True; end;
    end;
    while Q.Count > 0 do
    begin
      I := Q.Dequeue; Queued[I] := False;
      if I = Entry then InState := Copy(Initial)
      else
      begin
        SetLength(InState, Variables.Count);
        for K := 0 to High(InState) do InState[K] := True;
      end;
      for J in Nodes[I].Pred do if Nodes[J].Reachable then
        for K := 0 to High(InState) do InState[K] := InState[K] and Nodes[J].State[K];
      OutState := Copy(InState); Transfer(Nodes[I], OutState, False);
      Changed := False;
      for K := 0 to High(OutState) do Changed := Changed or (OutState[K] <> Nodes[I].State[K]);
      if Changed then
      begin
        Nodes[I].State := OutState;
        for J in Nodes[I].Succ do if not Queued[J] then begin Q.Enqueue(J); Queued[J] := True; end;
      end;
    end;
    for I := 0 to Nodes.Count - 1 do if Nodes[I].Reachable then
    begin
      if I = Entry then InState := Copy(Initial)
      else begin SetLength(InState, Variables.Count); for K := 0 to High(InState) do InState[K] := True; end;
      for J in Nodes[I].Pred do if Nodes[J].Reachable then
        for K := 0 to High(InState) do InState[K] := InState[K] and Nodes[J].State[K];
      Transfer(Nodes[I], InState, True);
    end;
    if AnyReturn then
      for I := 0 to Variables.Count - 1 do
        if (Variables[I].Owner <> F) and Writes[I] then F.CaptureWrites.Add(Variables[I]);
  finally Q.Free; end;
end;
procedure CheckFlowAssignment(F: TShaderFunction);
var C: TFlow;
begin
  C := TFlow.Create(F); try C.Run; finally C.Free; end;
end;

end.
