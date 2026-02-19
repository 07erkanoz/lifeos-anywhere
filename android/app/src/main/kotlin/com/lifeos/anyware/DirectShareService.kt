package com.lifeos.anyware

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build

/**
 * Manages Android Direct Share shortcuts so that recently discovered devices
 * appear as share targets in the system share sheet.
 *
 * Uses the ShortcutManager API (Android 7.1+) to publish dynamic shortcuts.
 * Each shortcut represents a discovered device on the LAN.
 */
object DirectShareService {

    private const val CATEGORY = "com.lifeos.anyware.category.SHARE_TARGET"
    private const val MAX_SHORTCUTS = 4

    /**
     * Updates the dynamic shortcuts with the given list of devices.
     *
     * @param context Application or activity context.
     * @param devices List of maps with keys: id, name, ip, port, platform.
     */
    fun updateShortcuts(context: Context, devices: List<Map<String, Any>>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return

        val shortcutManager = context.getSystemService(ShortcutManager::class.java) ?: return

        val shortcuts = devices.take(MAX_SHORTCUTS).map { device ->
            val deviceId = device["id"] as? String ?: return@map null
            val deviceName = device["name"] as? String ?: "Unknown"
            val deviceIp = device["ip"] as? String ?: ""
            val platform = device["platform"] as? String ?: ""

            val icon = when (platform) {
                "android" -> Icon.createWithResource(context, android.R.drawable.stat_sys_data_bluetooth)
                "windows" -> Icon.createWithResource(context, android.R.drawable.ic_menu_share)
                "ios" -> Icon.createWithResource(context, android.R.drawable.stat_sys_data_bluetooth)
                else -> Icon.createWithResource(context, android.R.drawable.ic_menu_share)
            }

            val intent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_SEND
                type = "*/*"
                putExtra("directShareDeviceId", deviceId)
                putExtra("directShareDeviceName", deviceName)
                putExtra("directShareDeviceIp", deviceIp)
            }

            ShortcutInfo.Builder(context, "device_$deviceId")
                .setShortLabel(deviceName)
                .setLongLabel("$deviceName ($deviceIp)")
                .setIcon(icon)
                .setIntent(intent)
                .setCategories(setOf(CATEGORY))
                .setRank(devices.indexOf(device))
                .build()
        }.filterNotNull()

        try {
            shortcutManager.dynamicShortcuts = shortcuts
        } catch (e: Exception) {
            // Fail silently — shortcuts are a nice-to-have.
        }
    }

    /**
     * Clears all dynamic share shortcuts.
     */
    fun clearShortcuts(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return

        val shortcutManager = context.getSystemService(ShortcutManager::class.java) ?: return
        try {
            shortcutManager.removeAllDynamicShortcuts()
        } catch (_: Exception) {}
    }
}
