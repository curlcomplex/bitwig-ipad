import com.bitwig.nitro.NitroFile;
import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Recognizes pointwise programs that preserve the repeated stereo carrier. */
final class GridCarrierProof {
    private enum Shape { SCALAR, CARRIER, UNSUPPORTED }

    private static String kind(Object node) {
        return node == null ? "" : node.getClass().getSimpleName();
    }

    private static Object get(Object node, String owner, String name) throws ReflectiveOperationException {
        Class<?> type = Class.forName("com.bitwig.nitro." + owner);
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(node);
    }

    private static String identifier(Object node) throws ReflectiveOperationException {
        if (!kind(node).equals("IdentifierExpression")) return "";
        return (String)get(node, "IdentifierExpression", "beI");
    }

    static boolean accepts(NitroFile file) throws ReflectiveOperationException {
        List<?> top = (List<?>)get(file,"NitroFile","unz");
        if (top.size() != 1 || !kind(top.getFirst()).equals("ComponentDeclaration")) return false;
        List<?> declarations = (List<?>)get(top.getFirst(),"ComponentDeclaration","Anf");
        var inputs = new HashMap<String,Shape>();
        var outputs = new HashMap<String,Shape>();
        Object process = null;
        for (Object declaration : declarations) {
            switch (kind(declaration)) {
                case "PortDeclaration" -> {
                    String name = (String)declaration.getClass().getMethod("scr").invoke(declaration);
                    Object port = get(declaration,"PortDeclaration","tWW");
                    switch (kind(port)) {
                        case "InputAudioPortType", "OutputAudioPortType" -> {
                            Object type = get(port,"AudioPortType","Gef");
                            Shape layout = isStereoCarrier(type) ? Shape.CARRIER :
                                isScalar(type) ? Shape.SCALAR : Shape.UNSUPPORTED;
                            if (layout == Shape.UNSUPPORTED) return false;
                            if (kind(port).equals("InputAudioPortType")) inputs.put(name,layout);
                            else outputs.put(name,layout);
                        }
                        case "InputValuePortType" -> {
                            if (!isScalar(get(port,"ValuePortType","beI"))) return false;
                            inputs.put(name,Shape.SCALAR);
                        }
                        default -> { return false; }
                    }
                    if (get(declaration,"PortDeclaration","ZRB") != null) return false;
                }
                case "ProcessBlockDeclaration" -> {
                    if (process != null) return false;
                    process = declaration;
                }
                default -> { return false; }
            }
        }
        if (process == null || outputs.isEmpty()) return false;
        Set<String> writes = writtenOutputs(get(process,"ProcessBlockDeclaration","Gef"),inputs,outputs);
        return writes != null && writes.containsAll(outputs.keySet());
    }

    private static boolean isScalar(Object type) throws ReflectiveOperationException {
        return kind(type).equals("BooleanType") || Class.forName("com.bitwig.nitro.NumberType").isInstance(type);
    }

    private static boolean isStereoCarrier(Object type) throws ReflectiveOperationException {
        if (!kind(type).equals("VectorType") || !isScalar(get(type,"VectorType","Gef"))) return false;
        Object length = get(type,"VectorType","MgQ");
        return kind(length).equals("IntegerValueExpression") &&
            ((Number)get(length,"IntegerValueExpression","Gef")).longValue() == 8;
    }

    // null means an unsupported operation; an empty set is valid but writes
    // no outputs on every path through this statement.
    private static Set<String> writtenOutputs(Object node, Map<String,Shape> inputs, Map<String,Shape> outputs)
        throws ReflectiveOperationException {
        return switch (kind(node)) {
            case "BlockStatement" -> {
                List<?> locals = (List<?>)get(node,"BlockStatement","beI");
                if (locals != null && !locals.isEmpty()) yield null;
                var writes = new HashSet<String>();
                for (Object child : (List<?>)get(node,"BlockStatement","Gef")) {
                    var childWrites = writtenOutputs(child,inputs,outputs);
                    if (childWrites == null) yield null;
                    writes.addAll(childWrites);
                }
                yield writes;
            }
            case "AssignStatement" -> {
                String name = identifier(get(node,"AssignStatement","Gef"));
                Shape source = shape(get(node,"AssignStatement","sCA"),inputs);
                Shape destination = outputs.get(name);
                yield destination != null && (source == destination || source == Shape.SCALAR) ? Set.of(name) : null;
            }
            case "IfStatement" -> {
                if (shape(get(node,"IfStatement","Gef"),inputs) != Shape.SCALAR) yield null;
                var whenTrue = writtenOutputs(get(node,"IfStatement","sCA"),inputs,outputs);
                Object otherwise = get(node,"IfStatement","MgQ");
                Set<String> whenFalse = otherwise == null ? Set.of() : writtenOutputs(otherwise,inputs,outputs);
                if (whenTrue == null || whenFalse == null) yield null;
                var both = new HashSet<>(whenTrue);
                both.retainAll(whenFalse);
                yield both;
            }
            default -> null;
        };
    }

    private static Shape shape(Object node, Map<String,Shape> inputs) throws ReflectiveOperationException {
        String kind = kind(node);
        return switch (kind) {
            case "IdentifierExpression" -> inputs.getOrDefault(identifier(node),Shape.UNSUPPORTED);
            case "IntegerValueExpression", "BooleanValueExpression", "FloatValueExpression" -> Shape.SCALAR;
            case "AddExpression", "SubExpression", "MulExpression", "DivExpression",
                 "GTExpression", "GEExpression", "LTExpression", "LEExpression", "EQExpression", "NEExpression",
                 "AndExpression", "OrExpression", "XorExpression" ->
                join(shape(get(node,"BinaryExpression","Gef"),inputs),
                     shape(get(node,"BinaryExpression","sCA"),inputs));
            case "BangExpression", "NotExpression" -> shape(get(node,"UnaryExpression","sCA"),inputs);
            case "AndAndExpression", "OrOrExpression" ->
                join(shape(get(node,"BinaryExpression","Gef"),inputs),
                     shape(get(node,"BinaryExpression","sCA"),inputs)) == Shape.SCALAR
                    ? Shape.SCALAR : Shape.UNSUPPORTED;
            case "ConditionalExpression", "SelectExpression" -> {
                Shape condition = shape(get(node,kind,"Gef"),inputs);
                if (kind.equals("ConditionalExpression") && condition != Shape.SCALAR) yield Shape.UNSUPPORTED;
                yield join(condition,join(shape(get(node,kind,"sCA"),inputs),shape(get(node,kind,"MgQ"),inputs)));
            }
            default -> Shape.UNSUPPORTED;
        };
    }

    private static Shape join(Shape left, Shape right) {
        if (left == Shape.UNSUPPORTED || right == Shape.UNSUPPORTED) return Shape.UNSUPPORTED;
        return left == Shape.CARRIER || right == Shape.CARRIER ? Shape.CARRIER : Shape.SCALAR;
    }
}
