package io.github.jobeacon.joaiclient

import android.app.Activity
import android.content.ActivityNotFoundException
import android.net.Uri
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.engine.FlutterEngine
import io.github.jobeacon.joaiclient.workspace.WorkspacePlugin
import io.flutter.plugin.common.MethodChannel
import com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val kelivo get() = application as KelivoApplication
    private var reusedEngine = false

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine {
        reusedEngine = kelivo.hasEngine
        return kelivo.engine
    }
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onStart() {
        super.onStart()
        kelivo.backgroundRuntime.setForeground(true)
    }

    override fun onPostResume() {
        super.onPostResume()
        // A headless engine may have sent SystemChrome settings before its
        // Activity/PlatformPlugin existed. Apply the window policy on attach.
        applyEdgeToEdgeSystemBars(window)
    }

    override fun onStop() {
        kelivo.backgroundRuntime.setForeground(false)
        super.onStop()
    }

    private companion object {
        const val CREATE_DOCUMENT_REQUEST_CODE = 4107

        // 保存对话框的兜底 MIME 类型；Dart 侧可通过 mimeType 参数覆盖，
        // 用于保存 .joaiclient 备份之外的普通文件。
        const val DEFAULT_DOCUMENT_MIME_TYPE = "application/zip"
        const val TAG = "MainActivity"
    }

    private enum class WritableFileState {
        IDLE,
        OPEN,
        COMMITTED,
        DISCARDED,
    }

    private val processTextChannelName = "app.process_text"
    private val fileSaveChannelName = "app.file_save"
    private val deviceStorageChannelName = "app.device_storage"
    private val displayModeChannelName = "app.display_mode"
    private var processTextChannel: MethodChannel? = null
    private var fileSaveChannel: MethodChannel? = null
    private var deviceStorageChannel: MethodChannel? = null
    private var displayModeChannel: MethodChannel? = null
    private var flutterSurfaceView: FlutterSurfaceView? = null
    private var pendingProcessText: String? = null
     private var pendingSaveResult: MethodChannel.Result? = null
     private var pendingSaveSourcePath: String? = null
     private var pendingSaveFileName: String? = null
     private var pendingDirectWrite = false
     private var pendingWritableStream: OutputStream? = null
     private var pendingWritableUri: Uri? = null
     @Volatile private var writableFileState = WritableFileState.IDLE
     private val writableFileExecutor = Executors.newSingleThreadExecutor()
     private var deviceLocalToolsHandler: DeviceLocalToolsHandler? = null
     private var workspacePlugin: WorkspacePlugin? = null
    private var incomingShareHandler: IncomingShareHandler? = null
    private var receivedShare = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        forwardCachedProcessTextLaunch(reusedEngine, savedInstanceState, intent, processTextChannel)
        (kelivo.engine.plugins.get(FlutterLocalNotificationsPlugin::class.java) as? FlutterLocalNotificationsPlugin)?.let {
            forwardCachedNotificationLaunch(reusedEngine, savedInstanceState, intent, it)
        }
        kelivo.backgroundRuntime.receiveConversation(intent)
        receivedShare = savedInstanceState?.getBoolean("kelivo.receivedShare") == true
        if (!receivedShare) receivedShare = incomingShareHandler?.receive(intent) == true
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("kelivo.receivedShare", receivedShare)
        super.onSaveInstanceState(outState)
    }

    override fun onFlutterSurfaceViewCreated(flutterSurfaceView: FlutterSurfaceView) {
        super.onFlutterSurfaceViewCreated(flutterSurfaceView)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            this.flutterSurfaceView = flutterSurfaceView
            flutterSurfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    requestNativeHighRefreshRate()
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    requestNativeHighRefreshRate()
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
            })
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
         super.configureFlutterEngine(flutterEngine)
        incomingShareHandler = IncomingShareHandler(this, flutterEngine.dartExecutor.binaryMessenger)
         OAuthHandler.configure(this, flutterEngine.dartExecutor.binaryMessenger)
         kelivo.backgroundRuntime.attachActivity(this)
         deviceLocalToolsHandler = kelivo.deviceTools.also { it.attachActivity(this) }
         workspacePlugin = kelivo.workspace.also { it.attachActivity(this) }
        processTextChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, processTextChannelName)
        processTextChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialText" -> {
                    val text = pendingProcessText ?: takeProcessText(intent)
                    pendingProcessText = null
                    result.success(text)
                }
                else -> result.notImplemented()
            }
        }
        fileSaveChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileSaveChannelName)
        fileSaveChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFileFromPath" -> handleSaveFileFromPath(call.arguments, result)
                "createWritableFile" -> handleCreateWritableFile(call.arguments, result)
                "writeWritableFileChunk" -> handleWriteWritableFileChunk(call.arguments, result)
                "completeWritableFile" -> handleCompleteWritableFile(result)
                "abortWritableFile" -> handleAbortWritableFile(result)
                else -> result.notImplemented()
            }
        }
        deviceStorageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceStorageChannelName)
        deviceStorageChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "freeBytes" -> result.success(usableBytesForAppData())
                else -> result.notImplemented()
            }
        }
        displayModeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, displayModeChannelName)
        displayModeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestHighRefreshRate" -> result.success(requestNativeHighRefreshRate())
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNativeHighRefreshRate(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return false

        try {
            val surface = flutterSurfaceView?.holder?.surface
            if (surface?.isValid == true) {
                val currentDisplay = display ?: return true
                val activeMode = currentDisplay.mode
                val targetRefreshRate = currentDisplay.supportedModes
                    .asSequence()
                    .filter {
                        it.physicalWidth == activeMode.physicalWidth &&
                            it.physicalHeight == activeMode.physicalHeight
                    }
                    .maxOfOrNull { it.refreshRate }
                if (targetRefreshRate != null) {
                    // 只提示 Flutter 实际渲染的那个 surface；模式选择、
                    // ARR 与系统限制仍交给 Android 决定。
                    surface.setFrameRate(
                        targetRefreshRate,
                        Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                        Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS,
                    )
                }
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "Unable to request a high refresh rate", error)
        }
        return true
    }

    /**
     * 应用数据所在卷上仍可用的空间；无法确定时返回 null。
     * 调用方把 null 当作“未知”并继续执行。
     */
    private fun usableBytesForAppData(): Long? = try {
        val target = filesDir ?: dataDir
        StatFs(target.absolutePath).availableBytes.takeIf { it > 0 }
    } catch (_: Exception) {
        null
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        kelivo.backgroundRuntime.receiveConversation(intent)
        setIntent(intent)
        receivedShare = incomingShareHandler?.receive(intent) == true
        val text = takeProcessText(intent) ?: return
        val ch = processTextChannel
        if (ch != null) {
            ch.invokeMethod("onProcessText", text)
        } else {
            pendingProcessText = text
        }
    }

    override fun onDestroy() {
        deviceLocalToolsHandler?.detachActivity(this)
        kelivo.backgroundRuntime.detachActivity(this)
        OAuthHandler.detachActivity(this)
        processTextChannel?.setMethodCallHandler(null)
        fileSaveChannel?.setMethodCallHandler(null)
        deviceStorageChannel?.setMethodCallHandler(null)
        displayModeChannel?.setMethodCallHandler(null)
        pendingSaveResult?.error("cancelled", "The file picker was closed.", null)
        pendingSaveResult = null
        pendingSaveSourcePath = null
        flutterSurfaceView = null
        val stream = pendingWritableStream
        val uri = pendingWritableUri
        if (stream != null && uri != null) {
            writableFileExecutor.execute {
                // 排在所有已入队的写入与完成回调之后执行。完成成功时
                // 会先标记 COMMITTED 再投递 UI 回调，因此在这个竞态窗口里
                // 完整的备份绝不会被删掉。
                if (writableFileState == WritableFileState.OPEN) {
                    discardWritableDestination(stream, uri)
                }
            }
        }
        writableFileExecutor.shutdown()
        incomingShareHandler?.dispose()
        workspacePlugin?.detachActivity(this)
        super.onDestroy()
    }
 
     override fun onRequestPermissionsResult(
         requestCode: Int,
         permissions: Array<out String>,
         grantResults: IntArray,
     ) {
         if (workspacePlugin?.onRequestPermissionsResult(requestCode) == true) return
        if (kelivo.backgroundRuntime.permissionResult(requestCode)) return
         if (deviceLocalToolsHandler?.onRequestPermissionsResult(requestCode, grantResults) == true) {
             return
         }
         super.onRequestPermissionsResult(requestCode, permissions, grantResults)
     }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (workspacePlugin?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CREATE_DOCUMENT_REQUEST_CODE) {
            return
        }

        val destUri = if (resultCode == Activity.RESULT_OK) data?.data else null
        handleSaveDestination(destUri)
    }

    private fun handleSaveFileFromPath(arguments: Any?, result: MethodChannel.Result) {
        if (pendingSaveResult != null || pendingWritableStream != null) {
            result.error("busy", "Another save operation is already in progress.", null)
            return
        }

        val args = arguments as? Map<*, *>
        val rawSourcePath = args?.get("sourcePath")?.toString()?.trim().orEmpty()
        if (rawSourcePath.isEmpty()) {
            result.error("invalid_args", "Missing sourcePath.", null)
            return
        }

        val sourceFile = File(rawSourcePath)
        if (!sourceFile.exists() || !sourceFile.isFile) {
            result.error("not_found", "Source file does not exist.", null)
            return
        }

        val suggestedFileName = args?.get("fileName")?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: sourceFile.name
        val mimeType = args?.get("mimeType")?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: DEFAULT_DOCUMENT_MIME_TYPE

        pendingSaveResult = result
        pendingSaveSourcePath = sourceFile.absolutePath
        pendingSaveFileName = suggestedFileName

        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, suggestedFileName)
            }
            startActivityForResult(intent, CREATE_DOCUMENT_REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            pendingSaveFileName = null
            result.error("launch_failed", e.message, null)
        }
    }

    private fun handleCreateWritableFile(arguments: Any?, result: MethodChannel.Result) {
        if (pendingSaveResult != null || pendingWritableStream != null) {
            result.error("busy", "Another save operation is already in progress.", null)
            return
        }

        val args = arguments as? Map<*, *>
        val fileName = args?.get("fileName")?.toString()?.trim().orEmpty()
        if (fileName.isEmpty()) {
            result.error("invalid_args", "Missing fileName.", null)
            return
        }

        val mimeType = args?.get("mimeType")?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
            ?: DEFAULT_DOCUMENT_MIME_TYPE
        pendingSaveResult = result
        pendingDirectWrite = true
        pendingSaveFileName = fileName
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, fileName)
            }
            startActivityForResult(intent, CREATE_DOCUMENT_REQUEST_CODE)
        } catch (e: ActivityNotFoundException) {
            pendingSaveResult = null
            pendingDirectWrite = false
            pendingSaveFileName = null
            result.error("launch_failed", e.message, null)
        }
    }

    private fun handleCompleteWritableFile(result: MethodChannel.Result) {
        val stream = pendingWritableStream
        val savedUri = pendingWritableUri
        val suggestedFileName = pendingSaveFileName
        if (stream == null) {
            result.error("not_open", "No writable file destination is open.", null)
            return
        }

        writableFileExecutor.execute {
            try {
                stream.flush()
                stream.close()
                writableFileState = WritableFileState.COMMITTED
                // Android 的“新建文档”会按 MIME 类型自动补 .zip；这里在流关闭后
                // 把 .joaiclient 备份的名字改回去，失败不影响已完成的备份。
                if (savedUri != null) renameAutoAppendedZip(savedUri, suggestedFileName)
                runOnUiThread {
                    if (pendingWritableStream === stream) {
                        pendingWritableStream = null
                        pendingWritableUri = null
                    }
                    pendingSaveFileName = null
                    result.success(true)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("close_failed", e.message, null)
                }
            }
        }
    }

    private fun handleWriteWritableFileChunk(arguments: Any?, result: MethodChannel.Result) {
        val stream = pendingWritableStream
        if (stream == null) {
            result.error("not_open", "No writable file destination is open.", null)
            return
        }
        val bytes = arguments as? ByteArray
        if (bytes == null) {
            result.error("invalid_args", "Missing writable file bytes.", null)
            return
        }
        if (bytes.isEmpty()) {
            result.success(true)
            return
        }

        writableFileExecutor.execute {
            try {
                stream.write(bytes)
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("write_failed", e.message, null)
                }
            }
        }
    }

    private fun handleAbortWritableFile(result: MethodChannel.Result) {
        val stream = pendingWritableStream
        val uri = pendingWritableUri
        if (stream == null || uri == null) {
            result.error("not_open", "No writable file destination is open.", null)
            return
        }

        writableFileExecutor.execute {
            val cleanupError = discardWritableDestination(stream, uri)

            runOnUiThread {
                if (pendingWritableStream === stream) {
                    pendingWritableStream = null
                    pendingWritableUri = null
                }
                pendingSaveFileName = null
                if (cleanupError == null) {
                    result.success(true)
                } else {
                    result.error("discard_failed", cleanupError.message, null)
                }
            }
        }
    }

    private fun discardWritableDestination(stream: OutputStream, uri: Uri): Exception? {
        var cleanupError: Exception? = null
        try {
            stream.close()
        } catch (e: Exception) {
            cleanupError = e
        }

        var deleted = false
        try {
            deleted = DocumentsContract.deleteDocument(contentResolver, uri)
            if (!deleted) {
                cleanupError = cleanupError
                    ?: IllegalStateException("Unable to delete incomplete destination file.")
            }
        } catch (e: Exception) {
            cleanupError = cleanupError ?: e
        }
        if (deleted) {
            writableFileState = WritableFileState.DISCARDED
        }
        return cleanupError
    }

    private fun handleSaveDestination(destUri: Uri?) {
        val result = pendingSaveResult ?: return
        if (pendingDirectWrite) {
            pendingSaveResult = null
            pendingDirectWrite = false
            if (destUri == null) {
                pendingSaveFileName = null
                result.success(null)
                return
            }
            try {
                pendingWritableUri = destUri
                val descriptor = contentResolver.openFileDescriptor(destUri, "rwt")
                    ?: throw IllegalStateException("Unable to open destination file.")
                pendingWritableStream = ParcelFileDescriptor.AutoCloseOutputStream(descriptor)
                writableFileState = WritableFileState.OPEN
                result.success(true)
            } catch (e: Exception) {
                try {
                    DocumentsContract.deleteDocument(contentResolver, destUri)
                } catch (_: Exception) {
                    // 保留导致目标文件打不开的那个错误。
                }
                pendingWritableUri = null
                pendingSaveFileName = null
                result.error("open_failed", e.message, null)
            }
            return
        }
        val sourcePath = pendingSaveSourcePath
        val suggestedFileName = pendingSaveFileName

        if (destUri == null || sourcePath.isNullOrBlank()) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            pendingSaveFileName = null
            result.success(false)
            return
        }

        Thread {
            try {
                contentResolver.openOutputStream(destUri)?.use { outputStream ->
                    FileInputStream(File(sourcePath)).use { inputStream ->
                        inputStream.copyTo(outputStream, DEFAULT_BUFFER_SIZE)
                    }
                } ?: throw IllegalStateException("Unable to open destination stream.")
                renameAutoAppendedZip(destUri, suggestedFileName)

                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    pendingSaveFileName = null
                    result.success(true)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    pendingSaveResult = null
                    pendingSaveSourcePath = null
                    pendingSaveFileName = null
                    result.error("save_failed", e.message, null)
                }
            }
        }.start()
    }

    // 本仓库自有：Android 的“新建文档”会按 MIME 类型自动补后缀，
    // .joaiclient 备份会被存成 .joaiclient.zip。确认是这种情况后改回原名。
    private fun renameAutoAppendedZip(uri: Uri, suggestedFileName: String?) {
        try {
            val expectedName = suggestedFileName?.trim()
                ?.takeIf { it.endsWith(".joaiclient", ignoreCase = true) }
                ?: return
            val actualName = contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return@use null
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index < 0) null else cursor.getString(index)
            } ?: return
            if (!actualName.equals("$expectedName.zip", ignoreCase = true)) return
            DocumentsContract.renameDocument(contentResolver, uri, expectedName)
        } catch (error: Exception) {
            // 备份本身已经完成；提供方不支持改名不能把成功的保存报成失败。
            Log.w("JO-AIClient", "Unable to restore .joaiclient extension", error)
        }
    }
}

