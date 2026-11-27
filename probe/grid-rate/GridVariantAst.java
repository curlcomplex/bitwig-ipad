import com.bitwig.nitro.ConstantDeclaration;
import com.bitwig.nitro.NitroFile;
import com.bitwig.nitro.QxI;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.IdentityHashMap;
import java.util.List;

final class GridVariantAst {
    private static final String PREFIX = "com.bitwig.nitro.";
    private static String carrier(String pair) {
        StringBuilder code = new StringBuilder("f32<8> carrier; ");
        for (int i = 0; i < 8; i++) code.append("carrier[").append(i).append("] = ")
            .append(pair).append("[").append(i % 2).append("]; ");
        return code.toString();
    }
    private static String outputCarrier(String pair) {
        return carrier(pair) + "out = carrier;";
    }
    private static Class<?> type(String name) throws ReflectiveOperationException {
        return Class.forName(PREFIX + name);
    }
    private static Field field(Class<?> owner, String name) throws ReflectiveOperationException {
        Field f = owner.getDeclaredField(name);
        f.setAccessible(true);
        return f;
    }
    private static String name(Object declaration) throws ReflectiveOperationException {
        var getter = declaration.getClass().getMethod("scr");
        getter.setAccessible(true);
        return (String) getter.invoke(declaration);
    }
    @SuppressWarnings("unchecked")
    private static List<Object> children(Object component) throws ReflectiveOperationException {
        return (List<Object>) field(type("ComponentDeclaration"), "Anf").get(component);
    }
    private static Object find(List<Object> children, String exactType, String optionalName) throws ReflectiveOperationException {
        List<Object> matches = new ArrayList<>();
        for (Object child : children) {
            if (child.getClass().getSimpleName().equals(exactType) &&
                (optionalName == null || optionalName.equals(name(child)))) matches.add(child);
        }
        if (matches.size() != 1) throw new IllegalStateException("Expected one " + exactType + "/" + optionalName);
        return matches.get(0);
    }
    private static List<Object> fragment(String source) throws ReflectiveOperationException {
        NitroFile ast = NitroFile.beI(("component PrivateFixture { " + source + " }")
            .getBytes(StandardCharsets.UTF_8), "private-grid-1x");
        return children(ast.ymo());
    }
    private static void replaceProcess(List<Object> declarations, String body) throws ReflectiveOperationException {
        Object old = find(declarations,"ProcessBlockDeclaration",null);
        Object replacement = find(fragment("process { " + body + " }"),"ProcessBlockDeclaration",null);
        declarations.set(declarations.indexOf(old), replacement);
    }

    static NitroFile apply(NitroFile stock) {
        return apply(stock, false);
    }

    static NitroFile apply(NitroFile stock, boolean builtinPulse) {
        try {
            Object root = stock.ymo();
            List<Object> declarations = children(root);
            switch (name(root)) {
            case "upsampler" -> replaceProcess(declarations, "f32<2> sample = in; " + outputCarrier("sample"));
            case "downsampler" -> replaceProcess(declarations, "f32<2> sample; sample[0] = in[0]; sample[1] = in[1]; out = sample;");
            case "grid_sine4", "grid_saw4", "grid_tri4", "grid_pulse4" -> oscillator(declarations, name(root));
            case "grid_sub4" -> sub(declarations);
            case "grid_swarm4" -> swarm(declarations);
            case "grid_bite_osc" -> bite(declarations);
            case "grid_union" -> union(declarations);
            case "grid_phase1" -> phaseFeedback(declarations);
            case "grid_phasor", "grid_phasor_pm", "grid_phase_counter", "grid_lfo_phasor", "LFOPhasor" ->
                phaseCarrier(declarations,name(root));
            case "trigger_merge" -> triggerMerge(declarations,builtinPulse);
            case "audioToTrigger" -> audioToTrigger(declarations);
            case "sum_stereo_triggers" -> samplerTriggers(declarations);
            case "grid_delay", "grid_allpass_delay" -> directDelay(declarations, name(root));
            case "logic_delay" -> logicDelay(declarations);
            case "grid_average" -> gridAverage(declarations);
            case "ShiftRegister" -> shiftRegister(declarations);
            case "grid_mod_delay" -> modDelay(declarations);
            case "slew" -> inlineSlew(declarations);
            case "DelayTime" -> modDelayTime(declarations);
            case "accent_stepper" -> stepper(declarations,true,"out_normals","out_accents");
            case "gate_stepper" -> stepper(declarations,true,"out");
            case "pitch_stepper" -> stepper(declarations,false,"pitchOut");
            case "grid_stepper" -> stepper(declarations,false,"valueOut");
            case "grid_clock_divide" -> clockDivide(declarations);
            case "ClockQuantize", "GateLength", "GateRepeat" -> clockGate(declarations,name(root));
            case "GridADSR", "AD", "AR" -> adsr(declarations);
            case "downsample_and_merge" -> tunerInput(declarations);
            case "AudioOut" -> audioOut(declarations);
            case "post" -> postMean(declarations);
            case "Hold", "Latch", "nlatch", "SampleAndHold", "LRMS",
                 "array", "Chance", "Dice", "phasereset", "phasechaser" ->
                packedStereoState(declarations,name(root));
            case "voice_stack_mixer" -> voiceStackMeter(declarations);
            case "grid_lifetimer" -> voiceLifeTimer(declarations);
            case "grid_gain_expression" -> noteExpression(root,declarations,"gain");
            case "grid_pan_expression" -> noteExpression(root,declarations,"pan");
            case "Timbre" -> noteExpression(root,declarations,"timbre");
            case "Pressure" -> pressure(root,declarations);
            case "midi_cc_in" -> {
                hostAdaptiveSmoothing(root,"smooth");
                packedStereoState(declarations,name(root));
            }
            case "grid_note_out_plus" -> noteOutInputs(declarations);
            case "Pluck", "decay" -> heldInterpolatedOutput(declarations,"state");
            case "EF" -> follower(declarations);
            case "clock_module" -> clockModule(declarations);
            case "attack" -> {
                Object process = firstTemporalIteration(declarations,"k");
                retimePackedPeriod(process,"M");
                appendPairRepeat(process,"out");
            }
            case "Recorder" -> recorder(declarations);
            case "pquant" -> zeroCrossings(declarations);
            case "DomeFilter" -> dome(stock,declarations);
            case "GrandLPF" -> grandLpf(stock,declarations);
            case "SallenKey" -> sallenKey(declarations);
            case "SVF" -> svf(stock,declarations);
            case "LDLPF", "Xpander" -> ladder(declarations);
            case "ResoMon" -> resonantRate(stock,declarations,"SAMPLE_RATE_NORMAL",2);
            case "VResFilter" -> resonantRate(stock,declarations,"SAMPLE_RATE",4);
            case "Vowel" -> vowelHostTime(declarations);
            case "APFBFilter" -> apfbHostTime(stock,declarations);
            case "FlangerModule" -> modulationFx(stock,declarations,"mod_fx/flanger/flanger.nitrobin",
                "719c7f56e5afd56933669e865ab250affa367bfb08a18eb73054c085c673d5e6",
                "Flanger","m_flanger","0.1");
            case "PolyPhaserComponent" -> modulationFx(stock,declarations,"mod_fx/phaser/phaser.nitrobin",
                "ff51899ccb4b8b96e337327ee96c8fce0d78f2940dd02839a608eb225e435add",
                "PolyPhaser","m_phaser","0.25");
            case "saturator_bwlpf" -> saturatorHostFilter(declarations);
            case "DiodeClipperComponent" -> diodeHostTime(stock,declarations);
            case "grid_shaper_howl" -> howlHostTime(declarations);
            case "quantizer" -> quantizerHostTime(declarations);
            case "pitch_shifter" -> pitchShifterHostTime(stock,declarations);
            case "frequency_shifter" -> frequencyShifterHostTime(stock,declarations);
            case "Comb" -> combHostTime(declarations);
            case "BWLPF", "BWHPF", "BWAPF" -> butterworth(declarations);
            case "LR2", "LR3" -> crossover(declarations,name(root));
            case "tanhClip", "drunk_fold", "e_clip", "gentle_fold", "hardclip2", "s_clip", "wavefolder",
                 "rectifier" -> shaper(declarations);
            case "grid_poly_logic" -> { /* Original trigger on first temporal pair is retained. */ }
            default -> throw new IllegalArgumentException("Prototype has no variant for this component");
            }
            return stock;
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("The exact 6.1.7 AST contract changed",error);
        }
    }

    private static void narrowNamedVectorTypes(Object node,int expected) throws ReflectiveOperationException {
        int changed = 0;
        for (Object vector : collect(node,"VectorType")) {
            Field count = field(type("VectorType"),"MgQ");
            if (literal(count.get(vector)) != 8) continue;
            count.set(vector,newInteger(2));
            changed++;
        }
        if (changed != expected) throw new IllegalStateException("Unexpected selected vector geometry " + changed);
    }

    private static void oscillator(List<Object> declarations,String component) throws ReflectiveOperationException {
        narrowNamedVectorTypes(find(declarations,"FunctionDeclaration","computeWaveForm"),4);
        if (component.equals("grid_saw4"))
            narrowNamedVectorTypes(find(declarations,"FunctionDeclaration","computeSaw"),3);
        hostPhase(declarations);
        Object original = find(declarations,"ProcessBlockDeclaration",null);
        Field processBody = field(type("ProcessBlockDeclaration"),"Gef");
        Object oldBlock = processBody.get(original);
        List<Object> locals = blockList(oldBlock,"beI");
        if (locals.size() != 3 || !name(locals.get(0)).equals("detuneVec") ||
            !name(locals.get(1)).equals("phaseInc") || !name(locals.get(2)).equals("y"))
            throw new IllegalStateException("Unexpected oscillator locals");
        List<Object> loops = collect(original,"ForStatement");
        if (loops.size() != 1 || !print(loops.getFirst()).contains("triggerIn[i]"))
            throw new IllegalStateException("Unexpected oscillator temporal update");

        // Retain each stock waveform formula and pulse gain expression. Narrow
        // only the selected vector functions and the returned waveform local.
        List<Object> oldVars = collect(original,"VariableDeclaration");
        boolean sine = component.equals("grid_sine4");
        List<Object> waveformLocals = new ArrayList<>();
        if (component.equals("grid_saw4") || component.equals("grid_pulse4"))
            waveformLocals.add(find(oldVars,"VariableDeclaration","pulseGain"));
        if (!sine) {
            Object sample = find(oldVars,"VariableDeclaration","z");
            narrowNamedVectorTypes(sample,1);
            waveformLocals.add(sample);
        }
        String sineSample = sine ? "f32<2> z = computeWaveForm(y, wrap, formant, bipolar); " : "";

        replaceProcess(declarations,
            "phase = (triggerIn[0] >= 0.5) ?? (0) : (phase); " +
            "f32<2> y = phase.f32<2>; " +
            "phase = phase + phaseInc; " +
            "f32<2> phasePair; phasePair[0] = phaseIn[0]; phasePair[1] = phaseIn[1]; " +
            "y = wrapPhase(y + phaseMod * phasePair); " +
            "{ " + sineSample + outputCarrier("z") + " phase = phase - floor(phase); }");
        Object nextBlock = processBody.get(find(declarations,"ProcessBlockDeclaration",null));
        blockList(nextBlock,"beI").addAll(0,locals.subList(0,2));
        Object outputBlock = collect(nextBlock,"BlockStatement").stream().filter(b -> b != nextBlock)
            .findFirst().orElseThrow();
        blockList(outputBlock,"beI").addAll(0,waveformLocals);
    }

    private static void sub(List<Object> declarations) throws ReflectiveOperationException {
        hostPhase(declarations);
        Object waveform = find(declarations,"FunctionDeclaration","computeWaveForm");
        narrowNamedVectorTypes(waveform,6);
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        narrowNamedVectorTypes(process,2);

        List<Object> waves = collect(waveform,"ForStatement");
        if (waves.size() != 2 || !print(waves.get(0)).contains("adaa.triangle") ||
            !print(waves.get(1)).contains("adaa.sawtooth"))
            throw new IllegalStateException("Unexpected stock Sub anti-aliasing modes");
        for (Object loop : waves) firstOscillatorPair(loop);
        firstOscillatorPair(find(collect(process,"ForStatement"),"ForStatement",null));
        Object output = find(fragment("process { " + outputCarrier("z") + " }"),"ProcessBlockDeclaration",null);
        swapAssignment(process,output,"out = z");
    }

