# kotlinx.serialization: Serializer-Klassen und JsonElement-Typen behalten
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keep,includedescriptorclasses class de.uniflow.**$$serializer { *; }
-keepclassmembers class de.uniflow.** { *** Companion; }
-keepclasseswithmembers class de.uniflow.** { kotlinx.serialization.KSerializer serializer(...); }
# Tink (ueber security-crypto) verweist auf Annotationen, die nicht mitgeliefert werden; zur Laufzeit unnoetig
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn javax.annotation.concurrent.**
# PdfRenderer und Verschluesselung der Einstellungen sind Plattformklassen; nichts weiter noetig
