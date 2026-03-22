package com.cclaude

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.cclaude.ui.pages.ChatPage
import com.cclaude.ui.theme.CClaudeTheme
import java.io.File

class MainActivity : ComponentActivity() {
    companion object {
        var importedFilePath: String? = null
    }

    private val pickDocument = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            val importedDir = File(filesDir, "imports")
            importedDir.mkdirs()
            val name = queryDisplayName(uri) ?: "imported_file.txt"
            val outFile = File(importedDir, name)
            contentResolver.openInputStream(uri)?.use { input ->
                outFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            importedFilePath = outFile.absolutePath
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            CClaudeTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ChatPage(
                        onPickDocument = {
                            pickDocument.launch(arrayOf("text/*", "application/octet-stream"))
                        },
                        importedFilePath = importedFilePath
                    )
                }
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val idx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && cursor.moveToFirst()) return cursor.getString(idx)
        }
        return null
    }
}
