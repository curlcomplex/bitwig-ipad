import com.bitwig.nitro.ConstantDeclaration;
import com.bitwig.nitro.NitroFile;
import com.bitwig.nitro.Yop;
import com.bitwig.nitro.nEh;
import com.bitwig.nitro.vP2;
import java.util.ArrayList;

/** One immutable, already-qualified source choice for the stock compiler. */
final class GridVariantInput extends vP2 {
    // Advance the suffix when a rate rule changes generated DSP semantics.
    private static final String CACHE_SUFFIX = ":bitwigipad-grid-1x-v3";
    private final vP2 original;
    private final boolean passthrough;
    private final boolean builtinPulse;

    GridVariantInput(vP2 original, boolean passthrough) {
        this(original, passthrough, false);
    }

    GridVariantInput(vP2 original, boolean passthrough, boolean builtinPulse) {
        this.original = original;
        this.passthrough = passthrough;
        this.builtinPulse = builtinPulse;
    }

    static ArrayList<ConstantDeclaration> compilerProperties(
        vP2 selection, ArrayList<ConstantDeclaration> stock) {
        if (!(selection instanceof GridVariantInput variant) || variant.passthrough ||
            !GridSourceProfile.gridModulationFx(variant.original)) return stock;

        ArrayList<ConstantDeclaration> adjusted = new ArrayList<>(stock);
        int replacements = 0;
        for (int i = 0; i < stock.size(); i++) {
            ConstantDeclaration property = stock.get(i);
            if (!property.scr().equals("SR_MULTIPLIER")) continue;
            if (!GridVariantAst.isFourTimesProperty(property))
                throw new IllegalStateException("Unexpected stock modulation FX multiplier");
            adjusted.set(i,Yop.beI("SR_MULTIPLIER",1).BBg());
            replacements++;
        }
        if (replacements != 1) throw new IllegalStateException("Expected one modulation FX multiplier");
        return adjusted;
    }

    @Override
    protected byte[] beI() {
        return original.BBg();
    }

    @Override
    protected nEh sCA() {
        return nEh.Gef;
    }

    @Override
    public boolean Gef() {
        return false;
    }

    @Override
    public String MgQ() {
        return original.MgQ() + CACHE_SUFFIX + (builtinPulse ? ":builtin-pulse" : "");
    }

    @Override
    public NitroFile unz() {
        NitroFile parsed = original.unz();
        return passthrough ? parsed : GridVariantAst.apply(parsed, builtinPulse);
    }
}
