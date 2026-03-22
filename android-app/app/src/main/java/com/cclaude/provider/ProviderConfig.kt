package com.cclaude.provider

enum class ProviderType {
    CLAUDE,
    OPENAI_COMPAT,
    CLAUDE_COMPAT
}

data class ProviderConfig(
    val providerType: ProviderType = ProviderType.CLAUDE,
    val name: String = "Default",
    val apiKey: String = "",
    val baseUrl: String = "https://api.anthropic.com/v1",
    val model: String = "claude-3-5-sonnet-20241022",
    val chatPath: String = "/chat/completions"
)
