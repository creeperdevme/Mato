# Flutter 的 Gradle 外掛會自動把這個檔案加進 release 的 R8 規則。

# 以 Pigeon JNI 實作的外掛（例如 shared_preferences_android 2.5 起）會用類別名稱
# 在執行期查找這些 Kotlin 類別；R8 把它們改名後，suspend 方法的簽章對不上，
# 一呼叫就丟 NoSuchMethodError，App 停在啟動畫面（flutter/flutter#194649）。
# 等 package:jni 自帶這些規則後即可移除（dart-lang/native#3732）。
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt { *; }
