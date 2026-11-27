import com.bitwig.flt.document.core.master.device.AiR;
import com.bitwig.flt.document.core.master.device.utt;
import java.util.IdentityHashMap;
import java.util.Map;

/** Adds the native choice when the whole selected Grid can change rate. */
final class GridInspectorRow {
    private static final String STOCK = "4×";
    private static final String HOST = "1×";

    static void append(aKf inspector, sgf selection, dXL rows) {
        if (!(selection instanceof utt device) || !GridSourceSelection.isAdmitted(device)) return;
        var field = (dfB)AiR.sCA.beI(PatchGridPolicy.PROPERTY);
        var control = dDu.beI(new Choice(device, field), new Object[]{STOCK, HOST});
        control.Gef(inspector.JrT());
        rows.IvP(aMZ.beI("Oversampling", (String)null, control));
    }

    private static final class Choice implements uB1 {
        private final utt device;
        private final dfB field;
        private final Map<NVD,NVD> listeners = new IdentityHashMap<>();

        Choice(utt device, dfB field) {
            this.device = device;
            this.field = field;
        }

        @Override
        public Object getValue() {
            return field.Bqk(device) ? HOST : STOCK;
        }

        @Override
        public boolean isSettable() {
            return GridSourceSelection.isAdmitted(device);
        }

        @Override
        public void setValue(Object value) {
            if (isSettable() && (HOST.equals(value) || STOCK.equals(value))) {
                field.sCA(device, HOST.equals(value));
            }
        }

        @Override
        public boolean isObservable() {
            return true;
        }

        @Override
        public void addListener(NVD listener) {
            if (listeners.containsKey(listener)) return;
            NVD relay = ignored -> listener.eventOccurred(getValue());
            field.beI(device, relay);
            listeners.put(listener, relay);
        }

        @Override
        public void removeListener(NVD listener) {
            NVD relay = listeners.remove(listener);
            if (relay != null) field.Gef(device, relay);
        }
    }
}
