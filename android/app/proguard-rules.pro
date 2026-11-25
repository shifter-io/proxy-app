# hev-socks5-tunnel registers its JNI methods on io.shifter.app.HevTunnel by
# name when the library loads. R8 must not rename or remove that class or its
# native methods, or JNI_OnLoad fails and the VPN service crashes on connect.
-keep class io.shifter.app.HevTunnel { *; }
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
