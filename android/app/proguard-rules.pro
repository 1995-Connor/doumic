# Flutter / plugins
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.doumic.app.** { *; }

# Shizuku UserService (loaded by reflection in another process)
-keep class com.doumic.app.VirtualMicUserService { *; }
-keepclassmembers class com.doumic.app.VirtualMicUserService { *; }
-keep class com.doumic.app.IVirtualMicUserService { *; }
-keep class com.doumic.app.IVirtualMicUserService$* { *; }

# AudioPolicy accessed via reflection
-dontwarn android.media.audiopolicy.**

# Flutter deferred components / Play Core (not used)
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task
