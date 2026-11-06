# Vulkan 1.1 extended profile

`[Vulkan11]` on `procedure Main` selects `compute-vulkan1.1`, emitting SPIR-V 1.3.
It exposes the same bounded extended scalar and local-reference language as
`[Vulkan12]`; it does not replace arithmetic with approximations or software
emulation. The generated instruction stream is the same for equivalent source.

The target must enable every reflected `required_features` entry. Reflection additionally
contains `required_device_extensions` for features not yet core in Vulkan 1.1:

| Use | Required device extension on Vulkan 1.1 |
| --- | --- |
| `Byte` values | `VK_KHR_shader_float16_int8` |
| 8-bit buffer/push-constant storage | `VK_KHR_8bit_storage` |
| `StrictFloat` | `VK_KHR_shader_float_controls` |

16-bit storage is core in Vulkan 1.1, but its reflected optional feature bits must
still be enabled. `Int64`/`UInt64` and `Double` still require native `shaderInt64`
and `shaderFloat64`. Strict floating point additionally requires the reflected
denormal, signed-zero/NaN/infinity and rounding-mode properties for each width.
An advertised Vulkan API version alone never proves these capabilities.

For a newer target, core promotion may satisfy the device-extension requirements;
the application must still query and enable the required features. `[Vulkan12]`
retains its existing Vulkan 1.2 contract, while an entry with neither attribute
remains SPIR-V 1.0 / Vulkan 1.0. The two target attributes cannot be combined.
