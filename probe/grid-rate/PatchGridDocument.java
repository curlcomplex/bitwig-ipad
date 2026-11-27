import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** Completes restored Grid owners at the stock document's activation boundary. */
final class PatchGridDocument implements Opcodes {
    private static final String DOCUMENT = "com/bitwig/flt/document/core/master/CmH";
    private static final String STOCK = "fb304e90b4855b54a82bab577431f466b2cc2339916fab0f75432c2085355b36";

    public static void main(String[] arguments) throws Exception {
        Path root = Path.of(arguments[0]);
        byte[] bytes = Files.readAllBytes(root.resolve("CmH.stock"));
        if (bytes[7] != 69 || !HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(STOCK))
            throw new IllegalArgumentException("Expected the original 6.1.7 project model class");

        bytes[7] = 66;
        var reader = new ClassReader(bytes);
        var writer = new ClassWriter(reader,ClassWriter.COMPUTE_MAXS);
        int[] sites = {0};
        reader.accept(new ClassVisitor(ASM9,writer) {
            @Override
            public MethodVisitor visitMethod(int access,String name,String desc,String signature,String[] exceptions) {
                MethodVisitor next = super.visitMethod(access,name,desc,signature,exceptions);
                if (!name.equals("el") || !desc.equals("()V")) return next;
                return new MethodVisitor(ASM9,next) {
                    @Override
                    public void visitMethodInsn(int opcode,String owner,String method,String descriptor,boolean iface) {
                        if (opcode == INVOKEVIRTUAL && owner.equals(DOCUMENT) &&
                            method.equals("jbK") && descriptor.equals("()Ljava/util/stream/Stream;")) {
                            super.visitVarInsn(ALOAD,0);
                            super.visitMethodInsn(INVOKESTATIC,"GridSourceSelection","documentReady","(L"+DOCUMENT+";)V",false);
                            sites[0]++;
                        }
                        super.visitMethodInsn(opcode,owner,method,descriptor,iface);
                    }
                };
            }
        },0);
        if (sites[0] != 1) throw new IllegalStateException("Unexpected stock project activation path");
        byte[] patched = writer.toByteArray();
        patched[7] = 69;
        Path path = root.resolve("classes").resolve(DOCUMENT+".class");
        Files.createDirectories(path.getParent());
        Files.write(path,patched);
    }
}
