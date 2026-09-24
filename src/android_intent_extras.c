// Read the launch intent's string extras (labelle-sokol#25; the sokol twin of
// labelle-bgfx's `android_intent_extras.c`, labelle-bgfx#139).
//
// `labelle run --platform=android --scene=X` launches the activity with
// `am start ... --es LABELLE_SCENE X` (labelle-cli#397), because an app the
// system starts has no environment the CLI could write into. The backend turns
// the allow-listed extras back into env vars (`android_intent_env.zig`, driven
// by `launch_intent_env.zig`) so the engine's `getenv` reads work unchanged.
// This is the JNI half:
//   activity.getIntent().getStringExtra(key)
//   activity.getApplicationInfo().flags & FLAG_DEBUGGABLE
//
// It lives in C rather than Zig because <jni.h> already declares the
// JNINativeInterface / JNIInvokeInterface vtables; hand-rolling those ordered
// function-pointer slots in Zig would be a silent-wrong-field hazard (same
// rationale as `android_gamepad_jni.c`). Off Android this is an empty TU;
// `build.zig` only compiles it for Android anyway.
#ifdef __ANDROID__

#include <android/native_activity.h>
#include <jni.h>
#include <stddef.h>
#include <string.h>

// android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE. A platform constant
// since API 1; spelled out here because the NDK exposes no header for it.
#define LABELLE_FLAG_DEBUGGABLE 0x00000002

// Resolve a JNIEnv for the calling thread. `sokol_main()` runs on the UI
// thread, which the VM already has attached, but don't depend on it: attach if
// needed and report it, so the caller detaches only what WE attached
// (detaching a thread someone else attached would tear down their env).
static JNIEnv *acquire_env(JavaVM *vm, int *we_attached) {
    JNIEnv *env = NULL;
    *we_attached = 0;
    jint rc = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (rc == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
        *we_attached = 1;
    } else if (rc != JNI_OK) {
        return NULL;
    }
    return env;
}

// For each of the `count` keys, copy its string extra (NUL-terminated) into
// `buf` back to back and store its length in `lens[i]`; -1 means the extra is
// absent (or not a string), -2 that it did not fit in what was left of `buf`.
// `activity_ptr` is the running `ANativeActivity*`
// (`sapp_android_get_native_activity()`). Returns 1 when the intent was read,
// 0 on any JNI failure (then `lens` is all -1: nothing to apply). Never leaves
// a Java exception pending and never leaks a local ref.
int labelle_sokol_read_intent_extras(const void *activity_ptr, const char *const *keys, int count,
                                     char *buf, size_t buf_cap, int *lens) {
    if (lens == NULL || count < 0) return 0;
    for (int i = 0; i < count; i++) lens[i] = -1;
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL || keys == NULL || buf == NULL) return 0;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;

    int we_attached = 0;
    JNIEnv *env = acquire_env(vm, &we_attached);
    if (env == NULL) return 0;

    int ok = 0;
    // Room for the activity class, intent, its class and, per key, the key and
    // value strings; the frame hands them all back in one pop.
    if ((*env)->PushLocalFrame(env, 4 + 2 * count) == JNI_OK) {
        jclass activity_cls = (*env)->GetObjectClass(env, activity);
        jmethodID get_intent = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getIntent", "()Landroid/content/Intent;") : NULL;
        // A launcher-icon launch still has an intent, just no extras; null only
        // if something unusual cleared it. Either way "no extras" is the answer.
        jobject intent = (get_intent && !(*env)->ExceptionCheck(env)) ? (*env)->CallObjectMethod(env, activity, get_intent) : NULL;
        if (!(*env)->ExceptionCheck(env) && intent != NULL) {
            jclass intent_cls = (*env)->GetObjectClass(env, intent);
            jmethodID get_extra = intent_cls ? (*env)->GetMethodID(env, intent_cls, "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;") : NULL;
            if (get_extra != NULL && !(*env)->ExceptionCheck(env)) {
                ok = 1;
                size_t used = 0;
                for (int i = 0; i < count && ok; i++) {
                    jstring jkey = (*env)->NewStringUTF(env, keys[i]);
                    if (jkey == NULL || (*env)->ExceptionCheck(env)) {
                        ok = 0;
                        break;
                    }
                    // getStringExtra answers null for a missing key and for an
                    // extra of another type (`--ei`); both read as "absent".
                    jstring jval = (jstring)(*env)->CallObjectMethod(env, intent, get_extra, jkey);
                    if ((*env)->ExceptionCheck(env)) {
                        ok = 0;
                        break;
                    }
                    if (jval != NULL) {
                        const char *chars = (*env)->GetStringUTFChars(env, jval, NULL);
                        if (chars == NULL) {
                            ok = 0; // OOM: an exception is pending
                            break;
                        }
                        size_t len = strlen(chars);
                        if (len + 1 <= buf_cap - used) {
                            memcpy(buf + used, chars, len + 1);
                            lens[i] = (int)len;
                            used += len + 1;
                        } else {
                            lens[i] = -2;
                        }
                        (*env)->ReleaseStringUTFChars(env, jval, chars);
                    }
                }
            }
        }
        // Never hand a pending exception back to the caller's thread.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            ok = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }

    if (!ok) {
        for (int i = 0; i < count; i++) lens[i] = -1;
    }
    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return ok;
}

// Is the RUNNING apk `android:debuggable`? The screenshot extras are honoured
// only then (see `android_intent_env.zig`: the NativeActivity is exported, so
// any app could otherwise make a release build write a file of its choosing).
// Returns 1 (debuggable), 0 (not), or 0 on any JNI failure — fail CLOSED.
int labelle_sokol_app_is_debuggable(const void *activity_ptr) {
    const ANativeActivity *na = (const ANativeActivity *)activity_ptr;
    if (na == NULL || na->vm == NULL || na->clazz == NULL) return 0;
    JavaVM *vm = na->vm;
    jobject activity = na->clazz;

    int we_attached = 0;
    JNIEnv *env = acquire_env(vm, &we_attached);
    if (env == NULL) return 0;

    int debuggable = 0;
    if ((*env)->PushLocalFrame(env, 8) == JNI_OK) {
        jclass activity_cls = (*env)->GetObjectClass(env, activity);
        jmethodID get_app_info = activity_cls ? (*env)->GetMethodID(env, activity_cls, "getApplicationInfo", "()Landroid/content/pm/ApplicationInfo;") : NULL;
        jobject app_info = (get_app_info && !(*env)->ExceptionCheck(env)) ? (*env)->CallObjectMethod(env, activity, get_app_info) : NULL;
        if (!(*env)->ExceptionCheck(env) && app_info != NULL) {
            jclass app_info_cls = (*env)->GetObjectClass(env, app_info);
            jfieldID flags_fid = app_info_cls ? (*env)->GetFieldID(env, app_info_cls, "flags", "I") : NULL;
            if (flags_fid != NULL && !(*env)->ExceptionCheck(env)) {
                jint flags = (*env)->GetIntField(env, app_info, flags_fid);
                debuggable = (flags & LABELLE_FLAG_DEBUGGABLE) ? 1 : 0;
            }
        }
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            debuggable = 0;
        }
        (*env)->PopLocalFrame(env, NULL);
    } else if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }

    if (we_attached) (*vm)->DetachCurrentThread(vm);
    return debuggable;
}

#endif /* __ANDROID__ */
