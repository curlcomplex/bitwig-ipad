import com.bitwig.flt.document.core.master.device.ZFS;
import com.bitwig.flt.document.core.master.device.utt;
import com.bitwig.nitro.vP2;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.stream.Stream;

/** Model-thread handoff to the original per-atom compiler queue. */
public final class GridSourceSelection {
    private static final Set<utt> admitted = Collections.newSetFromMap(new WeakHashMap<>());

    private static final class Policy {
        static final Method oneX = method(utt.class, "bwIsGridOneX");
        static final Method recompile = method(TLG.class, "ogS", boolean.class);
    }

    private static Method method(Class<?> owner, String name, Class<?>... arguments) {
        try {
            Method method = owner.getDeclaredMethod(name, arguments);
            method.setAccessible(true);
            return method;
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Stock Grid model contract differs", error);
        }
    }

    // Whole-graph qualification must finish before enabling the owner. Source
    // selection still validates each actual input as the graph is edited.
    static void admit(utt owner) {
        admitted.add(owner);
    }

    static boolean isAdmitted(utt owner) {
        return admitted.contains(owner);
    }

    public static void policyChanged(utt owner) {
        if (!isAdmitted(owner)) return;
        Set<TLG> affected = Collections.newSetFromMap(new IdentityHashMap<>());
        collect(owner.vUU(),owner,affected);
        for (Object module : owner.Qnz().dvk()) {
            collect(((ZFS)module).vUU(),owner,affected);
        }
        try {
            for (TLG atom : affected) Policy.recompile.invoke(atom, false);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Cannot recompile the admitted Grid", error);
        }
    }

    private static void collect(Stream<?> atoms, utt owner, Set<TLG> affected) {
        try (atoms) {
            for (TLG atom : atoms.filter(TLG.class::isInstance).map(TLG.class::cast).toList()) {
                if (atom.BBg(utt.class) == owner) affected.add(atom);
            }
        }
    }

    static vP2 choose(TLG atom, vP2 source) {
        Object ancestor = atom.BBg(utt.class);
        if (!(ancestor instanceof utt owner) || !isAdmitted(owner)) return source;
        try {
            if (!(boolean)Policy.oneX.invoke(owner)) return source;
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Cannot read the admitted Grid policy", error);
        }
        GridSourceProfile.Rule rule = GridSourceProfile.classify(source);
        if (rule == null) throw new IllegalStateException("Admitted Grid source requires a rate rule");
        return new GridVariantInput(source, rule == GridSourceProfile.Rule.CARRIER);
    }
}
