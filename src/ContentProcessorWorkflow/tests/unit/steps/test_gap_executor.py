# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Tests for GapExecutor prompt/rules loading."""

from __future__ import annotations

import asyncio
import inspect
import json
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

with patch.dict(
    sys.modules,
    {
        "repositories.claim_processes": MagicMock(Claim_Processes=object),
        "services.content_process_service": MagicMock(ContentProcessService=object),
    },
):
    with patch("agent_framework.handler", lambda fn: fn):
        from steps.gap_analysis.executor.gap_executor import GapExecutor

from steps.models.output import Executor_Output, Workflow_Output


def _report() -> dict:
    return {
        "status": "ok",
        "inputs": {},
        "documents": [],
        "gaps": [],
        "discrepancies": [],
        "observations": [],
        "narrative_report": "Found 0 Gaps, 2 Discrepancies.",
    }


class TestGapReportValidation:
    def test_accepts_complete_report(self):
        GapExecutor._validate_gap_report(json.dumps(_report()))

    @pytest.mark.parametrize(
        "text",
        [
            "",
            '{"narrative_report": "truncated',
            "```json\n{}\n```",
            "null",
            "[]",
        ],
    )
    def test_rejects_invalid_json_or_non_object(self, text):
        with pytest.raises(RuntimeError, match="Gap analysis"):
            GapExecutor._validate_gap_report(text)

    @pytest.mark.parametrize(
        "key,value",
        [
            ("status", "error"),
            ("inputs", []),
            ("documents", {}),
            ("gaps", [None]),
            ("discrepancies", None),
            ("observations", "none"),
            ("narrative_report", ""),
            ("narrative_report", "   "),
            ("narrative_report", None),
        ],
    )
    def test_rejects_invalid_report_fields(self, key, value):
        report = _report()
        report[key] = value
        with pytest.raises(RuntimeError, match="Gap analysis"):
            GapExecutor._validate_gap_report(json.dumps(report))

    @pytest.mark.parametrize("valid_response", [True, False])
    def test_only_persists_valid_reports(self, valid_response):
        with patch.object(GapExecutor, "__init__", lambda self, *a, **kw: None):
            exe = GapExecutor.__new__(GapExecutor)
        text = json.dumps(_report()) if valid_response else '{"narrative_report":"'
        agent = MagicMock()
        agent.run = AsyncMock(return_value=MagicMock(text=text))
        repository = MagicMock()
        repository.Update_Claim_Process_Gaps = AsyncMock(return_value=MagicMock())
        helper = MagicMock()
        helper.get_client_async = AsyncMock(return_value=MagicMock())
        exe.app_context = MagicMock()
        exe.app_context.get_service.side_effect = [helper, repository]
        exe.fetch_processed_result = AsyncMock(return_value={"result": {}})
        exe._load_prompt_and_rules = MagicMock(return_value="JSON instructions")
        ctx = MagicMock()
        ctx.yield_output = AsyncMock()
        result = Workflow_Output(
            claim_process_id="claim-id",
            schemaset_id="set-id",
            workflow_process_outputs=[
                Executor_Output(
                    step_name="document_processing",
                    output_data={
                        "document_results": [
                            {
                                "status": 302,
                                "process_id": "document-id",
                                "file_name": "claim.pdf",
                                "mime_type": "application/pdf",
                            }
                        ]
                    },
                )
            ],
        )
        builder = MagicMock()
        with patch.dict(
            inspect.unwrap(exe.handle_execute).__globals__, {"AgentBuilder": builder}
        ):
            chain = builder.return_value
            for method in (
                "with_name",
                "with_instructions",
                "with_temperature",
                "with_top_p",
                "with_max_tokens",
                "with_additional_chat_options",
            ):
                getattr(chain, method).return_value = chain
            chain.build.return_value = agent
            if valid_response:
                asyncio.run(exe.handle_execute(result, ctx))
                repository.Update_Claim_Process_Gaps.assert_awaited_once_with(
                    process_id="claim-id", new_gaps=text
                )
                ctx.yield_output.assert_awaited_once_with(result)
            else:
                with pytest.raises(RuntimeError, match="invalid or truncated"):
                    asyncio.run(exe.handle_execute(result, ctx))
                repository.Update_Claim_Process_Gaps.assert_not_awaited()
                ctx.yield_output.assert_not_awaited()
            chain.with_max_tokens.assert_called_once_with(16384)
            chain.with_additional_chat_options.assert_called_once_with(
                {"response_format": {"type": "json_object"}}
            )


class TestReadTextFile:
    def _make_executor(self):
        """Create a GapExecutor without a real app context."""
        with patch.object(GapExecutor, "__init__", lambda self, *a, **kw: None):
            exe = GapExecutor.__new__(GapExecutor)
        exe._PROMPT_FILE_NAME = "gap_executor_prompt.txt"
        exe._RULES_FILE_NAME = "fnol_gap_rules.dsl.yaml"
        return exe

    def test_reads_text_file(self, tmp_path):
        f = tmp_path / "test.txt"
        f.write_text("hello world", encoding="utf-8")
        exe = self._make_executor()
        assert exe._read_text_file(f) == "hello world"

    def test_raises_on_empty_file(self, tmp_path):
        f = tmp_path / "empty.txt"
        f.write_text("   \n  ", encoding="utf-8")
        exe = self._make_executor()
        with pytest.raises(RuntimeError, match="empty"):
            exe._read_text_file(f)


class TestLoadPromptAndRules:
    def _make_executor(self):
        with patch.object(GapExecutor, "__init__", lambda self, *a, **kw: None):
            exe = GapExecutor.__new__(GapExecutor)
        exe._PROMPT_FILE_NAME = "gap_executor_prompt.txt"
        exe._RULES_FILE_NAME = "fnol_gap_rules.dsl.yaml"
        return exe

    def test_loads_real_prompt_and_rules(self):
        """The actual prompt and rules files should exist and load correctly."""
        exe = self._make_executor()
        prompt = exe._load_prompt_and_rules()
        assert len(prompt) > 0
        assert isinstance(prompt, str)
        # The rules should have been injected (no placeholder remaining)
        assert "{{RULES_DSL}}" not in prompt

    def test_raises_on_invalid_yaml_rules(self):
        """If the YAML rules file is invalid, should raise RuntimeError."""
        exe = self._make_executor()

        call_count = [0]

        def fake_read(path):
            call_count[0] += 1
            if call_count[0] == 1:
                return "Prompt: {{RULES_DSL}}"
            else:
                return "invalid: yaml: [broken"

        exe._read_text_file = fake_read

        with pytest.raises(RuntimeError, match="Invalid YAML"):
            exe._load_prompt_and_rules()
