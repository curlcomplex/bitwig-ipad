import com.bitwig.base.serial.binary.SJF;
import com.bitwig.flt.document.core.master.fix;
import com.bitwig.flt.document.core.master.device.AiR;
import com.bitwig.ramona.core.tjc;
import com.bitwig.ramona.core.ytz;
import java.io.ByteArrayInputStream;
import com.bitwig.ramona.serial.qAF;
import java.io.ByteArrayOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

final class VerifyGridPolicy {
    private static final String PROPERTY="bitwigipad_grid_one_x";
    private static byte[] serialize(ytz value,dga config,qAF flags) {
        var bytes=new ByteArrayOutputStream();
        var out=SJF.beI().beI(bytes);
        out.beI();
        value.beI(out,flags);
        out.Gef();
        return bytes.toByteArray();
    }
    private static ytz read(dfD schema,byte[] bytes) {
        var source=SJF.beI().beI(new ByteArrayInputStream(bytes));
        return (ytz)schema.beI(source);
    }
    private static boolean named(byte[] bytes) {
        return new String(bytes,java.nio.charset.StandardCharsets.ISO_8859_1).contains(PROPERTY);
    }
    private static void require(boolean condition,String message) {
        if (!condition) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        dga config=fix.beI();
        dfD schema=AiR.sCA;
        var make=AiR.class.getDeclaredMethod("XnJ");
        make.setAccessible(true);
        ytz first=(ytz)make.invoke(schema);
        ytz second=(ytz)make.invoke(schema);
        first.H_();
        second.H_();
        dgt identity=(dgt)schema.beI("UUID");
        identity.beI(first, java.util.UUID.randomUUID());
        identity.beI(second, java.util.UUID.randomUUID());
        dfB field=(dfB)schema.beI(PROPERTY);
        if (args[0].equals("stock-write")) {
            require(field==null,"stock property absent");
            Files.write(Path.of(args[1],"stock-absent.obj"),serialize(first,config,qAF.sCA));
            return;
        }
        if (args[0].equals("stock")) {
            require(field==null,"stock property absent");
            for (String name : new String[]{"default.obj","selected.obj"}) {
                var result=read(schema,Files.readAllBytes(Path.of(args[1],name)));
                require(result!=null && result.getClass()==first.getClass(),"stock native-device record opens");
                require(!named(serialize(result,config,qAF.sCA)),"stock re-save drops unknown property");
                System.out.println("Stock tagged codec opened and re-saved "+name);
            }
            return;
        }
        require(field!=null && field.ymo()==0 && field.unz(),"named optional ID0");
        require(field.unz("dont_send_to_slave") && !s1I.beI(field) && !s1I.beI(field,first),
            "original property filters exclude policy from engine/peer");
        System.out.println("Original s1I engine-filter predicates exclude policy");
        byte[] absent=Files.readAllBytes(Path.of(args[1],"stock-absent.obj"));
        require(!named(absent) && !field.Bqk(read(schema,absent)),"old stock absent defaults to 4x");
        require(!field.Bqk(first) && !field.Bqk(second),"independent defaults");
        byte[] fileDefault=serialize(first,config,qAF.sCA);
        field.sCA(first,true);
        require(field.Bqk(first) && !field.Bqk(second),"independent normal transaction");
        byte[] fileSelected=serialize(first,config,qAF.sCA);
        Files.write(Path.of(args[1],"default.obj"),fileDefault);
        Files.write(Path.of(args[1],"selected.obj"),fileSelected);
        System.out.println(" tagged fixture lengths="+fileDefault.length+"/"+fileSelected.length+" named="+named(fileDefault)+"/"+named(fileSelected));
        require(!Arrays.equals(fileDefault,fileSelected) && named(fileDefault) && named(fileSelected),"standard file stores exact named values");
        require(!named(serialize(second,config,qAF.MgQ)) && named(serialize(first,config,qAF.MgQ)),"omit-default mode tags only true");
        require(!field.Bqk(read(schema,fileDefault)) && field.Bqk(read(schema,fileSelected)),
            "original writer/reader roundtrip");
        ytz cloned=tjc.beI().Gef(first);
        require(cloned!=first && field.Bqk(cloned),"stock copy");
        field.sCA(first,false);
        require(!field.Bqk(first) && field.Bqk(cloned),"independent after clone");
        System.out.println("Two native-devices, normal txn, named wire ID0 roundtrip and stock clone passed");
    }
}
