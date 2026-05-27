import { build } from "esbuild";
import { rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { run } from "node:test";
import { spec } from "node:test/reporters";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const outdir = join(root, ".tmp-tests");
const outfile = join(outdir, "adapterContracts.test.mjs");

rmSync(outdir, { recursive: true, force: true });

await build({
  entryPoints: [join(root, "tests", "adapterContracts.test.ts")],
  outfile,
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  sourcemap: "inline",
  logLevel: "silent",
  external: ["node:*"],
});

const stream = run({ files: [outfile] }).compose(spec);
stream.pipe(process.stdout);

let failed = false;
for await (const event of stream) {
  if (event?.type === "test:fail") failed = true;
}

rmSync(outdir, { recursive: true, force: true });
if (failed) process.exitCode = 1;
