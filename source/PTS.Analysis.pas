unit PTS.Analysis;

{$BOOLEVAL OFF}

interface

uses
  PTS.IR;

// Loop-aware definite-assignment check. The parser's single pass checks each
// loop body only with the state before the loop; this pass also follows loop
// back-edges (for example a nested for that leaves its counter uninitialized).
procedure CheckDefiniteAssignment(AFunction: TShaderFunction);

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  PTS.FlowAnalysis,
  PTS.Diagnostics;

type
  TBitSet = TArray<UInt64>;

  // End(S) = (S and Preserve) or Generate. Exact for these structured statements.
  TSummary = record
    Preserve: TBitSet;
    Generate: TBitSet;
  end;

  TChecker = class
  private
    FFunction: TShaderFunction;
    FIndex: TDictionary<TShaderVariable, Integer>;
    FSummaries: TDictionary<TStatement, TSummary>;
    FWords: Integer;
    function Empty: TBitSet;
    function Full: TBitSet;
    function Copy(const A: TBitSet): TBitSet;
    function AndSet(const A, B: TBitSet): TBitSet;
    function OrSet(const A, B: TBitSet): TBitSet;
    procedure Include(var A: TBitSet; I: Integer);
    procedure Exclude(var A: TBitSet; I: Integer);
    function Contains(const A: TBitSet; I: Integer): Boolean;
    function Tracked(AVariable: TShaderVariable; out I: Integer): Boolean;
    function Summary(AStatement: TStatement): TSummary;
    procedure CheckRead(AExpression: TExpression; const AState: TBitSet);
    procedure CheckExpression(AExpression: TExpression; const AState: TBitSet);
    procedure CheckLValue(AExpression: TExpression; const AState: TBitSet);
    procedure Walk(AStatement: TStatement; var AState: TBitSet);
  public
    constructor Create(AFunction: TShaderFunction);
    destructor Destroy; override;
    procedure Run;
  end;

constructor TChecker.Create(AFunction: TShaderFunction);
var
  I: Integer;
begin
  inherited Create;
  FFunction := AFunction;
  FIndex := TDictionary<TShaderVariable, Integer>.Create;
  FSummaries := TDictionary<TStatement, TSummary>.Create;
  for I := 0 to AFunction.Locals.Count - 1 do
    FIndex.Add(AFunction.Locals[I], I);
  FWords := (AFunction.Locals.Count + 63) div 64;
end;

destructor TChecker.Destroy;
begin
  FSummaries.Free;
  FIndex.Free;
  inherited;
end;

function TChecker.Empty: TBitSet;
begin
  SetLength(Result, FWords);
  if FWords > 0 then FillChar(Result[0], FWords * SizeOf(UInt64), 0);
end;

function TChecker.Full: TBitSet;
var
  I: Integer;
begin
  SetLength(Result, FWords);
  for I := 0 to FWords - 1 do Result[I] := High(UInt64);
end;

function TChecker.Copy(const A: TBitSet): TBitSet;
begin
  Result := System.Copy(A);
end;

function TChecker.AndSet(const A, B: TBitSet): TBitSet;
var
  I: Integer;
begin
  SetLength(Result, FWords);
  for I := 0 to FWords - 1 do Result[I] := A[I] and B[I];
end;

function TChecker.OrSet(const A, B: TBitSet): TBitSet;
var
  I: Integer;
begin
  SetLength(Result, FWords);
  for I := 0 to FWords - 1 do Result[I] := A[I] or B[I];
end;

procedure TChecker.Include(var A: TBitSet; I: Integer);
begin
  A[I div 64] := A[I div 64] or (UInt64(1) shl (I mod 64));
end;

procedure TChecker.Exclude(var A: TBitSet; I: Integer);
begin
  A[I div 64] := A[I div 64] and not (UInt64(1) shl (I mod 64));
end;

function TChecker.Contains(const A: TBitSet; I: Integer): Boolean;
begin
  Result := (A[I div 64] and (UInt64(1) shl (I mod 64))) <> 0;
end;

function TChecker.Tracked(AVariable: TShaderVariable; out I: Integer): Boolean;
begin
  Result := (AVariable <> nil) and FIndex.TryGetValue(AVariable, I);
end;

function TChecker.Summary(AStatement: TStatement): TSummary;
var
  Child: TStatement;
  A, B: TSummary;
  I: Integer;
