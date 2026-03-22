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
    }

    suspend fun initialize(apiKey: String = providerConfig.apiKey): Boolean = withContext(Dispatchers.IO) {
        val dataDir = context.filesDir.absolutePath + "/agent"
        providerConfig = providerConfig.copy(apiKey = apiKey)
        providerManager.save(providerConfig)

        CClaudeNative.setHttpCallback(object : HttpCallback {
            override fun execute(url: String, headers: String, body: ByteArray): String {
                return executeHttpRequest(url, headers, body)
            }
        })

        val result = CClaudeNative.init(dataDir, apiKey)
        _isInitialized.value = result == 0
        updateUndoRedoState()
        result == 0
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
            when (providerConfig.providerType) {
                ProviderType.CLAUDE, ProviderType.CLAUDE_COMPAT -> executeClaudeCompatible(body)
                ProviderType.OPENAI_COMPAT -> executeOpenAICompatible(body)
            }
        } catch (e: Exception) {
            "500:${e.message}"
        }
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
        val openAiBody = """
            {
              "model": "${providerConfig.model}",
              "messages": [
                {"role": "system", "content": "${escapeJson(system)}"},
                {"role": "user", "content": "${escapeJson(user)}"}
              ],
              "temperature": 0.2
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
            val text = raw.substringAfter("\"content\":\"").substringBefore("\"")
            val wrapped = "{\"content\":[{\"type\":\"text\",\"text\":\"${escapeJson(text)}\"}]}"
            return "${response.code}:$wrapped"
        }
    }

    private fun escapeJson(s: String): String = s
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
        .replace("\r", "")
}
