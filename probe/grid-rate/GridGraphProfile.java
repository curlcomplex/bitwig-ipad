import com.bitwig.flt.document.core.master.device.Jpp;
import com.bitwig.flt.document.core.master.device.OqJ;
import com.bitwig.flt.document.core.master.device.ZFS;
import com.bitwig.flt.document.core.master.device.nWI;
import com.bitwig.flt.document.core.master.device.utt;
import com.bitwig.flt.packaging.core.SJF;
import com.bitwig.nitro.QxI;
import com.bitwig.nitro.vP2;
import java.lang.reflect.Field;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Read-only qualification for the exact original Grid factories. */
final class GridGraphProfile {
    private record Pulse(String source, int outlet) {}

    private static final Pulse GRID_VOICE = new Pulse("grid/voice_logic/grid_poly_logic.nitro",1);
    private static final class StockFactories {
        static final Map<UUID,Pulse> PULSES = Map.of(
            SJF.UnB, GRID_VOICE,
            SJF.JrT, GRID_VOICE,
            SJF.XnJ, new Pulse("polymer/polymer_poly_logic.nitro",2));
    }

    private static final class StockSource {
        static final Field PREFER_ARCHIVE = field("Anf");
        static final Field PATH = field("MgQ");
        static final Field BINARY = field("unz");
        static final Field PAYLOAD = field("BBg");

        private static Field field(String name) {
            try {
                Field field = dad.class.getDeclaredField(name);
                field.setAccessible(true);
                return field;
            } catch (ReflectiveOperationException error) {
                throw new IllegalStateException("Stock Grid source layout differs",error);
            }
        }
    }

    static boolean isFactory(utt owner) {
        if (owner.Qnz() == null) return false;
        UUID id = owner.beI();
        return id != null && StockFactories.PULSES.containsKey(id);
    }

    static boolean qualifies(utt owner) {
        nWI grid = owner.Qnz();
        if (grid == null) return false;
        try (var atoms = owner.vUU()) {
            return qualifies(owner.beI(),atoms.toList(),grid);
        }
    }

    static boolean qualifies(UUID type,List<?> outer,nWI grid) {
        Pulse pulse = type == null ? null : StockFactories.PULSES.get(type);
        if (pulse == null || !matchesPulseSource(outer,pulse) || !qualifiedSources(outer)) return false;
        for (Object child : grid.dvk()) {
            if (!qualifiedModule((ZFS)child)) return false;
        }
        return true;
    }

    static boolean qualifiedModule(ZFS module) {
        var definition = module.MvA();
        if (definition == null || !GridStockModuleIds.contains(definition.unz())) return false;
        try (var atoms = module.vUU()) {
            return qualifiedSources(atoms.toList());
        }
    }

    private static boolean qualifiedSources(List<?> atoms) {
        for (Object atom : atoms) {
            if (atom instanceof TLG processor && !qualifiedSource(originalInput(processor))) return false;
        }
        return true;
    }

    private static boolean matchesPulseSource(List<?> outer,Pulse expected) {
        Jpp input = null;
        for (Object atom : outer) {
            if (atom instanceof Jpp candidate && "TRIGGER_IN".equals(candidate.ay_())) {
                if (input != null) return false;
                input = candidate;
            }
        }
        if (input == null || input.GKn() == null || input.GKn().unz() != 1) return false;
        OqJ wire = input.GKn().Gef(0);
        if (wire == null || wire.MgQ() != expected.outlet() || !(wire.mEL() instanceof TLG processor) ||
            outer.stream().noneMatch(atom -> atom == processor)) return false;
        vP2 source = originalInput(processor);
        return source instanceof plf && expected.source().equals(source.MgQ()) && qualifiedSource(source);
    }

    private static boolean qualifiedSource(vP2 source) {
        return source != null && GridSourceProfile.classify(source) != null;
    }

    /** Follow the original source-kind branches without queuing a compile. */
    static vP2 originalInput(TLG atom) {
        try {
            String path = (String)StockSource.PATH.get(atom);
            if (StockSource.PREFER_ARCHIVE.getBoolean(atom)) {
                if (path == null || path.isBlank()) return null;
                Qly archive = QxI.sCA();
                // The original prefers this plain-text path before trying
                // its compiled stock archive sibling. Plain text is outside
                // the pinned binary profile.
                if (archive.nhI(UhI.beI(path))) return null;
                UhI binary = UhI.beI(path + "bin");
                return archive.nhI(binary) ? new plf(atom,archive,binary,path) : null;
            }
            byte[] payload = (byte[])StockSource.PAYLOAD.get(atom);
            return StockSource.BINARY.getBoolean(atom) && payload != null && payload.length != 0 ?
                new bjh(atom,payload,path) : null;
        } catch (IllegalAccessException error) {
            throw new IllegalStateException("Cannot read the stock Grid source",error);
        }
    }
}
