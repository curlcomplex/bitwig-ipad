import com.bitwig.nitro.NitroFile;
import com.bitwig.nitro.nEh;
import com.bitwig.nitro.vP2;

/** One immutable, already-qualified source choice for the stock compiler. */
final class GridVariantInput extends vP2 {
    private static final String CACHE_SUFFIX = ":bitwigipad-grid-1x-v1";
    private final vP2 original;
    private final boolean passthrough;

    GridVariantInput(vP2 original, boolean passthrough) {
        this.original = original;
        this.passthrough = passthrough;
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
        return original.MgQ() + CACHE_SUFFIX;
    }

    @Override
    public NitroFile unz() {
        NitroFile parsed = original.unz();
        return passthrough ? parsed : GridVariantAst.apply(parsed);
    }
}
