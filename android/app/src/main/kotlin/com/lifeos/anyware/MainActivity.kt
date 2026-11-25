package com.lifeos.anyware

import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.provider.DocumentsContract
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.lifeos.anyware/platform"
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Syncthing is run from here (lib/features/esitleme/data/syncthing.dart)
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    // where the app was installed from (Google Play updates it itself)
                    "installerPackage" -> result.success(
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                packageManager.getInstallSourceInfo(packageName).installingPackageName
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getInstallerPackageName(packageName)
                            }
                        } catch (_: Exception) {
                            null
                        }
                    )
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
                                val mimeCandidates = linkedSetOf(
                                    resolvedMimeType,
                                    if (resolvedMimeType.contains('/')) {
                                        "${resolvedMimeType.substringBefore('/')}/*"
                                    } else {
                                        "*/*"
                                    },
                                    "*/*"
                                )

                                // Just try: asking resolveActivity() first answered "no app"
                                // on Android 11+ (package visibility), so nothing opened.
                                fun viewIntent(type: String) = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, type)
                                    clipData = android.content.ClipData.newRawUri(file.name, uri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                var opened = false
                                for (candidate in mimeCandidates) {
                                    try {
                                        startActivity(viewIntent(candidate))
                                        opened = true
                                        break
                                    } catch (_: ActivityNotFoundException) {
                                    } catch (_: SecurityException) {
                                    }
                                }
                                if (!opened) {
                                    // the system's "open with" sheet, which also says when no app can
                                    try {
                                        startActivity(Intent.createChooser(viewIntent("*/*"), file.name))
                                        opened = true
                                    } catch (_: Exception) {
                                    }
                                }
                                result.success(opened)
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

                                // The folder as a DocumentsProvider document. Its id is
                                // "primary:Download/AnyWhere" and must be encoded (':' and '/'):
                                // built by hand it was not, and file managers fell back to the
                                // root of the storage instead of the folder.
                                val authority = "com.android.externalstorage.documents"
                                val base = "/storage/emulated/0"
                                val abs = dir?.absolutePath ?: base
                                val relative = if (abs.startsWith("$base/")) abs.removePrefix("$base/") else ""
                                val docUri = DocumentsContract.buildDocumentUri(authority, "primary:$relative")
                                var opened = false

                                fun tryStart(intent: Intent): Boolean = try {
                                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    startActivity(intent)
                                    true
                                } catch (_: Exception) {
                                    false
                                }

                                // 1. The system Files app (DocumentsUI), straight at the folder.
                                for (pkg in listOf("com.google.android.documentsui", "com.android.documentsui")) {
                                    if (opened) break
                                    opened = tryStart(Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(docUri, DocumentsContract.Document.MIME_TYPE_DIR)
                                        setPackage(pkg)
                                    })
                                }
                                // 2. Any file manager that takes a folder document.
                                if (!opened) {
                                    opened = tryStart(Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(docUri, DocumentsContract.Document.MIME_TYPE_DIR)
                                    })
                                }
                                // 3. Files app opened on its own (at least the right app).
                                if (!opened) {
                                    val launch = packageManager.getLaunchIntentForPackage("com.google.android.documentsui")
                                        ?: packageManager.getLaunchIntentForPackage("com.android.documentsui")
                                    if (launch != null) opened = tryStart(launch)
                                }

                                if (opened) {
                                    result.success(true)
                                } else {
                                    result.error("NO_FILE_MANAGER", "No file manager found", null)
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
                    "consumeDirectShareTarget" -> {
                        val currentIntent = intent
                        // Android 10+: a sharing shortcut picked in the share sheet arrives as the
                        // share intent with its shortcut id ("device_<id>"); the shortcut's own
                        // extras are not delivered then.
                        val shortcutId = currentIntent?.getStringExtra(Intent.EXTRA_SHORTCUT_ID)
                        val deviceId = currentIntent?.getStringExtra("directShareDeviceId")
                            ?: shortcutId?.removePrefix("device_")
                        if (deviceId == null) {
                            result.success(null)
                        } else {
                            result.success(mapOf(
                                "id" to deviceId,
                                "name" to (currentIntent.getStringExtra("directShareDeviceName") ?: ""),
                                "ip" to (currentIntent.getStringExtra("directShareDeviceIp") ?: "")
                            ))
                            currentIntent.removeExtra("directShareDeviceId")
                            currentIntent.removeExtra("directShareDeviceName")
                            currentIntent.removeExtra("directShareDeviceIp")
                            currentIntent.removeExtra(Intent.EXTRA_SHORTCUT_ID)
                        }
                    }
                    "startHotspot" -> {
                        try {
                            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                wifiManager.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation?) {
                                        hotspotReservation = reservation
                                        val config = reservation?.wifiConfiguration
                                        val ssid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                            reservation?.softApConfiguration?.ssid ?: config?.SSID ?: "LifeOS-Hotspot"
                                        } else {
                                            @Suppress("DEPRECATION")
                                            config?.SSID ?: "LifeOS-Hotspot"
                                        }
                                        val password = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                            reservation?.softApConfiguration?.passphrase ?: config?.preSharedKey ?: ""
                                        } else {
                                            @Suppress("DEPRECATION")
                                            config?.preSharedKey ?: ""
                                        }
                                        runOnUiThread {
                                            result.success(mapOf(
                                                "ssid" to ssid.replace("\"", ""),
                                                "password" to password.replace("\"", ""),
                                                "ip" to "192.168.43.1"
                                            ))
                                        }
                                    }

                                    override fun onStopped() {
                                        hotspotReservation = null
                                    }

                                    override fun onFailed(reason: Int) {
                                        val reasonText = when (reason) {
                                            WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL -> "No channel available"
                                            WifiManager.LocalOnlyHotspotCallback.ERROR_GENERIC -> "Generic error"
                                            WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE -> "Incompatible mode (is WiFi tethering already on?)"
                                            WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED -> "Tethering disallowed by system"
                                            else -> "Unknown error ($reason)"
                                        }
                                        runOnUiThread {
                                            result.error("HOTSPOT_FAILED", "Hotspot failed: $reasonText", null)
                                        }
                                    }
                                }, null)
                            } else {
                                result.error("UNSUPPORTED", "Hotspot requires Android 8.0+", null)
                            }
                        } catch (e: SecurityException) {
                            result.error("PERMISSION_DENIED", "Location permission required: ${e.message}", null)
                        } catch (e: Exception) {
                            result.error("HOTSPOT_ERROR", "Hotspot error: ${e.message}", null)
                        }
                    }
                    "stopHotspot" -> {
                        try {
                            hotspotReservation?.close()
                            hotspotReservation = null
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("HOTSPOT_STOP_ERROR", "Failed to stop hotspot: ${e.message}", null)
                        }
                    }
                    "connectToWifi" -> {
                        val ssid = call.argument<String>("ssid")
                        val password = call.argument<String>("password")
                        if (ssid == null) {
                            result.error("INVALID_ARGS", "ssid is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                // Android 10+ : WifiNetworkSpecifier + ConnectivityManager
                                val specifierBuilder = WifiNetworkSpecifier.Builder()
                                    .setSsid(ssid)
                                if (!password.isNullOrEmpty()) {
                                    specifierBuilder.setWpa2Passphrase(password)
                                }
                                val specifier = specifierBuilder.build()

                                val request = NetworkRequest.Builder()
                                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                                    .setNetworkSpecifier(specifier)
                                    .build()

                                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                                cm.requestNetwork(request, object : ConnectivityManager.NetworkCallback() {
                                    override fun onAvailable(network: Network) {
                                        cm.bindProcessToNetwork(network)
                                        runOnUiThread {
                                            result.success(true)
                                        }
                                    }
                                    override fun onUnavailable() {
                                        runOnUiThread {
                                            result.success(false)
                                        }
                                    }
                                })
                            } else {
                                // Android 9 and below: legacy WifiManager
                                @Suppress("DEPRECATION")
                                val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                @Suppress("DEPRECATION")
                                val conf = android.net.wifi.WifiConfiguration().apply {
                                    SSID = "\"$ssid\""
                                    preSharedKey = "\"$password\""
                                }
                                @Suppress("DEPRECATION")
                                val netId = wifiManager.addNetwork(conf)
                                if (netId != -1) {
                                    @Suppress("DEPRECATION")
                                    wifiManager.enableNetwork(netId, true)
                                    result.success(true)
                                } else {
                                    result.success(false)
                                }
                            }
                        } catch (e: Exception) {
                            result.error("WIFI_ERROR", "WiFi connect error: ${e.message}", null)
                        }
                    }
                    "unbindNetwork" -> {
                        try {
                            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                            cm.bindProcessToNetwork(null)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("UNBIND_ERROR", "Failed to unbind network: ${e.message}", null)
                        }
                    }
                    "acquireMulticastLock" -> {
                        try {
                            if (multicastLock == null || !multicastLock!!.isHeld) {
                                val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                multicastLock = wifiManager.createMulticastLock("lifeos_discovery")
                                multicastLock!!.setReferenceCounted(false)
                                multicastLock!!.acquire()
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MULTICAST_ERROR", "Failed to acquire multicast lock: ${e.message}", null)
                        }
                    }
                    "releaseMulticastLock" -> {
                        try {
                            if (multicastLock != null && multicastLock!!.isHeld) {
                                multicastLock!!.release()
                            }
                            multicastLock = null
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MULTICAST_ERROR", "Failed to release multicast lock: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        try {
            if (multicastLock != null && multicastLock!!.isHeld) {
                multicastLock!!.release()
            }
        } catch (_: Exception) {}
        super.onDestroy()
    }
}
