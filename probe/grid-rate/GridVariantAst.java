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
        return code.append("out = carrier;").toString();
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
            case "upsampler" -> replaceProcess(declarations, "f32<2> sample = in; " + carrier("sample"));
            case "downsampler" -> replaceProcess(declarations, "f32<2> sample; sample[0] = in[0]; sample[1] = in[1]; out = sample;");
            case "grid_sine4", "grid_saw4", "grid_tri4", "grid_pulse4" -> oscillator(declarations, name(root));
            case "grid_union" -> union(declarations);
            case "trigger_merge" -> triggerMerge(declarations);
            case "grid_delay", "grid_allpass_delay" -> directDelay(declarations, name(root));
            case "grid_clock_divide" -> clockDivide(declarations);
            case "ClockQuantize", "GateLength", "GateRepeat" -> clockGate(declarations,name(root));
            case "GridADSR" -> adsr(declarations);
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
            "{ " + sineSample + carrier("z") + " phase = phase - floor(phase); }");
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

    private static void adsr(List<Object> declarations) throws ReflectiveOperationException {
        Object gate = find(declarations,"FunctionDeclaration","dsGate");
        Object getter = find(fragment("f32<2> gateFirst(f32<2>[4] x) { return x[0]; }"),
            "FunctionDeclaration","gateFirst");
        Field functionBody = field(type("FunctionDeclaration"),"ymo");
        functionBody.set(gate,functionBody.get(getter));

        Object process = find(declarations,"ProcessBlockDeclaration",null);
        Object replacement = find(fragment("process { " + carrier("state") + " }"),
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
