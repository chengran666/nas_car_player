package com.example.nas_car_player

import android.app.Activity
import android.content.ClipData
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** APK is shared from a restricted cache folder, never from arbitrary caller paths. */
@Suppress("DEPRECATION")
class AppUpdater(private val activity: Activity) {
    private data class Export(val code: Long, val result: MethodChannel.Result) {
        val name get() = "NAS-Car-Player-$code.apk"
    }
    private var pendingExport: Export? = null
    private val main = Handler(Looper.getMainLooper())
    private val pm get() = activity.packageManager
    private fun apk() = File(activity.cacheDir, "app_updates/update.apk")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    private fun flags() = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
    private fun certificates(info: PackageInfo): Set<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            ?.map { it.toCharsString() }?.toSet() ?: emptySet()

    private fun validatedApk(expectedCode: Long?): File {
        val file = apk()
        check(file.isFile) { "升级包不存在，请重新下载" }
        val candidate = pm.getPackageArchiveInfo(file.path, flags()) ?: error("升级包格式无效")
        val installed = pm.getPackageInfo(activity.packageName, flags())
        check(candidate.packageName == activity.packageName) { "升级包不是本播放器" }
        check(code(candidate) > code(installed) && code(candidate) == expectedCode) {
            "升级包版本无效，请重新下载"
        }
        val signer = certificates(candidate)
        check(signer.isNotEmpty() && signer == certificates(installed)) { "升级包签名不一致，无法覆盖安装" }
        return file
    }

    private fun finishExport(export: Export, location: String? = null, error: String? = null) {
        pendingExport = null
        if (error == null) export.result.success(location)
        else export.result.error("UPDATE_EXPORT_FAILED", error, null)
    }

