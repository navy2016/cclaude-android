package com.cclaude.zig

data class ProviderTestResult(
    val ok: Boolean,
    val statusCode: Int,
    val message: String,
    val latencyMs: Long
)
