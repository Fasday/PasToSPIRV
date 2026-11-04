program ExtendedBindingsCheck;
{$APPTYPE CONSOLE}
uses ExtendedLayoutBindings in '..\build\tests\ExtendedLayoutBindings.pas';
begin
  PTS_ValidateLayouts;
  Writeln('PASS: native small/wide scalar std430 layouts and generated Delphi bindings.');
end.
