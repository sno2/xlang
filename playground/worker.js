const enc = new TextEncoder();
const dec = new TextDecoder();

const promise = WebAssembly.instantiateStreaming(fetch("xlang.wasm")).then(
  ({ instance }) => instance.exports
);

addEventListener("message", async (e) => {
  const exports = await promise;
  const data = e.data;
  if (data.type === "codegen") {
    const ptr = exports.allocSource(data.source.length);
    enc.encodeInto(
      data.source,
      new Uint8Array(exports.memory.buffer, ptr, data.source.length)
    );
    const error_ptr = exports.codeGen(data.flavor, data.mode);
    if (error_ptr) {
      const error_info = new Uint32Array(exports.memory.buffer, error_ptr, 4);
      const message = dec.decode(
        new Uint8Array(exports.memory.buffer, error_info[0], error_info[1])
      );
      self.postMessage({
        type: "codegen",
        source: data.source,
        message,
        start: error_info[2],
        end: error_info[3],
      });
    } else {
      self.postMessage({ type: "codegen" });
    }
  } else if (data.type === "execute") {
    const start = performance.now();
    const info_ptr = exports.execute();
    const info = new Uint32Array(exports.memory.buffer, info_ptr, 8);

    const output = dec.decode(
      new Uint8Array(exports.memory.buffer, info[0], info[1])
    );

    const results = [];
    for (let i = 0; i < info[3]; i++) {
      const mapping = new Uint32Array(
        exports.memory.buffer,
        info[2] + i * 3 * 4,
        3
      );
      results.push({
        label: output.slice(mapping[0], mapping[1]),
        index: mapping[2],
      });
    }

    const exception =
      info[4] !== -1
        ? {
            message: output.slice(info[4], info[5]),
            start: info[6],
            end: info[7],
          }
        : undefined;

    self.postMessage({
      type: "execute",
      output,
      results,
      exception,
      time: performance.now() - start,
    });
  } else {
    console.error("unknown request from main");
  }
});
