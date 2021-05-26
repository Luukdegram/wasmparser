# Zig WASM parser

Parsing library implementing the wasm spec. To be used for projects written in [zig](https://ziglang.org).
The goal of this library is to kickstart wasm-related projects in the Zig ecosystem. It will try to stay
on top of the latest wasm proposals and implement those.

Currently it only provides a single `parse` function that accepts any reader into wasm source bytes.
In the future, more options such as a state-driven parser will be added that allows for better integration
with CLI's and tools to provide more information to the caller.

## example
```zig
const wasmparser = @import("wasmparser");

var result = try wasmparser.parse(allocator, some_reader);
defer result.deinit(allocator); // allows for memory cleanup

const module = result.module; // access the parsed Module

//get first export
const first_export_name = module.exports[0].name;
```
