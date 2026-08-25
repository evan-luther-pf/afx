import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, statSync } from "node:fs";
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

describe("eval: create folder", () => {
  test(
    "creates a nested directory structure",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "Create the following directory structure: src/components/ui/",
        {
          cwd: workDir,
          timeoutSec: 60,
        },
      );
      const dirPath = join(workDir, "src", "components", "ui");
      expect(existsSync(dirPath)).toBe(true);
      expect(statSync(dirPath).isDirectory()).toBe(true);
      expect(result.json.exit_code).toBe(0);
      assertToolUsed(result, "create_folder");
    },
    TIMEOUT,
  );
});
