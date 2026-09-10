package com.verygoodapp.tronclass

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 用系统的文件选择器读写文件。
 *
 * 现成的插件（file_picker / file_selector）都要求 AGP 把 Kotlin 内建打开，
 * 而这个工程里一堆插件还在自己 apply KGP，开了会连锁炸；所以这点活自己干：
 * 交给系统的 SAF，选哪个文件、存到哪个目录都由用户决定，App 本身不需要
 * 任何存储权限。
 */
class MainActivity : FlutterActivity() {

    private var pendingResult: MethodChannel.Result? = null
    private var pendingBytes: ByteArray? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "上一个文件操作还没结束", null)
            return
        }
        when (call.method) {
            "openDocument" -> {
                pendingResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*")
                startActivityForResult(intent, REQUEST_OPEN)
            }

            "createDocument" -> {
                val name = call.argument<String>("name") ?: "backup.bin"
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("badArgs", "没有要写入的内容", null)
                    return
                }
                pendingResult = result
                pendingBytes = bytes
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("application/octet-stream")
                    .putExtra(Intent.EXTRA_TITLE, name)
                startActivityForResult(intent, REQUEST_CREATE)
            }

            else -> result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_OPEN && requestCode != REQUEST_CREATE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingResult
        val bytes = pendingBytes
        pendingResult = null
        pendingBytes = null
        if (result == null) return

        // 用户按了返回：不算失败，回 null 让 Dart 那边安静收场
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }

        try {
            if (requestCode == REQUEST_OPEN) {
                val content = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                if (content == null) {
                    result.error("readFailed", "打不开这个文件", null)
                    return
                }
                result.success(mapOf("name" to displayName(uri), "bytes" to content))
            } else {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes ?: ByteArray(0)) }
                    ?: run {
                        result.error("writeFailed", "写不进这个位置", null)
                        return
                    }
                result.success(mapOf("name" to displayName(uri)))
            }
        } catch (e: Exception) {
            result.error("ioFailed", e.message, null)
        }
    }

    /** 拿文件在选择器里显示的那个名字，取不到就退回 uri 末段。 */
    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) return cursor.getString(index)
            }
        return uri.lastPathSegment ?: "未命名"
    }

    private companion object {
        const val CHANNEL = "tronclass/storage_access"
        const val REQUEST_OPEN = 0x5AF0
        const val REQUEST_CREATE = 0x5AF1
    }
}
