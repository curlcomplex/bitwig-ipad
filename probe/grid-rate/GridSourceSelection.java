import com.bitwig.flt.document.core.master.CmH;
import com.bitwig.flt.document.core.master.device.JXr;
import com.bitwig.flt.document.core.master.device.ZFS;
import com.bitwig.flt.document.core.master.device.nWI;
import com.bitwig.flt.document.core.master.device.utt;
import com.bitwig.flt.document.core.master.device.wh2;
import com.bitwig.nitro.vP2;
import com.bitwig.ramona.core.ClS;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;
import java.util.stream.Stream;

/** Model-thread handoff to the original per-atom compiler queue. */
public final class GridSourceSelection {
    // Absence means the original owner has not completed nJV.
    private static final WeakHashMap<utt,Boolean> admission = new WeakHashMap<>();
    // A false entry records completed nJV before a dispatcher was available.
    private static final Map<utt,Boolean> pending = Collections.synchronizedMap(new WeakHashMap<>());

    private static final class Policy {
        static final Method oneX = method(utt.class, "bwIsGridOneX");
        static final Field queue = queueField();
        static final Method cancel = method(queue.getType(), "beI", Object.class);
        static final Method recompile = method(TLG.class, "ogS", boolean.class);
        static final Method qualificationObservers = method(utt.class, "bwGridQualificationObservers", boolean.class);
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

    private static Field queueField() {
        try {
            Field field = TLG.class.getDeclaredField("GwM");
            field.setAccessible(true);
            return field;
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Stock Grid compiler queue differs",error);
        }
    }

    static boolean isAdmitted(utt owner) {
        return Boolean.TRUE.equals(admission.get(owner));
    }

    static boolean requestedOneX(utt owner) {
        try {
            return (boolean)Policy.oneX.invoke(owner);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Cannot read the Grid policy",error);
        }
    }

    static uLF qualificationObservers(utt owner,boolean create) {
        try {
            return (uLF)Policy.qualificationObservers.invoke(owner,create);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Cannot access stock Grid observers",error);
        }
    }

    private static final class DocumentDispatcher {
        static final Field executor = executorField();

        private static Field executorField() {
            try {
                Field field = qE.class.getDeclaredField("sCA");
                if (field.getType() != qx.class) throw new IllegalStateException("Unexpected stock document executor");
                field.setAccessible(true);
                return field;
            } catch (ReflectiveOperationException error) {
                throw new IllegalStateException("Stock document dispatcher differs",error);
            }
        }
    }

    private static boolean onDocumentThread(CmH document,ClS dispatcher) {
        FGj current = Ymy.beI();
        if (current == null || dispatcher == null || !dispatcher.isEventDispatchThread()) return false;
        if (dispatcher == current) return true;
        // The application event and its document wrapper share the original
        // application queue. Verify both the document and actual queue identity.
        if (dispatcher instanceof drM && current instanceof drL) {
            return dispatcher.MgQ() == document && current.isEventDispatchThread() &&
                dispatcher.getParallelAsyncTaskHandler() == current.getParallelAsyncTaskHandler();
        }
        // The original document dispatcher delivers its events through its
        // own qx instance, which is then the actual stock queue context.
        if (dispatcher.getClass() != qE.class || ((qE)dispatcher).beI() != document) return false;
        try {
            return DocumentDispatcher.executor.get(dispatcher) == current;
        } catch (IllegalAccessException error) {
            throw new IllegalStateException("Cannot read the stock document executor",error);
        }
    }

    private static boolean onModelThread(utt owner) {
        CmH document = owner.cc_();
        ClS dispatcher = owner.waj();
        return document != null && document.waj() == dispatcher && onDocumentThread(document,dispatcher);
    }

    public static void modelReady(utt owner) {
        if (onModelThread(owner)) {
            completeReadiness(owner,null);
            return;
        }
        if (!GridGraphProfile.isFactory(owner)) return;
        var dispatcher = owner.waj();
        var document = owner.cc_();
        if (dispatcher == null || document == null) {
            pending.putIfAbsent(owner,false);
        } else if (!Boolean.TRUE.equals(pending.put(owner,true))) {
            dispatcher.asyncExec(() -> {
                if (owner.cc_() == document && owner.waj() == dispatcher &&
                    onModelThread(owner) && pending.containsKey(owner))
                    completeReadiness(owner,null);
                else pending.replace(owner,true,false);
            });
        }
        // Stock project decode can finish nJV before document attachment.
        // Its first attached source capture completes this pending owner.
    }

    public static void documentReady(CmH document) {
        var dispatcher = document.waj();
        if (!onDocumentThread(document,dispatcher)) return;
        List<utt> owners;
        synchronized (pending) {
            owners = List.copyOf(pending.keySet());
        }
        for (utt owner : owners) {
            if (owner.cc_() == document && owner.waj() == dispatcher && pending.containsKey(owner))
                completeReadiness(owner,null);
        }
    }

