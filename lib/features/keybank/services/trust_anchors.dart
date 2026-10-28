import 'package:flutter/foundation.dart';

/// The authorities whose member certificates this build accepts — the one
/// thing the key bank hardcodes (design decision, 1405/07/05: only the
/// authority's **public** key; nothing secret is ever built into the app).
///
/// An authority public key is ML-DSA-65 + Ed25519, 1985 bytes, printed as hex
/// by `hamresan-keybank public <authority.hka>` (`tools/keybank/`). Knowing
/// it lets the app *check* a signature, never make one, so it is safe in an
/// APK anyone can unpack.
class TrustAnchors {
  TrustAnchors._();

  /// The production authorities. The authority was created anew on
  /// 1405/07/29 (id `7fda025a5a997b93`), when key files stopped carrying any
  /// list of members; its private file and password are kept **off the
  /// repository**, with the authority holder. Another authority is added as one more
  /// hex string. See `docs/architecture/editions.md`.
  static const List<String> _production = [
    // 7fda025a5a997b93
    '01f5151a09eff1fb6bd6b4d7f20fcfc4bed7d3a014e29d4106b7f35be59c5a89'
        'd271f91c99022a56d86d259d161fb75e32485cbc5d10e2bdfafeae5f629f6917'
        '4790f26181586c800f112bebecc28e2114092cbf975d48001a390a01bfe1ea81'
        'c27fe8fa7d42ca6c4692519622c55ce8a06e8c809bffae245fcdacc4214ef0b3'
        '4e22820e652919746761d82e2c61f86d8c64ac6c38fff322f2a5e5987a74232b'
        '054a60e1b84d6db87e73e72d5ab54f35e7524b34c7e9e0dc2ba95b14186d5131'
        '5506859a9bc7cf9d0ed43136dd12fac4e71c4d36fc8092b77a05661fdcfb4e62'
        '4e8e357e50055c0482a55194a8900d2fb57d329c400445e5285b623ad434e9b4'
        'a57e475e5adc37a2dc2951c74fce93bc68c2e811e39d7216baae80a04e9e6b42'
        'd8984b747a1e0189e740d4b7c8fd0773e82aff624720b57460d078cfcfce07dc'
        '97b7c0eb733b53be029fb7a11f04d1b203a67e5e29c74ab569e7d2f125cba7c3'
        '213c45a44bb3be5957299934246cd794b3e7133fef329bd277e2d7628e613371'
        '37c5f99cebfc9c10f57dde45d6087e9c87e68834131756391089491267a5e485'
        '9848180c5f3653038550b11dfbe114329d4d75d2390fedf78b2559d2ec076410'
        'da327d5826b3b3e7ece3e44aed5b7d14e67a4a95704375ae4f00360206ba41d1'
        'df1bdb7becec9f3d9f7b1bc77044ffd352133b31c85472d1c61551449c65db64'
        '8983620ac52ee7f462f1d7c86b8df9bc2e1e1b55a5c241642af0eb8cb551388c'
        '9450b3c81c70506aca094c6aaa1d32aaaa6c69bcba10b7b78eb21afc4f055492'
        '7720cafa26e719ddc66bfb28a4f2a453f1894b2c36c337bebd61672f7af5e194'
        'bfcbcb6cde9261b751a78d5f5ae77a85cec9cfb96533f822d5db8d9bcccb089a'
        'cbca04e20bf9ca90a8a4879c084ed7dc5c3c11951dc824a05a5059647a27dcbe'
        'df5aa09d7e01067a57ef3921b8233caa6286456a34776e300dc84b41d86930c5'
        'f157eb3a7017d85782177c79ad0046bde59f35933b019bbcbdaeadeaab756889'
        '582d7ca81986726d46fdf97e98ba5ee7a935cdaf4a3859195e7a57ba25d3ab61'
        'c48f69aa8c397b99d83fb85fb85b8ce6f72b87a18f13b8d861fb3d5a2f632a05'
        'df2f1aad92d4bde90f561a7f672234d04eb4f6abb3135af0f0d2c1830df5deda'
        'c95888eb2689003f521b4603b6ed1051a1507c807a923b06540834221632e606'
        'f878eaf57b58d209651080a179de26aa07ac1f4ff41eecda5b5ad5966ecb1465'
        '9b6cf178345997c983236b5a4a7e3807c0d9c0ebeca3faad75a408be9a470956'
        '937e75687c16ccf04d9d384fbe3dcda77c0552f3c71f15af7fe8f7932ff9b95c'
        '484ca8fa83f1318a8f85b358fb01c1be7072ed91a3ea94a481cde855c41b230f'
        '7da675d1fbbef3abfdafe4f3df6537fb65a25ec8acab7040350c64a681389c62'
        '0605f7bcb76ca0b99a92d62700170860a52985b20e73245d0103f962a4358ace'
        '65b5d95eee75b10d3bf9c9064045986feaf24d34af03806fded61c25f899352a'
        'b028a583fc855bfdb7d51cca6ea7779ff5e4af33538e91b4c87366e849a1f302'
        '9101a44528e3b3e2ca3f49919b9e5698c889bdcdbb447487fb3d09f5ff999386'
        'e9ca06da1b910a4931db9ffc7ec4df11231062c14a824c4eeddd921d0012ea63'
        'c3b6b220a1e22d46f1791b53f866858c05686d81d87591518bb351bcfe1da3fe'
        '0f379b90d37a10d991cab5a5a9916cd521bd0c3646d478fba3130359dd876a62'
        '1263ad67759c0a9b0977e2f06d0fd199e47110a81741f5f3926e7882d5b927a2'
        'e606225efb71ac55250ac88338b6dec871ead0767b0ffac9e29e85c82da674dd'
        '0537d96db3716b9de02bb61c496646abcd50254a329d7424d467ce7ca993459e'
        '82a6e10b2defc03f805ab72707466519e90b340ffba3bc1a3d7a03c891652c7b'
        '56d226efb16547a7204f9c92891ad48ddced46dace21cfe67a16681ebfbb376e'
        'cdf720563611bef90bd853324ad0d25a89f981963cde324c0ef1d3cf3ba069b7'
        '7ee5cdde544c2be2fa15f523afcc8281502e54b27246fdbc1a8bc4feec6399ab'
        'bf498bf39459067545d01b87e88fa14bf87aa79dd4640b3f3a817cf387eff22e'
        'a1b238c289dde19ff2fc078396fc4be78bab3593108146fec55bc44b1bc48933'
        'c512c5bdb44ca325460e5c56042912f3881a93c62233b8dac858eef51c60b533'
        '8cee9334a6aeb9ee1414e5f214415a048432d4f14eb7e3721842a2cc7a7afd37'
        '9a1ab54c9f74753828dde1ee6cddbd9d69334ba55ae3732bb07c8b1c3dc7b617'
        'd571979b0ce9bfbdb17d28cbe45f54e9121f405b33164f4bc0cc2917790d1692'
        '4fd4df34a1c6d894a39271444e26385b9620a71851c7eff9d803c77e5d7a8a7a'
        '4c6106c4fbf1e104ea6a38c6201a28387d3cf8292a815fc0eb6798f9cc34754b'
        '79a5fd46f2f215f960e8f5b161ed03c133f5d8c73bf150630d0552144292c212'
        '87ad8e7834bd4093e4b45048ad03eec9d0b3360f7a58d9a0b353c818c4707321'
        '4d3fd8c912da1300458341c27e2c625387b81760c666d3679043bc23cd0fda39'
        '35225e3fe1e9d81bd2ea43774ca473d1873f0dbb84de844124003e0b09319737'
        '79e32128cacd862eacb37364c3e3512c5ec36c9fa31716e16d5fc44599b731a4'
        'b6c67df638a3ea85b9a60677167f1af10a1760beccf67749b97ccb22cae16811'
        'c7baf4e339d3e61d34fa1ba09d65c8ae81d3e531897b630f223e29b5ee3fbffd'
        '3359b255623b5c0dfea13510a762ee54c2cc1b322e6125b757ae0935f5674632'
        '47',
  ];

