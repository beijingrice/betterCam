-keep class com.android.vending.billing.** { *; }
# EXIF tag names are enumerated reflectively when copying metadata to processed JPEGs.
-keepclassmembers class androidx.exifinterface.media.ExifInterface {
    public static final java.lang.String TAG_*;
}
