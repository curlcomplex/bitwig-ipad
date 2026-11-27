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
for name in TLG aKf; do
  unzip -p "$jar" "$name.class" > "$GRID_SCRATCH/policy/$name.stock"
done
java -cp "$GRID_SCRATCH/tools:$classpath" PatchGridSourceSelection "$GRID_SCRATCH/policy"
java -cp "$GRID_SCRATCH/tools:$classpath" PatchGridInspector "$GRID_SCRATCH/policy"
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

`VerifyGridSourceProfile` takes the locally resolved stock embedded Clock Quantize binary as its single argument. Include `$GRID_SCRATCH/policy/classes` before the test classes and stock JARs on its classpath, and set `-DinstallationRoot` to the original app bundle. It checks original source-object kind, archive path and digest, rejection of changed source, and stock pass-through with no admitted graph.

To prepare the same class overlay as a single local JAR, run `python3 probe/grid-rate/prepare.py "$BITWIG_APP" "$GRID_SCRATCH/overlay.jar"` with the Java 25 toolchain on `PATH`. The output contains four exact locally patched class definitions and the shared runtime helpers. It is a local build artifact. The normal launcher still uses its original archive, and the prepared code has no graph admission caller.

For a desktop Patchbay file hook, run `python3 probe/grid-rate/prepare.py --patchbay "$BITWIG_APP" "$GRID_SCRATCH/patchbay"`. This writes the four replacements as individual class files, a replacement map, and a helper JAR containing only compatibility classes. The upstream launcher from Patchbay commit `4756a2178276068d488fcde3725eaa6c0ad57e5e` loaded the four replacements and helper classes in the original system class loader during the headless codec check. A desktop GUI session still needs validation. Use an isolated original 6.1.7 app.

```sh
BITWIG_CLASS_HOOK_MODE=file \
BITWIG_REPLACEMENT_MAP="$GRID_SCRATCH/patchbay/replacement-map.tsv" \
BITWIG_HELPER_JAR="$GRID_SCRATCH/patchbay/grid-helper.jar" \
BML_TRACE_ENABLED=0 \
  bash "$PATCHBAY_ROOT/loader/src/loader/jvmti/launch-bitwig-agent.sh" "$BITWIG_APP"
```

The helper JAR and individual patched files are generated from your local copy. The command leaves that app bundle untouched. This staging path has no active Oversampling row until the whole-graph implementation admits the device.

For an opt-in iPad development package, add `--grid-rate-overlay` to the existing `build-native-host.py --device --embedded-engine` invocation with local 6.1.7. It adds a separate class overlay resource ahead of the unchanged copied stock JAR. Ordinary builds keep their existing classpath.
