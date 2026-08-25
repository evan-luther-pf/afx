import { afterEach, describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import {
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

describe("eval: delete file", () => {
  test(
    "deletes a seeded file when asked",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "Delete the file called remove-me.txt",
        {
          cwd: workDir,
          timeoutSec: 60,
          setup: async (dir) => {
            writeFileSync(join(dir, "remove-me.txt"), "this should be deleted");
          },
        },
      );
      assertNoFile(workDir, "remove-me.txt");
      assertToolUsed(result, "delete_file");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
