package com.cclaude.zig

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * High-level Kotlin wrapper for CClaude Agent with Undo/Redo
 */
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
    
    suspend fun initialize(apiKey: String): Boolean = withContext(Dispatchers.IO) {
        val dataDir = context.filesDir.absolutePath + "/agent"
        
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
    
    suspend fun sendMessage(
        message: String,
        onToken: (String) -> Unit
    ): String = withContext(Dispatchers.IO) {
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
            val requestBody = body.toRequestBody("application/json".toMediaType())
            val request = Request.Builder()
                .url(url)
                .post(requestBody)
                .header("Content-Type", "application/json")
                .apply {
                    headers.lines().forEach { line ->
                        val parts = line.split(":", limit = 2)
                        if (parts.size == 2) {
                            header(parts[0].trim(), parts[1].trim())
                        }
                    }
                }
                .build()
            
            client.newCall(request).execute().use { response ->
                val bodyStr = response.body?.string() ?: ""
                "${response.code}:$bodyStr"
            }
        } catch (e: Exception) {
            "500:${e.message}"
        }
    }
}