    private static void swarm(List<Object> declarations) throws ReflectiveOperationException {
        hostPhase(declarations);
        narrowNamedVectorTypes(find(declarations,"FunctionDeclaration","computeSaw"),3);
        narrowNamedVectorTypes(find(declarations,"FunctionDeclaration","computeSine"),3);
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> locals = collect(process,"VariableDeclaration");
        for (String local : List.of("p","z","y"))
            narrowNamedVectorTypes(find(locals,"VariableDeclaration",local),1);
        List<Object> loops = collect(process,"ForStatement");
        if (loops.size() != 2 || !print(loops.get(1)).contains("i < 8") ||
            !print(loops.get(1)).contains("dephase[i]"))
            throw new IllegalStateException("Unexpected stock Swarm voice loop");
        firstOscillatorPair(loops.getFirst());

        Object modulation = find(fragment("process { f32<2> modulation; modulation[0] = phaseIn[0]; modulation[1] = phaseIn[1]; " +
            "p = p + phaseMod * modulation; }"),"ProcessBlockDeclaration",null);
        swapAssignment(process,modulation,"p = p + phaseMod * phaseIn");

        // Each spread voice already advances once per host tick. Keep its
        // original increment even though the base oscillator now uses Fs.
        Field value = field(type("AssignStatement"),"sCA");
        Field left = field(type("BinaryExpression"),"Gef");
        int spread = 0;
        for (Object assignment : collect(process,"AssignStatement")) {
            if (!print(assignment).contains("skirtq(spreadVec, skirt)")) continue;
            for (Object product : collect(value.get(assignment),"MulExpression")) {
                if (!print(left.get(product)).equals("(phaseInc[0]).f32")) continue;
                Object scale = find(fragment("process { rate = (phaseInc[0]).f32 * 0.25; }"),
                    "ProcessBlockDeclaration",null);
                left.set(product,value.get(find(collect(scale,"AssignStatement"),"AssignStatement",null)));
                spread++;
            }
        }
        if (spread != 1) throw new IllegalStateException("Unexpected stock Swarm spread increment");

        Object output = find(fragment("process { f32<2> sample = 0; " + outputCarrier("sample") + " }"),
            "ProcessBlockDeclaration",null);
        Object sample = find(collect(output,"VariableDeclaration"),"VariableDeclaration","sample");
        for (Object assignment : collect(process,"AssignStatement")) {
            if (!print(assignment).strip().startsWith("out = z *")) continue;
            field(type("VariableDeclaration"),"Bqk").set(sample,value.get(assignment));
            swapAssignment(process,output,print(assignment).strip().replaceFirst(";\\s*$",""));
            return;
        }
        throw new IllegalStateException("Unexpected stock Swarm output gain");
    }

    private static void firstOscillatorPair(Object loop) throws ReflectiveOperationException {
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected stock oscillator temporal loop");
        right.set(guard,newInteger(1));
    }

