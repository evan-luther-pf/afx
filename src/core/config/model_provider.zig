const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum(u8) {
    gateway,
    codex,
    grok,
    google,
    google_vertex,
    google_antigravity,
    google_gemini_cli,
    anthropic,
    azure_openai,
    bedrock,
    ollama,
    openai,
    xai,
    moonshot,
    kimi,
    qwen,
    perplexity,
    huggingface,
    venice,
    zai,
    minimax,
    deepseek,
    groq,
    mistral,
    openrouter,
    together,
    cerebras,
    fireworks,
    nvidia,
    lm_studio,
    llama_cpp,
    vllm,
};

pub const provider_count = @typeInfo(ProviderId).@"enum".fields.len;

pub const CredentialPolicy = enum {
    gateway,
    api_key,
    chatgpt_subscription,
    grok_subscription,
    google_gemini_cli_oauth,
    google_antigravity_oauth,
};

pub const CompatibleAuthHeader = enum { bearer, api_key, none };

pub const MaxTokensField = enum { max_tokens, max_completion_tokens, omit };
pub const OpenAICompatible = struct {
    base_url: []const u8,
    base_url_env: []const u8,
    api_key_env: []const u8,
    default_model: []const u8,
    auth_header: CompatibleAuthHeader = .bearer,
    chat_path: []const u8 = "chat/completions",
    catalog_path: []const u8 = "models",
    api_key_optional: bool = false,
    stream_usage: bool = true,
    supports_multiple_system_messages: bool = true,
    supports_tool_choice: bool = true,
    supports_parallel_tool_calls: bool = true,
    supports_structured_output: bool = false,
    supports_images: bool = false,
    requires_tool_result_name: bool = false,
    requires_mistral_tool_ids: bool = false,
    first_event_timeout_ms: u32 = 60_000,
    idle_timeout_ms: u32 = 300_000,
    terminal_grace_ms: u32 = 2_500,
    max_tokens_field: MaxTokensField = .max_tokens,
};

pub const Entry = struct {
    id: ProviderId,
    slug: []const u8,
    login_slug: []const u8,
    name: []const u8,
    auth_description: []const u8,
    subscription: bool,
    command_name: []const u8,
    credential_policy: CredentialPolicy,
    missing_cli: []const u8,
    missing_interactive: []const u8,
    gateway_auxiliaries: bool = false,
    available_in_wasm: bool = true,
    api_key_env: []const u8 = "",
    default_model: []const u8 = "",
    openai_compatible: ?OpenAICompatible = null,

    pub fn authorizesCredential(
        self: Entry,
        source: ?types.CredentialSource,
        credential_provider: ?ProviderId,
    ) bool {
        const selected = source orelse return false;
        return switch (self.credential_policy) {
            .gateway => selected != .provider_api_key and !providerScopedOAuthSource(selected),
            .api_key => selected == .provider_api_key and credential_provider == self.id,
            .chatgpt_subscription => selected == .chatgpt_subscription,
            .grok_subscription => selected == .grok_subscription,
            .google_antigravity_oauth => selected == .google_antigravity,
            .google_gemini_cli_oauth => selected == .google_gemini_cli,
        };
    }

    pub fn dedicatedCredentialSource(self: Entry) ?types.CredentialSource {
        return switch (self.credential_policy) {
            .gateway => null,
            .api_key => .provider_api_key,
            .chatgpt_subscription => .chatgpt_subscription,
            .grok_subscription => .grok_subscription,
            .google_antigravity_oauth => .google_antigravity,
            .google_gemini_cli_oauth => .google_gemini_cli,
        };
    }
};

fn providerScopedOAuthSource(source: types.CredentialSource) bool {
    return source == .chatgpt_subscription or source == .grok_subscription or
        source == .google_antigravity or source == .google_gemini_cli;
}

