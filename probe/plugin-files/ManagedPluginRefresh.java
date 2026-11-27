import com.bitwig.flt.app.Hvv;
import com.bitwig.flt.prefs.EKq;
import com.bitwig.flt.prefs.Mv;
import java.io.File;
import java.util.HashMap;
import java.util.Map;

public final class ManagedPluginRefresh {
    private static final Map<String, Object> pending = new HashMap<>();
    private static boolean scheduled;

    public static synchronized void request(String clap, String vst3) {
        if (clap != null) pending.put(clap, new Object());
        if (vst3 != null) pending.put(vst3, new Object());
        schedule();
    }

    private static void schedule() {
        if (pending.isEmpty() || scheduled) return;
        drf app = drf.EO();
        if (app == null) return;
        scheduled = true;
        try {
            app.asyncExec(ManagedPluginRefresh::refresh);
        } catch (RuntimeException error) {
            scheduled = false;
            throw error;
        }
    }

    private static void refresh() {
        Map<String, Object> batch;
        synchronized (ManagedPluginRefresh.class) {
            batch = Map.copyOf(pending);
        }
        try {
            Hvv app = Hvv.mEL();
            if (app == null || app.oHY() == null || app.oHY().Fhl() == null) return;
            for (Object item : Mv.sCA.beI(app.oHY().Fhl())) {
                if (!(item instanceof EKq location)) continue;
                File configured = location.ymo();
                if (configured == null) continue;
                String path = configured.getAbsolutePath();
                Object token = batch.get(path);
                if (token == null) continue;
                uz scanner = location.Bqk();
                if (scanner == null) continue;
                scanner.beI(false, true);
                synchronized (ManagedPluginRefresh.class) {
                    pending.remove(path, token);
                }
            }
        } finally {
            synchronized (ManagedPluginRefresh.class) {
                scheduled = false;
                // New changes during this scan can run immediately. A missing scanner
                // is retried on the next activation instead of spinning.
                if (pending.entrySet().stream().anyMatch(entry -> batch.get(entry.getKey()) != entry.getValue()))
                    schedule();
            }
        }
    }
}
