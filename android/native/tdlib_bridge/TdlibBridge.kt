package com.example.telemanager

import android.content.Context
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
import java.util.concurrent.atomic.AtomicBoolean

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
    private var appContext: Context? = null
    private var client: Client? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private var closedLatch: CountDownLatch? = null
    private var closedObserved = false

    // Serializes every read/write of client / closedObserved /
    // closedLatch / clientGeneration. The lock is held only for brief,
    // non-blocking work (checks, flag updates, enqueuing a send or a
    // fire-and-forget channel publish); the latch awaits happen
    // outside it, so no deadlock is possible.
    private val clientLock = Any()

    // Increments on every initialize(). Handlers capture the
    // generation at Client.create time; an update or error whose
    // generation no longer matches the current one belongs to an old
    // client and is dropped before it can reach Dart.
    private var clientGeneration = 0

    // ---------- test-only reply delay (BuildConfig.DEBUG only) ----------
    //
    // D1/D3 need a deterministic technical timeout. The request is
    // still sent to TDLib immediately; only the delivery of its
    // MethodChannel.Result to Dart is delayed. Authorization-state
    // updates travel on a separate channel (onAuthorizationState) and
    // are never delayed.
    //
    // All of this state is inert in release builds: the delay map is
    // only written when BuildConfig.DEBUG is true, the counter is only
    // incremented then, and the delay methods report notImplemented.
    // It is removed with the Harness.

    // Method key -> reply delay in ms (armed by setTestReplyDelay).
    private val testReplyDelays = mutableMapOf<String, Long>()

    // Method key -> how many times it was sent (see getTestSendCounts).
    private val testSendCounts = mutableMapOf<String, Int>()

    // Replies whose delivery to Dart is pending (immediate or delayed).
    // Accessed from the TDLib thread (add) and the main thread
    // (deliver / cancel), so guarded by its own monitor.
    private val pendingReplies = mutableSetOf<PendingReply>()

    // Set in onDetachedFromEngine. Volatile so the TDLib thread and
    // the main thread agree. A delivery that sees it drops the result
    // instead of calling it after the channel expired.
    @Volatile
    private var detached = false

    // A TDLib result whose delivery to Dart is pending. The Result is
    // delivered exactly once (AtomicBoolean), on the main thread, and
    // never after detach. The runnable is stored so
    // onDetachedFromEngine can cancel a delayed delivery.
    private inner class PendingReply(
        private val result: MethodChannel.Result,
        private val deliverAction: () -> Unit,
    ) {
        val delivered = AtomicBoolean(false)
        var runnable: Runnable? = null

        fun deliver() {
            if (detached) {
                removeSelf()
                return
            }
            if (!delivered.compareAndSet(false, true)) {
                removeSelf()
                return
            }
            try {
                deliverAction()
            } catch (_: Throwable) {
                // Calling a Result after detach must never crash.
            } finally {
                removeSelf()
            }
        }

        private fun removeSelf() {
            synchronized(pendingReplies) { pendingReplies.remove(this) }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "telemanager.tdlib")
        channel?.setMethodCallHandler(this)
        appContext = binding.applicationContext
        detached = false
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Precise order (main thread; the main looper serializes this
        // with any delivery, so the two cannot interleave):
        // 1. Cancel every pending delayed delivery, so no Result is
        //    delivered after detach.
        // 2. Mark detached, so a delivery that already started drops.
        // 3. Close the client (terminates outstanding TDLib requests)
        //    and stop the executor (no new sends).
        // 4. Drop the channel.
        synchronized(pendingReplies) {
            for (reply in pendingReplies) {
                reply.runnable?.let { mainHandler.removeCallbacks(it) }
            }
            pendingReplies.clear()
        }
        detached = true
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
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
            "getNoBackupFilesDirectory" -> getNoBackupFilesDirectory(result)
            "setTestReplyDelay" -> setTestReplyDelay(call, result)
            "clearTestReplyDelays" -> clearTestReplyDelays(result)
            "getTestSendCounts" -> getTestSendCounts(result)
            "dispose" -> {
                closeClientBestEffort()
                result.success(mapOf("ok" to true))
            }
            else -> result.notImplemented()
        }
    }

    // ---------- no-backup directory (permanent) ----------

    /**
     * Returns the Android no-backup files directory
     * (`Context.getNoBackupFilesDir()`), which the OS excludes from
     * Auto Backup. The TDLib database lives under it so a backup can
     * never restore a database without its (Keystore-bound) key.
     * Permanent (not a test hook).
     */
    private fun getNoBackupFilesDirectory(result: MethodChannel.Result) {
        val dir = appContext?.noBackupFilesDir?.absolutePath
        if (dir == null) {
            result.error(
                "bridge_no_backup_dir",
                "No-backup directory is unavailable.",
                null,
            )
        } else {
            result.success(mapOf("path" to dir))
        }
    }

    // ---------- test-only reply delay (BuildConfig.DEBUG only) ----------

    /**
     * Arms a reply delay for one delayable TDLib method
     * (`setTdlibParameters` or `logOut`). The request is still sent
     * immediately; only the delivery of its result to Dart is delayed
     * by [delayMs]. A delay of 0 removes the entry. Debug builds only;
     * in release this reports `notImplemented`.
     */
    private fun setTestReplyDelay(call: MethodCall, result: MethodChannel.Result) {
        if (!BuildConfig.DEBUG) {
            result.notImplemented()
            return
        }
        val method = call.stringArg("method")
        val delayMs = call.numberArg("delayMs")?.toLong()
        if (method == null || delayMs == null || delayMs < 0 ||
            (method != "setTdlibParameters" && method != "logOut")
        ) {
            result.error(
                "bridge_invalid_args",
                "setTestReplyDelay requires method (setTdlibParameters or " +
                    "logOut) and delayMs >= 0.",
                null,
            )
            return
        }
        synchronized(testReplyDelays) {
            if (delayMs == 0L) {
                testReplyDelays.remove(method)
            } else {
                testReplyDelays[method] = delayMs
            }
        }
        result.success(mapOf("ok" to true))
    }

    /** Clears all armed reply delays. Debug builds only. */
    private fun clearTestReplyDelays(result: MethodChannel.Result) {
        if (!BuildConfig.DEBUG) {
            result.notImplemented()
            return
        }
        synchronized(testReplyDelays) { testReplyDelays.clear() }
        result.success(mapOf("ok" to true))
    }

    /**
     * How many times each delayable TDLib method was sent to the
     * native client. Used by D1 to prove no second
     * `setTdlibParameters` was sent. Debug builds only.
     */
    private fun getTestSendCounts(result: MethodChannel.Result) {
        if (!BuildConfig.DEBUG) {
            result.notImplemented()
            return
        }
        val counts = synchronized(testSendCounts) { testSendCounts.toMap() }
        result.success(counts)
    }

    /**
     * The delayable-method key for a TDLib function, or null when the
     * function is never delayed. Only `SetTdlibParameters` and
     * `LogOut` are delayable (D1/D3).
     */
    private fun delayableMethodKey(function: TdApi.Function<*>): String? {
        return when (function) {
            is TdApi.SetTdlibParameters -> "setTdlibParameters"
            is TdApi.LogOut -> "logOut"
            else -> null
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
        // Fail fast: never create a second client while a previous one
        // is still open (not confirmed closed). The Dart side waits for
        // the Closed state before re-initializing after signOut; if
        // this guard fires, the caller skipped that wait (a sequencing
        // bug). The check must come before closeClientBestEffort(),
        // which drops the reference.
        //
        // The guard, the generation increment, the defensive close,
        // the flag reset, and the Client.create happen inside one
        // synchronized block, so no update handler can interleave
        // between them. (Client.create does not synchronously invoke
        // its handlers — TDLib delivers updates on its own thread —
        // so creating the client while holding the lock cannot
        // deadlock.)
        synchronized(clientLock) {
            if (client != null && !closedObserved) {
                result.error(
                    "bridge_previous_client_open",
                    "A previous TDLib client is still open; wait for Closed " +
                        "before initializing.",
                    null,
                )
                return
            }
            // Defensive: a previous client (e.g. after a failed
            // attempt) is closed best-effort before creating a new one.
            closeClientBestEffortLocked()
            clientGeneration++
            val generation = clientGeneration
            closedObserved = false
            client = Client.create(
                { update ->
                    if (update is TdApi.UpdateAuthorizationState) {
                        onAuthState(update.authorizationState, generation)
                    }
                },
                { e -> postError(0, e.message ?: "update handler error", generation) },
                { e -> postError(0, e.message ?: "default handler error", generation) },
            )
        }
        result.success(mapOf("ok" to true))
    }

    private fun close(result: MethodChannel.Result) {
        // Check, latch install, and send inside one lock hold, so a
        // Closed arriving between them cannot leave the latch
        // installed after the client already closed (which would wait
        // the full 8s for a countdown that already happened). The
        // latch await itself happens outside the lock (otherwise
        // onAuthState could never acquire the lock to count it down).
        val latch = CountDownLatch(1)
        synchronized(clientLock) {
            val c = client
            if (c == null || closedObserved) {
                client = null
                result.success(mapOf("ok" to true))
                return
            }
            closedLatch = latch
            c.send(TdApi.Close(), { _ -> }, { _ -> })
        }
        executor.execute {
            val confirmed = latch.await(8, TimeUnit.SECONDS)
            mainHandler.post {
                // A Closed that arrived before the latch was installed
                // still counts: the client is gone either way.
                val closed = synchronized(clientLock) {
                    closedLatch = null
                    val ok = confirmed || closedObserved
                    if (ok) client = null
                    ok
                }
                if (closed) {
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
        synchronized(clientLock) {
            closeClientBestEffortLocked()
        }
    }

    /** Best-effort close, assuming [clientLock] is held. */
    private fun closeClientBestEffortLocked() {
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
        val databaseEncryptionKey = call.argument<ByteArray>("databaseEncryptionKey")
        if (apiId == null || apiHash == null || databaseDirectory == null ||
            filesDirectory == null || applicationVersion == null ||
            databaseEncryptionKey == null || databaseEncryptionKey.size != 32
        ) {
            result.error(
                "bridge_invalid_args",
                "setTdlibParameters requires apiId, apiHash, databaseDirectory, " +
                    "filesDirectory, applicationVersion, and a 32-byte " +
                    "databaseEncryptionKey.",
                null,
            )
            return
        }
        val dbDir = File(databaseDirectory)
        val filesDir = File(filesDirectory)
        dbDir.mkdirs()
        filesDir.mkdirs()
        // Exact arguments proven by the isolated spike (Tasks 03/04),
        // except the database encryption key: the spike used an empty
        // key (unencrypted database). TeleManager always encrypts the
        // database with the 32-byte key from secure storage (Task 05
        // Harness); the key is bytes end-to-end and is never logged.
        val params = TdApi.SetTdlibParameters(
            false, // useTestDc
            dbDir.absolutePath,
            filesDir.absolutePath,
            databaseEncryptionKey,
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
        // Check and send on the calling (platform) thread, inside the
        // lock, so a Closed arriving between them cannot send to a
        // client that is already gone. Only the latch await runs on
        // the executor. (The locals are written by the TDLib thread
        // in the send callbacks and read by the executor after the
        // latch await; the latch provides the happens-before edge.)
        val latch = CountDownLatch(1)
        var value: Long? = null
        var problem: String? = null
        var problemCode: Int? = null
        synchronized(clientLock) {
            val c = client
            if (c == null) {
                result.error(
                    "bridge_not_initialized",
                    "TDLib client is not initialized.",
                    null,
                )
                return
            }
            if (closedObserved) {
                result.error(
                    "bridge_client_closed",
                    "TDLib client is closed.",
                    null,
                )
                return
            }
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
        }
        executor.execute {
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
     *
     * Check and send inside one lock hold: a Closed arriving between
     * them must not send to a client TDLib already destroyed. The
     * send only enqueues (async), so holding the lock across it is
     * brief and cannot deadlock.
     *
     * Test-only reply delay (BuildConfig.DEBUG only, D1/D3): the
     * request is sent immediately; only the delivery of its
     * MethodChannel.Result to Dart is delayed. The delay is captured
     * at send time, so clearing it later cannot change a request
     * already sent. Authorization-state updates are unaffected (they
     * travel on the separate `onAuthorizationState` channel, never
     * through here). The lock is never held across the delay.
     */
    private fun sendAndAwait(function: TdApi.Function<*>, result: MethodChannel.Result) {
        // Capture the armed delay (if any) and count the send, before
        // sending. Both are brief, non-blocking, and debug-only.
        val delayKey = delayableMethodKey(function)
        val delayMs: Long? = if (BuildConfig.DEBUG && delayKey != null) {
            synchronized(testReplyDelays) { testReplyDelays[delayKey] }
        } else {
            null
        }
        if (BuildConfig.DEBUG && delayKey != null) {
            synchronized(testSendCounts) {
                testSendCounts[delayKey] = (testSendCounts[delayKey] ?: 0) + 1
            }
        }
        synchronized(clientLock) {
            val c = client
            if (c == null) {
                result.error(
                    "bridge_not_initialized",
                    "TDLib client is not initialized.",
                    null,
                )
                return
            }
            if (closedObserved) {
                result.error(
                    "bridge_client_closed",
                    "TDLib client is closed.",
                    null,
                )
                return
            }
            c.send(
                function,
                { obj ->
                    scheduleDelivery(result, delayMs) {
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
                    scheduleDelivery(result, delayMs) {
                        result.error(
                            "bridge_exception",
                            "${e.javaClass.simpleName}: ${e.message}",
                            null,
                        )
                    }
                },
            )
        }
    }

    /**
     * Schedules the delivery of a TDLib result to Dart. With no armed
     * delay (the normal case, and always in release builds) the result
     * is posted to the main thread immediately. With an armed delay
     * (debug only) the result is held in a [PendingReply] and
     * delivered after the delay. The TDLib callback returns
     * immediately in both cases; the reply is never lost while the
     * engine is attached (a Dart timeout does not discard it — it is
     * delivered late, which is what releases the Dart pending entry).
     * Delivery is exactly once, on the main thread, and never after
     * detach (see [PendingReply] and [onDetachedFromEngine]).
     */
    private fun scheduleDelivery(
        result: MethodChannel.Result,
        delayMs: Long?,
        deliverAction: () -> Unit,
    ) {
        val reply = PendingReply(result, deliverAction)
        synchronized(pendingReplies) { pendingReplies.add(reply) }
        val runnable = Runnable { reply.deliver() }
        reply.runnable = runnable
        if (delayMs != null && delayMs > 0) {
            mainHandler.postDelayed(runnable, delayMs)
        } else {
            mainHandler.post(runnable)
        }
    }

    // ---------- updates ----------

    /**
     * Authorization-state update from a TDLib client. [generation]
     * is the generation captured at `Client.create` time.
     *
     * Two checks close the publishing race:
     * - First check (TDLib thread, under the lock): drops a stale
     *   update early and applies the Closed side effects atomically
     *   (closedObserved + latch countdown + client nulling), so the
     *   latch timing stays synchronous with the update.
     * - Second check (publish time, under the lock): the generation
     *   check AND the `invokeMethod` happen inside the same lock
     *   hold, so no `initialize()` can interleave between them. A
     *   new client created in between makes this update stale and it
     *   is dropped before it can reach Dart.
     *
     * `invokeMethod` is fire-and-forget (no result callback, no wait
     * for Dart), does not call back into this class, and only encodes
     * a small map — so holding the lock across it is brief,
     * non-blocking, and cannot deadlock.
     */
    private fun onAuthState(state: TdApi.AuthorizationState, generation: Int) {
        val shouldPost = synchronized(clientLock) {
            if (generation != clientGeneration) {
                false
            } else {
                if (state is TdApi.AuthorizationStateClosed) {
                    closedObserved = true
                    closedLatch?.countDown()
                    client = null
                }
                true
            }
        }
        if (!shouldPost) return
        mainHandler.post {
            synchronized(clientLock) {
                if (generation == clientGeneration) {
                    val payload = mapAuthState(state)
                    channel?.invokeMethod("onAuthorizationState", payload, null)
                }
                // else: dropped. The old update must not reach Dart,
                // must not overtake a newer update, and must not
                // change the new provider's state.
            }
        }
    }

    /**
     * Unsolicited TDLib error. Same two-check, atomic-publish
     * pattern as [onAuthState]: a stale error must not overwrite the
     * new client's `lastError`.
     */
    private fun postError(code: Int, message: String, generation: Int) {
        val shouldPost = synchronized(clientLock) {
            generation == clientGeneration
        }
        if (!shouldPost) return
        mainHandler.post {
            synchronized(clientLock) {
                if (generation == clientGeneration) {
                    channel?.invokeMethod(
                        "onError",
                        mapOf("code" to code, "message" to message),
                        null,
                    )
                }
            }
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
