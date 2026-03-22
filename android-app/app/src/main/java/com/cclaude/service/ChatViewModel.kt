package com.cclaude.service

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.cclaude.data.Message
import com.cclaude.data.MessageRole
import com.cclaude.zig.CClaudeAgent
import com.cclaude.zig.ApprovalCallback
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.SharingStarted

class ChatViewModel(application: Application) : AndroidViewModel(application) {
    private val agent = CClaudeAgent(application)

    private val _messages = MutableStateFlow<List<Message>>(emptyList())
    val messages: StateFlow<List<Message>> = _messages.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()

    private val _localCanUndo = MutableStateFlow(false)
    private val _localCanRedo = MutableStateFlow(false)

    val canUndo: StateFlow<Boolean> = combine(agent.canUndo, _localCanUndo) { a, b -> a || b }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)
    val canRedo: StateFlow<Boolean> = combine(agent.canRedo, _localCanRedo) { a, b -> a || b }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    val undoDescription: StateFlow<String?> = agent.undoDescription
    val redoDescription: StateFlow<String?> = agent.redoDescription

    private val _showSettings = MutableStateFlow(false)
    val showSettings: StateFlow<Boolean> = _showSettings.asStateFlow()

    private val undoSnapshots = ArrayDeque<List<Message>>()
    private val redoSnapshots = ArrayDeque<List<Message>>()

    init {
        agent.setApprovalCallback(object : ApprovalCallback {
            override fun requestApproval(toolName: String, args: String): Boolean {
                return toolName in listOf("readfile", "search", "glob")
            }
        })

        viewModelScope.launch {
            val prefs = application.getSharedPreferences("cclaude", Application.MODE_PRIVATE)
            val apiKey = prefs.getString("api_key", "") ?: ""
            initialize(apiKey)
        }
    }

    private fun syncLocalUndoState() {
        _localCanUndo.value = undoSnapshots.isNotEmpty()
        _localCanRedo.value = redoSnapshots.isNotEmpty()
    }

    suspend fun initialize(apiKey: String): Boolean {
        val success = agent.initialize(apiKey)
        _isInitialized.value = success
        if (success) {
            getApplication<Application>().getSharedPreferences("cclaude", Application.MODE_PRIVATE)
                .edit()
                .putString("api_key", apiKey)
                .apply()
            _showSettings.value = false
        }
        syncLocalUndoState()
        return success
    }

    private fun pushUndoSnapshot() {
        undoSnapshots.addLast(_messages.value.map { it.copy() })
        if (undoSnapshots.size > 100) undoSnapshots.removeFirst()
        redoSnapshots.clear()
        syncLocalUndoState()
    }

    suspend fun sendMessage(content: String) {
        if (!_isInitialized.value) {
            _showSettings.value = true
            return
        }

        pushUndoSnapshot()

        val userMessage = Message(role = MessageRole.USER, content = content)
        _messages.value = _messages.value + userMessage
        _isLoading.value = true

        try {
            val assistantMessage = Message(
                role = MessageRole.ASSISTANT,
                content = "",
                isStreaming = true
            )
            _messages.value = _messages.value + assistantMessage

            val responseBuilder = StringBuilder()
            val result = agent.sendMessage(content) { token: String ->
                responseBuilder.append(token)
                val updated = _messages.value.toMutableList()
                val lastIndex = updated.size - 1
                if (lastIndex >= 0) {
                    updated[lastIndex] = assistantMessage.copy(
                        content = responseBuilder.toString(),
                        isStreaming = true
                    )
                    _messages.value = updated
                }
            }

            val finalText = if (responseBuilder.isNotEmpty()) responseBuilder.toString() else result
            val updated = _messages.value.toMutableList()
            val lastIndex = updated.size - 1
            if (lastIndex >= 0) {
                updated[lastIndex] = assistantMessage.copy(
                    content = finalText,
                    isStreaming = false
                )
                _messages.value = updated
            }
        } catch (e: Exception) {
            _messages.value = _messages.value + Message(
                role = MessageRole.SYSTEM,
                content = "Error: ${e.message}"
            )
        } finally {
            _isLoading.value = false
            syncLocalUndoState()
        }
    }

    suspend fun undo(): Boolean {
        val nativeOk = agent.undo()
        if (undoSnapshots.isNotEmpty()) {
            redoSnapshots.addLast(_messages.value.map { it.copy() })
            _messages.value = undoSnapshots.removeLast()
            syncLocalUndoState()
            return true
        }
        syncLocalUndoState()
        return nativeOk
    }

    suspend fun redo(): Boolean {
        val nativeOk = agent.redo()
        if (redoSnapshots.isNotEmpty()) {
            undoSnapshots.addLast(_messages.value.map { it.copy() })
            _messages.value = redoSnapshots.removeLast()
            syncLocalUndoState()
            return true
        }
        syncLocalUndoState()
        return nativeOk
    }

    fun clearChat() {
        pushUndoSnapshot()
        _messages.value = emptyList()
        syncLocalUndoState()
    }

    fun showSettings() {
        _showSettings.value = true
    }

    fun dismissSettings() {
        _showSettings.value = false
    }

    override fun onCleared() {
        super.onCleared()
        agent.destroy()
    }
}
