import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

final class GridCacheProof {
    public static void main(String[] args) throws Exception {
        Class<?> src = Class.forName("com.bitwig.nitro.vP2");
        Class<?> context = Class.forName("com.bitwig.nitro.Hvv");
        Class<?> opts = Class.forName("com.bitwig.nitro.Tlo");
        Class<?> service = Class.forName("com.bitwig.nitro.tIb");
        Class<?> roots = Class.forName("com.bitwig.nitro.QxI");
        Class<?> configuration = Class.forName("dga");
        roots.getMethod("beI",configuration).invoke(null,new Object[]{null});
        Object settings = opts.getConstructor().newInstance();
        opts.getField("MgQ").setInt(settings,48000);
        opts.getField("sCA").setInt(settings,560);
        Object rate = opts.getMethod("beI").invoke(settings);
        Object partition = service.getMethod("beI", File.class,context,boolean.class)
            .invoke(null,Files.createTempDirectory(Path.of(args[0]),"isolated-cache-").toFile(),rate,false);
        var compile = service.getMethod("beI", src,List.class,List.class,List.class,List.class,String.class,boolean.class);
        for (String filename : java.util.Arrays.copyOfRange(args,1,args.length)) {
            Path path = Path.of(filename);
            byte[] content = Files.readAllBytes(path);
            String stable = path.getFileName().toString();
            Object stockA = compile.invoke(partition, new GridCompileInput(content,stable),
                List.of(),List.of(),List.of(),List.of(),"Grid diagnostic",false);
            Object variant = compile.invoke(partition, new GridVariantInput(new GridCompileInput(content,stable), false),
                List.of(),List.of(),List.of(),List.of(),"Grid diagnostic",false);
            Object stockB = compile.invoke(partition, new GridCompileInput(content,stable),
                List.of(),List.of(),List.of(),List.of(),"Grid diagnostic",false);
            var compileKey = stockA.getClass().getMethod("ymo");
            var ir = stockA.getClass().getMethod("scr");
            var cached = service.getMethod("beI",stockA.getClass());
            var readFormat = service.getDeclaredMethod("Bqk");
            readFormat.setAccessible(true);
            Object serializer = readFormat.invoke(null);
            Object configurationObject = roots.getMethod("beI").invoke(null);
            var read = configuration.getMethod("beI",Class.forName("scz"),Class.forName("com.bitwig.base.serial.Jpp"));
            String original = (String)ir.invoke(read.invoke(configurationObject,cached.invoke(partition,stockA),serializer));
            String changed = (String)ir.invoke(read.invoke(configurationObject,cached.invoke(partition,variant),serializer));
            String returned = (String)ir.invoke(read.invoke(configurationObject,cached.invoke(partition,stockB),serializer));
            if (original.isEmpty() || changed.isEmpty() || !original.equals(returned) || original.equals(changed) ||
                stockA != stockB || stockA == variant || compileKey.invoke(stockA).equals(compileKey.invoke(variant)))
                throw new IllegalStateException("Unexpected compiler/cache isolation for " + stable);
            System.out.println(stable + ": stock identity reused, bit-identical original LLVM IR restored, 1x isolated (" +
                original.length() + "/" + changed.length() + " bytes)");
        }
    }
}
