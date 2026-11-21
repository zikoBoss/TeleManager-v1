package com.example.telemanager

import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Native TDLib bridge for TeleManager (Task 05).
 *
 * Owns exactly one TDLib [Client], created in `initialize` and confirmed
 * closed in `close`. Mirrors the flow proven by the isolated TDLib spike
 * (Tasks 03/04): the same `Client.create` handlers, the same
 * `SetTdlibParameters` arguments, the same Close-confirmation rule
 * (a second client is never created on the same database before the
 * first is confirmed closed), the same 5s `my_id` timeout and the same
 * 8s Close timeout.
 *
 * Channel `telemanager.tdlib`. Dart calls into the bridge with
 * request/response methods; the bridge pushes state changes back with
 * `onAuthorizationState` and unsolicited errors with `onError`.
 *
 * Errors from TDLib are reported with the numeric TDLib code as the
 * `MethodChannel.Result.error` code, so the Dart side can map them
 * onto [ProviderError]. Bridge-internal errors use `bridge_*` codes.
 *
 * No credentials, phone numbers, codes, passwords, session data, or
 * QR links are ever logged here. The QR link crosses to Dart only
 * inside the `onAuthorizationState` payload (in-memory, same process)
 * and must be dropped by the Dart side when the state leaves
 * WaitOtherDeviceConfirmation.
 */
