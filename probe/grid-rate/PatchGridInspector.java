import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** Inserts the same native row in iPad and desktop 6.1.7 Inspectors. */
final class PatchGridInspector implements Opcodes {
    private static final String STOCK = "3b3a446634388f4f0744c1a318e9f832dc45a8cb4ff656e58a60cdb41399fe83";

    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]);
        byte[] bytes = Files.readAllBytes(root.resolve("aKf.stock"));
        if (!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(STOCK))
            throw new IllegalStateException("Stock Grid inspector class differs");
        bytes[7] = 66;
        var reader = new ClassReader(bytes);
        var writer = new ClassWriter(reader,ClassWriter.COMPUTE_MAXS);
        int[] sites = {0};
        reader.accept(new ClassVisitor(ASM9,writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                MethodVisitor original = super.visitMethod(access,name,descriptor,signature,exceptions);
                if (!name.equals("beI") || !descriptor.equals("(Lsgf;)LdwF;")) return original;
                return new MethodVisitor(ASM9,original) {
                    @Override
                    public void visitMethodInsn(int opcode, String owner, String called, String type, boolean isInterface) {
                        super.visitMethodInsn(opcode,owner,called,type,isInterface);
                        if (!owner.equals("dXL") || !called.equals("IvP") || !type.equals("(LdwF;)V")) return;
                        if (++sites[0] != 2) return;
                        super.visitVarInsn(ALOAD,0);
                        super.visitVarInsn(ALOAD,1);
                        super.visitVarInsn(ALOAD,5);
                        super.visitMethodInsn(INVOKESTATIC,"GridInspectorRow","append","(LaKf;Lsgf;LdXL;)V",false);
                    }
                };
            }
        },0);
        if (sites[0] != 2) throw new IllegalStateException("Expected the stock Inspector name row");
        byte[] patched = writer.toByteArray();
        patched[7] = 69;
        Path classes = root.resolve("classes");
        Files.createDirectories(classes);
        Files.write(classes.resolve("aKf.class"),patched);
    }
}