    private static void bite(List<Object> declarations) throws ReflectiveOperationException {
        Object calculate = find(declarations,"FunctionDeclaration","computePhaseIncrement");
        Field right = field(type("BinaryExpression"),"sCA");
        int phaseRates = 0;
        for (Object division : collect(calculate,"DivExpression")) {
            Object denominator = right.get(division);
            String clock = print(denominator);
            if (clock.equals("EC.samplerate * 4") || clock.equals("4 * EC.samplerate")) {
                right.set(division,biteHostRate(denominator));
                phaseRates++;
            }
        }
        if (phaseRates != 2) throw new IllegalStateException("Unexpected stock Bite phase rates");

        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Field target = field(type("CallExpression"),"sCA");
        Field arguments = field(type("CallExpression"),"MgQ");
        for (String coefficient : List.of("hpfG","lpfG","rlpfG")) {
            Object declaration = find(declarations,"VariableDeclaration",coefficient);
            Object call = find(collect(initializer.get(declaration),"CallExpression"),"CallExpression",null);
            @SuppressWarnings("unchecked")
            List<Object> args = (List<Object>)arguments.get(call);
            if (!print(target.get(call)).equals("OnePole.hzToG") || args.size() != 2)
                throw new IllegalStateException("Unexpected stock Bite pole coefficient");
            args.set(1,biteHostRate(args.get(1)));
        }

        // The stock cap 0.124 at 4Fs is a pitch limit of 0.496Fs.
        // Preserve that physical limit without changing the BLEP solver.
        Object phaseLimit = find(declarations,"VariableDeclaration","maxPhaseInc");
        if (!print(initializer.get(phaseLimit)).equals("0.124"))
            throw new IllegalStateException("Unexpected stock Bite phase limit");
        Object replacement = find(fragment("f64 maxPhaseInc = 0.496;"),"VariableDeclaration","maxPhaseInc");
        initializer.set(phaseLimit,initializer.get(replacement));

        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        Object temporal = find(blockList(body.get(process),"Gef"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(temporal);
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected stock Bite time bound");
        right.set(guard,newInteger(1));
        appendPairRepeat(process,"out");
    }

    private static Object biteHostRate(Object product) throws ReflectiveOperationException {
        require(product,"MulExpression");
        Object left = field(type("BinaryExpression"),"Gef").get(product);
        Object right = field(type("BinaryExpression"),"sCA").get(product);
        if (print(left).equals("EC.samplerate") && literal(right) == 4) return left;
        if (print(right).equals("EC.samplerate") && literal(left) == 4) return right;
        throw new IllegalStateException("Unexpected stock Bite clock factor");
    }

    private static void hostPhase(List<Object> declarations) throws ReflectiveOperationException {
        Object phase = find(declarations,"FunctionDeclaration","computePhaseIncrement");
        List<Object> returns = collect(phase,"ReturnStatement");
        if (returns.size() != 2) throw new IllegalStateException("Unexpected phase return count");
        Field lhs = field(type("BinaryExpression"),"Gef");
        Field rhs = field(type("BinaryExpression"),"sCA");
        for (Object branch : returns) {
            Object increment = field(type("ReturnStatement"),"Gef").get(branch);
            require(increment,"MulExpression");
            Object reciprocal = rhs.get(increment);
            require(reciprocal,"DivExpression");
            Object denominator = rhs.get(reciprocal);
            require(denominator,"MulExpression");
            if (literal(rhs.get(denominator)) != 4) throw new IllegalStateException("Unexpected Sine phase scale");
            Object hostRate = lhs.get(denominator);
            require(hostRate,"MemberAccessExpression");
            rhs.set(reciprocal,hostRate);
        }
    }

    private static void union(List<Object> declarations) throws ReflectiveOperationException {
        hostPhase(declarations);
        Object filter = find(declarations,"VariableDeclaration","hpfG");
        String expected = "EC.samplerate * 4";
        if (!print(filter).contains(expected)) throw new IllegalStateException("Unexpected Union filter clock");
        Object baseFilter = find(fragment("f32 hpfG = hp.hzToG(0.2, EC.samplerate)[0];"),
                                 "VariableDeclaration","hpfG");
        declarations.set(declarations.indexOf(filter),baseFilter);
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object tick = find(collect(process,"ForStatement"),"ForStatement",null);
        Object condition = field(type("ForStatement"),"MgQ").get(tick);
        if (!type("BinaryExpression").isInstance(condition) || !print(condition).contains("< 4"))
            throw new IllegalStateException("Unexpected Union loop guard");
        Field right = field(type("BinaryExpression"),"sCA");
        if (literal(right.get(condition)) != 4)
            throw new IllegalStateException("Unexpected Union temporal lane count");
        right.set(condition,newInteger(1));

        Object replacement = find(fragment("process { out[0] = z; out[1] = z; out[2] = z; out[3] = z; }"),
                                  "ProcessBlockDeclaration",null);
        swapAssignment(process,replacement,"out[i] = z");
    }

    private static void phaseFeedback(List<Object> declarations) throws ReflectiveOperationException {
        hostPhase(declarations);
        Object original = find(declarations,"ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        List<Object> originalVariables = collect(original,"VariableDeclaration");
        Object detune = find(originalVariables,"VariableDeclaration","detuneVec");
        Object increment = find(originalVariables,"VariableDeclaration","phaseInc");
        Object firstWaveform = find(originalVariables,"VariableDeclaration","z0");
        if (collect(original,"ForStatement").size() != 1 ||
            !print(firstWaveform).contains("computeWaveForm(y0, shape, formant)") ||
            !print(find(originalVariables,"VariableDeclaration","z3")).contains("computeWaveForm(y3, shape, formant)"))
            throw new IllegalStateException("Unexpected Phase-1 feedback chain");

        // One feedback state update per host frame. The retained first
        // waveform consumes the previous frame's final stereo output.
        replaceProcess(declarations,
            "phase = (triggerIn[0] >= 0.5) ?? (0) : (phase); " +
            "{ f32<2> pair; pair[0] = phaseIn[0]; pair[1] = phaseIn[1]; " +
            "{ f32<2> y0 = wrapPhase(phase.f32<2> + phaseMod * pair + feedback * lastOutput); " +
            "phase = phase + phaseInc; { f32<2> z0 = 0; lastOutput = z0; " + outputCarrier("z0") +
            " phase = phase - floor(phase); } } }");
        Object converted = body.get(find(declarations,"ProcessBlockDeclaration",null));
        blockList(converted,"beI").addAll(0,List.of(detune,increment));
        Object replacementWaveform = find(collect(converted,"VariableDeclaration"),"VariableDeclaration","z0");
        Field init = field(type("VariableDeclaration"),"Bqk");
        init.set(replacementWaveform,init.get(firstWaveform));
    }

    private static void phaseCarrier(List<Object> declarations,String component) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        boolean phasor = component.equals("grid_phasor") || component.equals("grid_phasor_pm");
        boolean sampleAndHold = component.equals("LFOPhasor");
        boolean lfo = sampleAndHold || component.equals("grid_lfo_phasor");
        if (loops.size() != (component.equals("grid_phase_counter") ? 2 : 1))
            throw new IllegalStateException("Unexpected phase loop count");
        Object timeLoop = loops.getFirst();
        Object guard = field(type("ForStatement"),"MgQ").get(timeLoop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected phase temporal guard");
        right.set(guard,newInteger(1));
        if (phasor) hostPhase(declarations);
        if (lfo) lfoHostClock(process, sampleAndHold ? 1 : 2);

        String repeat;
        if (lfo) repeat = "out[1] = out[0]; out[2] = out[0]; out[3] = out[0];";
        else {
            String carrierName = phasor ? "y" : "out";
            var code = new StringBuilder();
            for (int lane = 2; lane < 8; lane++) code.append(carrierName).append('[').append(lane)
                .append("] = ").append(carrierName).append('[').append(lane % 2).append("]; ");
            repeat = code.toString();
        }
        Object fragment = find(fragment("process { " + repeat + " }"),"ProcessBlockDeclaration",null);
        List<Object> tail = blockList(field(type("ProcessBlockDeclaration"),"Gef").get(fragment),"Gef");
        for (Object block : collect(process,"BlockStatement")) {
            var statements = blockList(block,"Gef");
            int index = statements.indexOf(timeLoop);
            if (index >= 0) {
                statements.addAll(index+1,tail);
                return;
            }
        }
        throw new IllegalStateException("Expected original phase post-loop scope");
    }

    private static void lfoHostClock(Object process,int expectedRateExpressions) throws ReflectiveOperationException {
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        int rate = 0;
        int beat = 0;
        for (Object division : collect(process,"DivExpression")) {
            Object denominator = right.get(division);
            if (!print(left.get(division)).equals("1.0")) continue;
            if (denominator.getClass().getSimpleName().equals("MulExpression") &&
                print(left.get(denominator)).equals("4.0") && print(right.get(denominator)).equals("EC.samplerate")) {
                right.set(division,right.get(denominator));
                rate++;
            } else if (denominator.getClass().getSimpleName().equals("FloatValueExpression") &&
                       print(denominator).equals("4.0")) {
                right.set(division,left.get(division));
                beat++;
            }
        }
        if (rate != expectedRateExpressions || beat != 1) throw new IllegalStateException("Unexpected free-running LFO clocks");
        // The transport-synced branch already consumes host clock positions.
    }

    private static void directDelay(List<Object> declarations,String component) throws ReflectiveOperationException {
        Object original = find(declarations,"ProcessBlockDeclaration",null);
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object frameCount = find(collect(original,"VariableDeclaration"),"VariableDeclaration","frames");
        Object clock = initializer.get(frameCount);
        require(clock,"MulExpression");
        Field left = field(type("BinaryExpression"), "Gef");
        Field right = field(type("BinaryExpression"), "sCA");
        if (literal(right.get(clock)) != 4 || !print(left.get(clock)).equals("delayTime * EC.samplerate"))
            throw new IllegalStateException("Unexpected Grid delay frame equation");
        initializer.set(frameCount,left.get(clock));
        Object loop = find(collect(original,"ForStatement"),"ForStatement",null);
        Object condition = field(type("ForStatement"),"MgQ").get(loop);
        if (!print(condition).contains("< 4") || literal(right.get(condition)) != 4)
            throw new IllegalStateException("Unexpected Grid delay loop geometry");
        right.set(condition,newInteger(1));

        Field destination = field(type("AssignStatement"), "Gef");
        Field value = field(type("AssignStatement"), "sCA");
        int outputs = 0;
        for (Object assignment : collect(original,"AssignStatement")) {
            if (!print(destination.get(assignment)).equals("out[i]")) continue;
            Object repeated = find(fragment("process { f32<2> sample = 0; out[0] = sample; out[1] = sample; " +
                "out[2] = sample; out[3] = sample; }"),"ProcessBlockDeclaration",null);
            Object local = find(collect(repeated,"VariableDeclaration"),"VariableDeclaration","sample");
            initializer.set(local,value.get(assignment));
            swapAssignment(original,repeated,print(assignment).strip().replaceFirst(";\\s*$",""));
            outputs++;
        }
        int expected = component.equals("grid_delay") ? 2 : 1;
        if (outputs != expected) throw new IllegalStateException("Unexpected Grid delay output branches " + outputs);
    }

    private static Object firstTemporalIteration(List<Object> declarations,String index)
        throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object condition = field(type("ForStatement"),"MgQ").get(loop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(condition).equals(index + " < 4") || literal(right.get(condition)) != 4)
            throw new IllegalStateException("Unexpected stock temporal loop");
        right.set(condition,newInteger(1));
        return process;
    }

    private static void logicDelay(List<Object> declarations) throws ReflectiveOperationException {
        Object process = firstTemporalIteration(declarations,"i");
        Object frames = find(collect(process,"VariableDeclaration"),"VariableDeclaration","frames");
        Object cast = field(type("VariableDeclaration"),"Bqk").get(frames);
        require(cast,"CastExpression");
        Field input = field(type("UnaryExpression"),"sCA");
        Object product = input.get(cast);
        require(product,"MulExpression");
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        Object rate = right.get(product);
        require(rate,"MulExpression");
        if (!print(left.get(product)).equals("(length).f64") ||
            !print(left.get(rate)).equals("EC.samplerate") || literal(right.get(rate)) != 4)
            throw new IllegalStateException("Unexpected stock Logic Delay duration");
        right.set(product,left.get(rate));

        // Keep the original thresholds, startup guard, ring order and mode branches.
        appendPairRepeat(process,"out");
    }

    private static void gridAverage(List<Object> declarations) throws ReflectiveOperationException {
        Object process = firstTemporalIteration(declarations,"i");
        Object coefficient = find(collect(process,"VariableDeclaration"),"VariableDeclaration","C");
        Object division = find(collect(coefficient,"DivExpression"),"DivExpression",null);
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        Object denominator = right.get(division);
        require(denominator,"MulExpression");
        if (!print(left.get(denominator)).equals("EC.samplerate") ||
            !print(right.get(denominator)).equals("4.0"))
            throw new IllegalStateException("Unexpected stock Average coefficient");
        right.set(division,left.get(denominator));
        appendPairRepeat(process,"out");
    }

    private static void shiftRegister(List<Object> declarations) throws ReflectiveOperationException {
        Object process = firstTemporalIteration(declarations,"k");
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        List<Object> statements = blockList(body.get(process),"Gef");
        int index = statements.indexOf(loop);
        if (index < 0) throw new IllegalStateException("Unexpected stock Shift Register scope");

        // The eight taps and their meters remain intact. Extend each first
        // stereo result over the host carrier before the original output stores.
        var repeat = new StringBuilder("process { ");
        for (int tap = 0; tap < 8; tap++) repeat.append('o').append(tap).append(" = o").append(tap).append("; ");
        Object replacement = find(fragment(repeat.append('}').toString()),"ProcessBlockDeclaration",null);
        Field value = field(type("AssignStatement"),"sCA");
        var shuffle = type("ShuffleVectorExpression").getDeclaredConstructor(type("Expression"),
            type("Expression"),List.class);
        shuffle.setAccessible(true);
        for (Object assign : blockList(body.get(replacement),"Gef")) {
            List<Object> mask = new ArrayList<>();
            for (int lane = 0; lane < 8; lane++) mask.add(newInteger(lane % 2));
            Object tap = value.get(assign);
            value.set(assign,shuffle.newInstance(tap,tap,mask));
        }
        statements.addAll(index+1,blockList(body.get(replacement),"Gef"));
    }

    private static void modDelay(List<Object> declarations) throws ReflectiveOperationException {
        Object coefficient = find(declarations,"FunctionDeclaration","updateFilterCoeff");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object rate = find(collect(coefficient,"VariableDeclaration"),"VariableDeclaration","OVERSAMPLING");
        if (literal(initializer.get(rate)) != 4)
            throw new IllegalStateException("Unexpected Mod Delay feedback pole clock");
        initializer.set(rate,newInteger(1));

        // The delay-time companion supplies frame counts; the processor's
        // extra +1, interpolation and feedback order remain stock.
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected Mod Delay temporal guard");
        right.set(guard,newInteger(1));
        Object repeat = find(fragment("process { out[0] = read; out[1] = read; out[2] = read; out[3] = read; }"),
            "ProcessBlockDeclaration",null);
        swapAssignment(process,repeat,"out[i] = read");
    }

    private static void inlineSlew(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected stock slew time loop");
        right.set(guard,newInteger(1));

        Object step = find(collect(process,"VariableDeclaration"),"VariableDeclaration","step");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object oldStep = initializer.get(step);
        if (print(oldStep).equals("rate * 1.0 / EC.samplerate * 4.0")) {
            retimePackedPeriod(process,"step");
            appendPairRepeat(process,"out");
            return;
        }
        if (!print(oldStep).equals("rate * 1.0 / EC.samplerate"))
            throw new IllegalStateException("Unexpected stock slew increment");
        Object model = find(fragment("process { f32 step = originalStep * 4; " +
            "state = (!didStart) ? x[0] : state; }"),"ProcessBlockDeclaration",null);
        Object scale = initializer.get(find(collect(model,"VariableDeclaration"),"VariableDeclaration","step"));
        field(type("BinaryExpression"),"Gef").set(scale,oldStep);
        initializer.set(step,scale);

        // Four stock clamps toward a constant host target cover four old
        // increments. Seed from the actual stereo pair after start or reset.
        Field destination = field(type("AssignStatement"),"Gef");
        Field value = field(type("AssignStatement"),"sCA");
        int startup = 0;
        for (Object assignment : collect(process,"AssignStatement")) {
            if (!print(destination.get(assignment)).equals("state") ||
                !print(value.get(assignment)).contains("!didStart")) continue;
            if (!print(value.get(assignment)).contains("x.+ / 4"))
                throw new IllegalStateException("Unexpected stock slew startup");
            Object replace = find(collect(model,"AssignStatement"),"AssignStatement",null);
            value.set(assignment,value.get(replace));
            startup++;
        }
        if (startup != 1) throw new IllegalStateException("Expected one stock slew startup");
        appendPairRepeat(process,"out");
    }

    private static void modDelayTime(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object timeScale = find(collect(process,"VariableDeclaration"),"VariableDeclaration","OVERSAMPLING");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        if (!print(timeScale).strip().equals("f32 OVERSAMPLING = 4;") ||
            literal(initializer.get(timeScale)) != 4)
            throw new IllegalStateException("Unexpected Mod Delay time companion geometry");
        initializer.set(timeScale,newInteger(1));
    }

    private static void clockDivide(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        if (loops.size() != 2) throw new IllegalStateException("Unexpected Clock Divide nesting");
        Field guard = field(type("ForStatement"),"MgQ");
        Field right = field(type("BinaryExpression"),"sCA");
        Object temporal = guard.get(loops.get(0));
        Object channels = guard.get(loops.get(1));
        if (!print(temporal).equals("i < 4") || !print(channels).equals("c < 2") ||
            literal(right.get(temporal)) != 4 || literal(right.get(channels)) != 2)
            throw new IllegalStateException("Unexpected Clock Divide time/channel bounds");
        right.set(temporal,newInteger(1));
        Object repeat = find(fragment("process { out[0] = latch; out[1] = latch; out[2] = latch; out[3] = latch; }"),
            "ProcessBlockDeclaration",null);
        // This audio output holds a gate. The original currentVal event sends
        // remain inside the unchanged stereo trigger/update order.
        swapAssignment(process,repeat,"out[i] = latch");
    }

    private static void clockGate(List<Object> declarations,String component) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        if (loops.size() != 1) throw new IllegalStateException("Unexpected clock/gate process nesting");
        String index = component.equals("ClockQuantize") ? "k" : "i";
        Field right = field(type("BinaryExpression"),"sCA");
        Object guard = field(type("ForStatement"),"MgQ").get(loops.get(0));
        if (!print(guard).equals(index + " < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected clock/gate temporal guard");
        right.set(guard,newInteger(1));

        Field initializer = field(type("VariableDeclaration"),"Bqk");
        if (!component.equals("ClockQuantize")) {
            Object frames = find(collect(process,"VariableDeclaration"),"VariableDeclaration","frames");
            Object cast = initializer.get(frames);
            require(cast,"CastExpression");
            Field castInput = field(type("UnaryExpression"),"sCA");
            Object clock = castInput.get(cast);
            require(clock,"MulExpression");
            Field left = field(type("BinaryExpression"),"Gef");
            String port = component.equals("GateLength") ? "length" : "rate";
            if (!print(cast).endsWith(".i32") ||
                literal(right.get(clock)) != 4 || !print(left.get(clock)).equals(port + " * EC.samplerate"))
                throw new IllegalStateException("Unexpected clock/gate frame equation");
            castInput.set(cast,left.get(clock));
        }

        // These are held audio gates. Evaluate the selected stock branch once and
        // repeat its stereo pair; keep the original trigger/clock update order.
        Field destination = field(type("AssignStatement"),"Gef");
        Field expression = field(type("AssignStatement"),"sCA");
        int outputs = 0;
        for (Object assignment : collect(process,"AssignStatement")) {
            if (!print(destination.get(assignment)).equals("out[" + index + "]")) continue;
            Object repeat = find(fragment("process { f32<2> sample = 0; out[0] = sample; out[1] = sample; " +
                "out[2] = sample; out[3] = sample; }"),"ProcessBlockDeclaration",null);
            Object local = find(collect(repeat,"VariableDeclaration"),"VariableDeclaration","sample");
            initializer.set(local,expression.get(assignment));
            swapAssignment(process,repeat,print(assignment).strip().replaceFirst(";\\s*$",""));
            outputs++;
        }
        if (outputs != (component.equals("ClockQuantize") ? 2 : 1))
            throw new IllegalStateException("Unexpected clock/gate output branches");
    }

    private static void triggerMerge(List<Object> declarations,boolean builtinPulse) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        if (collect(process,"ForStatement").size() != 1 ||
            collect(process,"AssignStatement").size() != 1 ||
            !print(process).contains("calc(in1[k], 0)"))
            throw new IllegalStateException("Unexpected stock Grid trigger merge");
        String inlet2 = builtinPulse ? "in2[0]" : "calc(in2[0], 1)";
        replaceProcess(declarations,
            "out[0] = enable2 ? fmax(calc(in1[0], 0), " + inlet2 + ") : calc(in1[0], 0); " +
            "out[1] = 0; out[2] = 0; out[3] = 0;");
    }

    private static void samplerTriggers(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> shuffles = collect(process,"ShuffleVectorExpression");
        List<List<Long>> expected = List.of(List.of(0L,2L,4L,6L),List.of(1L,3L,5L,7L));
        if (shuffles.size() != expected.size()) throw new IllegalStateException("Unexpected sampler trigger shape");
        Field mask = field(type("ShuffleVectorExpression"),"BBg");
        for (int i = 0; i < shuffles.size(); i++) {
            var actual = new ArrayList<Long>();
            for (Object lane : (List<?>)mask.get(shuffles.get(i))) actual.add(literal(lane));
            if (!actual.equals(expected.get(i))) throw new IllegalStateException("Unexpected sampler trigger lanes");
        }
        // Preserve the original signed stereo sum for the host sample.
        // The native inlet still receives four slots, with the tail idle.
        replaceProcess(declarations,"out[0] = in[0] + in[1]; out[1] = 0; out[2] = 0; out[3] = 0;");
    }

    private static void audioToTrigger(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object sum = find(collect(process,"VariableDeclaration"),"VariableDeclaration","in_sum");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        if (!print(initializer.get(sum)).equals("in.+"))
            throw new IllegalStateException("Unexpected stock audio trigger sum");

        // Curves wires this input to trigger_merge. Its 1× output is a
        // binary stereo impulse in the first pair followed by three zero pairs.
        Object example = find(fragment("process { f32 in_sum = in[0] + in[1]; }"),
            "ProcessBlockDeclaration",null);
        Object replacement = find(collect(example,"VariableDeclaration"),"VariableDeclaration","in_sum");
        initializer.set(sum,initializer.get(replacement));
    }

    @SuppressWarnings("unchecked")
    private static void hostAdaptiveSmoothing(Object component,String name)
        throws ReflectiveOperationException {
        Field target = field(type("CallExpression"),"sCA");
        Field args = field(type("CallExpression"),"MgQ");
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        List<Object> setup = new ArrayList<>();
        for (Object call : collect(component,"CallExpression")) {
            if (print(target.get(call)).equals(name + ".setRate")) setup.add(call);
        }
        Object call = find(setup,"CallExpression",null);
        List<Object> arguments = (List<Object>)args.get(call);
        Object smoothingClock = arguments.getFirst();
        require(smoothingClock,"MulExpression");
        if (!print(left.get(smoothingClock)).equals("EC.samplerate") || literal(right.get(smoothingClock)) != 4)
            throw new IllegalStateException("Unexpected note expression smoothing clock");
        arguments.set(0,left.get(smoothingClock));
    }

    private static void noteExpression(Object component,List<Object> declarations,String kind)
        throws ReflectiveOperationException {
        hostAdaptiveSmoothing(component,kind + "Smooth");
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");

        // The decoder stores this handler alongside the component processing
        // declarations. The pretty-printer omits it.
        Field out = field(type("AssignStatement"),"Gef");
        Field value = field(type("AssignStatement"),"sCA");
        int ramps = 0;
        for (Object assign : collect(component,"AssignStatement")) {
            if (!print(out.get(assign)).equals(kind + "Ramptime")) continue;
            Object duration = value.get(assign);
            if (!duration.getClass().getSimpleName().equals("MulExpression")) continue;
            if (!print(left.get(duration)).equals("in.ramptime") || literal(right.get(duration)) != 4)
                throw new IllegalStateException("Unexpected note expression event duration");
            value.set(assign,left.get(duration));
            ramps++;
        }
        if (ramps != 1) throw new IllegalStateException("Expected one stock expression ramp writer");

        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected note expression time loop");
        right.set(guard,newInteger(1));
        appendPairRepeat(process,"out_" + kind);
    }

    @SuppressWarnings("unchecked")
    private static void pressure(Object component,List<Object> declarations) throws ReflectiveOperationException {
        Field target = field(type("CallExpression"),"sCA");
        Field arguments = field(type("CallExpression"),"MgQ");
        Object setup = null;
        for (Object call : collect(component,"CallExpression")) {
            if (print(target.get(call)).equals("pressureSmooth.setRate")) {
                if (setup != null) throw new IllegalStateException("Duplicate stock pressure smoother setup");
                setup = call;
            }
        }
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        if (setup == null || !print(guard).equals("i < 4") ||
            !print(process).contains("pressureSmooth.calcOptional(pressure, smoothing)"))
            throw new IllegalStateException("Unexpected stock pressure clock");
        var rates = (List<Object>)arguments.get(setup);
        if (rates.size() != 3 || !print(rates.getFirst()).equals("EC.samplerate") ||
            !print(rates.get(1)).equals("5") || !print(rates.getLast()).equals("0.1"))
            throw new IllegalStateException("Unexpected stock pressure smoother parameters");

        Object period = find(fragment("f32 rate = EC.samplerate * 0.25;"),"VariableDeclaration","rate");
        rates.set(0,field(type("VariableDeclaration"),"Bqk").get(period));
        // Preserve the original event's delta and advance its countdown by
        // the number of old samples elapsed in this host frame. Expose the
        // first sample and apply one coarse original smoother step.
        replaceProcess(declarations,
            "f32 sample = pressure; " +
            "if (pressureRamptime > 0) { " +
            "    sample = pressure + pressureDiff; " +
            "    i32 advance = pressureRamptime < 4 ? pressureRamptime : 4; " +
            "    pressure = pressure + pressureDiff * (advance).f32; " +
            "    pressureRamptime = pressureRamptime - advance; " +
            "} " +
            "out_pressure[0] = pressureSmooth.calcOptional(sample, smoothing); " +
            "out_pressure[1] = out_pressure[0]; out_pressure[2] = out_pressure[0]; out_pressure[3] = out_pressure[0];");
    }

    private static void retimePackedPeriod(Object process,String variable) throws ReflectiveOperationException {
        Object parameter = find(collect(process,"VariableDeclaration"),"VariableDeclaration",variable);
        Object initializer = field(type("VariableDeclaration"),"Bqk").get(parameter);
        Object reciprocal = find(collect(initializer,"DivExpression"),"DivExpression",null);
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        Object originalRate = right.get(reciprocal);
        require(originalRate,"MulExpression");
        Object a = left.get(originalRate);
        Object b = right.get(originalRate);
        Object host = print(a).equals("EC.samplerate") ? a : b;
        Object factor = host == a ? b : a;
        if (!print(host).equals("EC.samplerate") || !print(left.get(reciprocal)).equals("1.0") ||
            !List.of("4","4.0").contains(print(factor)))
            throw new IllegalStateException("Unexpected stock packed sample period");
        right.set(reciprocal,host);
    }

    private static void clockModule(List<Object> declarations) throws ReflectiveOperationException {
        Object process = firstTemporalIteration(declarations,"i");
        retimePackedPeriod(process,"increment");
        appendPairRepeat(process,"out","outTrig");
    }

    private static void follower(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        if (collect(process,"ForStatement").isEmpty()) {
            heldInterpolatedOutput(declarations,"x");
            return;
        }
        firstTemporalIteration(declarations,"k");
        retimePackedPeriod(process,"M");

        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        List<Object> statements = blockList(body.get(process),"Gef");
        Object time = find(collect(process,"ForStatement"),"ForStatement",null);
        int index = statements.indexOf(time);
        if (index < 0) throw new IllegalStateException("Unexpected stock follower loop location");
        Object repeat = find(fragment("process { out[2] = out[0]; out[3] = out[1]; " +
            "out[4] = out[0]; out[5] = out[1]; out[6] = out[0]; out[7] = out[1]; }"),
            "ProcessBlockDeclaration",null);
        // Preserve the original RMS conversion and mono meter after filling
        // the carrier with the one computed stereo state.
        statements.addAll(index+1,blockList(body.get(repeat),"Gef"));
    }

    private static void recorder(List<Object> declarations) throws ReflectiveOperationException {
        Object process = firstTemporalIteration(declarations,"i");
        Object capacity = find(declarations,"VariableDeclaration","LEN");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object length = initializer.get(capacity);
        require(length,"MulExpression");
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(left.get(length)).equals("4 * EC.samplerate") || literal(right.get(length)) != 4)
            throw new IllegalStateException("Unexpected stock Recorder buffer duration");
        initializer.set(capacity,left.get(length));
        appendPairRepeat(process,"out");
    }

