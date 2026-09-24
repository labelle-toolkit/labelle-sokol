// Read the launching Intent's string extras for a caller-supplied key list
// (labelle-sokol#25). The Zig side (`launch_intent_env.zig`) passes the
// `LABELLE_*` allow-list and `setenv`s whatever is reported back through
// `on_extra`, so `labelle run --platform=android --scene=X` (which launches
// with `am start … --es LABELLE_SCENE X`, labelle-cli#397) reaches the
// engine's `getenv`.
//
// The JNI walk:
//   Intent intent = activity.getIntent();
//   for each key: String v = intent.getStringExtra(key); if (v != null) report
//
// It lives in C rather than Zig because <jni.h> already declares the
// JNINativeInterface / JNIInvokeInterface vtables; hand-rolling those ordered
// function-pointer slots in Zig would be a silent-wrong-field hazard (same
// rationale as `android_gamepad_jni.c` and labelle-bgfx's
// `android_debuggable.c`).
//
// Off Android this is an empty TU (same convention as
// `android_gamepad_jni.c`); `build.zig` only compiles it for Android anyway.
#ifdef __ANDROID__

#include <android/native_activity.h>
#include <jni.h>
#include <stddef.h>

typedef void (*labelle_intent_extra_fn)(void *ctx, const char *key,
                                        const char *value);

// Clear any pending Java exception. Returns 1 if there was one.
static int clear_exception(JNIEnv *env) {
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return 1;
    }
    return 0;
}

// `activity_ptr` is the running `ANativeActivity*`
// (`sapp_android_get_native_activity()`). For each of `keys[0..key_count)`
// that the launch Intent carries as a String extra, calls
// `on_extra(ctx, key, value)`; `value` is valid only for that call.
//
// Returns the number of extras reported (0 when launched with none, e.g. from
// the launcher icon), or -1 when the Intent could not be read at all (no
// activity/VM, attach failure, JNI failure, null Intent). Never leaves a Java
// exception pending and never leaks a local ref.
int labelle_sokol_read_intent_extras(const void *activity_ptr,
                                     const char *const *keys, size_t key_count,
                                     labelle_intent_extra_fn on_extra,
                                     void *ctx) {
    const ANativeActivity *activity = (const ANativeActivity *)activity_ptr;
    if (activity == NULL || activity->vm == NULL || activity->clazz == NULL ||
        keys == NULL || on_extra == NULL)
        return -1;
    JavaVM *vm = activity->vm;

    // Called from `sokol_main()` on the UI thread, which the VM already has
    // attached — but don't depend on it: attach if needed, and detach again
    // only if WE attached (detaching a thread someone else attached would tear
    // down their env).
    JNIEnv *env = NULL;
    int we_attached = 0;
    jint rc = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK || env == NULL)
            return -1;
        we_attached = 1;
    } else if (rc != JNI_OK || env == NULL) {
        return -1;
    }

    int reported = -1;

    // Outer frame: the activity class, the Intent and the Intent class.
    if ((*env)->PushLocalFrame(env, 4) == JNI_OK) {
        jobject act = activity->clazz;
        jclass act_cls = (*env)->GetObjectClass(env, act);
        jmethodID get_intent =
            act_cls ? (*env)->GetMethodID(env, act_cls, "getIntent",
                                          "()Landroid/content/Intent;")
                    : NULL;
        jobject intent = NULL;
        if (!clear_exception(env) && get_intent != NULL) {
            intent = (*env)->CallObjectMethod(env, act, get_intent);
            if (clear_exception(env)) intent = NULL;
        }
        jclass intent_cls =
            intent ? (*env)->GetObjectClass(env, intent) : NULL;
        jmethodID get_string_extra =
            intent_cls
                ? (*env)->GetMethodID(env, intent_cls, "getStringExtra",
                                      "(Ljava/lang/String;)Ljava/lang/String;")
                : NULL;
        if (clear_exception(env)) get_string_extra = NULL;

        if (get_string_extra != NULL) {
            reported = 0;
            for (size_t i = 0; i < key_count; i++) {
                if (keys[i] == NULL) continue;
                // Per-key frame: the key jstring and the value jstring.
                if ((*env)->PushLocalFrame(env, 2) != JNI_OK) {
                    clear_exception(env);
                    break;
                }
                jstring jkey = (*env)->NewStringUTF(env, keys[i]);
                jstring jval = NULL;
                if (jkey != NULL && !clear_exception(env)) {
                    jval = (jstring)(*env)->CallObjectMethod(
                        env, intent, get_string_extra, jkey);
                    if (clear_exception(env)) jval = NULL;
                } else {
                    clear_exception(env);
                }
                if (jval != NULL) {
                    const char *utf = (*env)->GetStringUTFChars(env, jval, NULL);
                    if (utf != NULL) {
                        on_extra(ctx, keys[i], utf);
                        (*env)->ReleaseStringUTFChars(env, jval, utf);
                        reported++;
                    } else {
                        clear_exception(env); // OutOfMemoryError
                    }
                }
                (*env)->PopLocalFrame(env, NULL);
            }
        }

        clear_exception(env);
        (*env)->PopLocalFrame(env, NULL);
    } else {
        clear_exception(env);
    }

    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return reported;
}

#endif /* __ANDROID__ */