pub const entries = [_]Entry{
    .{
        .missing_cli = "afx needs access to Vercel AI Gateway. Run afx login, afx providers gateway, or set AI_GATEWAY_API_KEY.",
        .missing_interactive = "Vercel AI Gateway needs authentication. Run /login, use /providers to add an API key, or set AI_GATEWAY_API_KEY.",
        .id = .gateway,
        .slug = "gateway",
        .login_slug = "vercel",
        .name = "Vercel AI Gateway",
        .auth_description = "Vercel account or AI Gateway billing",
        .subscription = false,
        .credential_policy = .gateway,
        .command_name = "Gateway",
        .gateway_auxiliaries = true,
    },
    .{
        .id = .codex,
        .slug = "codex",
        .login_slug = "codex",
        .name = "Codex subscription",
        .command_name = "Codex",
        .auth_description = "ChatGPT Plus, Pro, Business, Enterprise, or Edu subscription",
        .subscription = true,
        .credential_policy = .chatgpt_subscription,
        .missing_cli = "afx needs a Codex subscription login for this model. Run afx login codex.",
        .missing_interactive = "Codex needs a subscription login. Run /login and choose Sign in with Codex.",
    },
    .{
        .id = .grok,
        .slug = "grok",
        .login_slug = "grok",
        .name = "Grok subscription",
        .command_name = "Grok",
        .auth_description = "SuperGrok or X Premium subscription",
        .subscription = true,
        .credential_policy = .grok_subscription,
        .missing_cli = "afx needs a Grok subscription login for this model. Run afx login grok.",
        .missing_interactive = "Grok needs a subscription login. Run /login and choose Sign in with Grok.",
    },
    .{
        .id = .google,
        .slug = "google",
        .login_slug = "",
        .name = "Google AI Studio",
        .command_name = "Google AI Studio",
        .auth_description = "Gemini API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Google AI Studio needs a Gemini API key. Set GEMINI_API_KEY or run afx providers google.",
        .missing_interactive = "Google AI Studio needs a Gemini API key. Use /providers or set GEMINI_API_KEY.",
        .available_in_wasm = false,
        .api_key_env = "GEMINI_API_KEY",
        .default_model = "gemini-3.6-flash",
    },
    .{
        .id = .google_vertex,
        .slug = "google-vertex",
        .login_slug = "",
        .name = "Google Vertex AI",
        .command_name = "Google Vertex AI",
        .auth_description = "Vertex AI API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Google Vertex AI needs GOOGLE_CLOUD_API_KEY. Set it or run afx providers google-vertex.",
        .missing_interactive = "Google Vertex AI needs an API key. Use /providers or set GOOGLE_CLOUD_API_KEY.",
        .available_in_wasm = false,
        .api_key_env = "GOOGLE_CLOUD_API_KEY",
        .default_model = "gemini-3.6-flash",
    },
    .{
        .id = .google_antigravity,
        .slug = "google-antigravity",
        .login_slug = "google",
        .name = "Google Antigravity",
        .command_name = "Google Antigravity",
        .auth_description = "Google Antigravity OAuth",
        .subscription = true,
        .credential_policy = .google_antigravity_oauth,
        .missing_cli = "Google Antigravity needs OAuth authentication. Run afx login google.",
        .missing_interactive = "Google Antigravity needs OAuth authentication. Run /providers and choose Google Antigravity.",
        .available_in_wasm = false,
    },
    .{
        .id = .google_gemini_cli,
        .slug = "google-gemini-cli",
        .login_slug = "gemini",
        .name = "Google Gemini CLI",
        .command_name = "Google Gemini CLI",
        .auth_description = "Gemini CLI OAuth",
        .subscription = true,
        .credential_policy = .google_gemini_cli_oauth,
        .missing_cli = "Google Gemini CLI needs OAuth authentication. Run afx login gemini.",
        .missing_interactive = "Google Gemini CLI needs OAuth authentication. Run /providers and choose Google Gemini CLI.",
        .available_in_wasm = false,
        .default_model = "gemini-2.5-pro",
    },
    .{
        .id = .anthropic,
        .slug = "anthropic",
        .login_slug = "",
        .name = "Anthropic",
        .command_name = "Anthropic",
        .auth_description = "Anthropic API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Anthropic needs ANTHROPIC_API_KEY. Set it or run afx providers anthropic.",
        .missing_interactive = "Anthropic needs an API key. Use /providers or set ANTHROPIC_API_KEY.",
        .available_in_wasm = false,
        .api_key_env = "ANTHROPIC_API_KEY",
        .default_model = "claude-opus-4-6",
        .openai_compatible = .{
            .base_url = "https://api.anthropic.com/v1",
            .base_url_env = "ANTHROPIC_BASE_URL",
            .api_key_env = "ANTHROPIC_API_KEY",
            .default_model = "claude-opus-4-6",
            .supports_multiple_system_messages = false,
            .supports_images = true,
        },
    },
    .{
        .id = .azure_openai,
        .slug = "azure-openai",
        .login_slug = "",
        .name = "Azure OpenAI",
        .command_name = "Azure OpenAI",
        .auth_description = "Azure OpenAI API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Azure OpenAI needs AZURE_OPENAI_API_KEY and AZURE_OPENAI_BASE_URL.",
        .missing_interactive = "Azure OpenAI needs an API key and deployment base URL.",
        .available_in_wasm = false,
        .api_key_env = "AZURE_OPENAI_API_KEY",
        .default_model = "gpt-4.1",
        .openai_compatible = .{
            .base_url = "",
            .base_url_env = "AZURE_OPENAI_BASE_URL",
            .api_key_env = "AZURE_OPENAI_API_KEY",
            .default_model = "gpt-4.1",
            .auth_header = .api_key,
            .chat_path = "chat/completions?api-version=2025-04-01-preview",
            .supports_images = true,
        },
    },
    .{
        .id = .bedrock,
        .slug = "bedrock",
        .login_slug = "",
        .name = "Amazon Bedrock",
        .command_name = "Amazon Bedrock",
        .auth_description = "Bedrock API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Amazon Bedrock needs AWS_BEARER_TOKEN_BEDROCK. Set it or run afx providers bedrock.",
        .missing_interactive = "Amazon Bedrock needs a Bedrock API key. Use /providers or set AWS_BEARER_TOKEN_BEDROCK.",
        .available_in_wasm = false,
        .api_key_env = "AWS_BEARER_TOKEN_BEDROCK",
        .default_model = "openai.gpt-oss-120b-1:0",
        .openai_compatible = .{
            .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1",
            .base_url_env = "BEDROCK_BASE_URL",
            .api_key_env = "AWS_BEARER_TOKEN_BEDROCK",
            .default_model = "openai.gpt-oss-120b-1:0",
            .supports_images = true,
        },
    },
    .{
        .id = .ollama,
        .slug = "ollama",
        .login_slug = "",
        .name = "Ollama",
        .command_name = "Ollama",
        .auth_description = "Local Ollama server",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Ollama is unavailable. Start Ollama or set OLLAMA_BASE_URL.",
        .missing_interactive = "Ollama is unavailable. Start Ollama or set OLLAMA_BASE_URL.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "http://127.0.0.1:11434/v1",
            .base_url_env = "OLLAMA_BASE_URL",
            .api_key_env = "OLLAMA_API_KEY",
            .default_model = "",
            .api_key_optional = true,
            .supports_multiple_system_messages = false,
            .supports_parallel_tool_calls = false,
            .supports_images = true,
        },
    },
    .{
        .id = .openai,
        .slug = "openai",
        .login_slug = "",
        .name = "OpenAI",
        .command_name = "OpenAI",
        .auth_description = "OpenAI API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "OpenAI needs OPENAI_API_KEY. Set it or run afx providers openai.",
        .missing_interactive = "OpenAI needs an API key. Use /providers or set OPENAI_API_KEY.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.openai.com/v1",
            .base_url_env = "OPENAI_BASE_URL",
            .api_key_env = "OPENAI_API_KEY",
            .default_model = "gpt-5.5",
            .supports_structured_output = true,
            .supports_images = true,
            .max_tokens_field = .max_completion_tokens,
        },
    },
    .{
        .id = .xai,
        .slug = "xai",
        .login_slug = "",
        .name = "xAI",
        .command_name = "xAI",
        .auth_description = "xAI API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "xAI needs XAI_API_KEY. Set it or run afx providers xai.",
        .missing_interactive = "xAI needs an API key. Use /providers or set XAI_API_KEY.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.x.ai/v1",
            .base_url_env = "XAI_BASE_URL",
            .api_key_env = "XAI_API_KEY",
            .default_model = "grok-4.20",
            .supports_structured_output = true,
            .supports_images = true,
        },
    },
    .{
        .id = .moonshot,
        .slug = "moonshot",
        .login_slug = "",
        .name = "Moonshot AI",
        .command_name = "Moonshot AI",
        .auth_description = "Moonshot API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Moonshot AI needs MOONSHOT_API_KEY.",
        .missing_interactive = "Moonshot AI needs an API key.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.moonshot.ai/v1",
            .base_url_env = "MOONSHOT_BASE_URL",
            .api_key_env = "MOONSHOT_API_KEY",
            .default_model = "kimi-k2.5",
        },
    },
    .{
        .id = .kimi,
        .slug = "kimi",
        .login_slug = "",
        .name = "Kimi",
        .command_name = "Kimi",
        .auth_description = "Kimi API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Kimi needs KIMI_API_KEY.",
        .missing_interactive = "Kimi needs an API key.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.kimi.com/coding/v1",
            .base_url_env = "KIMI_BASE_URL",
            .api_key_env = "KIMI_API_KEY",
            .default_model = "kimi-k2.5",
        },
    },
    .{
        .id = .qwen,
        .slug = "qwen",
        .login_slug = "",
        .name = "Qwen",
        .command_name = "Qwen",
        .auth_description = "Qwen API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Qwen needs QWEN_PORTAL_API_KEY.",
        .missing_interactive = "Qwen needs an API key.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            .base_url_env = "QWEN_BASE_URL",
            .api_key_env = "QWEN_PORTAL_API_KEY",
            .default_model = "qwen3-coder-plus",
        },
    },
    .{
        .id = .perplexity,
        .slug = "perplexity",
        .login_slug = "",
        .name = "Perplexity",
        .command_name = "Perplexity",
        .auth_description = "Perplexity API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Perplexity needs PERPLEXITY_API_KEY.",
        .missing_interactive = "Perplexity needs an API key.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.perplexity.ai",
            .base_url_env = "PERPLEXITY_BASE_URL",
            .api_key_env = "PERPLEXITY_API_KEY",
            .default_model = "sonar-pro",
            .supports_tool_choice = false,
            .supports_parallel_tool_calls = false,
        },
    },
    .{
        .id = .huggingface,
        .slug = "huggingface",
        .login_slug = "",
        .name = "Hugging Face",
        .command_name = "Hugging Face",
        .auth_description = "Hugging Face token",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Hugging Face needs HF_TOKEN.",
        .missing_interactive = "Hugging Face needs an access token.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://router.huggingface.co/v1",
            .base_url_env = "HUGGINGFACE_BASE_URL",
            .api_key_env = "HF_TOKEN",
            .default_model = "meta-llama/Llama-3.3-70B-Instruct",
        },
    },
    .{
        .id = .venice,
        .slug = "venice",
        .login_slug = "",
        .name = "Venice",
        .command_name = "Venice",
        .auth_description = "Venice API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Venice needs VENICE_API_KEY.",
        .missing_interactive = "Venice needs an API key.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.venice.ai/api/v1",
            .base_url_env = "VENICE_BASE_URL",
            .api_key_env = "VENICE_API_KEY",
            .default_model = "llama-3.3-70b",
        },
    },
    .{
        .id = .zai,
        .slug = "zai",
        .login_slug = "",
        .name = "Z.AI",
        .command_name = "Z.AI",
        .auth_description = "Z.AI API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Z.AI needs ZAI_API_KEY.",
        .missing_interactive = "Z.AI needs an API key.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.z.ai/api/paas/v4",
            .base_url_env = "ZAI_BASE_URL",
            .api_key_env = "ZAI_API_KEY",
            .default_model = "glm-4.7",
        },
    },
    .{
        .id = .minimax,
        .slug = "minimax",
        .login_slug = "",
        .name = "MiniMax",
        .command_name = "MiniMax",
        .auth_description = "MiniMax API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "MiniMax needs MINIMAX_API_KEY.",
        .missing_interactive = "MiniMax needs an API key.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.minimax.io/v1",
            .base_url_env = "MINIMAX_BASE_URL",
            .api_key_env = "MINIMAX_API_KEY",
            .default_model = "MiniMax-M2.1",
        },
    },
    .{
        .id = .deepseek,
        .slug = "deepseek",
        .login_slug = "",
        .name = "DeepSeek",
        .command_name = "DeepSeek",
        .auth_description = "DeepSeek API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "DeepSeek needs an API key. Set DEEPSEEK_API_KEY and retry.",
        .missing_interactive = "DeepSeek needs an API key. Set DEEPSEEK_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.deepseek.com",
            .base_url_env = "DEEPSEEK_BASE_URL",
            .api_key_env = "DEEPSEEK_API_KEY",
            .default_model = "deepseek-v4-pro",
        },
    },
    .{
        .id = .groq,
        .slug = "groq",
        .login_slug = "",
        .name = "Groq",
        .command_name = "Groq",
        .auth_description = "Groq API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Groq needs an API key. Set GROQ_API_KEY and retry.",
        .missing_interactive = "Groq needs an API key. Set GROQ_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.groq.com/openai/v1",
            .base_url_env = "GROQ_BASE_URL",
            .api_key_env = "GROQ_API_KEY",
            .default_model = "openai/gpt-oss-120b",
        },
    },
    .{
        .id = .mistral,
        .slug = "mistral",
        .login_slug = "",
        .name = "Mistral",
        .command_name = "Mistral",
        .auth_description = "Mistral API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Mistral needs an API key. Set MISTRAL_API_KEY and retry.",
        .missing_interactive = "Mistral needs an API key. Set MISTRAL_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.mistral.ai/v1",
            .base_url_env = "MISTRAL_BASE_URL",
            .api_key_env = "MISTRAL_API_KEY",
            .default_model = "devstral-medium-latest",
            .requires_tool_result_name = true,
            .requires_mistral_tool_ids = true,
        },
    },
    .{
        .id = .openrouter,
        .slug = "openrouter",
        .login_slug = "",
        .name = "OpenRouter",
        .command_name = "OpenRouter",
        .auth_description = "OpenRouter API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "OpenRouter needs an API key. Set OPENROUTER_API_KEY and retry.",
        .missing_interactive = "OpenRouter needs an API key. Set OPENROUTER_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://openrouter.ai/api/v1",
            .base_url_env = "OPENROUTER_BASE_URL",
            .api_key_env = "OPENROUTER_API_KEY",
            .default_model = "openai/gpt-5.5",
        },
    },
    .{
        .id = .together,
        .slug = "together",
        .login_slug = "",
        .name = "Together AI",
        .command_name = "Together AI",
        .auth_description = "Together API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Together AI needs an API key. Set TOGETHER_API_KEY and retry.",
        .missing_interactive = "Together AI needs an API key. Set TOGETHER_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.together.xyz/v1",
            .base_url_env = "TOGETHER_BASE_URL",
            .api_key_env = "TOGETHER_API_KEY",
            .default_model = "moonshotai/Kimi-K2.7-Code",
        },
    },
    .{
        .id = .cerebras,
        .slug = "cerebras",
        .login_slug = "",
        .name = "Cerebras",
        .command_name = "Cerebras",
        .auth_description = "Cerebras API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Cerebras needs an API key. Set CEREBRAS_API_KEY and retry.",
        .missing_interactive = "Cerebras needs an API key. Set CEREBRAS_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.cerebras.ai/v1",
            .base_url_env = "CEREBRAS_BASE_URL",
            .api_key_env = "CEREBRAS_API_KEY",
            .default_model = "zai-glm-4.7",
        },
    },
    .{
        .id = .fireworks,
        .slug = "fireworks",
        .login_slug = "",
        .name = "Fireworks",
        .command_name = "Fireworks",
        .auth_description = "Fireworks API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "Fireworks needs an API key. Set FIREWORKS_API_KEY and retry.",
        .missing_interactive = "Fireworks needs an API key. Set FIREWORKS_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://api.fireworks.ai/inference/v1",
            .base_url_env = "FIREWORKS_BASE_URL",
            .api_key_env = "FIREWORKS_API_KEY",
            .default_model = "kimi-k2.7-code",
        },
    },
    .{
        .id = .nvidia,
        .slug = "nvidia",
        .login_slug = "",
        .name = "NVIDIA",
        .command_name = "NVIDIA",
        .auth_description = "NVIDIA API key",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "NVIDIA needs an API key. Set NVIDIA_API_KEY and retry.",
        .missing_interactive = "NVIDIA needs an API key. Set NVIDIA_API_KEY and retry.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "https://integrate.api.nvidia.com/v1",
            .base_url_env = "NVIDIA_BASE_URL",
            .api_key_env = "NVIDIA_API_KEY",
            .default_model = "nvidia/llama-3.1-nemotron-70b-instruct",
        },
    },
    .{
        .id = .lm_studio,
        .slug = "lm-studio",
        .login_slug = "",
        .name = "LM Studio",
        .command_name = "LM Studio",
        .auth_description = "Local OpenAI-compatible server",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "LM Studio is unavailable. Start its local server or set LM_STUDIO_BASE_URL.",
        .missing_interactive = "LM Studio is unavailable. Start its local server or set LM_STUDIO_BASE_URL.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "http://127.0.0.1:1234/v1",
            .base_url_env = "LM_STUDIO_BASE_URL",
            .api_key_env = "LM_STUDIO_API_KEY",
            .default_model = "",
            .api_key_optional = true,
            .supports_multiple_system_messages = false,
            .supports_parallel_tool_calls = false,
        },
    },
    .{
        .id = .llama_cpp,
        .slug = "llama.cpp",
        .login_slug = "",
        .name = "llama.cpp",
        .command_name = "llama.cpp",
        .auth_description = "Local OpenAI-compatible server",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "llama.cpp is unavailable. Start its server or set LLAMA_CPP_BASE_URL.",
        .missing_interactive = "llama.cpp is unavailable. Start its server or set LLAMA_CPP_BASE_URL.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "http://127.0.0.1:8080/v1",
            .base_url_env = "LLAMA_CPP_BASE_URL",
            .api_key_env = "LLAMA_CPP_API_KEY",
            .default_model = "",
            .api_key_optional = true,
            .supports_multiple_system_messages = false,
            .supports_parallel_tool_calls = false,
        },
    },
    .{
        .id = .vllm,
        .slug = "vllm",
        .login_slug = "",
        .name = "vLLM",
        .command_name = "vLLM",
        .auth_description = "Local OpenAI-compatible server",
        .subscription = false,
        .credential_policy = .api_key,
        .missing_cli = "vLLM is unavailable. Start its server or set VLLM_BASE_URL.",
        .missing_interactive = "vLLM is unavailable. Start its server or set VLLM_BASE_URL.",
        .available_in_wasm = false,
        .openai_compatible = .{
            .base_url = "http://127.0.0.1:8000/v1",
            .base_url_env = "VLLM_BASE_URL",
            .api_key_env = "VLLM_API_KEY",
            .default_model = "",
            .api_key_optional = true,
            .supports_multiple_system_messages = false,
            .supports_parallel_tool_calls = false,
        },
    },
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn get(provider: ProviderId) *const Entry {
    return &entries[@intFromEnum(provider)];
}

