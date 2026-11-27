import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** Installs the exact source-selection hook before the original async capture. */
final class PatchGridSourceSelection implements Opcodes {
    private static final String STOCK_TLG = "e4cb4524d861b5e97926d99038cfbebdf342e03ca3e9730f137a4dba6a474102";
    private static final String SOURCE = "Lcom/bitwig/nitro/vP2;";
    private static final String ASYNC_COMPILE = "(Lcom/bitwig/nitro/tIb;" + SOURCE +
        "Ljava/util/ArrayList;Ljava/util/List;Ljava/util/List;Ljava/util/List;Ljava/lang/String;Z)Lcom/bitwig/nitro/Vyh;";

    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]);
        byte[] bytes = Files.readAllBytes(root.resolve("TLG.stock"));
        if (!HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)).equals(STOCK_TLG))
            throw new IllegalStateException("Stock Grid compiler class differs");
        bytes[7] = 66;
        var reader = new ClassReader(bytes);
        var writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
        int[] sites = {0,0};
        reader.accept(new ClassVisitor(ASM9, writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor, String signature, String[] exceptions) {
                MethodVisitor next = super.visitMethod(access, name, descriptor, signature, exceptions);
                if (name.equals("beI") && descriptor.equals(ASYNC_COMPILE)) {
                    return new MethodVisitor(ASM9,next) {
                        @Override
                        public void visitVarInsn(int opcode,int local) {
                            if (opcode == ALOAD && local == 2) {
                                super.visitVarInsn(ALOAD,1);
                                super.visitVarInsn(ALOAD,2);
                                super.visitMethodInsn(INVOKESTATIC,"GridVariantInput","compilerProperties",
                                    "(" + SOURCE + "Ljava/util/ArrayList;)Ljava/util/ArrayList;",false);
                                sites[1]++;
                            } else {
                                super.visitVarInsn(opcode,local);
                            }
                        }
                    };
                }
                if (!name.equals("beI") || !descriptor.equals("(Lcom/bitwig/nitro/wPc;Z)V")) return next;
                return new MethodVisitor(ASM9, next) {
                    @Override
                    public void visitVarInsn(int opcode, int local) {
                        if (opcode != ALOAD || local != 21) {
                            super.visitVarInsn(opcode, local);
                            return;
                        }
                        super.visitVarInsn(ALOAD, 0);
                        super.visitVarInsn(ALOAD, 21);
                        super.visitMethodInsn(INVOKESTATIC, "GridSourceSelection", "choose", "(LTLG;" + SOURCE + ")" + SOURCE, false);
                        sites[0]++;
                    }
                };
            }
        }, 0);
        if (sites[0] != 1 || sites[1] != 1)
            throw new IllegalStateException("Expected one stock source selection and one property capture");
        byte[] patched = writer.toByteArray();
        patched[7] = 69;
        Path classes = root.resolve("classes");
        Files.createDirectories(classes);
        Files.write(classes.resolve("TLG.class"), patched);
    }
}
