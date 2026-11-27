import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** Original model-thread callbacks around actual Grid module attachment. */
final class PatchGridGraph implements Opcodes {
    private static final String BASE = "com/bitwig/flt/document/core/master/device/";
    private static final String GRID = "L"+BASE+"nWI;";
    private static final String MODULE = "L"+BASE+"wh2;";
    private static final String ADD_ARGUMENTS = "("+MODULE+"I)V";
    private static final String REMOVE_ARGUMENTS = "("+MODULE+"IZ)V";
    private static final String STOCK = "db01059537274d14372db81ac7ddd68431b6304cf1f426f3c7694aa84df9c942";

    public static void main(String[] arguments) throws Exception {
        Path root = Path.of(arguments[0]);
        byte[] bytes = Files.readAllBytes(root.resolve("nWI.stock"));
        if (bytes[7] != 69 || !HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(STOCK))
            throw new IllegalArgumentException("Expected the original 6.1.7 Grid model class");

        bytes[7] = 66;
        var reader = new ClassReader(bytes);
        var writer = new ClassWriter(reader,ClassWriter.COMPUTE_MAXS);
        int[] sites = {0,0,0};
        reader.accept(new ClassVisitor(ASM9,writer) {
            @Override
            public MethodVisitor visitMethod(int access,String name,String desc,String signature,String[] exceptions) {
                MethodVisitor next = super.visitMethod(access,name,desc,signature,exceptions);
                if (!name.equals("beI") || !(desc.equals(ADD_ARGUMENTS) || desc.equals(REMOVE_ARGUMENTS))) return next;
                boolean adding = desc.equals(ADD_ARGUMENTS);
                return new MethodVisitor(ASM9,next) {
                    @Override
                    public void visitMethodInsn(int opcode,String owner,String method,String descriptor,boolean iface) {
                        boolean insertion = adding && opcode == INVOKESPECIAL && owner.equals(BASE+"Tqp") &&
                            method.equals("beI") && descriptor.equals(ADD_ARGUMENTS);
                        if (insertion) {
                            moduleHook("beforeAdd");
                            sites[0]++;
                        }
                        super.visitMethodInsn(opcode,owner,method,descriptor,iface);
                        if (insertion) {
                            moduleHook("afterAdd");
                            sites[1]++;
                        }
                    }

                    @Override
                    public void visitInsn(int instruction) {
                        if (!adding && instruction == RETURN) {
                            super.visitVarInsn(ALOAD,0);
                            super.visitMethodInsn(INVOKESTATIC,"GridSourceSelection","afterRemove","("+GRID+")V",false);
                            sites[2]++;
                        }
                        super.visitInsn(instruction);
                    }

                    private void moduleHook(String name) {
                        super.visitVarInsn(ALOAD,0);
                        super.visitVarInsn(ALOAD,1);
                        super.visitMethodInsn(INVOKESTATIC,"GridSourceSelection",name,"("+GRID+MODULE+")V",false);
                    }
                };
            }
        },0);
        if (sites[0] != 1 || sites[1] != 1 || sites[2] != 1)
            throw new IllegalStateException("Unexpected stock Grid module lifecycle");
        byte[] patched = writer.toByteArray();
        patched[7] = 69;
        Path path = root.resolve("classes").resolve(BASE+"nWI.class");
        Files.createDirectories(path.getParent());
        Files.write(path,patched);
    }
}