class TdlibBridge : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var client: Client? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var closedLatch: CountDownLatch? = null
    private var closedObserved = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "telemanager.tdlib")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        closeClientBestEffort()
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(call, result)
            "setTdlibParameters" -> setTdlibParameters(call, result)
            "setAuthenticationPhoneNumber" -> {
                val phone = call.stringArg("phoneNumber")
                if (phone == null) {
                    result.error(
                        "bridge_invalid_args",
                        "setAuthenticationPhoneNumber requires phoneNumber.",
                        null,
                    )
                } else {
                    sendAndAwait(
                        TdApi.SetAuthenticationPhoneNumber(
                            phone,
                            TdApi.PhoneNumberAuthenticationSettings(),
                        ),
                        result,
                    )
                }
            }
            "checkAuthenticationCode" -> {
                val code = call.stringArg("code")
                if (code == null) {
                    result.error(
                        "bridge_invalid_args",
                        "checkAuthenticationCode requires code.",
                        null,
                    )
                } else {
                    sendAndAwait(TdApi.CheckAuthenticationCode(code), result)
                }
            }
            "checkAuthenticationPassword" -> {
                val password = call.stringArg("password")
                if (password == null) {
                    result.error(
                        "bridge_invalid_args",
                        "checkAuthenticationPassword requires password.",
                        null,
                    )
                } else {
                    sendAndAwait(TdApi.CheckAuthenticationPassword(password), result)
                }
            }
            "requestQrCodeAuthentication" -> sendAndAwait(
                TdApi.RequestQrCodeAuthentication(longArrayOf()),
                result,
            )
            "getOptionVersion" -> getOptionVersion(result)
            "getMyId" -> getMyId(result)
            "logOut" -> sendAndAwait(TdApi.LogOut(), result)
            "close" -> close(result)
            "dispose" -> {
                closeClientBestEffort()
                result.success(mapOf("ok" to true))
            }
            else -> result.notImplemented()
        }
    }

    // ---------- lifecycle ----------

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val databaseDirectory = call.stringArg("databaseDirectory")
        val filesDirectory = call.stringArg("filesDirectory")
        if (databaseDirectory == null || filesDirectory == null) {
            result.error(
                "bridge_invalid_args",
                "initialize requires databaseDirectory and filesDirectory.",
                null,
            )
            return
        }
        // Fail fast: never create a second client while a previous one
        // is still open (not confirmed closed). The Dart side waits for
        // the Closed state before re-initializing after signOut; if
        // this guard fires, the caller skipped that wait (a sequencing
        // bug). The check must come before closeClientBestEffort(),
        // which drops the reference.
        if (client != null && !closedObserved) {
            result.error(
                "bridge_previous_client_open",
                "A previous TDLib client is still open; wait for Closed " +
                    "before initializing.",
                null,
            )
            return
        }
        // Defensive: a previous client (e.g. after a failed attempt) is
        // closed best-effort before creating a new one.
        closeClientBestEffort()
        try {
            System.loadLibrary("tdjni")
        } catch (e: Throwable) {
            result.error(
                "bridge_load_failed",
                "Failed to load tdjni: ${e.message}",
                null,
            )
            return
        }
        closedObserved = false
        client = Client.create(
            { update ->
                if (update is TdApi.UpdateAuthorizationState) {
                    onAuthState(update.authorizationState)
                }
            },
            { e -> postError(0, e.message ?: "update handler error") },
            { e -> postError(0, e.message ?: "default handler error") },
        )
        result.success(mapOf("ok" to true))
    }

    private fun close(result: MethodChannel.Result) {
        val c = client
        if (c == null || closedObserved) {
            client = null
            result.success(mapOf("ok" to true))
            return
        }
        executor.execute {
            val latch = CountDownLatch(1)
            closedLatch = latch
            c.send(TdApi.Close(), { _ -> }, { _ -> })
            val confirmed = latch.await(8, TimeUnit.SECONDS)
            closedLatch = null
            mainHandler.post {
                if (confirmed) {
                    client = null
                    result.success(mapOf("ok" to true))
                } else {
                    result.error(
                        "bridge_timeout",
                        "Close was not confirmed within 8s.",
                        null,
                    )
                }
            }
        }
    }

    /** Best-effort close: sends Close and drops the reference. Never waits. */
    private fun closeClientBestEffort() {
        val c = client ?: return
        client = null
        try {
            c.send(TdApi.Close(), { _ -> }, { _ -> })
        } catch (_: Throwable) {
            // Best-effort only.
        }
    }

    // ---------- parameters & auth ----------

    private fun setTdlibParameters(call: MethodCall, result: MethodChannel.Result) {
        val apiId = call.numberArg("apiId")?.toInt()
        val apiHash = call.stringArg("apiHash")
        val databaseDirectory = call.stringArg("databaseDirectory")
        val filesDirectory = call.stringArg("filesDirectory")
        val applicationVersion = call.stringArg("applicationVersion")
        if (apiId == null || apiHash == null || databaseDirectory == null ||
            filesDirectory == null || applicationVersion == null
        ) {
            result.error(
                "bridge_invalid_args",
                "setTdlibParameters requires apiId, apiHash, databaseDirectory, " +
                    "filesDirectory, applicationVersion.",
                null,
            )
            return
        }
        val dbDir = File(databaseDirectory)
        val filesDir = File(filesDirectory)
        dbDir.mkdirs()
        filesDir.mkdirs()
        // Exact arguments proven by the isolated spike (Tasks 03/04).
        val params = TdApi.SetTdlibParameters(
            false, // useTestDc
            dbDir.absolutePath,
            filesDir.absolutePath,
            ByteArray(0), // databaseEncryptionKey: none
            true, // useFileDatabase
            true, // useChatInfoDatabase
            true, // useMessageDatabase
            true, // useSecretChats
            apiId,
            apiHash,
            "en", // systemLanguageCode
            Build.MODEL, // deviceModel
            "Android " + Build.VERSION.RELEASE, // systemVersion
            applicationVersion,
        )
        sendAndAwait(params, result)
    }

    private fun getOptionVersion(result: MethodChannel.Result) {
        try {
            // execute() is generic: its return type is inferred as
            // OptionValue from GetOption, and Error is disjoint from
            // OptionValue, so an `is Error` check on the inferred type is
            // always false (Kotlin 2.4 rejects it). Widen to Object first
            // so both checks are ordinary downcasts.
            val raw: TdApi.Object? = Client.execute(TdApi.GetOption("version"))
            when (raw) {
                is TdApi.OptionValueString -> result.success(mapOf("value" to raw.value))
                is TdApi.Error -> result.error(raw.code.toString(), raw.message, null)
                else -> result.error(
                    "bridge_unexpected",
                    "Unexpected option value: ${raw?.javaClass?.simpleName ?: "null"}",
                    null,
                )
            }
        } catch (e: Throwable) {
            result.error(
                "bridge_exception",
                "${e.javaClass.simpleName}: ${e.message}",
                null,
            )
        }
    }

    /** Async `GetOption("my_id")` with the spike's 5s timeout. */
    private fun getMyId(result: MethodChannel.Result) {
        val c = client
        if (c == null) {
            result.error(
                "bridge_not_initialized",
                "TDLib client is not initialized.",
                null,
            )
            return
        }
        executor.execute {
            val latch = CountDownLatch(1)
            var value: Long? = null
            var problem: String? = null
            var problemCode: Int? = null
            c.send(
                TdApi.GetOption("my_id"),
                { obj ->
                    when (obj) {
                        is TdApi.OptionValueInteger -> value = obj.value
                        is TdApi.OptionValueEmpty -> problem = "EMPTY"
                        is TdApi.Error -> {
                            problemCode = obj.code
                            problem = obj.message
                        }
                        else -> problem = "unexpected: ${obj.javaClass.simpleName}"
                    }
                    latch.countDown()
                },
                { e ->
                    problem = "${e.javaClass.simpleName}: ${e.message}"
                    latch.countDown()
                },
            )
            val received = latch.await(5, TimeUnit.SECONDS)
            mainHandler.post {
                when {
                    value != null && value != 0L -> result.success(mapOf("myId" to value))
                    value == 0L -> result.error(
                        "bridge_unexpected",
                        "GetOption(\"my_id\") returned 0 (no user).",
                        null,
                    )
                    problemCode != null -> result.error(problemCode.toString(), problem, null)
                    problem != null -> result.error("bridge_unexpected", problem, null)
                    !received -> result.error(
                        "bridge_timeout",
                        "GetOption(\"my_id\") timed out after 5s (no async result).",
                        null,
                    )
                    else -> result.error(
                        "bridge_unexpected",
                        "GetOption(\"my_id\") returned no value.",
                        null,
                    )
                }
            }
        }
    }

    // ---------- send helper ----------

    /**
     * Sends a TDLib function and replies when its result arrives.
     * `TdApi.Ok` -> success; `TdApi.Error` -> error with the numeric
     * TDLib code so Dart can map it. Replies on the platform thread.
     */
    private fun sendAndAwait(function: TdApi.Function<*>, result: MethodChannel.Result) {
        val c = client
        if (c == null) {
            result.error(
                "bridge_not_initialized",
                "TDLib client is not initialized.",
                null,
            )
            return
        }
        c.send(
            function,
            { obj ->
                mainHandler.post {
                    when (obj) {
                        is TdApi.Ok -> result.success(mapOf("ok" to true))
                        is TdApi.Error -> result.error(obj.code.toString(), obj.message, null)
                        else -> result.error(
                            "bridge_unexpected",
                            "Unexpected response: ${obj.javaClass.simpleName}",
                            null,
                        )
                    }
                }
            },
            { e ->
                mainHandler.post {
                    result.error(
                        "bridge_exception",
                        "${e.javaClass.simpleName}: ${e.message}",
                        null,
                    )
                }
            },
        )
    }

    // ---------- updates ----------

    private fun onAuthState(state: TdApi.AuthorizationState) {
        if (state is TdApi.AuthorizationStateClosed) {
            closedObserved = true
            closedLatch?.countDown()
        }
        val payload = mapAuthState(state)
        mainHandler.post {
            channel?.invokeMethod("onAuthorizationState", payload, null)
        }
    }

    private fun postError(code: Int, message: String) {
        mainHandler.post {
            channel?.invokeMethod(
                "onError",
                mapOf("code" to code, "message" to message),
                null,
            )
        }
    }

    /**
     * Maps an authorization state to the Dart payload. Only the fields
     * the Dart side needs are included: WaitCode carries type/next
     * type/timeout (no phone number, no verifier data — spike rule);
     * WaitPassword carries the hint; WaitOtherDeviceConfirmation
     * carries the link (login token, in-memory only).
     */
    private fun mapAuthState(state: TdApi.AuthorizationState): Map<String, Any?> {
        val name = state.javaClass.simpleName
        return when (state) {
            is TdApi.AuthorizationStateWaitCode -> mapOf(
                "state" to name,
                "codeInfo" to mapCodeInfo(state.codeInfo),
            )
            is TdApi.AuthorizationStateWaitPassword -> mapOf(
                "state" to name,
                "passwordHint" to state.passwordHint,
            )
            is TdApi.AuthorizationStateWaitOtherDeviceConfirmation -> mapOf(
                "state" to name,
                "qrLink" to state.link,
            )
            is TdApi.AuthorizationStateWaitEmailCode -> mapOf(
                "state" to name,
                "emailAddressPattern" to state.codeInfo?.emailAddressPattern,
                "emailCodeLength" to state.codeInfo?.length,
            )
            else -> mapOf("state" to name)
        }
    }

    private fun mapCodeInfo(info: TdApi.AuthenticationCodeInfo): Map<String, Any?> {
        return mapOf(
            "type" to mapCodeType(info.type),
            "nextType" to info.nextType?.let { mapCodeType(it) },
            "timeoutSeconds" to info.timeout,
        )
    }

    private fun mapCodeType(type: TdApi.AuthenticationCodeType): Map<String, Any?> {
        return mapOf(
            "name" to type.javaClass.simpleName,
            "length" to codeTypeLength(type),
        )
    }

    /**
     * Digit length of the code, when the type carries one; null otherwise.
     * FlashCall carries a pattern (never read — it is verifier data) and
     * SmsWord/SmsPhrase carry word data, so they have no length. Mirrors
     * the spike's CodeInfoReport.codeTypeLength.
     */
    private fun codeTypeLength(type: TdApi.AuthenticationCodeType): Int? {
        return when (type) {
            is TdApi.AuthenticationCodeTypeTelegramMessage -> type.length
            is TdApi.AuthenticationCodeTypeSms -> type.length
            is TdApi.AuthenticationCodeTypeCall -> type.length
            is TdApi.AuthenticationCodeTypeMissedCall -> type.length
            is TdApi.AuthenticationCodeTypeFirebaseAndroid -> type.length
            is TdApi.AuthenticationCodeTypeFirebaseIos -> type.length
            is TdApi.AuthenticationCodeTypeFragment -> type.length
            else -> null
        }
    }

    // ---------- args ----------

    private fun MethodCall.stringArg(name: String): String? = argument<String>(name)

    private fun MethodCall.numberArg(name: String): Number? = argument<Number>(name)
}
