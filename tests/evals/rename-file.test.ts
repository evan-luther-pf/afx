import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertFileExists,
  assertNoFile,
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

describe("eval: rename file", () => {
  test(
    "renames old.txt to new.txt",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "Rename the file old.txt to new.txt",
        {
          cwd: workDir,
          timeoutSec: 60,
          setup: async (dir) => {
            writeFileSync(join(dir, "old.txt"), "original content");
          },
        },
      );
      assertFileExists(workDir, "new.txt");
      assertNoFile(workDir, "old.txt");
      const content = readFileSync(join(workDir, "new.txt"), "utf-8");
      expect(content).toContain("original content");
      assertToolUsed(result, "rename_file");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
