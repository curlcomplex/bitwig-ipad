import com.bitwig.nitro.vP2;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;

/** Source identities observed for the original 6.1.7 compiler inputs. */
final class GridSourceProfile {
    enum Rule { TRANSFORM, CARRIER }

    private record Named(String digest, Rule rule) {}

    private static final Map<String, Named> ARCHIVE = Map.ofEntries(
        variant("envelope/grid_ad.nitro", "16f3209e2dc2aaf550c6131a422d239f0c17a4aa488858dd86e9932637ede773"),
        variant("envelope/grid_ar.nitro", "c044f0237f25b8d47d23bc0ee726639d65527486a6bd9a3558e4913de67c8efc"),
        variant("envelope/grid_adsr.nitro", "e630faed6d3889f9cf1607be08fc4519eb22b7b51aba6a7218267ce694324330"),
        variant("grid/delay/grid_allpass_delay.nitro", "c689111d24f7c82404493750841bc8b03962917f485176d1a5d4888cc571b185"),
        variant("grid/delay/grid_delay.nitro", "c6ed90f6b01c61b3f0636232a5a0b79618b05753fa83e3c6dff30258733ee337"),
        variant("grid/delay/grid_mod_delay.nitro", "d04b4cf9ae56dc28cbf2521a5ba23985ba432bb63e79ae5b6b5929a901e56255"),
        variant("grid/io/trigger_merge.nitro", "c65bf54db69992bb57bbd4328498574c94bf658fed5e9e56ec045a73e89d9a44"),
        Map.entry("grid/gate/grid_gate_merge.nitro",
            new Named("f62e41745175162acb27493b5d923aaa07dbee5659eed9e09673485ffffb0162", Rule.CARRIER)),
        Map.entry("grid/voice_logic/grid_mute_when_stopped.nitro",
            new Named("282ed15c32c36320e47a989fea901c5d9e80b5e9e87d9e9a2ec34bae35bb3c1e", Rule.CARRIER)),
        variant("grid/logic/clock_divide.nitro", "d8ea4b572c83aa20730543c507012a64be624cad78ae7fc40f03ebcbbbfc30e5"),
        variant("grid/oscillators/grid_phase1.nitro", "f0c9172e35da0a6ec9b3a77258e6f69e392db26241d3e2c4de19920ca0216e48"),
        variant("grid/oscillators/grid_pulse4.nitro", "fd94695c8a1ea86a8edf437c9e6aaeb33e182ab039a9c9b74ce1a1d7c991a8a3"),
        variant("grid/oscillators/grid_saw4.nitro", "6538aeac6060c3b6eaadaff11fe55b64dd7c541bfc74cb989f08857e0c670894"),
        variant("grid/oscillators/grid_sine4.nitro", "a872a4017a8b0b3ce71372b79682f701adc11cfa3070e334111c6a44aacdb02f"),
        variant("grid/oscillators/grid_tri4.nitro", "e4cbc986712ffa08a1a857619d4fd992fbb9540fb7cf70cf28a57e1e8cd26e28"),
        variant("grid/oscillators/grid_union.nitro", "069d8cab8374f8d26258644dd97ebdc43fea3829bb7423371362f8b288482f7f"),
        Map.entry("grid/voice_logic/grid_poly_logic.nitro",
            new Named("942dc897dc3f9078863d88af4ab2c909f725993575491f7239d1321a4f5089b5", Rule.CARRIER)),
        variant("grid/shaper/distortion.nitro", "357be02a8216a8132bcca833cdf0cefa5764a698667a5862a38b3d0fd2961235"),
        variant("grid/shaper/drunk_clip.nitro", "8c4dc1fcdd9bf1909f0f97d268e71c4695c276eaae71f4bf09ecea90a93918bc"),
        variant("grid/shaper/e_clip.nitro", "1b61aae4201035bf8c27b824549476a599f2170b31c7be62f0807949cb5418ef"),
        variant("grid/shaper/gentle_fold.nitro", "1db1e2ab577521a3dcdabd322fc043c0feaea0b8d8b30ec6642edb601f3b88dc"),
        variant("grid/shaper/hardclip2.nitro", "ea3284c29c98aa26e4574ef6b997b5c063c1a41438a7e93809f0bce0b8e83053"),
        variant("grid/shaper/rectifier.nitro", "30819ffe29869024316ba7cbcf9ec9a115a8d79e9547416d5b305f71ca571cc6"),
        variant("grid/shaper/s_clip.nitro", "07e7143dd3d99d87d4a5b3961c9540fdbecb3263f249c7b72676949dd42431a8"),
        variant("grid/shaper/wavefolder.nitro", "73aa6d7808aca57c49cb34c09c9735974a9a5bd1740168e0526409aaf3770ff0"),
        variant("grid/phase/grid_phasor.nitro", "864a4f86a29017b0fef3f7298d934a733dc5f8b7a754165732a5d0a71bd11e5d"),
        variant("grid/phase/grid_phasor_pm.nitro", "0e7d1151cd98fb7fa8e1c313ee169a8ba8f77c6b62ec06c4fc4c16ba1530e9d2"),
        variant("grid/phase/grid_phase_counter.nitro", "d2424c255e86536839f69a17e713994ff21b44585a45b3f19c01691262d6ba77"),
        variant("grid/lfo/phasor.nitro", "0d4048c034d4ec9fb366311de56d8bc744f5433b7ce75f5274c10e492d967bcf"),
        variant("filter/BWLPF.nitro", "fac3170c9e1ff9d916d36e30e969aaa9141c1c8f0410132944bb14733aa9a755"),
        variant("filter/BWHPF.nitro", "f9099e715340d30f17411dbe247112794de4e23d52e242d79ee7efdc17d1f964"),
        variant("filter/BWAPF.nitro", "0115c734c9f9fd3d1605ce6121c949a5f92cff07a73daa7d4105e963c8026f13"),
        variant("filter/LR2.nitro", "0c41c4fa2c9e687c33d4fa3eac7e9768f94e6859951e0232a5eb263d59d77cf6"),
        variant("filter/LR3.nitro", "5e3f936e9c24fba001718e829ea6ebe2b8ecd1657970474c888543a7af20c4ed"),
        variant("grid/io/audio_out.nitro", "fdb4b59c3836c4f29c6315767a818b88994fd5e8c274d3d02cf68f8f6cc6f952")
    );

