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
import android.os.PowerManager
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
                    "isBatteryOptimizationExempt" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(pm.isIgnoringBatteryOptimizations(packageName))
                        } catch (e: Exception) {
                            result.error("BATTERY_OPT_ERROR", "Check failed: ${e.message}", null)
                        }
                    }
                    "requestBatteryOptimizationExemption" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$packageName")
                                }
                                startActivity(intent)
                                result.success(false)
                            } else {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.error("BATTERY_OPT_ERROR", "Failed to request battery exemption: ${e.message}", null)
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
