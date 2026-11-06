import 'package:communication_super_app/features/keybank/services/trust_anchors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every trusted authority has its sealed signer, in the same order', () {
    expect(TrustAnchors.all, isNotEmpty);
    expect(TrustAnchors.signers, hasLength(TrustAnchors.all.length));
    for (final anchor in TrustAnchors.all) {
      expect(anchor, hasLength(1985));
    }
    for (final signer in TrustAnchors.signers) {
      expect(signer, hasLength(48));
    }
  });
}