pub const CredentialSurface = enum { cli, interactive };

pub fn missingCredentialMessage(provider: ProviderId, surface: CredentialSurface) []const u8 {
    const provider_entry = get(provider);
    return switch (surface) {
        .cli => provider_entry.missing_cli,
        .interactive => provider_entry.missing_interactive,
    };
}

pub fn parse(value: []const u8) ?ProviderId {
    for (entries) |provider| {
        if (std.ascii.eqlIgnoreCase(value, provider.slug)) return provider.id;
    }
    return null;
}

pub fn parseLogin(value: []const u8) ?ProviderId {
    for (entries) |provider| {
        if (provider.login_slug.len > 0 and std.ascii.eqlIgnoreCase(value, provider.login_slug)) return provider.id;
    }
    if (std.ascii.eqlIgnoreCase(value, "ai-gateway")) return .gateway;
    return null;
}

pub fn label(provider: ProviderId) []const u8 {
    return get(provider).name;
}

pub fn authorizesCredential(
    provider: ProviderId,
    source: ?types.CredentialSource,
    credential_provider: ?ProviderId,
) bool {
    return get(provider).authorizesCredential(source, credential_provider);
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return get(provider).gateway_auxiliaries;
}

pub fn defaultModel(provider: ProviderId) ?[]const u8 {
    const entry = get(provider);
    if (entry.default_model.len > 0) return entry.default_model;
    const config = entry.openai_compatible orelse return null;
    return if (config.default_model.len > 0) config.default_model else null;
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key, null));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login, null));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription, null));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription, null));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key, null));
    try std.testing.expect(!authorizesCredential(.codex, null, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription, null));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription, null));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription, null));
    try std.testing.expect(authorizesCredential(.google, .provider_api_key, .google));
    try std.testing.expect(!authorizesCredential(.google, .provider_api_key, .deepseek));
    try std.testing.expect(authorizesCredential(.google_antigravity, .google_antigravity, null));
    try std.testing.expect(!authorizesCredential(.google_antigravity, .grok_subscription, null));
    try std.testing.expect(authorizesCredential(.deepseek, .provider_api_key, .deepseek));
    try std.testing.expect(!authorizesCredential(.deepseek, .provider_api_key, .groq));
    try std.testing.expect(!authorizesCredential(.deepseek, .ai_gateway_api_key, null));
}

test "provider parsing exposes gateway and OAuth providers" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expectEqual(ProviderId.google, parse("GOOGLE").?);
    try std.testing.expectEqual(ProviderId.google_antigravity, parse("GOOGLE-ANTIGRAVITY").?);
    try std.testing.expectEqual(ProviderId.google_antigravity, parseLogin("google").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("") == null);
}

test "registry order matches provider ids and login slugs" {
    try std.testing.expectEqual(provider_count, entries.len);
    for (entries, 0..) |provider, index| {
        try std.testing.expectEqual(index, @intFromEnum(provider.id));
        try std.testing.expectEqual(provider.id, parse(provider.slug).?);
        if (provider.login_slug.len > 0) try std.testing.expectEqual(provider.id, parseLogin(provider.login_slug).?);
    }
    try std.testing.expectEqual(ProviderId.gateway, parseLogin("ai-gateway").?);
}
