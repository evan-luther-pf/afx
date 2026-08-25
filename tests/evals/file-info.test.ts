import { afterEach, describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertToolUsed,
  cleanupWorkDir,
  createWorkDir,
  runEval,
} from "./eval-helpers";

const TIMEOUT = 120_000;
let workDir: string | null = null;

afterEach(() => {
  if (workDir) { cleanupWorkDir(workDir); workDir = null; }
});

describe("eval: file info", () => {
  test(
    "reports file size for a known file",
    async () => {
      workDir = createWorkDir();
      const content = "A".repeat(1024);
      const result = await runEval(
        "What is the size of data.txt in bytes? Reply with just the number.",
        {
          cwd: workDir,
          timeoutSec: 60,
          setup: async (dir) => {
            writeFileSync(join(dir, "data.txt"), content);
          },
        },
      );
      const output = result.json.output;
      expect(output).toContain("1024");
      expect(result.json.exit_code).toBe(0);
      assertToolUsed(result, "file_info");
    },
    TIMEOUT,
  );
});
