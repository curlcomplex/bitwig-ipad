import com.bitwig.nitro.nEh;
import com.bitwig.nitro.vP2;

final class GridCompileInput extends vP2 {
    private final byte[] payload;
    private final String identity;

    GridCompileInput(byte[] payload, String identity) {
        this.payload = payload.clone();
        this.identity = identity;
    }

    @Override
    protected byte[] beI() { return payload; }

    @Override
    protected nEh sCA() { return nEh.Gef; }

    @Override
    public boolean Gef() { return false; }

    @Override
    public String MgQ() { return identity; }
}
