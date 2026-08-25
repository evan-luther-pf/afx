# Provider expansion reference

## Decision

AFX can support OMP-level provider breadth, but providers must not be added by extending the current scattered provider switches. OMP's 76 registry entries reduce to roughly 14 wire APIs; 33 bundled providers use the same `openai-completions` transport.

The scalable unit is:

1. a wire adapter,
2. a declarative provider entry,
3. an optional authentication adapter,
4. model catalog and discovery metadata.

Keep AFX's `stream_provider.Provider`. Replace duplicated identity, dispatch, settings, and authentication tables with one compile-time provider registry.

## Current AFX constraints

Provider identity is currently repeated across:

- `src/core/auth/provider_catalog.zig`: `vercel`, `codex`, `grok`
- `src/core/config/model_provider.zig`: `gateway`, `codex`, `grok`
- `src/core/auth/credentials.zig`: provider-specific credential resolution
- configuration fields: `model`, `codex_model`, `grok_model`
- app, auth, session, and UI switches
- `src/builtins/providers.zig`: stream and catalog dispatch

`src/core/agent/stream_provider.zig` is already a suitable transport boundary. It supports request construction, streamed content/reasoning/tool input, deadlines, cancellation, retry ownership, delivery certainty, usage, and provider session state.

`src/core/gateway/gateway_provider.zig` is not the universal provider contract. It bundles Vercel-specific capabilities including credits, generation usage, web search, and gateway URLs. Those remain optional capabilities.

## Minimum registry

Use a compile-time Zig registry. `ProviderId` may remain an enum; the problem is behavior scattered outside the registry, not the enum itself.

```zig
const ProviderEntry = struct {
    id: ProviderId,
    slug: []const u8,
    name: []const u8,
    default_model: []const u8,
    stream: stream_provider.Provider,
    catalog: model_catalog.Provider,
    auth: AuthAdapter,
};
```

Registry requirements:

- one entry per enum member, checked at compile time or by a focused test;
- provider labels, defaults, stream/catalog providers, and credential policy resolved through the entry;
- no provider-specific switches in application code;
- serialized provider values remain stable slugs;
- provider model preferences use a provider-keyed object rather than `codex_model`, `grok_model`, and future sibling fields.

Authentication should become a small provider adapter supporting environment keys, interactive acquisition, refresh, and conversion into transport credentials. Initially store one credential per provider. Do not copy OMP's multi-account ranking, refresh leases, usage balancing, broker snapshots, or remote refresh machinery without a concrete requirement.

A generic credential needs provider ID, kind, access token or API key, optional refresh token and expiry, and optional account, tenant, project, and email fields. Continue using AFX's keychain/profile-file protections and secret zeroing.

Extract the loopback listener, state, PKCE, callback parsing, and token exchange duplicated in the ChatGPT and Grok flows into shared browser-OAuth code when the next OAuth provider is implemented.

## OMP transport families

OMP's provider guide separates catalog metadata from authentication definitions and dispatches streaming by wire API rather than provider ID.

| Wire family | Representative providers | AFX work |
| --- | --- | --- |
| OpenAI completions | DeepSeek, Groq, Mistral, Moonshot, Cerebras, Fireworks, Together, Nvidia, Kimi, Qwen, Alibaba plans, Xiaomi plans | One generic adapter plus provider metadata and auth |
| OpenAI responses | OpenAI, xAI, Meta, Sakana | Generalize or reuse Codex response parsing |
| Anthropic messages | Anthropic, Vercel Gateway, Cloudflare Gateway, ZAI, MiniMax | Native Anthropic adapter |
| OpenRouter | OpenRouter | OpenAI family plus routing options |
| Google Generative AI | Google AI Studio | Native Gemini adapter |
| Google Vertex | Vertex AI | Gemini conversion plus ADC, project, and location auth |
| Google Cloud Code | Gemini CLI, Antigravity | OAuth, project provisioning, wrapped Gemini SSE transport |
| Azure responses | Azure OpenAI | Azure URL, auth, and request variant |
| Bedrock Converse | AWS Bedrock | AWS credential chain, SigV4, and event stream |
| Ollama chat | Ollama and Ollama Cloud | Ollama adapter |
| Mixed proxies | Copilot, GitLab Duo, OpenCode, Zenmux | Existing transports plus provider routing and auth |
| Proprietary | Cursor, Devin, GitLab Duo Agent | Bespoke protocols; implement last |
| Search credentials | Tavily, Kagi, Exa, Parallel | Separate tool credentials, not model providers |

A registry entry is not full support by itself. Full support includes authentication, model discovery/defaults, request feature mapping, stream parsing, tool calls, reasoning, usage, retry/error semantics, configuration, session restore, and provider selection UI.

## Google OAuth and Cloud Code

OMP shares a Google browser authorization-code flow between Gemini CLI and Antigravity. It opens a loopback callback, requests offline access, exchanges the code, stores refresh/access tokens and email, and then performs provider-specific project discovery. Provisioning requests have bounded deadlines.