    private static final Map<String, Rule> EMBEDDED = Map.of(
        "f540c2e9e53042cbf028e3e278b5012345c20e88168c830a0d0036dfd7a294b1", Rule.TRANSFORM,
        "27ead7a03b9efb145db0262f35584f873efa0bff518deb1eaa8d86b57c0d4d0e", Rule.TRANSFORM,
        "29b723d70b6f23720ff78f8bbefa7d5feb48cedc74e7d73b129d9b73508e4f6c", Rule.TRANSFORM,
        "6f1f993016f39a8eb9cb4849ddb93033480dc18993bd7598888824ce91a3ffd7", Rule.TRANSFORM,
        "a8fc91789497be30ecc761be5f78ba70143dd000acdacdf18e4d167ddab895e6", Rule.TRANSFORM,
        "c277b68392f9beb729f7bf788dad288feeabb4c32a94504ba4875d04a1885212", Rule.TRANSFORM,
        "eae00669b1560819027bab1c14b4af9673b160447f4559976d722371efb62664", Rule.CARRIER,
        "8508e8783724639d4a2babfc61739239e8bf8eab1f5e6889961c2ce736343b0c", Rule.CARRIER
    );

    private static Map.Entry<String, Named> variant(String resource, String digest) {
        return Map.entry(resource, new Named(digest, Rule.TRANSFORM));
    }

    static Rule classify(vP2 source) {
        return switch (source.getClass().getName()) {
            case "plf" -> {
                String path = source.MgQ();
                Named named = path == null ? null : ARCHIVE.get(path);
                yield named != null && named.digest().equals(digest(source.BBg())) ? named.rule() : null;
            }
            case "bjh" -> {
                String hash = digest(source.BBg());
                yield hash == null ? null : EMBEDDED.get(hash);
            }
            default -> null;
        };
    }

    private static String digest(byte[] payload) {
        if (payload == null) return null;
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(payload));
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException(error);
        }
    }
}
