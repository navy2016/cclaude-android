package com.cclaude.provider

import android.content.Context

class ProviderManager(private val context: Context) {
    private val prefs = context.getSharedPreferences("cclaude_provider", Context.MODE_PRIVATE)

    fun load(): ProviderConfig {
        val typeName = prefs.getString("provider_type", ProviderType.CLAUDE.name) ?: ProviderType.CLAUDE.name
        val type = runCatching { ProviderType.valueOf(typeName) }.getOrDefault(ProviderType.CLAUDE)
        return ProviderConfig(
            providerType = type,
            name = prefs.getString("provider_name", "Default") ?: "Default",
            apiKey = prefs.getString("api_key", "") ?: "",
            baseUrl = prefs.getString("base_url", defaultBaseUrl(type)) ?: defaultBaseUrl(type),
            model = prefs.getString("model", defaultModel(type)) ?: defaultModel(type),
            chatPath = prefs.getString("chat_path", "/chat/completions") ?: "/chat/completions"
        )
    }

    fun save(config: ProviderConfig) {
        prefs.edit()
            .putString("provider_type", config.providerType.name)
            .putString("provider_name", config.name)
            .putString("api_key", config.apiKey)
            .putString("base_url", config.baseUrl)
            .putString("model", config.model)
            .putString("chat_path", config.chatPath)
            .apply()
    }

    companion object {
        fun defaultBaseUrl(type: ProviderType): String = when (type) {
            ProviderType.CLAUDE -> "https://api.anthropic.com/v1"
            ProviderType.OPENAI_COMPAT -> "https://api.openai.com/v1"
            ProviderType.CLAUDE_COMPAT -> "https://api.anthropic.com/v1"
        }

        fun defaultModel(type: ProviderType): String = when (type) {
            ProviderType.CLAUDE -> "claude-3-5-sonnet-20241022"
            ProviderType.OPENAI_COMPAT -> "gpt-4o-mini"
            ProviderType.CLAUDE_COMPAT -> "claude-3-5-sonnet-20241022"
        }
    }
}
