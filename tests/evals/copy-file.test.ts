import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertFileExists,
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

describe("eval: copy file", () => {
  test(
    "copies source.txt to backup.txt preserving content",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "Copy the file source.txt to backup.txt",
        {
          cwd: workDir,
          timeoutSec: 60,
          setup: async (dir) => {
            writeFileSync(join(dir, "source.txt"), "important data");
          },
        },
      );
      assertFileExists(workDir, "source.txt");
      assertFileExists(workDir, "backup.txt");
      const content = readFileSync(join(workDir, "backup.txt"), "utf-8");
      expect(content).toContain("important data");
      assertToolUsed(result, "copy_file");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