    private static void completeReadiness(utt owner,TLG choosing) {
        pending.remove(owner);
        if (GridGraphProfile.isFactory(owner)) {
            setAdmission(owner,GridGraphProfile.qualifies(owner),choosing);
        } else if (admission.containsKey(owner)) {
            setAdmission(owner,false,choosing);
        }
    }

    public static void beforeAdd(nWI grid,wh2 node) {
        if (grid.BBg(utt.class) instanceof utt owner && owner.Qnz() == grid && onModelThread(owner) &&
            isAdmitted(owner) &&
            node instanceof ZFS module && !GridGraphProfile.qualifiedModule(module))
            setAdmission(owner,false,null);
    }

    public static void afterAdd(nWI grid,wh2 node) {
        if (!(grid.BBg(utt.class) instanceof utt owner) || owner.Qnz() != grid ||
            !onModelThread(owner) || !(node instanceof ZFS module))
            return;
        Boolean qualified = admission.get(owner);
        if (Boolean.FALSE.equals(qualified)) {
            modelReady(owner);
        } else if (Boolean.TRUE.equals(qualified) && requestedOneX(owner)) {
            // A detached module may have compiled in its stock context.
            Set<TLG> affected = Collections.newSetFromMap(new IdentityHashMap<>());
            collect(module.vUU(),owner,affected);
            recompile(affected);
        }
    }

    public static void afterRemove(nWI grid) {
        if (grid.BBg(utt.class) instanceof utt owner && owner.Qnz() == grid && onModelThread(owner) &&
            Boolean.FALSE.equals(admission.get(owner))) modelReady(owner);
    }

    private static void setAdmission(utt owner,boolean enabled,TLG choosing) {
        boolean wasAdmitted = Boolean.TRUE.equals(admission.put(owner,enabled));
        if (wasAdmitted == enabled) return;
        if (requestedOneX(owner)) recompileOwner(owner,choosing);
        uLF observers = qualificationObservers(owner,false);
        if (observers != null) observers.fireEvent(owner);
    }

    public static void policyChanged(utt owner) {
        if (onModelThread(owner) && isAdmitted(owner)) recompileOwner(owner,null);
    }

    private static void recompileOwner(utt owner,TLG choosing) {
        nWI grid = owner.Qnz();
        if (grid == null) return;
        Set<TLG> affected = Collections.newSetFromMap(new IdentityHashMap<>());
        collect(owner.vUU(),owner,affected);
        for (Object module : grid.dvk()) collect(((ZFS)module).vUU(),owner,affected);
        affected.remove(choosing);
        recompile(affected);
    }

    private static void recompile(Set<TLG> atoms) {
        if (atoms.isEmpty()) return;
        try {
            Object queue = Policy.queue.get(null);
            // Invalidate all original callbacks before any of the deferred
            // rebuilds can enqueue their replacement work.
            for (TLG atom : atoms) {
                if (atom.cc_() != null) Policy.cancel.invoke(queue,atom);
            }
            for (TLG atom : atoms) Policy.recompile.invoke(atom, false);
        } catch (ReflectiveOperationException error) {
            throw new IllegalStateException("Cannot recompile the Grid",error);
        }
    }

    private static void collect(Stream<?> atoms, utt owner, Set<TLG> affected) {
        try (atoms) {
            for (TLG atom : atoms.filter(TLG.class::isInstance).map(TLG.class::cast).toList()) {
                if (atom.BBg(utt.class) == owner) affected.add(atom);
            }
        }
    }

    private static boolean isGridAtom(utt owner, TLG atom) {
        if (atom.BBg(ZFS.class) instanceof ZFS module)
            return owner.Qnz() != null && module.Xit() == owner.Qnz();
        try (Stream<?> outer = owner.vUU()) {
            return outer.anyMatch(item -> item == atom);
        }
    }

    static vP2 choose(TLG atom, vP2 source) {
        Object ancestor = atom.BBg(utt.class);
        if (!(ancestor instanceof utt owner) || !onModelThread(owner)) return source;
        if (pending.containsKey(owner) && isGridAtom(owner,atom)) completeReadiness(owner,atom);
        if (!isAdmitted(owner) || !requestedOneX(owner) || !isGridAtom(owner,atom)) return source;
        GridSourceProfile.Rule rule = GridSourceProfile.classify(source);
        if (rule == null) {
            // The actual source can change after initial qualification.
            // Restore the entire owner with the original per-atom queue.
            setAdmission(owner,false,atom);
            return source;
        }
        boolean builtinPulse = "grid/io/trigger_merge.nitro".equals(source.MgQ()) &&
            atom.GKn() != null && atom.GKn().unz() > 2 && atom.GKn().Gef(2) != null &&
            atom.GKn().Gef(2).mEL() instanceof JXr precord && "TRIGGER_IN".equals(precord.MgQ());
        return new GridVariantInput(source, rule == GridSourceProfile.Rule.CARRIER, builtinPulse);
    }
}
