package com.cclaude.data

data class Message(
    val id: String = System.currentTimeMillis().toString(),
    val role: MessageRole,
    val content: String,
    val isStreaming: Boolean = false
)

enum class MessageRole {
    USER,
    ASSISTANT,
    SYSTEM,
    TOOL
}