    private static void zeroCrossings(List<Object> declarations) throws ReflectiveOperationException {
        Object process = firstTemporalIteration(declarations,"i");
        Object frequency = find(collect(process,"VariableDeclaration"),"VariableDeclaration","Hz");
        Object division = field(type("VariableDeclaration"),"Bqk").get(frequency);
        require(division,"DivExpression");
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        Object originalRate = left.get(division);
        require(originalRate,"MulExpression");
        if (!print(left.get(originalRate)).equals("EC.samplerate") || !print(right.get(originalRate)).equals("4.0"))
            throw new IllegalStateException("Unexpected stock zero crossing rate");
        left.set(division,left.get(originalRate));

        Field condition = field(type("IfStatement"),"Gef");
        Object minimum = null;
        for (Object statement : collect(process,"IfStatement")) {
            Object candidate = condition.get(statement);
            if (print(candidate).equals("frames > 2")) {
                if (minimum != null) throw new IllegalStateException("Duplicate stock zero crossing guard");
                minimum = candidate;
            }
        }
        if (minimum == null) throw new IllegalStateException("Expected stock zero crossing guard");
        // A whole host sample spans four old periods, so a positive
        // host count preserves the stock minimum of three old frames.
        right.set(minimum,newInteger(0));
        appendPairRepeat(process,"out");
    }

