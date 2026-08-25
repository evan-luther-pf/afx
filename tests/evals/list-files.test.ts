import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
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

describe("eval: list files", () => {
  test(
    "lists files in the project root",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "List all files in this project directory. Reply with just the filenames, one per line.",
        {
          cwd: workDir,
          timeoutSec: 60,
          setup: async (dir) => {
            mkdirSync(join(dir, "src"), { recursive: true });
            writeFileSync(join(dir, "README.md"), "# Hello\n");
            writeFileSync(join(dir, "index.ts"), "export {};\n");
            writeFileSync(join(dir, "src", "app.ts"), "console.log('app');\n");
          },
        },
      );
      const output = result.json.output.toLowerCase();
      expect(output).toContain("readme");
      expect(output).toContain("index");
      expect(result.json.exit_code).toBe(0);
      assertToolUsed(result, "list_files");
    },
    TIMEOUT,
  );
});
