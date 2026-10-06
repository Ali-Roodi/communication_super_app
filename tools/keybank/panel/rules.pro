# ProGuard for the release installer: shrink only (no obfuscation, no
# optimisation). Its job is dropping the ~2000 Material icons the panel does
# not draw; the crypto is kept whole so nothing reflective can go missing.
-dontobfuscate
-dontoptimize
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class com.example.communication_super_app.** { *; }
-keep class ir.hamrasan.** { *; }