    private static void heldInterpolatedOutput(List<Object> declarations,String hostValue) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Field destination = field(type("AssignStatement"),"Gef");
        Field value = field(type("AssignStatement"),"sCA");
        var outputAssignments = new ArrayList<Object>();
        for (Object assignment : collect(process,"AssignStatement")) {
            if (print(destination.get(assignment)).matches("out\\[[0-3]\\]"))
                outputAssignments.add(assignment);
        }
        if (outputAssignments.size() != 4)
            throw new IllegalStateException("Unexpected stock host envelope output geometry");
        Object held = find(fragment("process { out[0] = " + hostValue +
            "; out[1] = " + hostValue + "; out[2] = " + hostValue + "; }"),
            "ProcessBlockDeclaration",null);
        List<Object> replacements = collect(held,"AssignStatement");
        for (int i = 0; i < 4; i++) {
            Object assignment = outputAssignments.get(i);
            if (!print(destination.get(assignment)).equals("out[" + i + "]") ||
                !(i == 3 ? print(value.get(assignment)).equals(hostValue) :
                    print(value.get(assignment)).contains("lastState")))
                throw new IllegalStateException("Unexpected stock host envelope interpolation");
            if (i < 3) value.set(assignment,value.get(replacements.get(i)));
        }
    }

    private static void noteOutInputs(List<Object> declarations) throws ReflectiveOperationException {
        Field value = field(type("ReturnStatement"),"Gef");
        Object numeric = find(declarations,"FunctionDeclaration","ds");
        Object gate = find(declarations,"FunctionDeclaration","dsGate");
        Object first = find(collect(numeric,"ReturnStatement"),"ReturnStatement",null);
        Object second = find(collect(gate,"ReturnStatement"),"ReturnStatement",null);
        String originalGate = print(value.get(second));
        if (!print(value.get(first)).equals("(in[6] + in[7]) * 0.5") ||
            !originalGate.contains("fmin(fmin(x[0], x[1]), fmin(x[2], x[3]))") ||
            !originalGate.contains("fmax(fmax(x[0], x[1]), fmax(x[2], x[3]))"))
            throw new IllegalStateException("Unexpected stock Note Out sample reductions");

        // Sampling a single stereo host frame needs neither the last
        // temporal pair nor a reduction across four temporal gate values.
        List<Object> pair = fragment("f32 ds(f32<8> in) { return (in[0] + in[1]) * 0.5; } " +
            "f32<2> dsGate(f32<2>[4] x) { return x[0]; }");
        for (Object output : List.of(first,second)) {
            String name = output == first ? "ds" : "dsGate";
            Object replacement = find(pair,"FunctionDeclaration",name);
            Object result = find(collect(replacement,"ReturnStatement"),"ReturnStatement",null);
            value.set(output,value.get(result));
        }
    }

    private static void packedStereoState(List<Object> declarations,String component)
        throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Field condition = field(type("ForStatement"),"MgQ");
        List<Object> loops = collect(process,"ForStatement");
        List<String> expected = switch (component) {
            case "Hold", "SampleAndHold" -> List.of("k < 4");
            case "Latch", "LRMS", "midi_cc_in", "Chance", "Dice", "phasereset", "phasechaser" ->
                List.of("i < 4");
            case "array" -> List.of("k < 4","c < 2");
            case "nlatch" -> List.of("k < 4","i < count","i < N");
            default -> throw new IllegalArgumentException("Unexpected packed stereo component");
        };
        var guards = new ArrayList<String>();
        for (Object loop : loops) guards.add(print(condition.get(loop)));
        if (!guards.equals(expected)) throw new IllegalStateException("Unexpected stock packed stereo loop");

        Object time = condition.get(loops.getFirst());
        Field bound = field(type("BinaryExpression"),"sCA");
        if (literal(bound.get(time)) != 4) throw new IllegalStateException("Unexpected stock temporal bound");
        bound.set(time,newInteger(1));

        if (!component.equals("nlatch")) {
            if (component.equals("phasechaser")) appendPairRepeat(process,"out","outTrig");
            else appendPairRepeat(process,"out");
            return;
        }
        // Preserve separate latch positions and outlets. Only the time
        // dimension of each stereo output is a repeated host sample.
        Object repeat = find(fragment("process { for (i32 i = 0; i < N; i++) { " +
            "out[i][1] = out[i][0]; out[i][2] = out[i][0]; out[i][3] = out[i][0]; } }"),
            "ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        blockList(body.get(process),"Gef").addAll(blockList(body.get(repeat),"Gef"));
    }

    private static void postMean(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> assignments = collect(process,"AssignStatement");
        Field destination = field(type("AssignStatement"),"Gef");
        Field value = field(type("AssignStatement"),"sCA");
        String target = assignments.size() == 2 ? "outMod" : "out";
        Object mean = assignments.getLast();
        String source = target.equals("outMod") ? "out" : "in";
        String reduction = print(value.get(mean));
        if (assignments.size() > 2 || !print(destination.get(mean)).equals(target) ||
            !(reduction.equals(source + ".+ / 8") ||
              (target.equals("out") && reduction.equals("in.+ * 0.125"))))
            throw new IllegalStateException("Unexpected stock post mean");

        // The carrier contains four temporal stereo pairs. At 1× the first pair
        // is the host sample, including both channels in the scalar mean.
        Object example = find(fragment("process { " + target + " = (" + source +
            "[0] + " + source + "[1]) * 0.5; }"),"ProcessBlockDeclaration",null);
        Object replacement = find(collect(example,"AssignStatement"),"AssignStatement",null);
        value.set(mean,value.get(replacement));
    }

    private static void voiceStackMeter(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Field destination = field(type("AssignStatement"),"Gef");
        Field value = field(type("AssignStatement"),"sCA");
        Object meter = null;
        for (Object assignment : collect(process,"AssignStatement")) {
            if (print(destination.get(assignment)).equals("LED[stack_index]")) {
                if (meter != null) throw new IllegalStateException("Duplicate stock voice stack meter");
                meter = assignment;
            }
        }
        if (meter == null || !print(value.get(meter)).equals("out.+"))
            throw new IllegalStateException("Unexpected stock voice stack meter");

        // Retain the stock summed LED scale for one stereo host sample.
        Object example = find(fragment("process { LED[stack_index] = (out[0] + out[1]) * 4; }"),
            "ProcessBlockDeclaration",null);
        Object replacement = find(collect(example,"AssignStatement"),"AssignStatement",null);
        value.set(meter,value.get(replacement));
    }

    private static void voiceLifeTimer(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> locals = collect(process,"VariableDeclaration");
        Object compare = find(locals,"VariableDeclaration","cmp");
        Object over = find(locals,"VariableDeclaration","over");
        if (!print(compare).strip().equals("bool<8> cmp = fabs(in) >= 0.5;") ||
            !print(over).strip().equals("bool over = cmp.||;"))
            throw new IllegalStateException("Unexpected stock lifetime reduction");

        Object source = find(fragment("process { bool over = fabs(in[0]) >= 0.5 || fabs(in[1]) >= 0.5; }"),
            "ProcessBlockDeclaration",null);
        Object replacement = find(collect(source,"VariableDeclaration"),"VariableDeclaration","over");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        initializer.set(over, initializer.get(replacement));
        for (Object block : collect(process,"BlockStatement")) {
            if (blockList(block,"beI").remove(compare)) return;
        }
        throw new IllegalStateException("Expected stock lifetime condition scope");
    }

    private static void dome(NitroFile stock,List<Object> declarations) throws ReflectiveOperationException {
        Object clock = find(collect(stock,"VariableDeclaration"),"VariableDeclaration","OVERSAMPLING");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        if (literal(initializer.get(clock)) != 4 || loops.size() != 4)
            throw new IllegalStateException("Unexpected stock Dome geometry");
        initializer.set(clock,newInteger(1));

        Field condition = field(type("ForStatement"),"MgQ");
        Field right = field(type("BinaryExpression"),"sCA");
        for (int mode = 0; mode < loops.size(); mode++) {
            Object loop = loops.get(mode);
            Object guard = condition.get(loop);
            if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4 ||
                !print(loop).contains("_h" + (6 * (mode + 1)) + ".advance(y)"))
                throw new IllegalStateException("Unexpected stock Dome state layout");
            right.set(guard,newInteger(1));
        }

        // Complete the carrier before the stock output polarities are applied.
        Object selector = find(collect(process,"SwitchStatement"),"SwitchStatement",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        List<Object> statements = blockList(body.get(process),"Gef");
        int switchIndex = statements.indexOf(selector);
        if (switchIndex < 0) throw new IllegalStateException("Unexpected stock Dome mode scope");
        var repeat = new StringBuilder("process { ");
        for (String signal : List.of("real","imag","mag","phase")) {
            for (int lane = 2; lane < 8; lane++)
                repeat.append(signal).append('[').append(lane).append("] = ")
                    .append(signal).append('[').append(lane % 2).append("]; ");
        }
        Object replacement = find(fragment(repeat.append('}').toString()),"ProcessBlockDeclaration",null);
        statements.addAll(switchIndex+1,blockList(body.get(replacement),"Gef"));
    }

    private static void svf(NitroFile stock,List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object clock = find(collect(process,"VariableDeclaration"),"VariableDeclaration","OVERSAMPLING");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        if (literal(initializer.get(clock)) != 4)
            throw new IllegalStateException("Unexpected stock SVF process clock");
        initializer.set(clock,newInteger(1));
        appendPairRepeat(process,"out");

        // Specialize the original coefficient implementation for this SVF
        // instance only. The stock import remains available to other graphs.
        NitroFile modules = exactStockLibrary("modules.nitrobin",
            "a665b644e9f11211f61a5a3091e7e89fb036da0a25ee1755bafd06d0edef1a8e");
        Object original = find(collect(modules,"StructureDeclaration"),"StructureDeclaration","SemiToG");
        Object convert = find(collect(original,"FunctionDeclaration"),"FunctionDeclaration","calc");
        Object rate = find(collect(convert,"VariableDeclaration"),"VariableDeclaration","OVERSAMPLING");
        if (literal(initializer.get(rate)) != 4)
            throw new IllegalStateException("Unexpected stock SVF coefficient clock");
        initializer.set(rate,newInteger(1));

        Class<?> structure = type("StructureDeclaration");
        var constructor = structure.getDeclaredConstructor(String.class,List.class);
        constructor.setAccessible(true);
        Object host = constructor.newInstance("GridHostSemiToG",field(structure,"Anf").get(original));
        @SuppressWarnings("unchecked")
        List<Object> fileDeclarations = (List<Object>)field(NitroFile.class,"unz").get(stock);
        fileDeclarations.add(fileDeclarations.indexOf(stock.ymo()),host);
        Object old = find(declarations,"VariableDeclaration","semiToG");
        Object next = find(fragment("GridHostSemiToG semiToG;"),"VariableDeclaration","semiToG");
        declarations.set(declarations.indexOf(old),next);
    }

    private static NitroFile exactStockLibrary(String resource,String expectedDigest) {
        try {
            byte[] bytes = QxI.Gef().kwH(UhI.beI(resource));
            String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
            if (!digest.equals(expectedDigest))
                throw new IllegalStateException("Unexpected stock Grid library " + resource);
            return NitroFile.beI(NitroFile.Gef,bytes);
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException("Cannot load stock Grid library " + resource,error);
        }
    }

    private static void ladder(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> locals = collect(process,"VariableDeclaration");
        Object clock = find(locals,"VariableDeclaration","OVERSAMPLING");
        Object period = find(locals,"VariableDeclaration","T");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        Object seconds = initializer.get(period);
        require(seconds,"DivExpression");
        Field right = field(type("BinaryExpression"),"sCA");
        if (literal(initializer.get(clock)) != 4 || !print(guard).equals("i < OVERSAMPLING") ||
            !print(right.get(seconds)).equals("EC.samplerate * (OVERSAMPLING).f32"))
            throw new IllegalStateException("Unexpected stock ladder time/coefficient geometry");
        initializer.set(clock,newInteger(1));

        // The original four-pole state and output mix stay in place. Only
        // the first stereo result belongs to this host frame.
        Object repeat = find(fragment("process { z[2] = z[0]; z[3] = z[1]; z[4] = z[0]; " +
            "z[5] = z[1]; z[6] = z[0]; z[7] = z[1]; }"),"ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        for (Object block : collect(process,"BlockStatement")) {
            List<Object> statements = blockList(block,"Gef");
            int index = statements.indexOf(loop);
            if (index < 0) continue;
            statements.addAll(index+1,blockList(body.get(repeat),"Gef"));
            return;
        }
        throw new IllegalStateException("Unexpected stock ladder carrier scope");
    }

    private static void grandLpf(NitroFile stock,List<Object> declarations)
        throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> locals = collect(process,"VariableDeclaration");
        Object clock = find(locals,"VariableDeclaration","OVERSAMPLING");
        Object period = find(locals,"VariableDeclaration","T");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Field condition = field(type("ForStatement"),"MgQ");
        List<Object> loops = collect(process,"ForStatement");
        var guards = new ArrayList<String>();
        for (Object loop : loops) guards.add(print(condition.get(loop)));
        List<String> expected = List.of("i < OVERSAMPLING");
        Object seconds = initializer.get(period);
        require(seconds,"DivExpression");
        if (literal(initializer.get(clock)) != 4 || !guards.equals(expected) ||
            !print(field(type("BinaryExpression"),"sCA").get(seconds))
                .equals("EC.samplerate * (OVERSAMPLING).f32"))
            throw new IllegalStateException("Unexpected stock analog filter time/pole geometry");

        // The selected period sets the prewarp and outer time step. The
        // inner pole cascades, clipping and feedback keep their stock order.
        initializer.set(clock,newInteger(1));
        appendPairRepeat(process,"out");
        grandFlavor(stock,declarations);
    }

    private static void grandFlavor(NitroFile stock,List<Object> declarations)
        throws ReflectiveOperationException {
        NitroFile library = exactStockLibrary("filter_flavor.nitrobin",
            "43bb0e4118206d0237162e838a1a3e1286ede946587458aff5de9f4780722c8f");
        Object original = find(collect(library,"StructureDeclaration"),"StructureDeclaration","filter_flavor");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Field target = field(type("CallExpression"),"sCA");
        Field arguments = field(type("CallExpression"),"MgQ");
        for (String coefficient : List.of("hpf50","hpf5")) {
            Object pole = find(collect(original,"VariableDeclaration"),"VariableDeclaration",coefficient);
            Object call = find(collect(initializer.get(pole),"CallExpression"),"CallExpression",null);
            @SuppressWarnings("unchecked")
            List<Object> args = (List<Object>)arguments.get(call);
            if (!print(target.get(call)).equals("hpIn.hzToG") || args.size() != 2 ||
                !print(args.get(1)).equals("EC.samplerate * 4"))
                throw new IllegalStateException("Unexpected stock GrandLPF coloration pole");
            args.set(1,field(type("BinaryExpression"),"Gef").get(args.get(1)));
        }

        Class<?> structure = type("StructureDeclaration");
        var constructor = structure.getDeclaredConstructor(String.class,List.class);
        constructor.setAccessible(true);
        Object host = constructor.newInstance("GridHostFilterFlavor",field(structure,"Anf").get(original));
        @SuppressWarnings("unchecked")
        List<Object> fileDeclarations = (List<Object>)field(NitroFile.class,"unz").get(stock);
        fileDeclarations.add(fileDeclarations.indexOf(stock.ymo()),host);
        Object old = find(declarations,"VariableDeclaration","flavor");
        Object next = find(fragment("GridHostFilterFlavor flavor;"),"VariableDeclaration","flavor");
        declarations.set(declarations.indexOf(old),next);
    }

    private static void sallenKey(List<Object> declarations)
        throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> locals = collect(process,"VariableDeclaration");
        Object clock = find(locals,"VariableDeclaration","OVERSAMPLING");
        Object period = find(locals,"VariableDeclaration","T");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Field condition = field(type("ForStatement"),"MgQ");
        List<Object> loops = collect(process,"ForStatement");
        var guards = new ArrayList<String>();
        for (Object loop : loops) guards.add(print(condition.get(loop)));
        List<String> expected = List.of("i < OVERSAMPLING","b < lps","b < hps");
        Object seconds = initializer.get(period);
        require(seconds,"DivExpression");
        if (literal(initializer.get(clock)) != 4 || !guards.equals(expected) ||
            !print(field(type("BinaryExpression"),"sCA").get(seconds))
                .equals("EC.samplerate * (OVERSAMPLING).f32"))
            throw new IllegalStateException("Unexpected stock analog filter time/pole geometry");

        // The selected period sets the prewarp and outer time step. The
        // inner pole cascades, clipping and feedback keep their stock order.
        initializer.set(clock,newInteger(1));
        appendPairRepeat(process,"out");
    }

    private static void resonantRate(NitroFile stock,List<Object> declarations,String rateName,
                                     int modeCount) throws ReflectiveOperationException {
        @SuppressWarnings("unchecked")
        List<Object> globals = (List<Object>)field(NitroFile.class,"unz").get(stock);
        Object clock = find(globals,"VariableDeclaration","OVERSAMPLING");
        Object rate = find(globals,"VariableDeclaration",rateName);
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        Field condition = field(type("ForStatement"),"MgQ");
        if (literal(initializer.get(clock)) != 4 || loops.size() != modeCount ||
            !print(initializer.get(rate)).equals("(EC.samplerate).f32 * (OVERSAMPLING).f32"))
            throw new IllegalStateException("Unexpected stock resonant filter geometry");
        for (Object loop : loops) {
            if (!print(condition.get(loop)).equals("i < OVERSAMPLING"))
                throw new IllegalStateException("Unexpected stock resonant temporal loop");
        }

        // Scope the change to the outer Grid clock. Ripple keeps its own
        // three internal HQ steps; Rasp keeps its zero-delay feedback solve.
        initializer.set(clock,newInteger(1));
        appendPairRepeat(process,"out");
    }

    private static void apfbHostTime(NitroFile stock,List<Object> declarations)
        throws ReflectiveOperationException {
        @SuppressWarnings("unchecked")
        List<Object> globals = (List<Object>)field(NitroFile.class,"unz").get(stock);
        Object networkClock = find(globals,"VariableDeclaration","OVERSAMPLING");
        Object processClock = find(declarations,"VariableDeclaration","OVERSAMPLING");
        Object rate = find(globals,"VariableDeclaration","SAMPLE_RATE");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        if (literal(initializer.get(networkClock)) != 4 || literal(initializer.get(processClock)) != 4 ||
            !print(initializer.get(rate)).equals("(EC.samplerate).f32 * (OVERSAMPLING).f32") ||
            !print(guard).equals("i < OVERSAMPLING"))
            throw new IllegalStateException("Unexpected stock Fizz process and network clocks");

        // Stock declares distinct clocks for the template and outer loop.
        initializer.set(networkClock,newInteger(1));
        initializer.set(processClock,newInteger(1));
        appendPairRepeat(process,"out");
    }

    private static void vowelHostTime(List<Object> declarations) throws ReflectiveOperationException {
        Object rate = find(declarations,"VariableDeclaration","OVERSAMPLING");
        Object cascade = find(declarations,"VariableDeclaration","svf");
        Object parallel = find(declarations,"VariableDeclaration","svfp");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        if (literal(initializer.get(rate)) != 4 ||
            !print(cascade).contains("SVF!<f32<2>, OVERSAMPLING>[TOTAL_FORMANTS]") ||
            !print(parallel).contains("SVF!<f32<2>, OVERSAMPLING>[NUM_FORMANTS]"))
            throw new IllegalStateException("Unexpected stock vowel filter geometry");

        // The named clock sets the two stock SVF template rates and their
        // time-buffer sizes. Formant counts and host control smoothers stay.
        initializer.set(rate,newInteger(1));
        appendPairRepeat(find(declarations,"ProcessBlockDeclaration",null),"out");
    }

    private static void modulationFx(NitroFile stock,List<Object> declarations,String resource,
                                     String digest,String flavor,String instance,String fadeSeconds)
        throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected stock modulation FX temporal loop");
        right.set(guard,newInteger(1));

        Object repeat = find(fragment("process { output[2] = output[0]; output[3] = output[1]; " +
            "output[4] = output[0]; output[5] = output[1]; output[6] = output[0]; output[7] = output[1]; }"),
            "ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        blockList(body.get(process),"Gef").addAll(blockList(body.get(repeat),"Gef"));

        NitroFile library = exactStockLibrary(resource,digest);
        @SuppressWarnings("unchecked")
        List<Object> globals = (List<Object>)field(NitroFile.class,"unz").get(library);
        Object original = find(globals,"StructureDeclaration",flavor);
        Class<?> structure = type("StructureDeclaration");
        @SuppressWarnings("unchecked")
        List<Object> members = (List<Object>)field(structure,"Anf").get(original);
        Object tick = find(members,"FunctionDeclaration","tick");
        Field left = field(type("BinaryExpression"),"Gef");
        int fadeUpdates = 0;
        for (Object increment : collect(tick,"DivExpression")) {
            Object denominator = right.get(increment);
            if (!print(left.get(increment)).equals("1.0") ||
                !print(denominator).equals("EC.samplerate * " + fadeSeconds)) continue;
            // The original type fade bypasses SR_MULTIPLIER. Its four
            // increments per host frame become one fourfold increment.
            left.set(increment,newInteger(4));
            fadeUpdates++;
        }
        if (fadeUpdates != 1) throw new IllegalStateException("Unexpected stock modulation FX type fade");

        String hostFlavor = "GridHost" + flavor;
        var constructor = structure.getDeclaredConstructor(String.class,List.class);
        constructor.setAccessible(true);
        Object host = constructor.newInstance(hostFlavor,members);
        @SuppressWarnings("unchecked")
        List<Object> file = (List<Object>)field(NitroFile.class,"unz").get(stock);
        file.add(file.indexOf(stock.ymo()),host);
        Object previous = find(declarations,"VariableDeclaration",instance);
        Object replacement = find(fragment(hostFlavor + " " + instance + ";"),"VariableDeclaration",instance);
        declarations.set(declarations.indexOf(previous),replacement);
    }

    static boolean isFourTimesProperty(ConstantDeclaration property) {
        try {
            return literal(property.Gef()) == 4;
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Cannot read exact modulation FX multiplier",error);
        }
    }

    private static void saturatorHostFilter(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object clock = find(collect(process,"VariableDeclaration"),"VariableDeclaration","OVERSAMPLING");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        List<Object> loops = collect(process,"ForStatement");
        Field condition = field(type("ForStatement"),"MgQ");
        var guards = new ArrayList<String>();
        for (Object loop : loops) guards.add(print(condition.get(loop)));
        if (literal(initializer.get(clock)) != 4 ||
            !guards.equals(List.of("i < OVERSAMPLING","j < poles","i < OVERSAMPLING","j < poles")))
            throw new IllegalStateException("Unexpected stock saturator filter geometry");
        initializer.set(clock,newInteger(1));
        appendPairRepeat(process,"out");
    }

    private static void diodeHostTime(NitroFile stock,List<Object> declarations)
        throws ReflectiveOperationException {
        @SuppressWarnings("unchecked")
        List<Object> globals = (List<Object>)field(NitroFile.class,"unz").get(stock);
        Object clock = find(globals,"VariableDeclaration","SAMPLE_RATE");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object clockProduct = initializer.get(clock);
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        require(clockProduct,"MulExpression");
        if (!print(left.get(clockProduct)).equals("4.0") ||
            !print(right.get(clockProduct)).equals("(EC.samplerate).f32"))
            throw new IllegalStateException("Unexpected stock diode base clock");
        initializer.set(clock,right.get(clockProduct));

        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        if (loops.size() != 2 || !print(loops.get(0)).contains("d2.proc(y)") ||
            !print(loops.get(1)).contains("d1.proc(y)"))
            throw new IllegalStateException("Unexpected stock diode quality branches");
        for (Object loop : loops) firstOscillatorPair(loop);
        // The independent HQ circuit still runs four internal iterations.
        appendPairRepeat(process,"out");
    }

    private static void howlHostTime(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        Object loop = find(blockList(body.get(process),"Gef"),"ForStatement",null);
        firstOscillatorPair(loop);
        Object pole = find(declarations,"VariableDeclaration","G");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object coefficient = find(collect(initializer.get(pole),"CallExpression"),"CallExpression",null);
        Field target = field(type("CallExpression"),"sCA");
        if (!print(target.get(coefficient)).equals("OnePole.hzToG"))
            throw new IllegalStateException("Unexpected stock Howl pole");
        @SuppressWarnings("unchecked")
        List<Object> args = (List<Object>)field(type("CallExpression"),"MgQ").get(coefficient);
        Object rate = args.get(1);
        require(rate,"MulExpression");
        if (!print(rate).equals("4 * EC.samplerate"))
            throw new IllegalStateException("Unexpected stock Howl rate");
        args.set(1,field(type("BinaryExpression"),"sCA").get(rate));
        appendPairRepeat(process,"out");
    }

    private static void quantizerHostTime(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object call = find(collect(process,"CallExpression").stream().filter(c -> {
            try { return print(c).startsWith("adaa.calc42("); }
            catch (ReflectiveOperationException error) { throw new IllegalStateException(error); }
        }).toList(),"CallExpression",null);
        Field target = field(type("CallExpression"),"sCA");
        Object targetFixture = find(fragment("process { quantizeFirstPair(0, 0); }"),
            "ProcessBlockDeclaration",null);
        Object replacement = find(collect(targetFixture,"CallExpression"),"CallExpression",null);
        target.set(call,target.get(replacement));
        List<Object> helper = fragment("f32<8> quantizeFirstPair(f32<8> input,i32 mode) { " +
            "f32<2> pair; pair[0] = input[0]; pair[1] = input[1]; " +
            "f32<2> stepped = adaa.calc(pair, mode); " + carrier("stepped") + "return carrier; }");
        declarations.addAll(declarations.indexOf(process),helper);
        repeatFlatPair(process,"out");
    }

    private static void pitchShifterHostTime(NitroFile stock,List<Object> declarations)
        throws ReflectiveOperationException {
        @SuppressWarnings("unchecked")
        List<Object> globals = (List<Object>)field(NitroFile.class,"unz").get(stock);
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        Object clock = find(globals,"VariableDeclaration","SAMPLERATE");
        Object inverse = find(globals,"VariableDeclaration","ONE_OVER_SAMPLERATE");
        Object delay = find(globals,"VariableDeclaration","SAMPLEOFFSET");
        Object forward = initializer.get(clock);
        Object reciprocal = initializer.get(inverse);
        Object denominator = right.get(reciprocal);
        if (!print(forward).equals("EC.samplerate * 4.0") ||
            !print(denominator).equals("EC.samplerate * 4") ||
            !print(initializer.get(delay)).equals("8.0"))
            throw new IllegalStateException("Unexpected stock pitch shifter clocks");
        initializer.set(clock,left.get(forward));
        right.set(reciprocal,left.get(denominator));
        initializer.set(delay,newInteger(2));

        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        Field condition = field(type("ForStatement"),"MgQ");
        if (loops.size() != 3) throw new IllegalStateException("Unexpected stock pitch shifter temporal branches");
        for (Object loop : loops) {
            Object guard = condition.get(loop);
            if (!print(guard).equals("j < 4") || literal(right.get(guard)) != 4)
                throw new IllegalStateException("Unexpected stock pitch shifter carrier loop");
            right.set(guard,newInteger(1));
        }
        Field value = field(type("AssignStatement"),"sCA");
        int fm = 0;
        for (Object assign : collect(process,"AssignStatement")) {
            if (!print(assign).strip().equals("_mod_fm = _mod_fm * 0.01;")) continue;
            Object scale = value.get(assign);
            Object example = find(fragment("process { _mod_fm = _mod_fm * 0.04; }"),
                "ProcessBlockDeclaration",null);
            Object updated = find(collect(example,"AssignStatement"),"AssignStatement",null);
            right.set(scale,right.get(value.get(updated)));
            fm++;
        }
        if (fm != 1) throw new IllegalStateException("Unexpected stock pitch shifter FM increment");
        repeatFlatPair(process,"out");
    }

    private static void frequencyShifterHostTime(NitroFile stock,List<Object> declarations)
        throws ReflectiveOperationException {
        @SuppressWarnings("unchecked")
        List<Object> globals = (List<Object>)field(NitroFile.class,"unz").get(stock);
        Object clock = find(globals,"VariableDeclaration","OVERSAMPLING");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        if (literal(initializer.get(clock)) != 4)
            throw new IllegalStateException("Unexpected stock frequency shifter clock");
        initializer.set(clock,newInteger(1));

        NitroFile library = exactStockLibrary("mod_fx/frequency_shifter/frequency_shifter.nitrobin",
            "0d65e44ec98862d002b2fbe7b5dadd6edb88a67937f2d89d74e614c08f282a7a");
        @SuppressWarnings("unchecked")
        List<Object> libraryGlobals = (List<Object>)field(NitroFile.class,"unz").get(library);
        Object template = find(libraryGlobals,"TemplateDeclaration","BodeShifter");
        Class<?> templateType = type("TemplateDeclaration");
        Class<?> structure = type("StructureDeclaration");
        Field declaration = field(templateType,"BBg");
        Object original = declaration.get(template);
        @SuppressWarnings("unchecked")
        List<Object> members = (List<Object>)field(structure,"Anf").get(original);
        Object dspTemplate = find(members,"TemplateDeclaration","_bode_shift");
        Object dsp = declaration.get(dspTemplate);
        Object body = field(type("FunctionDeclaration"),"ymo").get(dsp);
        Object scope = find(blockList(body,"Gef"),"BlockStatement",null);
        List<Object> steps = blockList(scope,"Gef");
        Object loop = find(steps,"ForStatement",null);
        firstOscillatorPair(loop);
        steps.addAll(steps.indexOf(loop)+1,repeatFlatAssignments("out"));

        // Only this source uses the local template. The stock wrapper keeps
        // its one host-rate control and delay-fade update.
        var structureConstructor = structure.getDeclaredConstructor(String.class,List.class);
        structureConstructor.setAccessible(true);
        Object host = structureConstructor.newInstance("GridHostBodeShifter",members);
        var templateConstructor = templateType.getDeclaredConstructor(List.class,type("Declaration"));
        templateConstructor.setAccessible(true);
        Object specialized = templateConstructor.newInstance(field(templateType,"Gef").get(template),host);
        globals.add(globals.indexOf(stock.ymo()),specialized);
        Object previous = find(declarations,"VariableDeclaration","shifter");
        Object replacement = find(fragment("GridHostBodeShifter!<BASE_SAMPLERATE, SAMPLE_RATE, " +
            "DLY_LENGTH, DLY_FADE> shifter;"),"VariableDeclaration","shifter");
        declarations.set(declarations.indexOf(previous),replacement);
    }

    private static void repeatFlatPair(Object process,String output) throws ReflectiveOperationException {
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        blockList(body.get(process),"Gef").addAll(repeatFlatAssignments(output));
    }

    private static List<Object> repeatFlatAssignments(String output) throws ReflectiveOperationException {
        var text = new StringBuilder("process { ");
        for (int lane = 2; lane < 8; lane++) {
            text.append(output).append('[').append(lane).append("] = ")
                .append(output).append('[').append(lane % 2).append("]; ");
        }
        Object repeat = find(fragment(text.append('}').toString()),"ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        return blockList(body.get(repeat),"Gef");
    }

    private static void combHostTime(List<Object> declarations) throws ReflectiveOperationException {
        Object clock = find(declarations,"VariableDeclaration","OVERSAMPLING");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        Field condition = field(type("ForStatement"),"MgQ");
        if (literal(initializer.get(clock)) != 4 || loops.size() != 2 ||
            !print(condition.get(loops.get(0))).equals("i < OVERSAMPLING") ||
            !print(condition.get(loops.get(1))).equals("i < OVERSAMPLING"))
            throw new IllegalStateException("Unexpected stock Comb outer timing");
        initializer.set(clock,newInteger(1));

        Object read = null;
        Object feedback = null;
        for (Object local : collect(loops.getFirst(),"VariableDeclaration")) {
            if (name(local).equals("delayed")) read = local;
            if (name(local).equals("w")) feedback = local;
        }
        if (read == null || feedback == null ||
            !print(initializer.get(read)).equals("(EC.revision >= 2) ? (delay.readFir(T)) : (delay.readLinear(T))") ||
            !print(initializer.get(feedback)).equals("x + FB * filtered"))
            throw new IllegalStateException("Unexpected stock Comb modern/legacy dispatch");

        Field pathValue = field(type("AssignStatement"),"sCA");
        Object damping = null;
        for (Object candidate : collect(loops.getFirst(),"AssignStatement")) {
            if (print(pathValue.get(candidate)).equals("apf.calcLP(delayed, dampC)")) {
                if (damping != null) throw new IllegalStateException("Unexpected stock Comb damping calls");
                damping = candidate;
            }
        }
        if (damping == null) throw new IllegalStateException("Expected stock Comb damping");

        Object model = find(fragment("process { " +
            "f32<2> delayed = EC.revision >= 2 ? readHostComb(T, polarity) : delay.readLinear(fmax(1, T)); " +
            "f32<2> damping = hostCombDamping(delayed, dampC, T, polarity); " +
            "f32<2> w = x + (EC.revision >= 2 ? hostCombFeedback(FB, T, decayTime, polarity) : FB) * filtered; }"),
            "ProcessBlockDeclaration",null);
        List<Object> locals = collect(model,"VariableDeclaration");
        initializer.set(read,initializer.get(find(locals,"VariableDeclaration","delayed")));
        initializer.set(feedback,initializer.get(find(locals,"VariableDeclaration","w")));
        pathValue.set(damping,initializer.get(find(locals,"VariableDeclaration","damping")));
        declarations.addAll(declarations.indexOf(process),combHostDeclarations());
        appendPairRepeat(process,"out");
    }

    private static List<Object> combHostDeclarations() throws ReflectiveOperationException {
        // Only modern HQ uses these states. The floor is 9 stock 4× samples
        // expressed in host frames. Ring history and FIR stay in stock code.
        return fragment("""
            i32<2> previousLow = -1;
            i32<2> previousHigh = -1;
            f32<2> lowState = 0;
            f32<2> highState = 0;

            f32 phaseTarget(f32 t, f32 pol)
            {
                return (pol < 0 ? PI : 2 * PI) / t;
            }

            f32 tunedCoefficient(f32 tuned, i32 tap, f32 pol)
            {
                f32 w = phaseTarget(tuned, pol);
                f32 q = tan(w * (tuned - (tap).f32) * 0.5) / tan(w * 0.5);
                return (1 - q) / (1 + q);
            }

            f32 groupDelay(f32 a, f32 w)
            {
                return (1 - a * a) / (1 + a * a + 2 * a * cos(w));
            }

            f32 smoothWeight(f32 f)
            {
                f32 x = fmin(1, fmax(0, 2 * (f - 0.25)));
                return x * x * (3 - 2 * x);
            }

            f32<2> effectiveShortDelay = 0;

            f32<2> readHostComb(f32<2> requested, i32 polarity)
            {
                f32<2> target = fmax(2.25, requested);
                i32<2> lo;
                i32<2> hi;
                f32<2> aLow;
                f32<2> aHigh;
                f32<2> highWeight;
                f32<2> effective;
                for (i32 c = 0; c < 2; ++c)
                {
                    f32 t = target[c];
                    i32 k = floor(t).i32;
                    f32 f = t - k.f32;
                    if (t >= 9)
                    {
                        lo[c] = 8;
                        hi[c] = -1;
                        aLow[c] = 0;
                        aHigh[c] = 0;
                        highWeight[c] = 0;
                        effective[c] = t;
                    }
                    else
                    {
                        if (k < 3)
                        {
                            lo[c] = 2;
                            hi[c] = -1;
                            aLow[c] = tunedCoefficient(t, 2, (polarity).f32);
                            aHigh[c] = 0;
                            highWeight[c] = 0;
                        }
                        else
                        {
                            lo[c] = k - 1;
                            hi[c] = k;
                            aLow[c] = tunedCoefficient(fmin(t, k.f32 + 0.75), lo[c], (polarity).f32);
                            aHigh[c] = tunedCoefficient(fmax(t, k.f32 + 0.25), hi[c], (polarity).f32);
                            highWeight[c] = smoothWeight(f);
                        }
                        f32 w = phaseTarget(t, (polarity).f32);
                        f32 loG = lo[c].f32 + groupDelay(aLow[c], w);
                        f32 hiG = hi[c].f32 + groupDelay(aHigh[c], w);
                        effective[c] = (1 - highWeight[c]) * loG + highWeight[c] * hiG;
                    }
                }

                f32<2> xLow = delay.readLinear(lo.f32<2>);
                f32<2> xHigh = delay.readLinear(fmax(1, hi.f32<2>));
                f32<2> wet;
                for (i32 c = 0; c < 2; ++c)
                {
                    f32 sLow = lo[c] == previousLow[c] ? lowState[c] :
                        (lo[c] == previousHigh[c] ? highState[c] : 0);
                    f32 sHigh = hi[c] == previousLow[c] ? lowState[c] :
                        (hi[c] == previousHigh[c] ? highState[c] : 0);
                    f32 gLow = sqrt(1 - aLow[c] * aLow[c]);
                    f32 gHigh = sqrt(1 - aHigh[c] * aHigh[c]);
                    f32 yLow = aLow[c] * xLow[c] + gLow * sLow;
                    f32 yHigh = aHigh[c] * xHigh[c] + gHigh * sHigh;
                    wet[c] = (1 - highWeight[c]) * yLow + highWeight[c] * yHigh;
                    lowState[c] = gLow * xLow[c] - aLow[c] * sLow;
                    highState[c] = hi[c] > 0 ? (gHigh * xHigh[c] - aHigh[c] * sHigh) : 0;
                }
                previousLow = lo;
                previousHigh = hi;
                if (target[0] >= 9 || target[1] >= 9)
                {
                    f32<2> stock = delay.readFir(requested);
                    wet = target >= 9 ?? stock : wet;
                }

                effectiveShortDelay = effective;
                return wet;
            }

            f32<2> hostDampingState = 0;
            f32<2> hostDampingCoupling = 0;

            f32<2> hostCombDamping(f32<2> input, f32<2> stock, f32<2> requested, i32 polarity)
            {
                f32<2> y;
                for (i32 c = 0; c < 2; ++c)
                {
                    f32 w = phaseTarget(fmax(2.25, requested[c]), (polarity).f32);
                    f32 t = tan(w * 0.125);
                    f32 t2 = t * t;
                    f32 ratio = 4 * (1 - t2) / (1 - 6 * t2 + t2 * t2);
                    f32 matched = stock[c] * ratio / (1 - stock[c]);
                    f32 inv = 1 / (1 + matched);
                    f32 G = matched * inv;
                    f32 a = (matched - 1) * inv;
                    f32 b = 2 * sqrt(matched) * inv;
                    f32 state = hostDampingState[c];
                    if (b > hostDampingCoupling[c])
                        state = state * hostDampingCoupling[c] / b;
                    y[c] = G * input[c] + 0.5 * b * state;
                    hostDampingState[c] = b * input[c] - a * state;
                    hostDampingCoupling[c] = b;
                }
                return y;
            }

            f32<2> hostCombFeedback(f32<2> stock, f32<2> requested, f32 seconds, i32 polarity)
            {
                if (seconds == 0) return stock;
                f32<2> effective = effectiveShortDelay * requested / fmax(requested, 2.25);
                f32<2> adjusted = copysign(pow(0.001, effective / (EC.samplerate * fabs(seconds))), (polarity).f32);
                return requested >= 9 ?? stock : adjusted;
            }
                """);
    }

    private static void butterworth(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object clock = find(collect(process,"VariableDeclaration"),"VariableDeclaration","OVERSAMPLING");
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        List<Object> loops = collect(process,"ForStatement");
        Field guard = field(type("ForStatement"),"MgQ");
        if (literal(initializer.get(clock)) != 4 || loops.size() != 2 ||
            !print(guard.get(loops.get(0))).equals("i < OVERSAMPLING") ||
            !print(guard.get(loops.get(1))).equals("j < poles"))
            throw new IllegalStateException("Unexpected Butterworth rate/pole geometry");
        // Stock prewarping already limits the tangent argument; the scoped
        // clock also sets the time step. The independent pole loop stays.
        initializer.set(clock,newInteger(1));
        appendPairRepeat(process,"out");
    }

    private static void crossover(List<Object> declarations,String component) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object clock = find(declarations,"VariableDeclaration","OVERSAMPLING");
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Field initializer = field(type("VariableDeclaration"),"Bqk");
        if (literal(initializer.get(clock)) != 4 ||
            !print(field(type("ForStatement"),"MgQ").get(loop)).equals("i < OVERSAMPLING"))
            throw new IllegalStateException("Unexpected crossover coefficient or time-step geometry");
        // The original rate-specific coefficient helper bounds its prewarp.
        initializer.set(clock,newInteger(1));
        if (component.equals("LR2")) appendPairRepeat(process,"outLow","outHigh");
        else appendPairRepeat(process,"outLow","outMid","outHigh");
    }

    private static void stepper(List<Object> declarations,boolean hasTrigger,String... outputs)
        throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> loops = collect(process,"ForStatement");
        Field guard = field(type("ForStatement"),"MgQ");
        Field right = field(type("BinaryExpression"),"sCA");
        if (loops.size() != (hasTrigger ? 2 : 1))
            throw new IllegalStateException("Unexpected stock stepper loop count");
        for (int i = 0; i < loops.size(); i++) {
            Object bound = guard.get(loops.get(i));
            String condition = print(bound);
            int limit = hasTrigger && i == 0 ? 4 : 8;
            if (!condition.equals("i < " + limit) || literal(right.get(bound)) != limit)
                throw new IllegalStateException("Unexpected stock stepper carrier loop");
            right.set(bound,newInteger(limit == 4 ? 1 : 2));
        }

        // The trigger loop advances one stereo state. The other loop gathers
        // sequence data independently for the left and right lanes.
        var repeat = new StringBuilder("process { ");
        for (String output : outputs) {
            for (int lane = 2; lane < 8; lane++)
                repeat.append(output).append('[').append(lane).append("] = ")
                    .append(output).append('[').append(lane % 2).append("]; ");
        }
        Object replacement = find(fragment(repeat.append('}').toString()),"ProcessBlockDeclaration",null);
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        blockList(body.get(process),"Gef").addAll(blockList(body.get(replacement),"Gef"));
    }

    private static void appendPairRepeat(Object process,String... outputs) throws ReflectiveOperationException {
        Field body = field(type("ProcessBlockDeclaration"),"Gef");
        var text = new StringBuilder("process { ");
        for (String output : outputs) {
            for (int i=1; i<4; i++) text.append(output).append('[').append(i).append("] = ").append(output).append("[0]; ");
        }
        Object repeat = find(fragment(text.append('}').toString()),"ProcessBlockDeclaration",null);
        blockList(body.get(process),"Gef").addAll(blockList(body.get(repeat),"Gef"));
    }

    private static void shaper(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object body = field(type("ProcessBlockDeclaration"),"Gef").get(process);
        List<Object> statements = blockList(body,"Gef");
        Object loop = find(collect(process,"ForStatement"),"ForStatement",null);
        Object guard = field(type("ForStatement"),"MgQ").get(loop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (statements.getLast() != loop || !print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected shaper process geometry");
        right.set(guard,newInteger(1));

        // Keep the original drive, clipping, quality modes and feedback.
        // Repeat the final stereo result after its one state update.
        appendPairRepeat(process,"out");
    }

    private static void tunerInput(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> shuffles = collect(process,"ShuffleVectorExpression");
        Field mask = field(type("ShuffleVectorExpression"),"BBg");
        List<List<Integer>> expected = List.of(List.of(0,8,2,10,4,12,6,14),
            List.of(1,9,3,11,5,13,7,15));
        if (shuffles.size() != expected.size() || !print(process).contains("ds.proc42(merged)"))
            throw new IllegalStateException("Unexpected stock Tuner downsampling");
        for (int i = 0; i < shuffles.size(); i++) {
            List<?> lanes = (List<?>)mask.get(shuffles.get(i));
            if (lanes.size() != 8) throw new IllegalStateException("Unexpected Tuner lane count");
            for (int lane = 0; lane < lanes.size(); lane++) {
                if (literal(lanes.get(lane)) != expected.get(i).get(lane))
                    throw new IllegalStateException("Unexpected Tuner stereo merge");
            }
        }
        // The stock downsampler reduces four temporal pairs after summing
        // the stereo channels of each input. 1× already supplies one pair.
        replaceProcess(declarations,"out1 = in1[0] + in1[1]; out2 = in2[0] + in2[1];");
    }

    private static void audioOut(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        List<Object> helpers = fragment(
            "f32<8> hostCarrier(f32<2> pair) { " + carrier("pair") + "return carrier; } " +
            "f32<8> clipSoftHost(f32<8> input) { " +
            "f32<2> pair; pair[0] = input[0]; pair[1] = input[1]; return hostCarrier(tanhApprox7(pair)); } " +
            "f32<8> clipHardHost(f32<8> input, i32 mode) { " +
            "f64<2> pair; pair[0] = (input[0]).f64; pair[1] = (input[1]).f64; " +
            "return hostCarrier(hardclip.calc(pair, mode).f32<2>); } " +
            "f32<8> clipHdHost(f32<8> input, i32 mode) { " +
            "f64<2> pair; pair[0] = (input[0]).f64; pair[1] = (input[1]).f64; " +
            "return hostCarrier(softclip.calc(pair, mode).f32<2>); }");
        var targets = java.util.Map.of("tanhApprox7","clipSoftHost",
            "hardclip.calc42","clipHardHost", "softclip.calc42","clipHdHost");
        Field target = field(type("CallExpression"),"sCA");
        var seen = new java.util.HashMap<String,Integer>();
        for (Object call : collect(process,"CallExpression")) {
            String name = print(target.get(call));
            String next = targets.get(name);
            if (next == null) continue;
            seen.merge(name,1,Integer::sum);
            Object example = find(fragment("process { " + next + "(0); }"),
                "ProcessBlockDeclaration",null);
            Object replacement = find(collect(example,"CallExpression"),"CallExpression",null);
            target.set(call,target.get(replacement));
        }
        if (!seen.equals(java.util.Map.of("tanhApprox7",1,"hardclip.calc42",2,"softclip.calc42",1)))
            throw new IllegalStateException("Unexpected Audio Out stock clipping modes");
        // Gate, metering, reset, and actual mode/range controls already run
        // once per host frame. Keep their stock timing and dispatch intact.
        declarations.addAll(declarations.indexOf(process),helpers);
    }

    private static void adsr(List<Object> declarations) throws ReflectiveOperationException {
        Object gate = find(declarations,"FunctionDeclaration","dsGate");
        Object getter = find(fragment("f32<2> gateFirst(f32<2>[4] x) { return x[0]; }"),
            "FunctionDeclaration","gateFirst");
        Field functionBody = field(type("FunctionDeclaration"),"ymo");
        functionBody.set(gate,functionBody.get(getter));

        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object replacement = find(fragment("process { " + outputCarrier("state") + " }"),
            "ProcessBlockDeclaration",null);
        swapAssignment(process,replacement,"out = us.upsample4(state)");
    }

    private static void swapAssignment(Object process,Object replacement,String required) throws ReflectiveOperationException {
        Object replacementBlock = field(type("ProcessBlockDeclaration"),"Gef").get(replacement);
        List<Object> matching = new ArrayList<>();
        for (Object assign : collect(process,"AssignStatement")) {
            if (print(assign).contains(required)) matching.add(assign);
        }
        if (matching.size() != 1) throw new IllegalStateException("Expected one exact carrier assignment");
        for (Object block : collect(process,"BlockStatement")) {
            List<Object> statements = blockList(block,"Gef");
            int index = statements.indexOf(matching.get(0));
            if (index >= 0) {
                statements.set(index,replacementBlock);
                return;
            }
        }
        throw new IllegalStateException("Original carrier assignment had no containing block");
    }

    @SuppressWarnings("unchecked")
    private static List<Object> blockList(Object block,String name) throws ReflectiveOperationException {
        return (List<Object>) field(type("BlockStatement"), name).get(block);
    }
    private static String print(Object node) throws ReflectiveOperationException {
        var writer = new java.io.StringWriter();
        var printer = Class.forName("com.bitwig.base.io.vQq");
        var print = node.getClass().getMethod("beI",printer);
        print.setAccessible(true);
        print.invoke(node,printer.getConstructor(java.io.Writer.class).newInstance(writer));
        return writer.toString();
    }
    private static void require(Object node,String typeName) {
        if (!node.getClass().getSimpleName().equals(typeName)) throw new IllegalStateException("Expected " + typeName);
    }
    private static long literal(Object value) throws ReflectiveOperationException {
        require(value,"IntegerValueExpression");
        return field(type("IntegerValueExpression"),"Gef").getLong(value);
    }
    private static Object newInteger(long value) throws ReflectiveOperationException {
        var ctor = type("IntegerValueExpression").getConstructor(long.class);
        ctor.setAccessible(true);
        return ctor.newInstance(value);
    }
    private static List<Object> collect(Object node,String name) throws ReflectiveOperationException {
        List<Object> result = new ArrayList<>();
        walk(node,name,result,new IdentityHashMap<>(),0);
        return result;
    }
    private static void walk(Object node,String name,List<Object> found,
                             IdentityHashMap<Object,Boolean> visited,int depth) throws ReflectiveOperationException {
        if (node == null || visited.put(node,true) != null) return;
        if (visited.size() > 1024 || depth > 24) throw new IllegalStateException("Unexpected AST depth/size");
        if (node instanceof List<?> list) {
            for (Object value : list) walk(value,name,found,visited,depth+1);
            return;
        }
        Class<?> ast = type("CLJ");
        if (!ast.isInstance(node)) return;
        if (node.getClass().getSimpleName().equals(name)) found.add(node);
        for (Class<?> c = node.getClass(); c != ast; c = c.getSuperclass()) {
            for (Field f : c.getDeclaredFields()) {
                if (Modifier.isStatic(f.getModifiers()) ||
                    (!ast.isAssignableFrom(f.getType()) && !List.class.isAssignableFrom(f.getType()))) continue;
                f.setAccessible(true);
                walk(f.get(node),name,found,visited,depth+1);
            }
        }
    }
}
