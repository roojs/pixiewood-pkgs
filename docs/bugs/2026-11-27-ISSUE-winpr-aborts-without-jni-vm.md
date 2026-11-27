# Opening a desktop on Android aborts in WinPR because no JavaVM was set

**Status:** ✔️

## User decisions required

None.

## User reported

- 🔷 The phone crashes, including when a remote desktop is opened.

## Success scenario

- Creating a FreeRDP context on Android does not abort when `libwinpr3.so` was not loaded through `System.loadLibrary`.
- `freerdp_settings_new` returns a settings object.
- The Argus controller can open the desktop page on the phone without the process dying in `winpr_jni_attach_thread`.

## Current behavior

- What you said
  - The phone has crashes, and one of them is the remote desktop.
- Observable product outcome
  - `org.roojs.argus` aborts on the GTK thread the first time it builds a FreeRDP context.
  - The abort text is `winpr_int_assert`: `((jniVm))` in `winpr/libwinpr/utils/android.c` `winpr_jni_attach_thread`.
  - The frames above that are `ConvertUtf8NToWChar`, `freerdp_getApplicationDetailsVendor`, `freerdp_settings_new`, `freerdp_context_new_ex`, then `argus_controller_rdp_screen_configure`.

## Codebase observed behavior

- This package builds FreeRDP `3.33.1` from the upstream tarball. [`packages/freerdp/freerdp.wrap`](../../packages/freerdp/freerdp.wrap) names that tarball. There is no patch on the WinPR Android file.
- Upstream `winpr/libwinpr/utils/android.c` at tag `3.33.1` stores the VM only in `JNI_OnLoad`:

```c
JavaVM* jniVm = nullptr;

WINPR_API jint JNI_OnLoad(JavaVM* vm, void* reserved)
{
	jniVm = vm;
	return JNI_VERSION_1_6;
}

jboolean winpr_jni_attach_thread(JNIEnv** env)
{
	WINPR_ASSERT(jniVm);
	if ((*jniVm)->GetEnv(jniVm, (void**)env, JNI_VERSION_1_4) != JNI_OK)
	{
		(*jniVm)->AttachCurrentThread(jniVm, env, nullptr);
		return JNI_TRUE;
	}
	return JNI_FALSE;
}
```

- `JNI_OnLoad` runs when Android loads a library with `System.loadLibrary`. `libwinpr3.so` is a dependency of the native controller, loaded by the linker. That path does not call `JNI_OnLoad`, so `jniVm` stays null and the assert fires.
- [`packages/glib/glib.wrap`](../../packages/glib/glib.wrap) already carries Android patches with `diff_files`. FreeRDP does not.

## Debugging

### Current debug output

- Source: phone crash buffer, `adb logcat -b crash`, 2026-11-27 16:02:30, process `org.roojs.argus`.

```text
Abort message: '[pid=14031:tid=000036ef] - [winpr_int_assert]: ((jniVm)) [winpr/libwinpr/utils/android.c:winpr_jni_attach_thread:54]'
#02 pc … libwinpr3.so
#04 pc … libwinpr3.so (ConvertUtf8NToWChar+92)
#07 pc … libfreerdp3.so (freerdp_getApplicationDetailsVendor+32)
#08 pc … libfreerdp3.so (freerdp_settings_new+64)
#10 pc … libfreerdp3.so (freerdp_context_new_ex+108)
#11 pc … libargus-controller.so (argus_controller_rdp_screen_configure+120)
#12 pc … libargus-controller.so (argus_controller_rdp_screen_begin+2356)
```

- Takeaway: settings creation asks WinPR to convert a string, and that conversion asserts because the JavaVM was never stored.

### Debug code added (remove when complete)

None.

## Proposed fix

### Phase 1 — patch WinPR so a missing JavaVM is not fatal

**Why:** The phone never gets `JNI_OnLoad`. The assert is the crash. Returning failure from the attach is not enough: the next line would dereference a null `jniVm`. The UTF-8 to wide conversion that called attach has to finish with a plain C conversion when there is no VM.

**Where:** A new `packages/freerdp/packagefiles/freerdp/jni-vm.patch` against FreeRDP `3.33.1`, listed from [`packages/freerdp/freerdp.wrap`](../../packages/freerdp/freerdp.wrap) the same way [`packages/glib/glib.wrap`](../../packages/glib/glib.wrap) lists `diff_files`.

**Depends on:** none.

#### Add — `diff_files` on the wrap, after `patch_directory`

```ini
diff_files=freerdp/jni-vm.patch
```

The patch itself:

- `winpr_jni_attach_thread` returns `JNI_FALSE` when `jniVm` is null. Delete the `WINPR_ASSERT(jniVm)` in that function.
- `winpr_jni_detach_thread` returns immediately when `jniVm` is null. Delete the `WINPR_ASSERT(jniVm)` in that function.
- `ConvertUtf8NToWChar` (the caller named in the tombstone) uses its non-JNI conversion when attach returns `JNI_FALSE` because there is no VM. Do not leave a path that uses `jniVm` after that failure.

## LLM

- ℹ️ This is the second phone abort from 2026-11-27. The other one, `gee_promise_set_value` inside `oll_mrpc_client_disconnect`, is `OLLMchat/docs/bugs/2026-11-27-ISSUE-client-disconnect-sets-promise-twice.md`. It is not this package.
- ℹ️ Argus `controller/Rdp/Screen.vala` `configure` calls `instance.context_new()`, which is `freerdp_context_new_ex`. No Argus change can set `jniVm` without a new WinPR entry point. The library has to tolerate the missing VM.
- ℹ️ Upstream file: `https://github.com/FreeRDP/FreeRDP/blob/3.33.1/winpr/libwinpr/utils/android.c`
