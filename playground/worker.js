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

    const error_ptr = exports.codeGen(data.mode === "1");
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
    const info = new Uint32Array(exports.memory.buffer, info_ptr, 5);
    if (info[0]) {
      const exception = dec.decode(
        new Uint8Array(exports.memory.buffer, info[1], info[2])
      );
      self.postMessage({
        type: "execute",
        exception,
        time: performance.now() - start,
        start: info[3],
        end: info[4],
      });
    } else {
      const stdout = dec.decode(
        new Uint8Array(exports.memory.buffer, info[1], info[2])
      );
      self.postMessage({
        type: "execute",
        stdout,
        time: performance.now() - start,
      });
    }
  } else {
    console.error("unknown request from main");
  }
});
