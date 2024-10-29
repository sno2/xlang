# xlang

Alternative implementation of the [ArithLang](https://github.com/clayness/arithlang),
[VarLang](https://github.com/clayness/varlang), [DefineLang](https://github.com/clayness/definelang),
[FuncLang](https://github.com/clayness/funclang), and [RefLang](https://github.com/clayness/reflang)
languages used in COM S 3420 at Iowa State University. The languages are
described in the textbook _An Experiential Introduction to Principles of
Programming Languages_ by Hridesh Rajan.

## Implementation details

xlang is written using the master version of the
[Zig programming language](https://ziglang.org/). Zig allows xlang to run on
many different platforms such as the web via
[WebAssembly](https://webassembly.org/).

The tokenizer is piped directly into code generation and xlang compiles the
source code into a bytecode format on the fly. This technique is also used by
the [QuickJS JavaScript engine](https://bellard.org/quickjs/quickjs.html#Bytecode)
and avoids the cost of building a parse tree.

Values are efficiently stored in 64-bit floating point numbers using
[NaN boxing](https://leonardschuetz.ch/blog/nan-boxing/). The NaN boxing
implementation used in xlang is adapted from the one I contributed to the
[Kiesel JavaScript engine](https://codeberg.org/kiesel-js/kiesel/pulls/37).

Locals are immutable memory but they must be allocated on the stack for every
function call. Defines are mutable memory so they are allocated as a list of
registers at the top of the stack. Captured variables, i.e. using an outer
function's local, are more complex and require attaching values to lambda
values.

The tail call optimization reuses the stack of the current call when returning
another function call. Note that this is not limited to self-recursive functions
but also works when returning any function call to efficiently support
[mutual recursion](https://wikipedia.org/wiki/Mutual_recursion).

Memory is managed via a simple garbage collector that maintains a free list
amongst a list of pages. I did not spend any time optimizing the garbage
collector, but more efficient methods such as generational garbage collection
would most likely improve its performance.

## Playground

The web playground uses the [Monaco Editor](https://microsoft.github.io/monaco-editor/),
[xterm.js](https://xtermjs.org/), and a Wasm build of xlang to interpret
programs on the web. The generated playground files are checked into Git to
avoid complex deployments. Build the playground using

```
zig build playground
# --watch for build on save
# -Doptimize=ReleaseFast for optimized Wasm
```

## Testing

Test files are located in the [examples folder](./examples/). Run the tests
against xlang:

```
zig build test -Djava_compat
# --fuzz to enable fuzz testing
```

Run the tests against RefLang:

```
zig build test -Djava_source=../path/to/reflang
```

## License

[MIT](./LICENSE)
