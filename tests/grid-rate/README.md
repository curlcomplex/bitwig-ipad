# Grid rate compatibility tests

These offline tests use an original Bitwig Studio 6.1.7 installation and run its compiler and document codec in a disposable directory. They cover individual source transformations and native-device record serialization. A complete Grid graph, finished selector, and desktop or iPad deployment are outside these tests.

Use a Java 25 or later JDK. Supply `BITWIG_APP` as the original app bundle path and `GRID_SCRATCH` as a fresh writable directory under the ignored local build tree. Copy no Bitwig input, extracted class, compiled IR, or test output into the source tree.

```sh
jar="$BITWIG_APP/Contents/Java/bitwig.jar"
classpath="$jar:$BITWIG_APP/Contents/Java/libs.jar"
mkdir -p "$GRID_SCRATCH"/{tools,home,policy}
javac --release 25 -cp "$classpath" -d "$GRID_SCRATCH/tools" \
  probe/grid-rate/*.java tests/grid-rate/*.java
for name in AiR utt; do
  unzip -p "$jar" "com/bitwig/flt/document/core/master/device/$name.class" \
    > "$GRID_SCRATCH/policy/$name.stock"
done
java -cp "$GRID_SCRATCH/tools:$classpath" PatchGridPolicy "$GRID_SCRATCH/policy"
java -Xverify:all -DinstallationRoot="$BITWIG_APP" -Duser.home="$GRID_SCRATCH/home" \
  -cp "$GRID_SCRATCH/tools:$classpath" VerifyGridPolicy stock-write "$GRID_SCRATCH/policy"
java -Xverify:all -DinstallationRoot="$BITWIG_APP" -Duser.home="$GRID_SCRATCH/home" \
  -cp "$GRID_SCRATCH/policy/classes:$GRID_SCRATCH/tools:$classpath" \
  VerifyGridPolicy patched "$GRID_SCRATCH/policy"
java -Xverify:all -DinstallationRoot="$BITWIG_APP" -Duser.home="$GRID_SCRATCH/home" \
  -cp "$GRID_SCRATCH/tools:$classpath" VerifyGridPolicy stock "$GRID_SCRATCH/policy"
```

`GridCacheProof` takes the scratch directory followed by local `.nitrobin` input paths. For each input, the original stock compiler runs a 4×, 1×, 4× sequence in one process. The test requires distinct variant cache identity and byte-identical original LLVM IR at the final 4× step. Configure `java.library.path` to locate the original Bitwig JNI library for this test. On macOS, a scratch link named `libbitwig-jni.dylib` can point to the installed `libbitwig-jni.jnilib`.
