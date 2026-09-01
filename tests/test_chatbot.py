from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import datetime, timezone

import pytest
from pydantic_ai import models
from pydantic_ai.models.anthropic import AnthropicModel
from pydantic_ai.models.openai import OpenAIChatModel
from wechatbot import IncomingMessage

from app import (
    ERROR_REPLY,
    TIMEOUT_REPLY,
    Settings,
    build_agent,
    handle_message,
    load_settings,
    run_bot,
)

models.ALLOW_MODEL_REQUESTS = False


@dataclass
class FakeResult:
    output: str


class FakeAgent:
    def __init__(self, output: str = "模型回答") -> None:
        self.output = output
        self.calls: list[tuple[str, dict[str, object]]] = []

    async def run(self, user_prompt: str, **kwargs: object) -> FakeResult:
        self.calls.append((user_prompt, kwargs))
        return FakeResult(self.output)


class FailingAgent:
    async def run(self, user_prompt: str) -> FakeResult:
        raise RuntimeError("provider unavailable")


class BlockingAgent:
    async def run(self, user_prompt: str) -> FakeResult:
        await asyncio.Event().wait()
        raise AssertionError("unreachable")


class FakeBot:
    def __init__(self, *, typing_error: bool = False) -> None:
        self.typing_error = typing_error
        self.typing_calls: list[str] = []
        self.replies: list[tuple[IncomingMessage, str]] = []

    async def send_typing(self, user_id: str) -> None:
        self.typing_calls.append(user_id)
        if self.typing_error:
            raise RuntimeError("typing unavailable")

    async def reply(self, msg: IncomingMessage, text: str) -> None:
        self.replies.append((msg, text))


class FakeLifecycleBot:
    def __init__(self) -> None:
        self.login_calls: list[bool] = []
        self.start_calls = 0

    async def login(self, *, force: bool = False) -> None:
        self.login_calls.append(force)

    async def start(self) -> None:
        self.start_calls += 1

    def stop(self) -> None:
        pass


def make_message(text: str = "你好", message_type: str = "text") -> IncomingMessage:
    return IncomingMessage(
        user_id="user-1",
        text=text,
        type=message_type,
        timestamp=datetime.now(timezone.utc),
        _context_token="context-token",
    )


def make_settings(provider: str, base_url: str | None = None) -> Settings:
    return Settings(
        provider=provider,
        model="test-model",
        api_key="test-key",
        base_url=base_url,
        timeout_seconds=1,
        max_tokens=100,
    )


def test_load_settings_defaults_to_openai() -> None:
    settings = load_settings(
        {
            "AI_MODEL": "gpt-test",
            "AI_API_KEY": "secret",
        }
    )

    assert settings.provider == "openai"
    assert settings.base_url is None
    assert settings.timeout_seconds == 60
    assert settings.max_tokens == 800
    assert settings.wechat_cred_path is None


def test_load_settings_accepts_wechat_credential_path() -> None:
    settings = load_settings(
        {
            "AI_MODEL": "gpt-test",
            "AI_API_KEY": "secret",
            "WECHAT_CRED_PATH": "/data/credentials.json",
        }
    )

    assert settings.wechat_cred_path == "/data/credentials.json"


@pytest.mark.asyncio
async def test_login_only_saves_credentials_without_starting_poller() -> None:
    bot = FakeLifecycleBot()

    await run_bot(bot, login_only=True)  # type: ignore[arg-type]

    assert bot.login_calls == [False]
    assert bot.start_calls == 0


@pytest.mark.asyncio
async def test_force_login_is_forwarded_to_wechat_sdk() -> None:
    bot = FakeLifecycleBot()

    await run_bot(bot, login_only=True, force_login=True)  # type: ignore[arg-type]

    assert bot.login_calls == [True]


@pytest.mark.parametrize("name", ["AI_MODEL", "AI_API_KEY"])
def test_load_settings_requires_model_and_key(name: str) -> None:
    env = {"AI_MODEL": "model", "AI_API_KEY": "key"}
    del env[name]

    with pytest.raises(ValueError, match=name):
        load_settings(env)


def test_load_settings_rejects_unknown_provider() -> None:
    with pytest.raises(ValueError, match="AI_PROVIDER"):
        load_settings(
            {
                "AI_PROVIDER": "other",
                "AI_MODEL": "model",
                "AI_API_KEY": "key",
            }
        )


@pytest.mark.parametrize(
    ("name", "value"),
    [("AI_TIMEOUT_SECONDS", "0"), ("AI_MAX_TOKENS", "not-an-int")],
)
def test_load_settings_validates_numeric_values(name: str, value: str) -> None:
    with pytest.raises(ValueError, match=name):
        load_settings(
            {
                "AI_MODEL": "model",
                "AI_API_KEY": "key",
                name: value,
            }
        )


def test_builds_openai_chat_model_with_custom_base_url() -> None:
    agent = build_agent(make_settings("openai", "https://openai.example/v1"))

    assert isinstance(agent.model, OpenAIChatModel)
    assert str(agent.model.base_url).rstrip("/") == "https://openai.example/v1"


def test_builds_anthropic_model_with_custom_base_url() -> None:
    agent = build_agent(make_settings("anthropic", "https://anthropic.example"))

    assert isinstance(agent.model, AnthropicModel)
    assert str(agent.model.base_url).rstrip("/") == "https://anthropic.example"


@pytest.mark.asyncio
async def test_text_message_is_sent_to_agent_and_replied() -> None:
    msg = make_message("  你好  ")
    bot = FakeBot()
    agent = FakeAgent("  你好！  ")

    await handle_message(msg, bot, agent, timeout_seconds=1)

    assert agent.calls == [("你好", {})]
    assert bot.typing_calls == ["user-1"]
    assert bot.replies == [(msg, "你好！")]


@pytest.mark.asyncio
async def test_two_messages_do_not_pass_history() -> None:
    bot = FakeBot()
    agent = FakeAgent()

    await handle_message(make_message("第一条"), bot, agent, timeout_seconds=1)
    await handle_message(make_message("第二条"), bot, agent, timeout_seconds=1)

    assert agent.calls == [("第一条", {}), ("第二条", {})]


@pytest.mark.asyncio
async def test_non_text_message_is_ignored() -> None:
    msg = make_message("图片地址", "image")
    bot = FakeBot()
    agent = FakeAgent()

    await handle_message(msg, bot, agent, timeout_seconds=1)

    assert agent.calls == []
    assert bot.typing_calls == []
    assert bot.replies == []


@pytest.mark.asyncio
async def test_model_failure_returns_generic_error() -> None:
    msg = make_message()
    bot = FakeBot()

    await handle_message(msg, bot, FailingAgent(), timeout_seconds=1)

    assert bot.replies == [(msg, ERROR_REPLY)]


@pytest.mark.asyncio
async def test_model_timeout_returns_timeout_error() -> None:
    msg = make_message()
    bot = FakeBot()

    await handle_message(msg, bot, BlockingAgent(), timeout_seconds=0.01)

    assert bot.replies == [(msg, TIMEOUT_REPLY)]


@pytest.mark.asyncio
async def test_empty_model_output_returns_generic_error() -> None:
    msg = make_message()
    bot = FakeBot()

    await handle_message(msg, bot, FakeAgent("   "), timeout_seconds=1)

    assert bot.replies == [(msg, ERROR_REPLY)]


@pytest.mark.asyncio
async def test_typing_failure_does_not_block_reply() -> None:
    msg = make_message()
    bot = FakeBot(typing_error=True)

    await handle_message(msg, bot, FakeAgent("回答"), timeout_seconds=1)

    assert bot.replies == [(msg, "回答")]
