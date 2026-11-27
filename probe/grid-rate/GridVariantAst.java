import com.bitwig.nitro.NitroFile;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
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
        try {
            Object root = stock.ymo();
            List<Object> declarations = children(root);
            switch (name(root)) {
            case "upsampler" -> replaceProcess(declarations, "f32<2> sample = in; " + outputCarrier("sample"));
            case "downsampler" -> replaceProcess(declarations, "f32<2> sample; sample[0] = in[0]; sample[1] = in[1]; out = sample;");
            case "grid_sine4", "grid_saw4", "grid_tri4", "grid_pulse4" -> oscillator(declarations, name(root));
            case "grid_union" -> union(declarations);
            case "grid_phase1" -> phaseFeedback(declarations);
            case "grid_phasor", "grid_phasor_pm", "grid_phase_counter", "grid_lfo_phasor" ->
                phaseCarrier(declarations,name(root));
            case "trigger_merge" -> triggerMerge(declarations);
            case "audioToTrigger" -> audioToTrigger(declarations);
            case "grid_delay", "grid_allpass_delay" -> directDelay(declarations, name(root));
            case "grid_mod_delay" -> modDelay(declarations);
            case "DelayTime" -> modDelayTime(declarations);
            case "accent_stepper" -> stepper(declarations,true,"out_normals","out_accents");
            case "gate_stepper" -> stepper(declarations,true,"out");
            case "pitch_stepper" -> stepper(declarations,false,"pitchOut");
            case "grid_stepper" -> stepper(declarations,false,"valueOut");
            case "grid_clock_divide" -> clockDivide(declarations);
            case "ClockQuantize", "GateLength", "GateRepeat" -> clockGate(declarations,name(root));
            case "GridADSR", "AD", "AR" -> adsr(declarations);
            case "AudioOut" -> audioOut(declarations);
            case "post" -> postMean(declarations);
            case "grid_lifetimer" -> voiceLifeTimer(declarations);
            case "grid_gain_expression" -> noteExpression(root,declarations,"gain");
            case "grid_pan_expression" -> noteExpression(root,declarations,"pan");
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
        boolean lfo = component.equals("grid_lfo_phasor");
        if (loops.size() != (component.equals("grid_phase_counter") ? 2 : 1))
            throw new IllegalStateException("Unexpected phase loop count");
        Object timeLoop = loops.getFirst();
        Object guard = field(type("ForStatement"),"MgQ").get(timeLoop);
        Field right = field(type("BinaryExpression"),"sCA");
        if (!print(guard).equals("i < 4") || literal(right.get(guard)) != 4)
            throw new IllegalStateException("Unexpected phase temporal guard");
        right.set(guard,newInteger(1));
        if (phasor) hostPhase(declarations);
        if (lfo) lfoHostClock(process);

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

    private static void lfoHostClock(Object process) throws ReflectiveOperationException {
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
        if (rate != 2 || beat != 1) throw new IllegalStateException("Unexpected free-running LFO clocks");
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

    private static void triggerMerge(List<Object> declarations) throws ReflectiveOperationException {
        Object process = find(declarations,"ProcessBlockDeclaration",null);
        if (collect(process,"ForStatement").size() != 1 ||
            collect(process,"AssignStatement").size() != 1 ||
            !print(process).contains("calc(in1[k], 0)"))
            throw new IllegalStateException("Unexpected stock Grid trigger merge");
        replaceProcess(declarations,
            "out[0] = enable2 ? fmax(calc(in1[0], 0), calc(in2[0], 1)) : calc(in1[0], 0); " +
            "out[1] = 0; out[2] = 0; out[3] = 0;");
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
    private static void noteExpression(Object component,List<Object> declarations,String kind)
        throws ReflectiveOperationException {
        Field target = field(type("CallExpression"),"sCA");
        Field args = field(type("CallExpression"),"MgQ");
        Field left = field(type("BinaryExpression"),"Gef");
        Field right = field(type("BinaryExpression"),"sCA");
        List<Object> setup = new ArrayList<>();
        for (Object call : collect(component,"CallExpression")) {
            if (print(target.get(call)).equals(kind + "Smooth.setRate")) setup.add(call);
        }
        Object call = find(setup,"CallExpression",null);
        List<Object> arguments = (List<Object>)args.get(call);
        Object smoothingClock = arguments.getFirst();
        require(smoothingClock,"MulExpression");
        if (!print(left.get(smoothingClock)).equals("EC.samplerate") || literal(right.get(smoothingClock)) != 4)
            throw new IllegalStateException("Unexpected note expression smoothing clock");
        arguments.set(0,left.get(smoothingClock));

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
