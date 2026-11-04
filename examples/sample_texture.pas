var
  [Binding(0,0)] SourceTexture: Texture2D;
  [Binding(0,1)] PointSampler: Sampler;
  [Binding(0,2), WriteOnly] OutputData: array of Single4;
  [PushConstant] Params: record Width: Cardinal; Height: Cardinal; end;
procedure Main;
var Index: Cardinal; UV: Single2;
begin
  Index := GlobalInvocationID.X;
  if Index < Params.Width * Params.Height then
  begin
    UV := Single2((Single(Index mod Params.Width) + 0.5) / Single(Params.Width),
                  (Single(Index div Params.Width) + 0.5) / Single(Params.Height));
    OutputData[Index] := SampleLevel(SourceTexture, PointSampler, UV, 0);
  end;
end;
