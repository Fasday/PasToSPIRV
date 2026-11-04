unit PTS.References;

// Reference-call shapes: pass a Function (or, for variables captured by nested
// routines, Private) memory-object root, never an access-chain
// pointer. Field paths are specialized; dynamic indices are additional value
// parameters. Aliases stay aliases, including overlapping fields and nested calls.

interface

uses PTS.Types, PTS.IR;

type
  TReferenceStep = record
    Dynamic: Boolean;
    Index: Cardinal;
    DataType: TShaderType;
  end;
  TReferenceShape = class
    RootType: TShaderType;
    RootComposite: TCompositeType;
    RootStorage: Cardinal; // Function (7) or Private (6, captured by a nested routine)
    Steps: TArray<TReferenceStep>;
    function Clone: TReferenceShape;
  end;
  TReferenceBinding = record
    RootID: Cardinal;
    Shape: TReferenceShape; // Non-owning for current function, owned for a call plan.
    Indices: TArray<Cardinal>;
  end;
  TFunctionInstance = class
    ShaderFunction: TShaderFunction;
    ID: Cardinal;
    Shapes: TArray<TReferenceShape>;
    destructor Destroy; override;
  end;

implementation

function TReferenceShape.Clone: TReferenceShape;
begin
  Result := TReferenceShape.Create;
  Result.RootType := RootType; Result.RootComposite := RootComposite; Result.RootStorage := RootStorage;
  Result.Steps := Copy(Steps);
end;
destructor TFunctionInstance.Destroy;
var S: TReferenceShape;
begin
  for S in Shapes do S.Free;
  inherited;
end;

end.