    private fun chooseExportLocation(export: Export) {
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = APK_MIME
            putExtra(Intent.EXTRA_TITLE, export.name)
            if (Build.VERSION.SDK_INT >= 26) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", "primary:Download"))
            }
        }
        try {
            DesktopLyricsController.get(activity).setInstallUIActive(true)
            activity.startActivityForResult(intent, EXPORT_REQUEST)
        } catch (error: Exception) {
            DesktopLyricsController.get(activity).setInstallUIActive(false)
            Log.w("NasPlayerUpdate", "Cannot open APK save picker", error)
            finishExport(export, error = "车机没有可用的系统文件选择器，请通过下载网站手动下载安装包")
        }
    }

    private fun copyApk(file: File, uri: Uri) {
        val length = file.length()
        val output = activity.contentResolver.openOutputStream(uri, "w") ?: error("无法打开保存位置")
        output.use { target ->
            val copied = file.inputStream().use { it.copyTo(target, 64 * 1024) }
            check(copied == length) { "安装包未完整保存，请重试" }
        }
    }

    private fun displayName(uri: Uri, fallback: String): String = runCatching {
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
    }.getOrNull() ?: fallback

    private fun exportToDownloads(file: File, export: Export): String {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, export.name)
            put(MediaStore.MediaColumns.MIME_TYPE, APK_MIME)
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: error("无法创建下载文件")
        try {
            copyApk(file, uri)
            val ready = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            check(resolver.update(uri, ready, null, null) == 1) { "无法完成保存" }
            return "下载/${displayName(uri, export.name)}"
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != EXPORT_REQUEST) return false
        val export = pendingExport ?: return true
        DesktopLyricsController.get(activity).setInstallUIActive(false)
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finishExport(export)
            return true
        }
        worker.execute {
            try {
                check(uri.scheme == "content") { "系统返回的保存位置无效" }
                copyApk(validatedApk(export.code), uri)
                val name = displayName(uri, export.name)
                main.post { finishExport(export, location = name) }
            } catch (error: Exception) {
                Log.w("NasPlayerUpdate", "APK export to document failed", error)
                if (uri.scheme == "content") {
                    runCatching { DocumentsContract.deleteDocument(activity.contentResolver, uri) }
                }
                main.post { finishExport(export, error = "保存安装包失败，请检查剩余空间后重试") }
            }
        }
        return true
    }

    private fun launchFirstAvailable(intents: List<Pair<String, Intent>>): String? {
        DesktopLyricsController.get(activity).setInstallUIActive(true)
        for ((route, intent) in intents) {
            try {
                // Try the actual launch: querying handlers can hide activities
                // on newer Android versions, and OEM settings often vary.
                activity.startActivity(intent)
                Log.i("NasPlayerUpdate", "Opened $route (Android ${Build.VERSION.RELEASE}, ${Build.MANUFACTURER})")
                return route
            } catch (error: Exception) {
                Log.w("NasPlayerUpdate", "Cannot open $route (API ${Build.VERSION.SDK_INT}, ${Build.MANUFACTURER})", error)
            }
        }
        DesktopLyricsController.get(activity).setInstallUIActive(false)
        return null
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAppVersion" -> {
                val info = pm.getPackageInfo(activity.packageName, 0)
                result.success(mapOf("code" to code(info), "name" to info.versionName,
                    "abis" to Build.SUPPORTED_ABIS.toList()))
            }
            "getUpdateDownloadPath" -> {
                val file = apk()
                check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs()) { "无法创建升级目录" }
                result.success(file.path)
            }
            "canInstallUpdates" -> {
                try { result.success(Build.VERSION.SDK_INT < 26 || pm.canRequestPackageInstalls()) }
                catch (error: Exception) {
                    Log.w("NasPlayerUpdate", "Cannot check install permission", error)
                    result.error("INSTALL_PERMISSION_CHECK_FAILED", "无法读取车机的安装权限，请在系统设置中检查是否允许本播放器安装未知应用", null)
                }
            }
            "requestInstallPermission" -> {
                if (Build.VERSION.SDK_INT < 26) {
                    result.success("not_required")
                    return
                }
                val packageUri = Uri.parse("package:${activity.packageName}")
                val route = launchFirstAvailable(listOf(
                    "app_source" to Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, packageUri),
                    "unknown_sources" to Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES),
                    "security" to Intent(Settings.ACTION_SECURITY_SETTINGS),
                    "app_details" to Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri),
                    "settings" to Intent(Settings.ACTION_SETTINGS)
                ))
                if (route != null) result.success(route)
                else result.error("INSTALL_SETTINGS_UNAVAILABLE",
                    "车机无法打开安装授权页面。请手动进入系统设置，找到“安装未知应用”，允许车机NAS播放器安装应用；如果系统没有此入口，可通过浏览器或文件管理器手动安装", null)
            }
            "installUpdate" -> {
                worker.execute {
                    try {
                        val file = validatedApk(call.argument<Number>("code")?.toLong())
                        check(Build.VERSION.SDK_INT < 26 || pm.canRequestPackageInstalls()) { "请先允许安装应用" }
                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            clipData = ClipData.newRawUri("播放器更新", uri)
                        }
                        val fallback = Intent(intent).apply { action = Intent.ACTION_INSTALL_PACKAGE }
                        Handler(Looper.getMainLooper()).post {
                            if (launchFirstAvailable(listOf("apk_view" to intent, "package_install" to fallback)) != null) {
                                result.success(null)
                            } else result.error("INSTALLER_UNAVAILABLE",
                                "车机无法打开系统安装程序，可能被系统限制或安装程序被禁用。安装包已保留，可稍后重试，或通过浏览器、文件管理器手动安装", null)
                        }
                    } catch (e: Exception) {
                        Log.w("NasPlayerUpdate", "APK validation/install failed (API ${Build.VERSION.SDK_INT})", e)
                        Handler(Looper.getMainLooper()).post {
                            val message = if (e is SecurityException) "车机系统禁止发起安装，请检查是否允许本播放器安装未知应用" else e.message
                            result.error("UPDATE_FAILED", message, null)
                        }
                    }
                }
            }
            "saveUpdateToDownloads" -> {
                check(pendingExport == null) { "正在保存安装包，请稍候" }
                val export = Export(requireNotNull(call.argument<Number>("code")).toLong(), result)
                pendingExport = export
                worker.execute {
                    val file = try { validatedApk(export.code) } catch (error: Exception) {
                        main.post { finishExport(export, error = error.message ?: "安装包无法校验，请重新下载") }
                        return@execute
                    }
                    if (Build.VERSION.SDK_INT >= 29) {
                        try {
                            val location = exportToDownloads(file, export)
                            main.post { finishExport(export, location = location) }
                            return@execute
                        } catch (error: Exception) {
                            Log.w("NasPlayerUpdate", "Downloads unavailable; trying file picker", error)
                        }
                    }
                    main.post { chooseExportLocation(export) }
                }
            }
        }
    }
    companion object {
        private const val APK_MIME = "application/vnd.android.package-archive"
        private const val EXPORT_REQUEST = 0x4E41
        private val worker = Executors.newSingleThreadExecutor()
    }
}
