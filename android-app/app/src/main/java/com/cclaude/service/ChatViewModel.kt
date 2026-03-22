package com.cclaude.service

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.cclaude.data.Message
import com.cclaude.data.MessageRole
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class ChatViewModel(application: Application) : AndroidViewModel(application) {
    private val _messages = MutableStateFlow<List<Message>>(emptyList())
    val messages: StateFlow<List<Message>> = _messages.asStateFlow()
    
    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()
    
    private val _isInitialized = MutableStateFlow(false)
    val isInitialized: StateFlow<Boolean> = _isInitialized.asStateFlow()
    
    private val _canUndo = MutableStateFlow(false)
    val canUndo: StateFlow<Boolean> = _canUndo.asStateFlow()
    
    private val _canRedo = MutableStateFlow(false)
    val canRedo: StateFlow<Boolean> = _canRedo.asStateFlow()
    
    private val _showSettings = MutableStateFlow(false)
    val showSettings: StateFlow<Boolean> = _showSettings.asStateFlow()
    
    init {
        _isInitialized.value = true
    }
    
    suspend fun initialize(apiKey: String): Boolean {
        _isInitialized.value = true
        _showSettings.value = false
        return true
    }
    
    suspend fun sendMessage(content: String) {
        if (!_isInitialized.value) {
            _showSettings.value = true
            return
        }
        
        val userMessage = Message(role = MessageRole.USER, content = content)
        _messages.value = _messages.value + userMessage
        
        _isLoading.value = true
        
        try {
            val assistantMessage = Message(
                role = MessageRole.ASSISTANT,
                content = "CClaude Agent is ready! (Zig integration coming soon)",
                isStreaming = false
            )
            _messages.value = _messages.value + assistantMessage
        } catch (e: Exception) {
            val errorMessage = Message(
                role = MessageRole.SYSTEM,
                content = "Error: ${e.message}"
            )
            _messages.value = _messages.value + errorMessage
        } finally {
            _isLoading.value = false
        }
    }
    
    suspend fun undo(): Boolean = false
    suspend fun redo(): Boolean = false
    
    fun clearChat() {
        _messages.value = emptyList()
    }
    
    fun showSettings() {
        _showSettings.value = true
    }
    
    fun dismissSettings() {
        _showSettings.value = false
    }
}
