#!/usr/bin/env python3
"""
nanogents Interactive Setup Wizard
===================================
A beginner-friendly, step-by-step configuration wizard.
Generates ~/.nanobot/config.json with all your settings.
"""

import json
import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

# ── Styling helpers (no external deps) ──────────────────────────────────────

CYAN = "\033[0;36m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
BLUE = "\033[0;34m"
MAGENTA = "\033[0;35m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"


def banner(text: str):
    width = 56
    print()
    print(f"{CYAN}{'━' * width}{NC}")
    print(f"{CYAN}  {BOLD}{text}{NC}")
    print(f"{CYAN}{'━' * width}{NC}")
    print()


def section(num: int, title: str, subtitle: str = ""):
    print()
    print(f"  {BLUE}{BOLD}Step {num}{NC}  {BOLD}{title}{NC}")
    if subtitle:
        print(f"         {DIM}{subtitle}{NC}")
    print(f"  {BLUE}{'─' * 48}{NC}")
    print()


def ok(msg: str):
    print(f"  {GREEN}✔{NC} {msg}")


def warn(msg: str):
    print(f"  {YELLOW}⚠{NC} {msg}")


def info(msg: str):
    print(f"  {CYAN}→{NC} {msg}")


def error(msg: str):
    print(f"  {RED}✘{NC} {msg}")


