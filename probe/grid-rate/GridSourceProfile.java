import com.bitwig.nitro.vP2;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;

/** Source identities observed for the original 6.1.7 compiler inputs. */
final class GridSourceProfile {
    enum Rule { TRANSFORM, CARRIER }

    private record Named(String digest, Rule rule) {}

    private static final Map<String, Named> ARCHIVE = Map.ofEntries(
        Map.entry("dummy_component.nitro",
            new Named("931fc2b993d17abb0a2fcb94a1fc3d12cd67e0f277577ff76865825578b9e7af", Rule.CARRIER)),
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
        variant("grid/voice_logic/grid_lifetimer.nitro", "1c640364de4c7cc9cdce4f5a8f0f547d75c6f25c6ea2cbda4120d1fcbbd60847"),
        variant("grid/io/audio_out.nitro", "fdb4b59c3836c4f29c6315767a818b88994fd5e8c274d3d02cf68f8f6cc6f952")
    );

    private static final Map<String, Rule> EMBEDDED = Map.ofEntries(
        Map.entry("f540c2e9e53042cbf028e3e278b5012345c20e88168c830a0d0036dfd7a294b1", Rule.TRANSFORM),
        Map.entry("27ead7a03b9efb145db0262f35584f873efa0bff518deb1eaa8d86b57c0d4d0e", Rule.TRANSFORM),
        Map.entry("29b723d70b6f23720ff78f8bbefa7d5feb48cedc74e7d73b129d9b73508e4f6c", Rule.TRANSFORM),
        Map.entry("6f1f993016f39a8eb9cb4849ddb93033480dc18993bd7598888824ce91a3ffd7", Rule.TRANSFORM),
        Map.entry("a8fc91789497be30ecc761be5f78ba70143dd000acdacdf18e4d167ddab895e6", Rule.TRANSFORM),
        Map.entry("c277b68392f9beb729f7bf788dad288feeabb4c32a94504ba4875d04a1885212", Rule.TRANSFORM),
        Map.entry("eae00669b1560819027bab1c14b4af9673b160447f4559976d722371efb62664", Rule.CARRIER),
        Map.entry("8508e8783724639d4a2babfc61739239e8bf8eab1f5e6889961c2ce736343b0c", Rule.CARRIER),
        Map.entry("9e81d942c9668a81bf388754ad63fb71c6e11a71cfb6685d2c9327fea2f80f1b", Rule.TRANSFORM),
        Map.entry("54987e7ab20695ea52272a9fd77304b3c4aaffa7cdf7f6a665aef7608bcc29eb", Rule.CARRIER),
        Map.entry("31c8036a93bd6b2e5f2ff43535efea8807bf92de9cbeb3ba9bd8e24337f24fc0", Rule.CARRIER)
    );

    // Exact embedded sources passing the typed first-pair projection proof.
    private static final Set<String> POINTWISE_EMBEDDED = Set.of(
        "04faf59d1f20ca4635c6d49432b4e1f3268035e3a35b1c3c7cfba781902a567a",
        "078cdebead1385fb92feff396e78f4c0a072ea7e770adaf9f1c89e4feb1a867a",
        "0edc2d24675182b92e452ea79c3b69382c984574e27780812f77f810d4f8c6bc",
        "14ac73cad4c3b29e665ba0d5f90002b84d90a6fea275e22810834b3c1e7edcc9",
        "1aeb5ba2b574bd909c0fc0579747a79531b91dc3891d945c41ea5e40e449f12e",
        "1bc95ed6ac1a8ce85bd4895987d2247f075f3ccb57ece3fbd5416a5196302fd1",
        "2371fcdef2f13f0eb201dbe5e58ed0714cc84739f0b4c77d7e5367fe8b0eb13a",
        "256ec3df55fe8fbea69d106e34c03250ea87b73cd29574222593bbfee289732d",
        "2789a872f998e203a980fa5e31266687c4a6629dbf9fcaa49553a7b4910265c3",
        "2adee2b7632f87670b6ec13837e3d935bbddc92c4ab32a5595809c2a79e29d94",
        "2dbabde8e79c906b586cf0f174f09288a57988af8c84c4cf054c1a39e4744dbf",
        "33c0afcea48c37374eb0338a0d871b59fcf59be3bf9c01862610dbcf8815231b",
        "35004d3c35a2803ca28eb2aebbf15c130d12008d6592c714c80b08f4feb043d1",
        "3a61b0cde0e98c238e13845db87a3dfef190abb7f8574f3faa3f1a06596c6858",
        "57f3808d9ee4d7fd58fadd3bf5b62ed31ed6a2180d135430864b391b78690be7",
        "655b40f4c9dfee687dbf74ff2b579ecd07d40de97a1e46ca0b9d98871d846e2a",
        "6c979d46689f9010ace6b1047c677734bae29a84acbb96fe67c7bca30160e929",
        "75038473a9a1126058fd28cfd0af7c7bf821651152667e1328e0c083a8d38e1f",
        "762413f9d0fc634f8666e71e19093e454a298ffad6916d593161ffb7e48296dd",
        "78a23bb5db1f7c27100e2a4e3555a11b214db20faf99df1106eca9a6a13d6975",
        "82874215e33aebdf82b93b6c1b058b94936a181b764b854179a7a980b011ebe5",
        "8508e8783724639d4a2babfc61739239e8bf8eab1f5e6889961c2ce736343b0c",
        "85de1413857e62af8c5dc82476cbc2a99af0b169b5e3ef281a3c461567686bfb",
        "85e09dfc6536571101876808407e58287e6e567fafc0732c2c3061d862aaf500",
        "8795a12b079b5ce250f293656962db1fc3293a042c9b529c503e98b171296858",
        "a1d3c7d6129e6fe62f166361622d46f1569207898302d5be50df41f0086caf81",
        "a481ec31676df245ad0b4cfd05132a2fcac171749e3a0dd926bfc8c7383f342d",
        "c9d03b4902ee618d3428795a5c7c72a811d25c59345fc63105bd635ae9a0cf7c",
        "cd621b00676a80d9726eb8ef636de9886de9e0b34585b1d7ec2e0ba52e5e8c39",
        "cf3cc73aab7481f2b1da75c795e38c97e060f7559e629c53735a1ae4167162ca",
        "d50941480c550f0c3e3c5b42d0a44925f051460b3b1224158ca9b4c090f822ff",
        "eae00669b1560819027bab1c14b4af9673b160447f4559976d722371efb62664",
        "f26426cd0055f591728b18d6f3c53017c6b8e46c727e94e387c4a7aaa9af6f2b",
        "f55ab7eb26c584916a2981ab7ad8758329f9e4663812e6b7ff07e172b169c946"
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
                if (hash == null) yield null;
                yield POINTWISE_EMBEDDED.contains(hash) ? Rule.CARRIER : EMBEDDED.get(hash);
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