begin
  if FSummaries.TryGetValue(AStatement, Result) then Exit;
  Result.Preserve := Full;
  Result.Generate := Empty;
  case AStatement.Kind of
    skBlock:
      for Child in AStatement.Children do
      begin
        A := Summary(Child);
        Result.Generate := OrSet(AndSet(Result.Generate, A.Preserve), A.Generate);
        Result.Preserve := AndSet(Result.Preserve, A.Preserve);
      end;
    skAssign:
      if (AStatement.Target.Kind = ekLocal) and Tracked(AStatement.Target.Variable, I) then
        Include(Result.Generate, I);
    skIf:
      begin
        A := Summary(AStatement.ThenPart);
        if AStatement.ElsePart <> nil then B := Summary(AStatement.ElsePart)
        else begin B.Preserve := Full; B.Generate := Empty; end;
        Result.Preserve := OrSet(OrSet(AndSet(A.Preserve, B.Preserve),
          AndSet(A.Preserve, B.Generate)), AndSet(A.Generate, B.Preserve));
        Result.Generate := AndSet(A.Generate, B.Generate);
      end;
    skWhile:
      begin
        A := Summary(AStatement.Body);
        Result.Preserve := OrSet(A.Preserve, A.Generate);
      end;
    skFor:
      begin
        A := Summary(AStatement.Body);
        Result.Preserve := OrSet(A.Preserve, A.Generate);
        if Tracked(AStatement.Target.Variable, I) then Exclude(Result.Preserve, I);
      end;
  end;
  FSummaries.Add(AStatement, Result);
end;

procedure TChecker.CheckRead(AExpression: TExpression; const AState: TBitSet);
var
  I: Integer;
begin
  if Tracked(AExpression.Variable, I) and not Contains(AState, I) then
    raise EShaderError.Create(AExpression.Position, Format(
      'Local variable "%s" may be uninitialized (including on a later loop iteration); aggregates must be initialized as a whole',
      [AExpression.Variable.Name]));
end;

procedure TChecker.CheckExpression(AExpression: TExpression; const AState: TBitSet);
var
  Argument: TExpression;
begin
  if AExpression = nil then Exit;
  if AExpression.Kind = ekLocal then CheckRead(AExpression, AState);
  CheckExpression(AExpression.Left, AState);
  CheckExpression(AExpression.Right, AState);
  for Argument in AExpression.Arguments do CheckExpression(Argument, AState);
end;

procedure TChecker.CheckLValue(AExpression: TExpression; const AState: TBitSet);
begin
  // Partial writes require the whole base value; indices are ordinary reads.
  while AExpression.Kind in [ekField, ekIndex, ekComponent, ekSwizzle] do
  begin
    CheckExpression(AExpression.Right, AState);
    AExpression := AExpression.Left;
  end;
  if AExpression.Kind = ekLocal then CheckRead(AExpression, AState)
  else CheckExpression(AExpression, AState);
end;

procedure TChecker.Walk(AStatement: TStatement; var AState: TBitSet);
var
  Child: TStatement;
  ThenState, ElseState, Head, Body: TBitSet;
  Loop: TSummary;
  I: Integer;
begin
  case AStatement.Kind of
    skBlock:
      for Child in AStatement.Children do Walk(Child, AState);
    skAssign:
      begin
        CheckExpression(AStatement.Value, AState);
        if AStatement.Target.Kind = ekLocal then
        begin
          if Tracked(AStatement.Target.Variable, I) then Include(AState, I);
        end
        else CheckLValue(AStatement.Target, AState);
      end;
    skEvaluate:
      CheckExpression(AStatement.Value, AState);
    skIf:
      begin
        CheckExpression(AStatement.Condition, AState);
        ThenState := Copy(AState);
        Walk(AStatement.ThenPart, ThenState);
        ElseState := Copy(AState);
        if AStatement.ElsePart <> nil then Walk(AStatement.ElsePart, ElseState);
        AState := AndSet(ThenState, ElseState);
      end;
    skWhile:
      begin
        Loop := Summary(AStatement.Body);
        Head := AndSet(AState, OrSet(Loop.Preserve, Loop.Generate));
        CheckExpression(AStatement.Condition, Head);
        Body := Copy(Head);
        Walk(AStatement.Body, Body);
        AState := Head;
      end;
    skFor:
      begin
        CheckExpression(AStatement.Value, AState);
        CheckExpression(AStatement.Limit, AState);
        Loop := Summary(AStatement.Body);
        Head := AndSet(AState, OrSet(Loop.Preserve, Loop.Generate));
        Body := Copy(Head);
        if Tracked(AStatement.Target.Variable, I) then Include(Body, I);
        Walk(AStatement.Body, Body);
        AState := Head;
        if Tracked(AStatement.Target.Variable, I) then Exclude(AState, I);
      end;
  end;
end;

procedure TChecker.Run;
var
  State: TBitSet;
  I: Integer;
begin
  if FFunction.Body = nil then Exit;
  State := Empty;
  Walk(FFunction.Body, State);
  if Tracked(FFunction.ResultVariable, I) and not Contains(State, I) then
    raise EShaderError.Create(FFunction.Position, Format(
      'Function "%s" may return an uninitialized Result', [FFunction.Name]));
end;

procedure CheckDefiniteAssignment(AFunction: TShaderFunction);
var
  Checker: TChecker;
begin
  if NeedsFlowAnalysis(AFunction) then
  begin
    CheckFlowAssignment(AFunction);
    Exit;
  end;
  Checker := TChecker.Create(AFunction);
  try
    Checker.Run;
  finally
    Checker.Free;
  end;
end;

end.
