from __future__ import annotations

import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from scripts.pgso.corpus import (
    Corpus,
    CorpusRunError,
    Scenario,
    load_corpus,
    run_behavior_corpus,
    run_corpus,
)
from scripts.pgso.model import PgsoError
from scripts.pgso.runner import CommandResult


TRAINING_E2E_TESTS = (
    "cli.test.ts",
    "ask-presentation.test.ts",
    "config-persistence.test.ts",
    "prompt-history.test.ts",
    "auth-refresh.test.ts",
    "file-tool-paths.test.ts",
    "file-tool-permissions.test.ts",
    "gateway-stream-lifecycle.test.ts",
    "web-fetch-fake-network.test.ts",
    "web-search-fake-gateway.test.ts",
    "vision-route-fake-gateway.test.ts",
    "acp.test.ts",
    "mcp-http.test.ts",
    "mcp-legacy-remote.test.ts",
    "mcp-stdio.test.ts",
    "mcp-auth.test.ts",
    "session-recovery.test.ts",
    "terminal-host.test.ts",
    "tui-startup.test.ts",
    "permission-errors.test.ts",
    "tui-resize.test.ts",
    "tui-render-stress.test.ts",
    "tui-full-transcript-brutal.test.ts",
    "tui-resume-brutal.test.ts",
    "tui-permissions.test.ts",
    "tui-interrupt-recovery.test.ts",
    "tui-subagent-manager.test.ts",
    "tui-terminal-tool.test.ts",
    "tui-native-clear-recovery.test.ts",
    "tui-gateway-stream-lifecycle.test.ts",
)

VERIFICATION_E2E_TESTS = (
    "auto-mode-reliability.test.ts",
    "oauth-keychain-migration.test.ts",
    "tui-auth-source-selection.test.ts",
    "tui-composer-edit-contracts.test.ts",
    "tui-cost.test.ts",
    "tui-decision-prompts.test.ts",
    "tui-file-picker.test.ts",
    "tui-input-line-delete.test.ts",
    "tui-input-navigation.test.ts",
    "tui-render-replay.test.ts",
    "tui-resume.test.ts",
    "tui-slash-commands.test.ts",
    "tui-slash-extra.test.ts",
    "tui-slash-menu.test.ts",
    "web-fetch-permission-progress.test.ts",
    "web-search-permission-progress.test.ts",
    "yolo-permission-mode.test.ts",
    "bridge.test.ts",
    "bridge-slack.test.ts",
    "bridge-telegram.test.ts",
    "bridge-imsg.test.ts",
)

EXCLUDED_E2E_TESTS = (
    "ci-shards.test.ts",
    "context-limits-live.test.ts",
    "notifications.test.ts",
    "tmux-helpers.test.ts",
    "tui-agent.test.ts",
    "tui-command-permissions.test.ts",
    "tui-direct-write-audit.test.ts",
    "tui-keybindings.test.ts",
    "tui-render-lab.test.ts",
    "tui-render-live-stress.test.ts",
    "web-fetch-live.test.ts",
    "web-search-live.test.ts",
)


class PgsoCorpusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="afx-pgso-corpus-"
        )
        self.root = pathlib.Path(self.temporary_directory.name)
        (self.root / "tests" / "e2e").mkdir(parents=True)
        for test_file in (
            "notifications.test.ts",
            "tui-agent.test.ts",
            "tui-command-permissions.test.ts",
        ):
            (self.root / "tests" / "e2e" / test_file).write_text("test")
        self.manifest_path = self.root / "corpus.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def direct_scenarios(self) -> list[dict[str, object]]:
        commands = (
            ("direct-help", ("help",)),
            ("direct-version", ("--version",)),
            ("direct-status", ("status", "--json")),
            ("direct-background", ("background", "--json")),
            ("direct-doctor", ("doctor", "--json")),
            ("direct-sessions", ("sessions", "--json")),
        )
        return [
            {
                "name": name,
                "argv": ["{binary}", *arguments],
                "cwd": ".",
                "env_set": {"FX_SOUND": "0"},
                "env_unset": [],
                "timeout_seconds": 30,
                "requires_tmux": False,
            }
            for name, arguments in commands
        ]

    def manifest(self) -> dict[str, object]:
        return {
            "version": 1,
            "intentional_exclusions": {
                "notifications.test.ts": "sound-related",
                "tui-agent.test.ts": "requires a real model credential",
                "tui-command-permissions.test.ts": "contains a sound scenario",
            },
            "scenarios": self.direct_scenarios(),
            "verification_scenarios": [],
        }

    def write_manifest(self, payload: dict[str, object]) -> pathlib.Path:
        self.manifest_path.write_text(json.dumps(payload))
        return self.manifest_path

    def e2e_scenario(self, test_file: str) -> dict[str, object]:
        return {
            "name": f"e2e-{test_file.removesuffix('.test.ts')}",
            "argv": ["bun", "test", "--max-concurrency", "1", f"./{test_file}"],
            "cwd": "tests/e2e",
            "env_set": {"FX_SOUND": "0"},
            "env_unset": ["AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN"],
            "timeout_seconds": 60,
            "requires_tmux": True,
            "test_file": test_file,
        }

    def test_load_rejects_duplicate_names(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.append(dict(scenarios[0]))

        with self.assertRaisesRegex(PgsoError, "duplicate scenario name"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_separates_training_and_verification_scenarios(self) -> None:
        test_file = "new-feature.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        verification = payload["verification_scenarios"]
        assert isinstance(verification, list)
        verification.append(self.e2e_scenario(test_file))

        corpus = load_corpus(self.write_manifest(payload), repo_root=self.root)

        self.assertEqual(6, len(corpus.scenarios))
        self.assertEqual(
            ("e2e-new-feature",),
            tuple(scenario.name for scenario in corpus.verification_scenarios),
        )
        self.assertEqual(7, len(corpus.candidate_scenarios))

    def test_load_rejects_duplicate_test_files_across_phases(self) -> None:
        test_file = "shared.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        verification = payload["verification_scenarios"]
        assert isinstance(scenarios, list)
        assert isinstance(verification, list)
        scenarios.append(self.e2e_scenario(test_file))
        duplicate = self.e2e_scenario(test_file)
        duplicate["name"] = "e2e-shared-verification"
        verification.append(duplicate)

        with self.assertRaisesRegex(PgsoError, "duplicate corpus test file"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_unclassified_e2e_files(self) -> None:
        test_file = "forgotten-feature.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")

        with self.assertRaisesRegex(
            PgsoError,
            "unclassified E2E test file: forgotten-feature.test.ts",
        ):
            load_corpus(self.write_manifest(self.manifest()), repo_root=self.root)

    def test_load_rejects_stale_exclusions(self) -> None:
        payload = self.manifest()
        exclusions = payload["intentional_exclusions"]
        assert isinstance(exclusions, dict)
        exclusions["removed.test.ts"] = "removed from the suite"

        with self.assertRaisesRegex(
            PgsoError,
            "excluded E2E test file does not exist: removed.test.ts",
        ):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_multiple_classifications(self) -> None:
        test_file = "classified-twice.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        exclusions = payload["intentional_exclusions"]
        assert isinstance(scenarios, list)
        assert isinstance(exclusions, dict)
        scenarios.append(self.e2e_scenario(test_file))
        exclusions[test_file] = "also excluded"

        with self.assertRaisesRegex(PgsoError, "multiple corpus classifications"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_path_traversal(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios[0]["cwd"] = "../outside"

        with self.assertRaisesRegex(PgsoError, "cwd escapes repository"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_a_missing_test_file(self) -> None:
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenarios.append(self.e2e_scenario("missing.test.ts"))

        with self.assertRaisesRegex(PgsoError, "test file does not exist"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_binds_each_test_file_to_its_exact_bun_command(self) -> None:
        test_file = "cli.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
        assert isinstance(scenarios, list)
        scenario = self.e2e_scenario(test_file)
        scenario["argv"] = ["bun", "test", "./different.test.ts"]
        scenarios.append(scenario)

        with self.assertRaisesRegex(PgsoError, "test command mismatch"):
            load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_an_empty_command_or_nonpositive_timeout(self) -> None:
        cases = (("argv", []), ("timeout_seconds", 0))
        for field, value in cases:
            with self.subTest(field=field):
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios[0][field] = value
                with self.assertRaises(PgsoError):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_invalid_profile_runs(self) -> None:
        for value in (True, 0, 101, 1.5):
            with self.subTest(value=value):
                payload = self.manifest()
                scenarios = payload["scenarios"]
                assert isinstance(scenarios, list)
                scenarios[-1]["profile_runs"] = value
                with self.assertRaisesRegex(PgsoError, "profile_runs"):
                    load_corpus(self.write_manifest(payload), repo_root=self.root)

    def test_load_rejects_profile_runs_for_e2e_scenarios(self) -> None:
        test_file = "profile-repeat.test.ts"
        (self.root / "tests" / "e2e" / test_file).write_text("test")
        payload = self.manifest()
        scenarios = payload["scenarios"]
⚠ 1 unresolved conflict detected
- ours = HEAD
- theirs = 3f52b90 (Add iMessage bridge connector and typedstream extractor)
NOTICE: Inspect a block by reading `conflict://<N>` (add `/ours` / `/theirs` / `/base` to render a single side). Resolve with `write({ path: "conflict://<N>", content })`, or bulk-resolve every registered conflict with `write({ path: "conflict://*", content })`. Writes replace ONLY the marker block (markers + all sides) — never repeat the lines before/after it; they stay in place.
`content` shorthand: a line that is exactly `@ours` / `@theirs` / `@base` / `@both` expands to that recorded section. `@both` is ours-then-theirs with no separator — only for additive conflicts where each side adds something different; NEVER for competing edits of the same lines (pick a side or write the combined text). Lines that are not a token pass through verbatim, so `"// keep both\n@ours\n@theirs"` literally writes the comment, then ours, then theirs.
Per-id bulk: `write({ path: "conflict://*", content: "1: @ours\n2: @theirs\n…" })` resolves each listed id with that side in ONE call — the cheapest way through many pick-one conflicts; unlisted ids stay registered.
Resolve each block faithfully: keep one side (`@ours`/`@theirs`), or combine them when both intents apply — never invent content beyond the recorded sides, and never stack both sides of competing edits. Resolve several conflicts in a single turn by issuing multiple `write` calls at once; ids stay valid as earlier blocks are resolved.

──── #4  L75-79 ────
<<< ours
    "bridge-telegram.test.ts",
>>> theirs
    "bridge-imsg.test.ts",

[Showing lines 1-300 of 884. Use :301 to continue]