  /// The development authority (its private file lives only in the
  /// gitignored `tools/keybank/dev/`). Compiled in **only** with
  /// `--dart-define=HAMRESAN_DEV_ANCHOR=true`; the release scripts never pass
  /// it, so a store or organization build cannot trust it.
  static const bool _allowDevelopment = bool.fromEnvironment(
    'HAMRESAN_DEV_ANCHOR',
  );

  static const String _development =
      '01261554df90d515d1e144db9389b7bd3167875e6c4ff21115e88b3c1fecb8b1'
      'e5692f84557e1af29c77ffa90501b5e1ecddef1714d28cfa3eb0fa306ab6fe5d'
      'f0355c4ef55989ff6be00415de8c6428c321f7c7006c87074b1771dad3b66b9d'
      '8ec7c4a09e989b9ee9943884fb8debdac1060c6b92164f83d382f84a33616e46'
      'c4b3d1c7b8fc46f54f7d68ac518313e9794090076a7f3dc4d3ed6d0fbeec9054'
      '7d99c11fe7ba5b3a6b4af7e49e658172b9f4cf226a9dc30dabf2f20299a13fd2'
      '720bd05b7aff13ae0fcb4c96b4ca02ba01213af541007eba2bab72430809929d'
      '12c7aa0b6c3e6da3a8922601669b89a6aba0df1794fb2976ae1698e6062386a5'
      '8d24e80f6d3772d2dd11703a94fc2e01763b616574e35280457790caf84bb38b'
      'c952060b879ebac4621fb51db39e611af752fdca8e582260f0ed1d468008c25d'
      '29bf304dd8c8af2a74a0ba1c116ee10bf98fa2d48ba82ecbc7e9029c7b89a16e'
      '21c200012fecc175ae3d7a60af1453e837140669f7523acc5c2ee50e55a4d784'
      'd7daaab5c73c64ecde20534ccb092e86f97d6ac6d3f12389ec84ca43c4dfa36b'
      'c870a75bfcb9fdcc08d624045770deb9f41d29ce4014836433efa32a3895a3fb'
      '4886e3dc061a2b27840b3de4a559bbd0fe3cb8e6e67163919c2d35e6ddd5d018'
      '188d2923d96e39919513b75ef2e9cf113cb78b18defe8f39021a383e89235c9d'
      '05d5b32274cb7609e15226278f521112cb71652be0f9e826309442be01a0c05b'
      '5d857166819a22604d6c7a4024b1f6234e01f237d9482dd36452461eefed4736'
      '4037d170cc23d71543f01bac100a9c13e0ade98f594584cf161e11c010c058e4'
      '19b63f255039446e87853ca481818619b75f65b5edd71cf227bf531d77bd313a'
      'b60bfdac54144692130b88e6f4d3d4955ad025a17579727ea829fa8102347fdb'
      'b79803f17757a45f29ad5f72e0302566b5bb5bb5b7c001bbc53296d5e5e29bfc'
      '5aac0c30f653c02d26e05354aa599c78d7bfed134d99b81a654aea7ea2737daf'
      'eae490cef4bf5111322398bbe25b1457f939ed0283278dfc12bce2dd5a8ecfd7'
      '8ece0493b01a7b54c714b2bb9fe529ca06bb133a646359b8784a0c3f8cc76553'
      '4bdcc56537bbde18e09baa78b70c17169b9be6d599b9518f3e7b1f3661ba088c'
      '1ba838f6ae223d48a06e5709637518f7b2b5dd18d5d93dbb5198b6a2aae695c9'
      'f6fe671f8de966218d7fd7d47d34d8a1efbba9dbca4d78e8a6a83a3e740ccc05'
      '9a0dc32eb1e36195edb2b584f8bc861ff404456e4395931de5051916a546737e'
      '96523ec3d34d7cca3dada7ed814a9e4aecfb16c8dcc7303bc175b20046817078'
      '956bf6a2b8e2d4245af0cbde29b45340fe4736d189589032ece060bdb161f05a'
      '237da5a9f7df5ed309826cbcb224970102ecd5198dda04fda01e89d215abedeb'
      '5a492712d53f619e2469bac9de6103d45a40081f114ba3cbba83fcef63254074'
      '3621cc55bef093a69b8b5effc4a4820a05e5238a80dc72af8005b28570d44d48'
      'f3f9c5c5390de7cbbc4e41a4df6c860d090aba971f9c1d1c048e2938adaea34a'
      'aa2b692779984788c8f605e1dee07907dee2ec080b4c1cb44a4679d2e1fe7d8d'
      '4ce86af36174b3440aaffd2d8debd107d0c5eb781caea9d1326a17844c31fbe5'
      '962339e7ab07765ff6bc43f9a1f341da7448fcdfd3a342ccfe6dda73b1e2a677'
      'b78b2c1072c3bb102d188b89eb2b4f6e4089a5380bfecbea5b70934ee8ef9bb5'
      '92623d4f81f61d6b12fca850ba42b2a58c33ec5ca8a650cb0e0981471c3e25c0'
      '53169d6279a5d80cca0e5ed98aa6c565b593b4169ef13b66a1f38127d8520125'
      '2ab23f6bd05bca69e27f2768d6ba68c391746ca4f8555d138e2f9f251ce5fbc5'
      '7d46b65294c37e2b8394aa33593d69a2f21fecfc7e53851a9d3504a38064494d'
      'a073172165e013b79f502768c5ceb13acea99d3e4881353e99c39339ae7464f6'
      'b92986169414497251ce7356bcdf881d69e6f7f078ef149575ad5c463a8648fb'
      'dd57f75192ddfd768b8891659e3c8a4c01761439dea1788a6e19d5e5c4191a08'
      '71892cb5cf716a23d701ba80e6a1253c8f4b5a47e4268f40003688fe86d1226f'
      'f40b39f83533dcde83afb2bf6198bba963d466fbb2f6712feb26a5ae3a4ce6b3'
      '85ef800b70ddb962b4ac0e4ef01c69353490185da0ae73312457d810305da1ee'
      '4437c3ff7e33377881e0f3cce78a1605194fdef16e26d13db7eac69456e1c018'
      '71bfa01a4da8296a7e930a7e0e7b317729bdc9cb3066d29d346e469d3bf6b487'
      '160d01e2f96fed5d6ebeb7fc5210715c7f6c200c1c15fc16cc4a7e510afa7436'
      '1c7426c4316ecd2114337477fe2be94406d5d2921bca3060f74dc3464f134c54'
      '1dd0726145295206d9631dcbd342088ecbdaa4922a1af4fae36d320a419ea11a'
      '6f384cf92c8d9e79caea57fa7a123270260a22bee3cfd24e9c7ee4d1cbf54c1b'
      'd233cd890a064ebba24fa6f3fb8ee9b0f1d5223b4ca8c00969b6e97a590c12dd'
      'a0198a539da89dde778d511bcf6695124c415c737ac2fc583eb2ffb988f93585'
      '236c49a4a86799a55cf1b87f51103fc4232fd6fc6d9277c7751284f0848e7c0b'
      'bd192bef8c7ef9d5cb98462206423413cddb380421ec55cb7cdcb4d6a197541f'
      'abb74ca2641a33828b904fa7c058f684d45d2078bbecf4ac5a15ee6db3b691c3'
      '606e6615e4b724560a07ccca860e2a872acfbc1e5e0de9e6449afcaf912a56a1'
      '92b7dbd6cdbb3c0372fa295787ffe13a6866613eef153bd2558826651fd851f5'
      '5c';

  /// Every trusted authority public key, as bytes.
  static List<Uint8List> get all => [
    for (final hex in _production) _bytes(hex),
    if (_allowDevelopment) _bytes(_development),
  ];

  /// Whether this build trusts the development authority (shown in the key
  /// bank screen, so a test build can never pass for a real one).
  static bool get includesDevelopment => _allowDevelopment;

  static Uint8List _bytes(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
    }
    return out;
  }
}
