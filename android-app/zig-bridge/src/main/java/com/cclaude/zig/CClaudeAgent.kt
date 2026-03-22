package com.cclaude.zig

import android.content.Context
import com.cclaude.provider.ProviderConfig
import com.cclaude.provider.ProviderManager
import com.cclaude.provider.ProviderType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class CClaudeAgent(private val context: Context) {
    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized

    private val _canUndo = MutableStateFlow(false)
    val canUndo: StateFlow<Boolean> = _canUndo

    private val _canRedo = MutableStateFlow(false)
    val canRedo: StateFlow<Boolean> = _canRedo

    private val _undoDescription = MutableStateFlow<String?>(null)
    val undoDescription: StateFlow<String?> = _undoDescription

    private val _redoDescription = MutableStateFlow<String?>(null)
    val redoDescription: StateFlow<String?> = _redoDescription

    private val client = OkHttpClient()
    private val providerManager = ProviderManager(context)
    private var providerConfig: ProviderConfig = providerManager.load()

    fun getProviderConfig(): ProviderConfig = providerConfig

    fun updateProviderConfig(config: ProviderConfig) {
        providerConfig = config
        providerManager.save(config)
        CClaudeNative.free()
        _isInitialized.value = false
    }

    suspend fun initialize(apiKey: String = providerConfig.apiKey): Boolean = withContext(Dispatchers.IO) {
        val dataDir = context.filesDir.absolutePath + "/agent"
        providerConfig = providerConfig.copy(apiKey = apiKey)
        providerManager.save(providerConfig)

        val result = CClaudeNative.init(dataDir, apiKey)
        if (result == 0) {
            CClaudeNative.setHttpCallback(object : HttpCallback {
                override fun execute(url: String, headers: String, body: ByteArray): String {
                    return executeHttpRequest(url, headers, body)
                }
            })
        }
        _isInitialized.value = result == 0
        updateUndoRedoState()
        result == 0
    }


    suspend fun testProviderConnection(): ProviderTestResult = withContext(Dispatchers.IO) {
        val start = System.currentTimeMillis()
        return@withContext try {
            when (providerConfig.providerType) {
                ProviderType.CLAUDE, ProviderType.CLAUDE_COMPAT -> {
                    val body = "{\"model\":\"${providerConfig.model}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
                    val req = Request.Builder()
                        .url(providerConfig.baseUrl.trimEnd('/') + "/messages")
                        .post(body.toRequestBody("application/json".toMediaType()))
                        .header("Content-Type", "application/json")
                        .header("x-api-key", providerConfig.apiKey)
                        .header("anthropic-version", "2023-06-01")
                        .build()
                    client.newCall(req).execute().use { r ->
                        ProviderTestResult(r.isSuccessful, r.code, r.body?.string() ?: "", System.currentTimeMillis() - start)
                    }
                }
                ProviderType.OPENAI_COMPAT -> {
                    val temperature = if (providerConfig.model.contains("kimi-k2.5", ignoreCase = true)) "1" else "0.2"
                    val body = "{\"model\":\"${providerConfig.model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"temperature\":$temperature,\"stream\":false}"
                    val req = Request.Builder()
                        .url(providerConfig.baseUrl.trimEnd('/') + providerConfig.chatPath)
                        .post(body.toRequestBody("application/json".toMediaType()))
                        .header("Content-Type", "application/json")
                        .header("Authorization", "Bearer ${providerConfig.apiKey}")
                        .build()
                    client.newCall(req).execute().use { r ->
                        ProviderTestResult(r.isSuccessful, r.code, r.body?.string() ?: "", System.currentTimeMillis() - start)
                    }
                }
            }
        } catch (e: Exception) {
            ProviderTestResult(false, 500, e.message ?: "unknown", System.currentTimeMillis() - start)
        }
    }

    suspend fun sendMessage(message: String, onToken: (String) -> Unit): String = withContext(Dispatchers.IO) {
        val callback = object : TokenCallback {
            override fun onToken(token: String) {
                onToken(token)
            }
        }
        val result = CClaudeNative.send(message, callback)
        updateUndoRedoState()
        result
    }

    suspend fun undo(): Boolean = withContext(Dispatchers.IO) {
        val result = CClaudeNative.undo()
        updateUndoRedoState()
        result
    }

    suspend fun redo(): Boolean = withContext(Dispatchers.IO) {
        val result = CClaudeNative.redo()
        updateUndoRedoState()
        result
    }

    suspend fun rollbackConversation(): Boolean = withContext(Dispatchers.IO) {
        val result = CClaudeNative.rollbackConversation()
        updateUndoRedoState()
        result == 0
    }

    fun setApprovalCallback(callback: ApprovalCallback) {
        CClaudeNative.setApprovalCallback(callback)
    }

    fun destroy() {
        CClaudeNative.free()
        _isInitialized.value = false
    }

    private fun updateUndoRedoState() {
        _canUndo.value = CClaudeNative.canUndo()
        _canRedo.value = CClaudeNative.canRedo()
        _undoDescription.value = CClaudeNative.getUndoDescription()
        _redoDescription.value = CClaudeNative.getRedoDescription()
    }

    private fun executeHttpRequest(url: String, headers: String, body: ByteArray): String {
        return try {
            val method = extractMethod(headers)
            val isLlmRequest = url.contains("anthropic.com/v1/messages") ||
                headers.contains("anthropic-version") ||
                headers.contains("x-api-key")

            if (!isLlmRequest) {
                return executeRawHttpRequest(url, method, headers, body)
            }

            when (providerConfig.providerType) {
                ProviderType.CLAUDE, ProviderType.CLAUDE_COMPAT -> executeClaudeCompatible(body)
                ProviderType.OPENAI_COMPAT -> executeOpenAICompatible(body)
            }
        } catch (e: Exception) {
            val msg = escapeJson(e.message ?: "unknown")
            "500:{\"content\":[{\"type\":\"text\",\"text\":\"Provider HTTP error: $msg\"}]}"
        }
    }

    private fun executeRawHttpRequest(url: String, method: String, headers: String, body: ByteArray): String {
        val requestBuilder = Request.Builder().url(url)

        headers.lines().forEach { line ->
            val parts = line.split(":", limit = 2)
            if (parts.size == 2 && parts[0].trim() != "METHOD") {
                requestBuilder.header(parts[0].trim(), parts[1].trim())
            }
        }

        when (method.uppercase()) {
            "GET" -> requestBuilder.get()
            "POST" -> requestBuilder.post(body.toRequestBody("application/json".toMediaType()))
            else -> requestBuilder.get()
        }

        client.newCall(requestBuilder.build()).execute().use { response ->
            val bodyStr = response.body?.string() ?: ""
            return "${response.code}:$bodyStr"
        }
    }

    private fun extractMethod(headers: String): String {
        return headers.lines()
            .firstOrNull { it.startsWith("METHOD:") }
            ?.substringAfter(":")
            ?.trim()
            ?: "POST"
    }

    private fun executeClaudeCompatible(body: ByteArray): String {
        val request = Request.Builder()
            .url(providerConfig.baseUrl.trimEnd('/') + "/messages")
            .post(body.toRequestBody("application/json".toMediaType()))
            .header("Content-Type", "application/json")
            .header("x-api-key", providerConfig.apiKey)
            .header("anthropic-version", "2023-06-01")
            .build()
        client.newCall(request).execute().use { response ->
            val bodyStr = response.body?.string() ?: ""
            return "${response.code}:$bodyStr"
        }
    }

    private fun executeOpenAICompatible(body: ByteArray): String {
        val anthropicJson = String(body)
        val system = anthropicJson.substringAfter("\"system\":\"").substringBefore("\"")
        val user = anthropicJson.substringAfter("\"content\":\"").substringBefore("\"")
        val temperature = if (providerConfig.model.contains("kimi-k2.5", ignoreCase = true)) "1" else "0.2"
        val openAiBody = """
            {
              "model": "${providerConfig.model}",
              "messages": [
                {"role": "system", "content": "${escapeJson(system)}"},
                {"role": "user", "content": "${escapeJson(user)}"}
              ],
              "temperature": $temperature,
              "stream": false
            }
        """.trimIndent()

        val request = Request.Builder()
            .url(providerConfig.baseUrl.trimEnd('/') + providerConfig.chatPath)
            .post(openAiBody.toRequestBody("application/json".toMediaType()))
            .header("Content-Type", "application/json")
            .header("Authorization", "Bearer ${providerConfig.apiKey}")
            .build()

        client.newCall(request).execute().use { response ->
            val raw = response.body?.string() ?: ""
            val text = extractOpenAiText(raw)
            val wrapped = "{\"content\":[{\"type\":\"text\",\"text\":\"${escapeJson(text)}\"}]}"
            return "${response.code}:$wrapped"
        }
    }

    private fun extractOpenAiText(raw: String): String {
        return when {
            raw.contains("\"choices\"") && raw.contains("\"message\"") && raw.contains("\"content\"") ->
                raw.substringAfter("\"content\":\"").substringBefore("\"", missingDelimiterValue = raw)
            raw.contains("\"output_text\"") ->
                raw.substringAfter("\"output_text\":\"").substringBefore("\"", missingDelimiterValue = raw)
            else -> raw
        }
    }

    private fun escapeJson(s: String): String = s
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "")
}
