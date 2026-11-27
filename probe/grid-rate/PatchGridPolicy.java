import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Label;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/** Private exact-6.1.7 model schema experiment. No DSP or engine field changes. */
final class PatchGridPolicy implements Opcodes {
    private static final String BASE="com/bitwig/flt/document/core/master/device/";
    private static final String AIR=BASE+"AiR";
    private static final String UTT=BASE+"utt";
    private static final String SUPER=BASE+"zCn";
    private static final String DEV="L"+BASE+"sgH;";
    private static final String DESCRIPTOR="bwGridOneXDescriptor";
    private static final String FIELD="bwGridOneX";
    private static final String SETTER="bwSetGridOneX";
    private static final String GETTER="bwIsGridOneX";
    static final String PROPERTY="bitwigipad_grid_one_x";
    private static final int STOCK_ACTIVE_STYLE=410;

    public static void main(String[] args) throws Exception {
        Path root=Path.of(args[0]);
        patch(root,"AiR","31249b9577f4ad7447f3825fbb6862a5024aba8e24961131502b4489bc967766",true);
        patch(root,"utt","571ec0dd2c8b16ca1e70cb5f1298b0d97f4032139c7b87e6f21162bd29cd6fb6",false);
    }

    private static void patch(Path root,String name,String pin,boolean schema) throws Exception {
        byte[] input=Files.readAllBytes(root.resolve(name+".stock"));
        if (input[7]!=69 || !HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(input)).equals(pin))
            throw new IllegalStateException("Stock device schema differs");
        input[7]=66;
        var reader=new ClassReader(input);
        var output=new ClassWriter(reader,ClassWriter.COMPUTE_MAXS);
        int[] registration={0};
        reader.accept(new ClassVisitor(ASM9,output) {
            public MethodVisitor visitMethod(int access,String method,String desc,String signature,String[] exceptions) {
                MethodVisitor next=super.visitMethod(access,method,desc,signature,exceptions);
                if (!schema || !method.equals("beI") || !desc.equals("(Ljava/util/List;)V")) return next;
                return new MethodVisitor(ASM9,next) {
                    public void visitInsn(int instruction) {
                        if (instruction==RETURN) {
                            register(this);
                            registration[0]++;
                        }
                        super.visitInsn(instruction);
                    }
                };
            }
            public void visitEnd() {
                if (schema) {
                    super.visitField(ACC_STATIC,DESCRIPTOR,"LdfB;",null,null).visitEnd();
                    accessor(this,ACC_PROTECTED,"beI",false,true);
                    accessor(this,ACC_PUBLIC,"sCA",true,false);
                    accessor(this,ACC_PUBLIC,"Gef",false,false);
                    accessor(this,ACC_PUBLIC,"sCA",false,false);
                } else {
                    super.visitField(0,FIELD,"Z",null,null).visitEnd();
                    getter(this);
                    setter(this);
                }
                super.visitEnd();
            }
        },0);
        if (registration[0]!=(schema?1:0)) throw new IllegalStateException("Unexpected field enumeration");
        byte[] bytes=output.toByteArray();
        bytes[7]=69;
        Path path=root.resolve("classes").resolve(BASE+name+".class");
        Files.createDirectories(path.getParent());
        Files.write(path,bytes);
    }

    private static void register(MethodVisitor method) {
        method.visitTypeInsn(NEW,"dfB");
        method.visitInsn(DUP);
        method.visitLdcInsn(PROPERTY);
        method.visitInsn(ICONST_0); // Original wire writer uses the property name for ID 0.
        method.visitVarInsn(ALOAD,0);
        method.visitFieldInsn(GETSTATIC,"java/lang/Boolean","FALSE","Ljava/lang/Boolean;");
        method.visitIntInsn(SIPUSH,STOCK_ACTIVE_STYLE);
        method.visitMethodInsn(INVOKESPECIAL,"dfB","<init>","(Ljava/lang/String;ILdfD;Ljava/lang/Boolean;I)V",false);
        for (String flag : new String[]{"not_engine","dont_send_to_slave"}) {
            method.visitInsn(DUP);
            method.visitLdcInsn(flag);
            method.visitFieldInsn(GETSTATIC,"java/lang/Boolean","TRUE","Ljava/lang/Boolean;");
            method.visitMethodInsn(INVOKEVIRTUAL,"dfB","beI","(Ljava/lang/String;Ljava/lang/Object;)V",false);
        }
        method.visitFieldInsn(PUTSTATIC,AIR,DESCRIPTOR,"LdfB;");
        method.visitVarInsn(ALOAD,0);
        method.visitFieldInsn(GETSTATIC,AIR,DESCRIPTOR,"LdfB;");
        method.visitVarInsn(ALOAD,1);
        method.visitMethodInsn(INVOKEVIRTUAL,AIR,"beI","(LdfZ;Ljava/util/List;)V",false);
    }

    private static void accessor(ClassVisitor visitor,int access,String name,boolean read,boolean raw) {
        String descriptor="("+DEV+(read?"I)Z":"IZ)V");
        MethodVisitor method=visitor.visitMethod(access,name,descriptor,null,null);
        Label original=new Label();
        method.visitCode();
        method.visitVarInsn(ILOAD,2);
        method.visitJumpInsn(IFNE,original);
        method.visitVarInsn(ALOAD,1);
        method.visitTypeInsn(CHECKCAST,UTT);
        if (read) {
            method.visitFieldInsn(GETFIELD,UTT,FIELD,"Z");
            method.visitInsn(IRETURN);
        } else {
            method.visitVarInsn(ILOAD,3);
            if (raw) method.visitFieldInsn(PUTFIELD,UTT,FIELD,"Z");
            else method.visitMethodInsn(INVOKEVIRTUAL,UTT,SETTER,"(Z)V",false);
            method.visitInsn(RETURN);
        }
        method.visitLabel(original);
        method.visitFrame(F_SAME,0,null,0,null);
        method.visitVarInsn(ALOAD,0);
        method.visitVarInsn(ALOAD,1);
        method.visitVarInsn(ILOAD,2);
        if (!read) method.visitVarInsn(ILOAD,3);
        method.visitMethodInsn(INVOKESPECIAL,SUPER,name,descriptor,false);
        method.visitInsn(read?IRETURN:RETURN);
        method.visitMaxs(0,0);
        method.visitEnd();
    }

    private static void getter(ClassVisitor visitor) {
        MethodVisitor method=visitor.visitMethod(ACC_PUBLIC | ACC_FINAL,GETTER,"()Z",null,null);
        method.visitCode();
        method.visitVarInsn(ALOAD,0);
        method.visitFieldInsn(GETFIELD,UTT,FIELD,"Z");
        method.visitInsn(IRETURN);
        method.visitMaxs(0,0);
        method.visitEnd();
    }

    private static void setter(ClassVisitor visitor) {
        MethodVisitor method=visitor.visitMethod(ACC_PUBLIC | ACC_FINAL,SETTER,"(Z)V",null,null);
        Label done=new Label();
        method.visitCode();
        method.visitVarInsn(ALOAD,0);
        method.visitFieldInsn(GETFIELD,UTT,FIELD,"Z");
        method.visitVarInsn(ILOAD,1);
        method.visitJumpInsn(IF_ICMPEQ,done);
        method.visitVarInsn(ALOAD,0);
        method.visitFieldInsn(GETSTATIC,AIR,DESCRIPTOR,"LdfB;");
        method.visitVarInsn(ALOAD,0);
        method.visitVarInsn(ILOAD,1);
        method.visitMethodInsn(INVOKEVIRTUAL,UTT,"beI","(LdfB;Lcom/bitwig/ramona/core/ytz;Z)V",false);
        method.visitVarInsn(ALOAD,0);
        method.visitVarInsn(ILOAD,1);
        method.visitFieldInsn(PUTFIELD,UTT,FIELD,"Z");
        method.visitLabel(done);
        method.visitFrame(F_SAME,0,null,0,null);
        method.visitInsn(RETURN);
        method.visitMaxs(0,0);
        method.visitEnd();
    }
}
