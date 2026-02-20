package com.lifeos.anyware

import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.lifeos.anyware/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTV" -> {
                        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                        val isTV = uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                        result.success(isTV)
                    }
                    "scanFile" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            MediaScannerConnection.scanFile(
                                applicationContext,
                                arrayOf(path),
                                null
                            ) { _, uri ->
                                result.success(uri?.toString())
                            }
                        } else {
                            result.error("INVALID_ARGS", "path argument is required", null)
                        }
                    }
                    "openFile" -> {
                        val path = call.argument<String>("path")
                        val mimeType = call.argument<String>("mimeType")
                        if (path != null) {
                            try {
                                val file = File(path)
                                if (!file.exists()) {
                                    result.error("FILE_NOT_FOUND", "File not found: $path", null)
                                    return@setMethodCallHandler
                                }

                                val resolvedMimeType = mimeType
                                    ?: MimeTypeMap.getSingleton()
                                        .getMimeTypeFromExtension(file.extension.lowercase())
                                    ?: "*/*"

                                // APK files: check install permission first
                                if (resolvedMimeType == "application/vnd.android.package-archive") {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                        if (!packageManager.canRequestPackageInstalls()) {
                                            val settingsIntent = Intent(
                                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                                Uri.parse("package:$packageName")
                                            )
                                            settingsIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                            startActivity(settingsIntent)
                                            result.success(false)
                                            return@setMethodCallHandler
                                        }
                                    }
                                }

                                val uri = FileProvider.getUriForFile(
                                    this@MainActivity,
                                    "${packageName}.fileprovider",
                                    file
                                )

                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, resolvedMimeType)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }

                                try {
                                    startActivity(intent)
                                    result.success(true)
                                } catch (e: ActivityNotFoundException) {
                                    val chooser = Intent.createChooser(intent, file.name)
                                    chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    try {
                                        startActivity(chooser)
                                        result.success(true)
                                    } catch (e2: Exception) {
                                        result.error("NO_APP", "No app to open: $resolvedMimeType", null)
                                    }
                                }
                            } catch (e: IllegalArgumentException) {
                                result.error("PROVIDER_ERROR", "FileProvider error: ${e.message}", null)
                            } catch (e: Exception) {
                                result.error("OPEN_ERROR", "Failed to open file: ${e.message}", null)
                            }
                        } else {
                            result.error("INVALID_ARGS", "path argument is required", null)
                        }
                    }
                    "openFolder" -> {
                        val path = call.argument<String>("path")
                        if (path != null) {
                            try {
                                val file = File(path)
                                val dir = if (file.isDirectory) file else file.parentFile

                                // Build a content URI for the Downloads provider
                                val relativePath = dir?.absolutePath
                                    ?.removePrefix("/storage/emulated/0/") ?: ""
                                val encodedPath = Uri.encode(relativePath, "/")
                                val uri = Uri.parse(
                                    "content://com.android.externalstorage.documents/document/primary:$encodedPath"
                                )

                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "vnd.android.document/directory")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }

                                try {
                                    startActivity(intent)
                                    result.success(true)
                                } catch (e: ActivityNotFoundException) {
                                    // Fallback: open system file manager via BROWSE_DOCUMENT
                                    val browseIntent = Intent("android.provider.action.BROWSE").apply {
                                        data = uri
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    try {
                                        startActivity(browseIntent)
                                        result.success(true)
                                    } catch (e2: ActivityNotFoundException) {
                                        // Last resort: just open Files app
                                        val filesIntent = Intent(Intent.ACTION_VIEW).apply {
                                            data = Uri.parse("content://com.android.externalstorage.documents/root/primary")
                                            type = "vnd.android.document/root"
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        }
                                        try {
                                            startActivity(filesIntent)
                                            result.success(true)
                                        } catch (e3: Exception) {
                                            result.error("NO_FILE_MANAGER", "No file manager found", null)
                                        }
                                    }
                                }
                            } catch (e: Exception) {
                                result.error("OPEN_ERROR", "Failed to open folder: ${e.message}", null)
                            }
                        } else {
                            result.error("INVALID_ARGS", "path argument is required", null)
                        }
                    }
                    "updateDirectShareTargets" -> {
                        @Suppress("UNCHECKED_CAST")
                        val devices = call.argument<List<Map<String, Any>>>("devices")
                        if (devices != null) {
                            DirectShareService.updateShortcuts(applicationContext, devices)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "devices argument is required", null)
                        }
                    }
                    "clearDirectShareTargets" -> {
                        DirectShareService.clearShortcuts(applicationContext)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
