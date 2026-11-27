import com.bitwig.flt.document.core.master.device.AiR;
import com.bitwig.flt.document.core.master.device.utt;
import java.util.IdentityHashMap;
import java.util.Map;

/** Adds the native choice when the whole selected Grid can change rate. */
final class GridInspectorRow {
    private static final String STOCK = "4×";
    private static final String HOST = "1×";

    static void append(aKf inspector, sgf selection, dXL rows) {
        if (!(selection instanceof utt device) || !GridGraphProfile.isFactory(device)) return;
        var field = (dfB)AiR.sCA.beI(PatchGridPolicy.PROPERTY);
        var control = dDu.beI(new Choice(device, field), new Object[]{STOCK, HOST});
        control.Gef(inspector.JrT());
        rows.IvP(aMZ.beI("DSP rate",
            "Grid oversampling. 1× uses the host sample rate. 4× uses the original processing rate.", control));
    }

    static final class Choice implements uB1 {
        private final utt device;
        private final dfB field;
        private final Map<NVD,NVD> listeners = new IdentityHashMap<>();

        Choice(utt device, dfB field) {
            this.device = device;
            this.field = field;
        }

        @Override
        public Object getValue() {
            return isSettable() && field.Bqk(device) ? HOST : STOCK;
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
            NVD relay = new NVD() {
                private Object previous = getValue();

                @Override
                public void eventOccurred(Object event) {
                    Object current = getValue();
                    Object old = previous;
                    previous = current;
                    listener.eventOccurred(new MNh(Choice.this,current,old));
                }
            };
            field.beI(device,relay);
            GridSourceSelection.qualificationObservers(device,true).addListener(relay);
            listeners.put(listener,relay);
        }

        @Override
        public void removeListener(NVD listener) {
            NVD relay = listeners.remove(listener);
            if (relay != null) {
                field.Gef(device,relay);
                GridSourceSelection.qualificationObservers(device,false).removeListener(relay);
            }
        }
    }
}
