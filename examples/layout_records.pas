type
  TWeights = array[0..1] of Single3;
  TItem = record
    Position: Single3;
    Weight: Single;
    Samples: TWeights;
    Tag: Cardinal;
  end;
  TOptions = record
    Count: Cardinal;
    Scale: Single;
    Offset: Single3;
    Extra: Single;
    Factors: array[0..1] of Single2;
  end;

var
  [Binding(0, 0), ReadOnly]
  InputData: array of TItem;
  [Binding(0, 1), WriteOnly]
  OutputData: array of TItem;
  [Binding(0, 2), WriteOnly]
  VectorData: array of Single3;
  [PushConstant]
  Params: TOptions;

function Transform(Value: TItem; Shift: Single3; Factor: Single): TItem;
var
  I: Integer;
begin
  Result := Value;
  Result.Position := Value.Position * Factor + Shift;
  for I := 0 to 1 do
    Result.Samples[I] := Value.Samples[I] + Result.Position;
  Result.Tag := Value.Tag + 1;
end;

procedure Main;
var
  Index: Cardinal;
  Item: TItem;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Count then
  begin
    Item := Transform(InputData[Index], Params.Offset, Params.Scale);
    Item.Weight := Item.Weight + Params.Extra;
    Item.Samples[0].X := Item.Samples[0].X + Params.Factors[0].X;
    Item.Samples[1].Y := Item.Samples[1].Y + Params.Factors[1].Y;
    OutputData[Index] := Item;
    VectorData[Index] := Item.Position;
  end;
end;
