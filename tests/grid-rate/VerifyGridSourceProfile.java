import com.bitwig.nitro.QxI;
import com.bitwig.nitro.vP2;
import java.nio.file.Files;
import java.nio.file.Path;

final class VerifyGridSourceProfile {
    public static void main(String[] args) throws Exception {
        var owner = new TLG();
        var installed = QxI.sCA();
        String sine = "grid/oscillators/grid_sine4.nitro";
        var sinePath = UhI.beI(sine + "bin");
        var sineSource = new plf(owner, installed, sinePath, sine);
        require(sineSource, GridSourceProfile.Rule.TRANSFORM);
        for (String path : new String[]{"grid/gate/grid_gate_merge.nitro", "grid/voice_logic/grid_mute_when_stopped.nitro"}) {
            var source = new plf(owner, installed, UhI.beI(path + "bin"), path);
            require(source, GridSourceProfile.Rule.CARRIER);
            if (!GridCarrierProof.accepts(source.unz())) throw new AssertionError("Carrier proof failed: " + path);
        }
        if (GridCarrierProof.accepts(sineSource.unz())) throw new AssertionError("Accepted stateful oscillator");
        if (GridSourceSelection.choose(owner, sineSource) != sineSource)
            throw new AssertionError("Unadmitted graph changed its stock input");
        require(new plf(owner, installed, sinePath, "lag/lag_grid.nitro"), null);
        require(new plf(owner, installed, UhI.beI("grid/oscillators/grid_saw4.nitrobin"), sine), null);

        byte[] clock = Files.readAllBytes(Path.of(args[0]));
        require(new bjh(owner, clock, "Clock Quantize"), GridSourceProfile.Rule.TRANSFORM);
        require(new bjh(owner, installed.kwH(sinePath), sine), null);
        clock[clock.length - 1] ^= 1;
        require(new bjh(owner, clock, "Clock Quantize"), null);
        System.out.println("Stock archive and embedded source identity checks passed");
    }

    private static void require(vP2 source, GridSourceProfile.Rule expected) {
        if (GridSourceProfile.classify(source) != expected)
            throw new AssertionError("Unexpected source rule: " + source.MgQ());
    }
}
