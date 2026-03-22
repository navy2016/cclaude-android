package com.cclaude.zig

/**
 * JNI bridge to Zig-native CClaude Agent with Undo/Redo Support
 */
object CClaudeNative {
    init {
        System.loadLibrary("cclaude-jni")
    }
    
    @JvmStatic
    external fun init(dataDir: String, apiKey: String): Int
    
    @JvmStatic
    external fun free()
    
    @JvmStatic
    external fun send(message: String, tokenCallback: TokenCallback): String
    
    // Undo/Redo
    @JvmStatic
    external fun undo(): Boolean
    
    @JvmStatic
    external fun redo(): Boolean
    
    @JvmStatic
    external fun canUndo(): Boolean
    
    @JvmStatic
    external fun canRedo(): Boolean
    
    @JvmStatic
    external fun getUndoDescription(): String?
    
    @JvmStatic
    external fun getRedoDescription(): String?
    
    @JvmStatic
    external fun rollbackConversation(): Int
    
    // Callbacks
    @JvmStatic
    external fun setHttpCallback(callback: HttpCallback)
    
    @JvmStatic
    external fun setApprovalCallback(callback: ApprovalCallback)
}

interface TokenCallback {
    fun onToken(token: String)
}

interface HttpCallback {
    fun execute(url: String, headers: String, body: ByteArray): String
}

interface ApprovalCallback {
    fun requestApproval(toolName: String, args: String): Boolean
}
