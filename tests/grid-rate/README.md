# Grid rate compatibility tests

These offline tests use an original Bitwig Studio 6.1.7 installation and run its compiler and document codec in a disposable directory. They check exact source admission, source transformations, cache isolation, and the native device record codec. Runtime evidence is tracked separately below.

Use a Java 25 or later JDK. Supply `BITWIG_APP` as the original app bundle path and `GRID_SCRATCH` as a fresh writable directory under the ignored local build tree. Copy no Bitwig input, extracted class, compiled IR, or test output into the source tree.

```sh
jar="$BITWIG_APP/Contents/Java/bitwig.jar"
classpath="$jar:$BITWIG_APP/Contents/Java/libs.jar"
mkdir -p "$GRID_SCRATCH"/{tools,home,policy}
javac --release 25 -cp "$classpath" -d "$GRID_SCRATCH/tools" \
  probe/grid-rate/*.java tests/grid-rate/*.java
for name in AiR utt nWI; do
  unzip -p "$jar" "com/bitwig/flt/document/core/master/device/$name.class" \
    > "$GRID_SCRATCH/policy/$name.stock"
done
unzip -p "$jar" com/bitwig/flt/document/core/master/CmH.class > "$GRID_SCRATCH/policy/CmH.stock"
for name in TLG aKf; do
  unzip -p "$jar" "$name.class" > "$GRID_SCRATCH/policy/$name.stock"
done
java -cp "$GRID_SCRATCH/tools:$classpath" PatchGridSourceSelection "$GRID_SCRATCH/policy"
java -cp "$GRID_SCRATCH/tools:$classpath" PatchGridInspector "$GRID_SCRATCH/policy"
java -cp "$GRID_SCRATCH/tools:$classpath" PatchGridGraph "$GRID_SCRATCH/policy"
java -cp "$GRID_SCRATCH/tools:$classpath" PatchGridDocument "$GRID_SCRATCH/policy"
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

To prepare the same class overlay as a single local JAR, run `python3 probe/grid-rate/prepare.py "$BITWIG_APP" "$GRID_SCRATCH/overlay.jar"` with the Java 25 toolchain on `PATH`. The output contains six exact locally patched class definitions and the shared runtime helpers. It is a local build artifact. The normal launcher still uses its original archive.

For a desktop Patchbay file hook, run `python3 probe/grid-rate/prepare.py --patchbay "$BITWIG_APP" "$GRID_SCRATCH/patchbay"`. This writes the six replacements as individual class files, a replacement map, and a helper JAR containing only compatibility classes. The upstream launcher from Patchbay commit `4756a2178276068d488fcde3725eaa6c0ad57e5e` loaded all six class replacements and the compatibility helpers through the native JVMTI file hook in the original system class loader during the headless codec check. A desktop GUI session still needs validation. Use an isolated original 6.1.7 app.

```sh
BITWIG_CLASS_HOOK_MODE=file \
BITWIG_REPLACEMENT_MAP="$GRID_SCRATCH/patchbay/replacement-map.tsv" \
BITWIG_HELPER_JAR="$GRID_SCRATCH/patchbay/grid-helper.jar" \
BML_TRACE_ENABLED=0 \
  bash "$PATCHBAY_ROOT/loader/src/loader/jvmti/launch-bitwig-agent.sh" "$BITWIG_APP"
```

The helper JAR and individual patched files are generated from your local copy. The command leaves that app bundle untouched. The Inspector exposes the **DSP rate** choice when the complete graph qualifies for the overlay. The default is 4×.

For an opt-in iPad development package, add `--grid-rate-overlay` to the existing `build-native-host.py --device --embedded-engine` invocation with local 6.1.7. It adds a separate class overlay resource ahead of the unchanged copied stock JAR. Ordinary builds keep their existing classpath.

## Coverage and runtime evidence

The overlay targets the exact stock 6.1.7 source set for Poly Grid, FX Grid and Note Grid. The source audit classified 233 stock module definitions and materialized 118 distinct transformed source inputs. This measures source coverage. The same-process compiler test covers cache separation and byte-identical restored stock IR for the inputs it exercises.

Physical iPad checks covered native selector interaction and persistence and a small patch benchmark. A saved Poly Grid cold-opened at 1× before the Inspector appeared, published 15 compiled assets, and produced 49,178 nonzero output frames. Inserting stock Constant through the original model method grew that graph from three to four modules and compiled the new atom at 1×. FX Grid exposed the native 1× row and produced 49,731 nonzero wet output frames. Note Grid exposed the native 1× row and produced 48,626 nonzero output frames through a downstream Poly Grid with the original Note Thru disabled. The stock codec check verifies that an unmodified app opens the record and drops the overlay field when re-saving.

Long Delay and Comb were wired through the original Grid model in disposable iPad projects. The app displayed the tested Long Delay settings of 100 and 150 ms and the Comb settings of 200 Hz and 18 kHz. The routed graphs ran and produced audio. A Sampler accepted a local fixture WAV and the original model wired its Gate In and stereo output while the FX Grid stayed at 1×. The stock onset analysis subprocess reported a launch error. The recorded test PCM could not be retrieved, so precise delay timing, the Comb FIR transition waveform, and isolated Sampler playback and retrigger behavior remain unverified on hardware.

The same FX Grid published 12 assets at 4× and then 12 at 1× while the transport kept running. The loop was resting during the changes and produced audio again afterwards. An in-flight worker result was not exercised. The pinned Patchbay native file loader check ran headlessly, and desktop GUI validation remains pending.
