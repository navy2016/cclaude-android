#include <jni.h>
#include <string>
#include <cstring>
#include <android/log.h>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "CClaude", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "CClaude", __VA_ARGS__)

// Zig function declarations
extern "C" {
    int cclaude_init(const char* data_dir, const char* api_key);
    void cclaude_free();
    const char* cclaude_send(const char* message, void (*token_callback)(const char*));
    int cclaude_undo();
    int cclaude_redo();
    int cclaude_can_undo();
    int cclaude_can_redo();
    const char* cclaude_get_undo_description();
    const char* cclaude_get_redo_description();
    int cclaude_rollback_conversation();
    void cclaude_set_http_callback(const char* (*callback)(const char*, const char*, const char*, size_t));
    void cclaude_set_approval_callback(int (*callback)(const char*, const char*));
    void cclaude_free_string(const char* s);
}

// Global JVM reference for callbacks
static JavaVM* g_vm = nullptr;
static jobject g_http_callback = nullptr;
static jobject g_approval_callback = nullptr;
static jobject g_token_callback = nullptr;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_vm = vm;
    return JNI_VERSION_1_6;
}

// HTTP callback from Zig
static const char* http_callback(const char* url, const char* headers, const char* body, size_t body_len) {
    if (!g_http_callback || !g_vm) return "";
    
    JNIEnv* env;
    jint attach_result = g_vm->AttachCurrentThread(&env, nullptr);
    if (attach_result != 0) return "";
    
    // Call Kotlin HTTP handler
    jclass cls = env->GetObjectClass(g_http_callback);
    jmethodID method = env->GetMethodID(cls, "execute", "(Ljava/lang/String;Ljava/lang/String;[B)Ljava/lang/String;");
    
    jstring jurl = env->NewStringUTF(url);
    jstring jheaders = env->NewStringUTF(headers);
    jbyteArray jbody = env->NewByteArray(body_len);
    env->SetByteArrayRegion(jbody, 0, body_len, (jbyte*)body);
    
    jstring result = (jstring)env->CallObjectMethod(g_http_callback, method, jurl, jheaders, jbody);
    
    const char* result_str = env->GetStringUTFChars(result, nullptr);
    static std::string response;
    response = result_str;
    env->ReleaseStringUTFChars(result, result_str);
    
    if (attach_result == JNI_EDETACHED) {
        g_vm->DetachCurrentThread();
    }
    
    return response.c_str();
}

// Token callback from Zig
static void token_callback(const char* token) {
    if (!g_token_callback || !g_vm) return;
    
    JNIEnv* env;
    jint attach_result = g_vm->AttachCurrentThread(&env, nullptr);
    if (attach_result != 0) return;
    
    jclass cls = env->GetObjectClass(g_token_callback);
    jmethodID method = env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)V");
    
    jstring jtoken = env->NewStringUTF(token);
    env->CallVoidMethod(g_token_callback, method, jtoken);
    
    if (attach_result == JNI_EDETACHED) {
        g_vm->DetachCurrentThread();
    }
}

// Approval callback from Zig
static int approval_callback(const char* tool_name, const char* args) {
    if (!g_approval_callback || !g_vm) return 0;
    
    JNIEnv* env;
    jint attach_result = g_vm->AttachCurrentThread(&env, nullptr);
    if (attach_result != 0) return 0;
    
    jclass cls = env->GetObjectClass(g_approval_callback);
    jmethodID method = env->GetMethodID(cls, "requestApproval", "(Ljava/lang/String;Ljava/lang/String;)Z");
    
    jstring jtool = env->NewStringUTF(tool_name);
    jstring jargs = env->NewStringUTF(args);
    
    jboolean result = env->CallBooleanMethod(g_approval_callback, method, jtool, jargs);
    
    if (attach_result == JNI_EDETACHED) {
        g_vm->DetachCurrentThread();
    }
    
    return result ? 1 : 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_cclaude_zig_CClaudeNative_init(
    JNIEnv* env,
    jclass clazz,
    jstring data_dir,
    jstring api_key
) {
    const char* c_data_dir = env->GetStringUTFChars(data_dir, nullptr);
    const char* c_api_key = env->GetStringUTFChars(api_key, nullptr);
    
    int result = cclaude_init(c_data_dir, c_api_key);
    
    env->ReleaseStringUTFChars(data_dir, c_data_dir);
    env->ReleaseStringUTFChars(api_key, c_api_key);
    
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_cclaude_zig_CClaudeNative_free(JNIEnv* env, jclass clazz) {
    cclaude_free();
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_cclaude_zig_CClaudeNative_send(
    JNIEnv* env,
    jclass clazz,
    jstring message,
    jobject token_callback_obj
) {
    g_token_callback = env->NewGlobalRef(token_callback_obj);
    
    const char* c_message = env->GetStringUTFChars(message, nullptr);
    const char* result = cclaude_send(c_message, token_callback);
    
    env->ReleaseStringUTFChars(message, c_message);
    
    jstring jresult = env->NewStringUTF(result);
    cclaude_free_string(result);
    
    return jresult;
}

extern "C" JNIEXPORT void JNICALL
Java_com_cclaude_zig_CClaudeNative_setHttpCallback(
    JNIEnv* env,
    jclass clazz,
    jobject callback
) {
    if (g_http_callback) {
        env->DeleteGlobalRef(g_http_callback);
    }
    g_http_callback = env->NewGlobalRef(callback);
    cclaude_set_http_callback(http_callback);
}

extern "C" JNIEXPORT void JNICALL
Java_com_cclaude_zig_CClaudeNative_setApprovalCallback(
    JNIEnv* env,
    jclass clazz,
    jobject callback
) {
    if (g_approval_callback) {
        env->DeleteGlobalRef(g_approval_callback);
    }
    g_approval_callback = env->NewGlobalRef(callback);
    cclaude_set_approval_callback(approval_callback);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_cclaude_zig_CClaudeNative_undo(JNIEnv* env, jclass clazz) {
    return cclaude_undo() == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_cclaude_zig_CClaudeNative_redo(JNIEnv* env, jclass clazz) {
    return cclaude_redo() == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_cclaude_zig_CClaudeNative_canUndo(JNIEnv* env, jclass clazz) {
    return cclaude_can_undo() == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_cclaude_zig_CClaudeNative_canRedo(JNIEnv* env, jclass clazz) {
    return cclaude_can_redo() == 1 ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_cclaude_zig_CClaudeNative_getUndoDescription(JNIEnv* env, jclass clazz) {
    const char* s = cclaude_get_undo_description();
    if (!s) return nullptr;
    jstring result = env->NewStringUTF(s);
    cclaude_free_string(s);
    return result;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_cclaude_zig_CClaudeNative_getRedoDescription(JNIEnv* env, jclass clazz) {
    const char* s = cclaude_get_redo_description();
    if (!s) return nullptr;
    jstring result = env->NewStringUTF(s);
    cclaude_free_string(s);
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_cclaude_zig_CClaudeNative_rollbackConversation(JNIEnv* env, jclass clazz) {
    return cclaude_rollback_conversation();
}