/** Cold launches are read by HomePage; a retained HomePage instead needs an
 * event when Android creates its replacement Activity. Consume the extra so
 * restoring that Activity or querying initial text cannot deliver it twice. */
internal fun forwardCachedProcessTextLaunch(
    reusedEngine: Boolean,
    savedState: Bundle?,
    intent: Intent,
    channel: MethodChannel?,
) {
    if (reusedEngine && savedState == null && channel != null &&
        intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) {
        takeProcessText(intent)?.let { channel.invokeMethod("onProcessText", it) }
    }
}

internal fun takeProcessText(intent: Intent?): String? {
    if (intent?.action != Intent.ACTION_PROCESS_TEXT) return null
    val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
    intent.removeExtra(Intent.EXTRA_PROCESS_TEXT)
    return text?.trim()?.takeIf { it.isNotEmpty() }
}

/** The notifications plugin queries cold launches once from Dart. A new
 * Activity on an existing engine needs its new notification Intent forwarded,
 * because onAttachedToActivity does not deliver a normal notification tap. */
internal fun forwardCachedNotificationLaunch(
    reusedEngine: Boolean,
    savedState: Bundle?,
    intent: Intent,
    plugin: FlutterLocalNotificationsPlugin,
) {
    if (reusedEngine && savedState == null &&
        intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) {
        plugin.onNewIntent(intent)
    }
}