AFX should reuse its existing ChatGPT/Grok loopback flow, but should not copy OMP's embedded Google OAuth client credentials. Google documents desktop apps as public clients that cannot keep secrets and recommends S256 PKCE. Use an AFX-owned desktop OAuth client, state validation, and PKCE.

### Gemini CLI / Cloud Code Assist

OMP's Gemini CLI adapter:

- requests `cloud-platform`, email, and profile scopes;
- calls `cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`;
- handles free, standard, legacy, organization, and VPC-SC account states;
- provisions with `v1internal:onboardUser`;
- polls the long-running operation with cancellation and an attempt bound;
- stores the resulting `projectId`;
- honors `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_PROJECT_ID` where required.

The Cloud Code transport posts to `/v1internal:streamGenerateContent?alt=sse`. It wraps Gemini requests in `{ project, model, request, ... }`, converts messages, images, system instructions, tools, thinking configuration, and usage, and parses SSE events including thought signatures, tool calls, blocked prompts, and in-band errors. It owns the first-event watchdog so a silent HTTP 200 can fail over before output is committed.

### Antigravity

OMP's Antigravity variant changes the OAuth client, scopes, callback, control-plane endpoint, free-tier eligibility checks, and onboarding metadata. Its streaming delta adds:

- daily and sandbox endpoint failover;
- sticky last-good endpoint;
- per-conversation agent and trajectory UUIDs;
- signed-decimal session ID;
- monotonic step index and `last_execution_id`;
- model-specific wire profiles;
- Antigravity client fingerprint headers;
- default `VALIDATED` tool behavior;
- Claude-specific thinking headers;
- a forced-tool fallback for Gemini routes.

This uses undocumented `v1internal` services and mirrors client fingerprints. It should be isolated behind an experimental provider flag and verified with a live canary.

Google also provides an official Antigravity managed agent through the Gemini Interactions API. It is not a drop-in model provider: it owns a remote agent/tool loop and sandbox, overlapping AFX's runtime. Use Gemini API or Vertex for ordinary AFX completions. Implement the private Cloud Code Antigravity route only when subscription-backed raw Gemini, Claude, or GPT-OSS access is an explicit requirement.

## Implementation order

1. Move the existing three providers into one registry without changing behavior.
2. Add generic provider model preferences and authentication dispatch.
3. Add generic OpenAI completions/responses configuration and the high-value API-key providers.
4. Add official Gemini API, sharing message conversion and SSE parsing with later Google transports.
5. Add Vertex AI.
6. Add Google OAuth, Cloud Code project discovery, and Gemini CLI transport.
7. Add Antigravity as an experimental Cloud Code variant.
8. Add Anthropic, Azure, Bedrock, and Ollama families.
9. Add subscription proxies and proprietary protocols last.

Current status: steps 1–8 and the OpenAI-compatible proxy portion of step 9 are implemented. Cursor, Devin, and GitLab Duo remain remote-agent protocols rather than AFX model providers.

## Verification contract

Every wire family must cover:

- text streaming;
- streamed tool calls and arguments;
- reasoning or thought output;
- usage accounting;
- images and structured output when advertised;
- malformed and in-band errors;
- HTTP 401, 429, and transient 5xx behavior;
- cancellation, delivery certainty, and retry ownership.

Every OAuth provider must cover:

- state and PKCE validation;
- invalid callback handling;
- refresh-token retention when refresh omits a replacement;
- expiry skew;
- cancellation and bounded provisioning;
- secure persistence.

Google Cloud Code additionally requires free and organization project discovery, onboarding timeout, VPC-SC handling, two-turn provider state, silent-stream failover, Gemini and Claude tool-call fixtures, and one live OAuth-to-refresh smoke test.

## Risks

- OMP is MIT licensed; retain its copyright and license notice when copying substantial code.
- Do not reuse OMP's embedded OAuth client credentials.
- Google's Cloud Platform and Antigravity scopes may require consent-screen review.
- Cloud Code `v1internal` endpoints and Antigravity fingerprints can change without notice and may carry service-policy risk.
- Do not import OMP's credential-broker complexity until AFX needs multiple accounts per provider.

## Sources

- [OMP provider guide](https://github.com/can1357/oh-my-pi/blob/main/docs/adding-a-provider.md)
- [OMP provider registry](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/registry/registry.ts)
- [OMP wire API map](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/types.ts)
- [OMP shared Google OAuth](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/registry/oauth/google-oauth-shared.ts)
- [OMP Gemini CLI OAuth](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/registry/oauth/google-gemini-cli.ts)
- [OMP Antigravity OAuth](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/registry/oauth/google-antigravity.ts)
- [OMP Cloud Code transport](https://github.com/can1357/oh-my-pi/blob/main/packages/ai/src/providers/google-gemini-cli.ts)
- [Google desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Gemini CLI authentication](https://geminicli.com/docs/get-started/authentication/)
- [Official Antigravity managed agent](https://ai.google.dev/gemini-api/docs/antigravity-agent)