def ask(prompt: str, default: str = "", secret: bool = False, required: bool = False) -> str:
    """Ask the user for input with optional default."""
    suffix = ""
    if default:
        if secret:
            masked = default[:8] + "..." if len(default) > 10 else "***"
            suffix = f" {DIM}[{masked}]{NC}"
        else:
            suffix = f" {DIM}[{default}]{NC}"

    while True:
        try:
            if secret:
                import getpass
                val = getpass.getpass(f"  {CYAN}?{NC} {prompt}{suffix}: ")
            else:
                val = input(f"  {CYAN}?{NC} {prompt}{suffix}: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)

        if not val and default:
            return default
        if not val and required:
            error("This field is required.")
            continue
        return val


def ask_yes_no(prompt: str, default: bool = True) -> bool:
    """Yes/No question."""
    hint = "Y/n" if default else "y/N"
    try:
        val = input(f"  {CYAN}?{NC} {prompt} [{hint}]: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)
    if not val:
        return default
    return val in ("y", "yes")


def ask_choice(prompt: str, options: list[dict], default: int = 0) -> dict:
    """
    Show numbered options and let user pick.
    Each option: {"label": "...", "value": "...", "desc": "..."}
    """
    print(f"  {CYAN}?{NC} {prompt}")
    print()
    for i, opt in enumerate(options):
        marker = f"{GREEN}●{NC}" if i == default else f"{DIM}○{NC}"
        label = f"{BOLD}{opt['label']}{NC}" if i == default else opt["label"]
        desc = f"  {DIM}{opt.get('desc', '')}{NC}" if opt.get("desc") else ""
        print(f"    {marker} {i + 1}) {label}{desc}")
    print()

    while True:
        try:
            val = input(f"    Enter number [{default + 1}]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)
        if not val:
            return options[default]
        try:
            idx = int(val) - 1
            if 0 <= idx < len(options):
                return options[idx]
        except ValueError:
            pass
        error(f"Pick a number between 1 and {len(options)}")


def ask_multi_choice(prompt: str, options: list[dict]) -> list[dict]:
    """Let user pick multiple items by entering comma-separated numbers."""
    print(f"  {CYAN}?{NC} {prompt}")
    print(f"    {DIM}(enter comma-separated numbers, or 'none' to skip){NC}")
    print()
    for i, opt in enumerate(options):
        desc = f"  {DIM}{opt.get('desc', '')}{NC}" if opt.get("desc") else ""
        print(f"    {DIM}○{NC} {i + 1}) {opt['label']}{desc}")
    print()

    while True:
        try:
            val = input(f"    Your choices: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            sys.exit(0)
        if not val or val == "none":
            return []
        try:
            indices = [int(x.strip()) - 1 for x in val.split(",")]
            selected = []
            for idx in indices:
                if 0 <= idx < len(options):
                    selected.append(options[idx])
                else:
                    raise ValueError
            return selected
        except ValueError:
            error(f"Enter numbers between 1 and {len(options)}, separated by commas")


# ── Provider definitions ────────────────────────────────────────────────────
# Full list from README. Grouped: gateways first, then direct, then local/OAuth.

PROVIDERS = [
    # ── Gateways (access to all models) ──
    {
        "label": "OpenRouter",
        "value": "openrouter",
        "desc": "Recommended — access to all models (Claude, GPT, Gemini, etc.)",
        "key_hint": "Get key at: https://openrouter.ai/keys",
        "key_prefix": "sk-or-",
        "models": [
            {"label": "Claude Opus 4.5", "value": "anthropic/claude-opus-4-5", "desc": "Most capable"},
            {"label": "Claude Sonnet 4.5", "value": "anthropic/claude-sonnet-4-5", "desc": "Fast + smart"},
            {"label": "GPT-4o", "value": "openai/gpt-4o", "desc": "OpenAI flagship"},
            {"label": "DeepSeek V3", "value": "deepseek/deepseek-chat", "desc": "Budget-friendly"},
            {"label": "Gemini 2.5 Pro", "value": "google/gemini-2.5-pro-preview", "desc": "Google latest"},
        ],
    },
    {
        "label": "AiHubMix",
        "value": "aihubmix",
        "desc": "API gateway — access to all models",
        "key_hint": "Get key at: https://aihubmix.com",
        "key_prefix": "",
        "models": [
            {"label": "Claude Opus 4.5", "value": "anthropic/claude-opus-4-5", "desc": "Most capable"},
            {"label": "GPT-4o", "value": "openai/gpt-4o", "desc": "OpenAI flagship"},
        ],
    },
    # ── Direct providers ──
    {
        "label": "Anthropic",
        "value": "anthropic",
        "desc": "Claude models directly",
        "key_hint": "Get key at: https://console.anthropic.com/settings/keys",
        "key_prefix": "sk-ant-",
        "models": [
            {"label": "Claude Opus 4.5", "value": "claude-opus-4-5", "desc": "Most capable"},
            {"label": "Claude Sonnet 4.5", "value": "claude-sonnet-4-5", "desc": "Fast + smart"},
        ],
    },
    {
        "label": "OpenAI",
        "value": "openai",
        "desc": "GPT models directly",
        "key_hint": "Get key at: https://platform.openai.com/api-keys",
        "key_prefix": "sk-",
        "models": [
            {"label": "GPT-4o", "value": "gpt-4o", "desc": "Flagship"},
            {"label": "GPT-4o Mini", "value": "gpt-4o-mini", "desc": "Fast + cheap"},
        ],
    },
    {
        "label": "DeepSeek",
        "value": "deepseek",
        "desc": "Budget-friendly, great for coding",
        "key_hint": "Get key at: https://platform.deepseek.com/api_keys",
        "key_prefix": "sk-",
        "models": [
            {"label": "DeepSeek V3", "value": "deepseek-chat", "desc": "Latest"},
            {"label": "DeepSeek R1", "value": "deepseek-reasoner", "desc": "Reasoning"},
        ],
    },
    {
        "label": "Gemini",
        "value": "gemini",
        "desc": "Google Gemini models",
        "key_hint": "Get key at: https://aistudio.google.com/apikey",
        "key_prefix": "",
        "models": [
            {"label": "Gemini 2.5 Pro", "value": "gemini-2.5-pro-preview-06-05", "desc": "Latest"},
            {"label": "Gemini 2.0 Flash", "value": "gemini-2.0-flash", "desc": "Fast"},
        ],
    },
    {
        "label": "Groq",
        "value": "groq",
        "desc": "Ultra-fast inference + free Whisper voice transcription",
        "key_hint": "Get key at: https://console.groq.com/keys",
        "key_prefix": "gsk_",
        "models": [
            {"label": "Llama 3.3 70B", "value": "llama-3.3-70b-versatile", "desc": "Best on Groq"},
        ],
    },
    {
        "label": "MiniMax",
        "value": "minimax",
        "desc": "MiniMax models directly",
        "key_hint": "Get key at: https://platform.minimaxi.com",
        "key_prefix": "",
        "needs_api_base": True,
        "api_base_hint": "Mainland China? Use: https://api.minimaxi.com/v1",
        "models": [
            {"label": "MiniMax default", "value": "minimax", "desc": "Default model"},
        ],
    },
    {
        "label": "SiliconFlow",
        "value": "siliconflow",
        "desc": "SiliconFlow (硅基流动)",
        "key_hint": "Get key at: https://siliconflow.cn",
        "key_prefix": "",
        "models": [
            {"label": "DeepSeek V3", "value": "deepseek-chat", "desc": "Via SiliconFlow"},
        ],
    },
    {
        "label": "VolcEngine",
        "value": "volcengine",
        "desc": "VolcEngine (火山引擎)",
        "key_hint": "Get key at: https://www.volcengine.com",
        "key_prefix": "",
        "needs_api_base": True,
        "api_base_hint": "Coding plan? Use: https://ark.cn-beijing.volces.com/api/coding/v3",
        "models": [
            {"label": "VolcEngine default", "value": "volcengine", "desc": "Default model"},
        ],
    },
    {
        "label": "DashScope (Qwen)",
        "value": "dashscope",
        "desc": "Alibaba Qwen models",
        "key_hint": "Get key at: https://dashscope.console.aliyun.com",
        "key_prefix": "",
        "models": [
            {"label": "Qwen Max", "value": "qwen-max", "desc": "Most capable"},
            {"label": "Qwen Plus", "value": "qwen-plus", "desc": "Balanced"},
        ],
    },
    {
        "label": "Moonshot (Kimi)",
        "value": "moonshot",
        "desc": "Moonshot/Kimi models",
        "key_hint": "Get key at: https://platform.moonshot.cn",
        "key_prefix": "",
        "models": [
            {"label": "Kimi default", "value": "moonshot-v1-8k", "desc": "Default"},
        ],
    },
    {
        "label": "Zhipu (GLM)",
        "value": "zhipu",
        "desc": "Zhipu GLM models",
        "key_hint": "Get key at: https://open.bigmodel.cn",
        "key_prefix": "",
        "needs_api_base": True,
        "api_base_hint": "Coding plan? Use: https://open.bigmodel.cn/api/coding/paas/v4",
        "models": [
            {"label": "GLM-4", "value": "glm-4", "desc": "Latest"},
        ],
    },
    # ── Local ──
    {
        "label": "vLLM / Local",
        "value": "vllm",
        "desc": "Local LLM server (any OpenAI-compatible endpoint)",
        "key_hint": "No key needed for local. Start your server first, e.g.:\n"
                    "           vllm serve meta-llama/Llama-3.1-8B-Instruct --port 8000",
        "key_prefix": "",
        "needs_api_base": True,
        "api_base_default": "http://localhost:8000/v1",
        "api_base_hint": "URL of your local OpenAI-compatible server",
        "allow_dummy_key": True,
        "models": [
            {"label": "Enter model name manually", "value": "__custom__", "desc": "Type your model ID"},
        ],
    },
    # ── Custom endpoint ──
    {
        "label": "Custom (OpenAI-compatible)",
        "value": "custom",
        "desc": "Any OpenAI-compatible API (LM Studio, Together AI, Fireworks, Azure, etc.)",
        "key_hint": "Enter your API key for the custom endpoint",
        "key_prefix": "",
        "needs_api_base": True,
        "api_base_hint": "Full URL, e.g. https://api.your-provider.com/v1",
        "allow_dummy_key": True,
        "models": [
            {"label": "Enter model name manually", "value": "__custom__", "desc": "Type your model ID"},
        ],
    },
    # ── OAuth providers ──
    {
        "label": "OpenAI Codex (OAuth)",
        "value": "openai_codex",
        "desc": "Codex — requires ChatGPT Plus/Pro account",
        "key_hint": "Login with: nanobot provider login openai-codex",
        "key_prefix": "",
        "is_oauth": True,
        "models": [
            {"label": "GPT-5.1 Codex", "value": "openai-codex/gpt-5.1-codex", "desc": "Codex model"},
        ],
    },
    {
        "label": "GitHub Copilot (OAuth)",
        "value": "github_copilot",
        "desc": "GitHub Copilot — requires Copilot subscription",
        "key_hint": "Login with: nanobot provider login github-copilot",
        "key_prefix": "",
        "is_oauth": True,
        "models": [
            {"label": "Copilot default", "value": "github_copilot", "desc": "Copilot model"},
        ],
    },
]

# ── Channel definitions ─────────────────────────────────────────────────────

CHANNELS = [
    {
        "label": "Telegram",
        "value": "telegram",
        "desc": "Most popular, easiest to set up",
        "fields": [
            {
                "key": "token",
                "prompt": "Bot token",
                "hint": "Create a bot: open Telegram → search @BotFather → /newbot → copy token",
                "required": True,
                "secret": True,
            },
            {
                "key": "allowFrom",
                "prompt": "Your Telegram user ID (for security)",
                "hint": "Find it: Telegram Settings → copy your username without @",
                "required": False,
                "is_list": True,
            },
        ],
    },
    {
        "label": "Discord",
        "value": "discord",
        "desc": "For Discord servers",
        "fields": [
            {
                "key": "token",
                "prompt": "Bot token",
                "hint": "Create at: https://discord.com/developers/applications → Bot → Copy token\n           Also enable MESSAGE CONTENT INTENT in Bot settings",
                "required": True,
                "secret": True,
            },
            {
                "key": "allowFrom",
                "prompt": "Your Discord user ID (for security)",
                "hint": "Enable Developer Mode → right-click your avatar → Copy User ID",
                "required": False,
                "is_list": True,
            },
        ],
    },
    {
        "label": "Slack",
        "value": "slack",
        "desc": "For Slack workspaces (Socket Mode)",
        "fields": [
            {
                "key": "botToken",
                "prompt": "Bot token (xoxb-...)",
                "hint": "Create app at: https://api.slack.com/apps → OAuth → Bot Token\n           Required scopes: chat:write, reactions:write, app_mentions:read",
                "required": True,
                "secret": True,
            },
            {
                "key": "appToken",
                "prompt": "App-level token (xapp-...)",
                "hint": "Socket Mode → ON → Generate App-Level Token with connections:write",
                "required": True,
                "secret": True,
            },
        ],
    },
    {
        "label": "WhatsApp",
        "value": "whatsapp",
        "desc": "Via QR code scan (requires Node.js)",
        "fields": [
            {
                "key": "allowFrom",
                "prompt": "Your phone number (e.g. +1234567890)",
                "hint": "Only messages from this number will be processed",
                "required": False,
                "is_list": True,
            },
        ],
    },
    {
        "label": "Feishu",
        "value": "feishu",
        "desc": "Lark/Feishu (WebSocket, no public IP needed)",
        "fields": [
            {
                "key": "appId",
                "prompt": "App ID (cli_xxx)",
                "hint": "Create at: https://open.feishu.cn/app → Credentials",
                "required": True,
            },
            {
                "key": "appSecret",
                "prompt": "App Secret",
                "hint": "Same page as App ID",
                "required": True,
                "secret": True,
            },
        ],
    },
    {
        "label": "DingTalk",
        "value": "dingtalk",
        "desc": "DingDing (Stream Mode, no public IP needed)",
        "fields": [
            {
                "key": "clientId",
                "prompt": "App Key (Client ID)",
                "hint": "Create at: https://open-dev.dingtalk.com/ → Credentials",
                "required": True,
            },
            {
                "key": "clientSecret",
                "prompt": "App Secret (Client Secret)",
                "required": True,
                "secret": True,
            },
        ],
    },
    {
        "label": "Email",
        "value": "email",
        "desc": "IMAP/SMTP email assistant",
        "fields": [
            {
                "key": "imapHost",
                "prompt": "IMAP host",
                "hint": "Gmail: imap.gmail.com | Outlook: outlook.office365.com",
                "required": True,
                "default": "imap.gmail.com",
            },
            {
                "key": "imapUsername",
                "prompt": "Email address",
                "required": True,
            },
            {
                "key": "imapPassword",
                "prompt": "App password",
                "hint": "Gmail: https://myaccount.google.com/apppasswords (NOT your regular password)",
                "required": True,
                "secret": True,
            },
            {
                "key": "smtpHost",
                "prompt": "SMTP host",
                "default": "smtp.gmail.com",
                "required": True,
            },
            {
                "key": "allowFrom",
                "prompt": "Only respond to emails from (your email)",
                "required": False,
                "is_list": True,
            },
        ],
    },
    {
        "label": "Matrix (Element)",
        "value": "matrix",
        "desc": "Matrix/Element chat",
        "fields": [
            {
                "key": "homeserver",
                "prompt": "Homeserver URL",
                "default": "https://matrix.org",
                "required": True,
            },
            {
                "key": "userId",
                "prompt": "Bot user ID (e.g. @nanobot:matrix.org)",
                "required": True,
            },
            {
                "key": "accessToken",
                "prompt": "Access token",
                "required": True,
                "secret": True,
            },
        ],
    },
    {
        "label": "QQ",
        "value": "qq",
        "desc": "QQ bot (private messages)",
        "fields": [
            {
                "key": "appId",
                "prompt": "App ID",
                "hint": "Create at: https://q.qq.com → Developer Settings",
                "required": True,
            },
            {
                "key": "secret",
                "prompt": "App Secret",
                "required": True,
                "secret": True,
            },
        ],
    },
]


# ── Wizard logic ────────────────────────────────────────────────────────────

class SetupWizard:
    def __init__(self):
        self.config_path = Path.home() / ".nanobot" / "config.json"
        self.config: dict = {}
        self.load_existing()

    def load_existing(self):
        """Load existing config if present."""
        if self.config_path.exists():
            try:
                self.config = json.loads(self.config_path.read_text())
                info(f"Found existing config at {self.config_path}")
            except json.JSONDecodeError:
                warn("Existing config is invalid, starting fresh")
                self.config = {}

    def _deep_merge(self, base: dict, override: dict) -> dict:
        """Merge override into base recursively."""
        result = base.copy()
        for k, v in override.items():
            if k in result and isinstance(result[k], dict) and isinstance(v, dict):
                result[k] = self._deep_merge(result[k], v)
            else:
                result[k] = v
        return result

    def run(self):
        banner("nanogents Setup Wizard")
        info("This wizard will walk you through configuring your AI assistant.")
        info("Press Enter to accept defaults (shown in brackets).")
        info("Press Ctrl+C at any time to quit.\n")

        self._whatsapp_selected = False

        self.step_provider()
        self.step_model()
        self.step_channels()
        self.step_web_search()
        self.step_tools()
        self.step_save()
        self.step_whatsapp_login()

    # ── Step 1: Provider ────────────────────────────────────────────────────

    def step_provider(self):
        section(1, "LLM Provider", "Choose where your AI brain runs")

        # Check existing
        existing_providers = self.config.get("providers", {})
        configured = [p for p in existing_providers if existing_providers[p].get("apiKey")]
        if configured:
            info(f"Already configured: {', '.join(configured)}")
            if not ask_yes_no("Reconfigure provider?", default=False):
                return

        provider = ask_choice("Which LLM provider do you want to use?", PROVIDERS)
        provider_name = provider["value"]

        print()
        info(provider["key_hint"])
        print()

        # OAuth providers don't need API keys
        if provider.get("is_oauth"):
            warn("This provider uses OAuth login. After setup, run:")
            info(f"  {provider['key_hint']}")
            self.config.setdefault("providers", {})
            self.config["providers"][provider_name] = {}
            self._chosen_provider = provider
            ok(f"{provider['label']} selected! Remember to login after setup.")
            return

        # API key
        existing_key = existing_providers.get(provider_name, {}).get("apiKey", "")
        if provider.get("allow_dummy_key"):
            api_key = ask(
                f"{provider['label']} API key (or any string for local)",
                default=existing_key or "no-key",
                secret=True,
            )
        else:
            api_key = ask(
                f"{provider['label']} API key",
                default=existing_key,
                secret=True,
                required=True,
            )

        # Validate key prefix
        if provider.get("key_prefix") and api_key and not api_key.startswith(provider["key_prefix"]):
            warn(f"Key doesn't start with '{provider['key_prefix']}' — double-check it's correct")

        provider_config: dict = {"apiKey": api_key}

        # API base URL (for custom, vllm, and some providers)
        if provider.get("needs_api_base"):
            if provider.get("api_base_hint"):
                info(provider["api_base_hint"])
            existing_base = existing_providers.get(provider_name, {}).get("apiBase", "")
            api_base = ask(
                "API base URL",
                default=existing_base or provider.get("api_base_default", ""),
                required=(provider_name in ("custom", "vllm")),
            )
            if api_base:
                provider_config["apiBase"] = api_base

        self.config.setdefault("providers", {})
        self.config["providers"][provider_name] = provider_config

        # Store chosen provider for model step
        self._chosen_provider = provider

        ok(f"{provider['label']} configured!")

    # ── Step 2: Model ───────────────────────────────────────────────────────

    def step_model(self):
        section(2, "Model Selection", "Pick your AI model")

        provider = getattr(self, "_chosen_provider", None)

        if provider and provider.get("models"):
            model_choice = ask_choice("Which model do you want to use?", provider["models"])
            model = model_choice["value"]
            provider_name = provider["value"]

            # Custom model entry
            if model == "__custom__":
                model = ask("Enter your model name/ID", required=True)
        else:
            # Fallback: manual entry
            model = ask("Model name", default="anthropic/claude-sonnet-4-5", required=True)
            provider_name = ask("Provider name", default="openrouter")

        self.config.setdefault("agents", {})
        self.config["agents"]["defaults"] = {
            "model": model,
            "provider": provider_name,
        }

        ok(f"Model: {model} via {provider_name}")

    # ── Step 3: Channels ────────────────────────────────────────────────────

    def step_channels(self):
        section(3, "Chat Channels", "Connect your favorite messaging apps")

        info("Select which chat platforms you want to connect.")
        info("You can always add more later in ~/.nanobot/config.json\n")

        selected = ask_multi_choice("Which channels do you want to set up?", CHANNELS)

        if not selected:
            info("No channels selected. You can still use: nanobot agent (CLI chat)")
            return

        self.config.setdefault("channels", {})

        for channel in selected:
            ch_name = channel["value"]
            print()
            print(f"  {MAGENTA}{BOLD}── {channel['label']} ──{NC}")
            print()

            ch_config = {"enabled": True}
            existing_ch = self.config.get("channels", {}).get(ch_name, {})

            for field in channel.get("fields", []):
                if field.get("hint"):
                    info(field["hint"])

                is_list = field.get("is_list", False)
                existing_val = existing_ch.get(field["key"], "")
                if isinstance(existing_val, list):
                    existing_val = ", ".join(existing_val) if existing_val else ""

                val = ask(
                    field["prompt"],
                    default=field.get("default", existing_val or ""),
                    secret=field.get("secret", False),
                    required=field.get("required", False),
                )

                if val:
                    if is_list:
                        ch_config[field["key"]] = [v.strip() for v in val.split(",") if v.strip()]
                    else:
                        ch_config[field["key"]] = val

            # Email needs extra defaults
            if ch_name == "email":
                ch_config.setdefault("consentGranted", True)
                ch_config.setdefault("imapPort", 993)
                ch_config.setdefault("smtpPort", 587)
                if ch_config.get("imapUsername"):
                    ch_config.setdefault("smtpUsername", ch_config["imapUsername"])
                    ch_config.setdefault("fromAddress", ch_config["imapUsername"])
                if ch_config.get("imapPassword"):
                    ch_config.setdefault("smtpPassword", ch_config["imapPassword"])

            # WhatsApp defaults + QR login flow
            if ch_name == "whatsapp":
                ch_config.setdefault("bridgeUrl", "ws://localhost:3001")
                self._whatsapp_selected = True

            self.config["channels"][ch_name] = ch_config
            ok(f"{channel['label']} configured!")

    # ── Step 4: Web Search ──────────────────────────────────────────────────

    def step_web_search(self):
        section(4, "Web Search (Optional)", "Give your agent the ability to search the web")

        if not ask_yes_no("Enable web search? (requires Brave Search API key)", default=False):
            info("Skipped. You can add this later in config.json")
            return

        info("Get a free API key at: https://brave.com/search/api/")
        existing_key = (
            self.config.get("tools", {}).get("web", {}).get("search", {}).get("apiKey", "")
        )
        api_key = ask("Brave Search API key", default=existing_key, secret=True, required=True)

        self.config.setdefault("tools", {})
        self.config["tools"].setdefault("web", {})
        self.config["tools"]["web"]["search"] = {"apiKey": api_key, "maxResults": 5}

        ok("Web search configured!")

    # ── Step 5: Tool Access ─────────────────────────────────────────────────

    def step_tools(self):
        section(5, "Agent Permissions", "How much access should the agent have?")

        choice = ask_choice(
            "Agent filesystem/shell access level:",
            [
                {
                    "label": "Full access (recommended for VPS)",
                    "value": "full",
                    "desc": "Agent can read/write/execute anywhere on the system",
                },
                {
                    "label": "Workspace only (safer)",
                    "value": "restricted",
                    "desc": "Agent is sandboxed to ~/.nanobot/workspace",
                },
            ],
        )

        self.config.setdefault("tools", {})

        if choice["value"] == "full":
            self.config["tools"]["restrictToWorkspace"] = False
            self.config["tools"].setdefault("exec", {})
            self.config["tools"]["exec"]["pathAppend"] = "/usr/sbin:/sbin"
            ok("Full access enabled — agent can manage your entire system")
        else:
            self.config["tools"]["restrictToWorkspace"] = True
            ok("Sandbox mode — agent restricted to workspace only")

    # ── WhatsApp Login ─────────────────────────────────────────────────────

    def step_whatsapp_login(self):
        """If WhatsApp was selected, offer to scan QR code now."""
        if not self._whatsapp_selected:
            return

        # Find the bridge directory
        script_dir = Path(__file__).resolve().parent.parent
        bridge_dir = script_dir / "bridge"
        bridge_entry = bridge_dir / "dist" / "index.js"

        # Check if bridge is built
        if not bridge_entry.exists():
            warn("WhatsApp bridge not built. Skipping QR login.")
            info("Build it manually: cd bridge && npm install && npm run build")
            return

        # Check Node.js
        if not shutil.which("node"):
            warn("Node.js not found. Skipping WhatsApp QR login.")
            return

        # Check if already linked
        auth_dir = Path.home() / ".nanobot" / "whatsapp-auth"
        if auth_dir.exists() and any(auth_dir.iterdir()):
            ok("WhatsApp already linked!")
            if not ask_yes_no("Re-link WhatsApp? (scan QR again)", default=False):
                return

        section(6, "WhatsApp Login", "Scan QR code to link your WhatsApp")

        print(f"  {MAGENTA}{BOLD}┌────────────────────────────────────────────┐{NC}")
        print(f"  {MAGENTA}{BOLD}│  📱  WhatsApp QR Code Login                │{NC}")
        print(f"  {MAGENTA}{BOLD}└────────────────────────────────────────────┘{NC}")
        print()
        info("A QR code will appear below.")
        info("On your phone:")
        info("  WhatsApp → Settings → Linked Devices → Link a Device")
        info("  Scan the QR code with your phone camera.")
        print()
        warn("After you see '✅ Connected to WhatsApp', press Ctrl+C to continue.")
        print()
        warn("NOTE: Someone ELSE must message your WhatsApp number for the bot")
        warn("to respond. Messages you send to yourself are ignored by design.")
        print()

        if not ask_yes_no("Ready to scan QR code now?", default=True):
            info("Skipped. You can link later with: nanobot channels login")
            return

        print()
        print(f"  {DIM}────── WhatsApp Bridge Output ──────{NC}")
        print()

        try:
            # Run the bridge in foreground; Ctrl+C stops it and returns here
            subprocess.run(
                ["node", str(bridge_entry)],
                cwd=str(bridge_dir),
            )
        except KeyboardInterrupt:
            pass

        print()
        print(f"  {DIM}────── End Bridge Output ───────────{NC}")
        print()

        # Check if session was created
        if auth_dir.exists() and any(auth_dir.iterdir()):
            ok("WhatsApp linked successfully!")
        else:
            warn("WhatsApp session not detected. You can try again later:")
            info("  nanobot channels login")

    # ── Save ────────────────────────────────────────────────────────────────

    def step_save(self):
        banner("Review & Save")

        # Pretty print summary
        print(f"  {BOLD}Provider:{NC}  ", end="")
        providers = self.config.get("providers", {})
        active = [p for p in providers if providers[p].get("apiKey")]
        print(", ".join(active) if active else f"{YELLOW}none configured{NC}")

        agent_defaults = self.config.get("agents", {}).get("defaults", {})
        print(f"  {BOLD}Model:{NC}     {agent_defaults.get('model', 'not set')}")

        channels = self.config.get("channels", {})
        active_channels = [ch for ch in channels if isinstance(channels[ch], dict) and channels[ch].get("enabled")]
        print(f"  {BOLD}Channels:{NC}  ", end="")
        print(", ".join(active_channels) if active_channels else "CLI only")

        tools = self.config.get("tools", {})
        access = "Sandbox" if tools.get("restrictToWorkspace") else "Full access"
        print(f"  {BOLD}Access:{NC}    {access}")

        search = tools.get("web", {}).get("search", {}).get("apiKey")
        print(f"  {BOLD}Search:{NC}    {'enabled' if search else 'disabled'}")

        print(f"\n  {BOLD}Config:{NC}    {self.config_path}")
        print()

        if not ask_yes_no("Save this configuration?", default=True):
            warn("Configuration not saved. Run the wizard again anytime.")
            return

        # Merge with existing (don't overwrite unrelated settings)
        if self.config_path.exists():
            try:
                existing = json.loads(self.config_path.read_text())
                self.config = self._deep_merge(existing, self.config)
            except json.JSONDecodeError:
                pass

        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(json.dumps(self.config, indent=2, ensure_ascii=False) + "\n")

        ok(f"Configuration saved to {self.config_path}")


# ── Entry point ─────────────────────────────────────────────────────────────

if __name__ == "__main__":
    try:
        wizard = SetupWizard()
        wizard.run()
    except KeyboardInterrupt:
        print(f"\n\n  {YELLOW}Setup cancelled.{NC} Run again anytime: bash setup.sh\n")
        sys.exit(0)
