import 'package:flutter/foundation.dart';

/// The authorities whose member certificates this build accepts, and what
/// «کد ۱۶ نویسه‌ای» needs to build a member's key in the app.
///
/// An authority public key is ML-DSA-65 + Ed25519, 1985 bytes, printed as hex
/// by `hamresan-keybank public <authority.hka>` (`tools/keybank/`). Knowing
/// it lets the app *check* a signature, never make one, so it is safe in an
/// APK anyone can unpack.
///
/// A sealed signer is the authority's Ed25519 seed under the organization's
/// unlock secret, 48 bytes, printed by `hamresan-keybank signer <authority.hka>`.
/// It opens only with a member's valid code and password (`MemberCode.kt`);
/// that it is here at all is a design decision (1405/08/15). See `editions.md`.
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

  /// [_production]'s sealed signers, in the same order.
  static const List<String> _productionSigners = [
    // 7fda025a5a997b93
    'dab8dd58541900b97394d022cfe776daa756b83cc93df32e36bdffdc75a3738f'
        'c1368211f4ceba1ff5b460ac57b60407',
  ];

  /// The development authority (its private file lives only in the
  /// gitignored `tools/keybank/dev/`). Compiled in **only** with
  /// `--dart-define=HAMRESAN_DEV_ANCHOR=true`; the release scripts never pass
  /// it, so a store or organization build cannot trust it.
  static const bool _allowDevelopment = bool.fromEnvironment(
    'HAMRESAN_DEV_ANCHOR',
  );

  static const String _development =
      '01be980e59c02307eeec126a63cf49dc4c777fbba9e02f1115a68091725b7d70'
      '912acad9b03cdae27eb0416552dbd645a6f3b4b860d561a73c6d73ea99c22633'
      'e8ee1bfb2361dd4bda5cd6dd27cb8420c2b45288c0d179ed5dd5e7897e41c8df'
      '84c916dc7c6ebececd7d23a851c2e296f9ecd78eaf942029537098218508bf6a'
      'a0cb413529fe8d1fa308b72fc22f4857a3282cb33ecab149967f8e79ac65406e'
      '826b62233fadffaec928bcaeac5b7c3bfb65e66ac8c3d884776fbbc7b143b1aa'
      'b0c3e76ed852b13ac86c3e6bde317b19e0f97178bc0637a0f7e3b39c28c66be8'
      'e966873d376bd399d2fee7a28a6538b2b731e7fe73e7bf70acce6050a2a08e38'
      '04df8093f08968d21fc5dd996d1d25c7580fa52a2a33bef9d817bd8504c8d188'
      'bd0dc84ab63c58a301dd56840ab7b4e39afcfa336891944956baece9ca43c9c5'
      '1cf900e2dc739255e66ef69b6c65168c007e0223bf0287395a7d79888a6f6c96'
      'd7055017b50e4c0c7dd90c635a3b955dad8717103a88f20f93b52eb0b9db5fb7'
      '6a42c90c4dab7c7d92ba47e86b06517d15a6ac186fe04e3bcd096744aaf94ada'
      '39aa28f0ac5481f0a51e0e52df68c3e8b7d2ab3dbdbce1ff96b2bcac35f03adf'
      'ac0b476db8d4642cb69af7d2b9d4a5952a511a05e07a924061076d4aabeab93a'
      '47d7a0d5ed38f2542bebb8b814679df261658b8060cfabc7e94d52427362c10d'
      '06451834ff66de701d994d64587c42c36b6a9ad58d20b37d1de1bc3af7d3694d'
      '94626e8d7fb0332147b957afe90b8cb8bd85918f0e57dffc648294082967ad4c'
      '7c614e38039297771c584a4240a7c23acfc34811ecc36a06c27a27edf9acf9b3'
      '660ce42f40b492d1d00c26df6ad268750acbc4b4bde8e0bb71eeaf99fb62a9b2'
      'e844cc5a7498869233b34ada24916caa4bec49b68c40dfe90622ce62f8df61d7'
      '91b5f824ef87404b4318576d48f9d5f1c5fe3ed828f460a65b1cf23f9e97a269'
      'e3eaa182d3b16a99f4947e01dca169329089f91a5582f273c0010f8185d7398c'
      '48d5a92d2b1940f16dc373cb7faa1879f22dcfc60e031319d5d9ad48f76390e4'
      '2012ea06b7956a1f906578b2467cd1b3b68092b5548daeaf4abd08361a97659f'
      'ef0c4017a87bdcb087b4470c7567896df6bf4ae63f0c26cb421f79769e91c9c8'
      '9a692e02d32659e1e0cbd26d94f187ee37f8c8f23803225c795fedf473cce798'
      'b91b3b68015d30915ea29cb1b03cef0d303afb610a09916bc0f68e9ca77be5ac'
      '9f67538b895e252c043abdfc8cbbbf5c49600ac5a73f382f2f36576115ec2851'
      '26dd8976c361a85d8001f2890b8675af91ae67141588b40c0f9a723a7807ce6e'
      '09e66affb38e21435dfd82d377ee5fe14d7d9dd6c22fd490d23756bec5fba975'
      '5eae77e044cec120e67f2a79eaea064c54b78b69afe8c84195045d653b035a7b'
      '89cd1b6616e4f0f74dc7a3b11376d8db2da59f8ed422794b2fd32c22c7d41c1f'
      'aef128c9372d7563c5c9585b1cb4766c0156630a7556df29a201d85bdc3ffba8'
      '9809625f763223145d803fb3a5b35d627665015a686df828138c068a0872c878'
      '267d5a99f321a796e13e4526e6dae7e67c654564202d2b9d1536d266331c9c1a'
      '0b5cf1a1ddc3fce50398c73f3300f1fdb5ae54f2b53e2a9961ffba3a7f857848'
      '770497253ef4ee843d8bb67dd64eb0e3c9a710ddff75c0107bccac858da2aa01'
      '78776638559500e89de1bf7baba08acfa4818321e73c2ad7f368aea1e59d5dfb'
      'a56e68094b7d77ec86e54dce941cf6eb3da4d7823a503c9269ef1c090460bc6d'
      '69e8186bc5139d4907bb5a03187ecb0d1d11bd619eceaa87a8e1a01553307d24'
      '9c3b7e01a65d061459ed46c163e10651c7141c88e47aac3c7baaf1ed45797842'
      'd529e757c934e270f5ce39d35d87f3a0cd8d5e361b4db2fa16e77f66cc21af12'
      'ba8767829c80bf29f869bc97793b11b323a7d2acb81c841689db86adc57ddacc'
      '728251f91bb810be8158f0124d1e598ae75e4bad5d3faffacf98e602feb92a05'
      '79b5eedb70fe1fe5c96cc34f91642ee9f589985bc1c3298b66ff304200b55586'
      'a86ada26af9fbe7ab6d007691c432bd590f4a2103d5923cdb381a19d9e3aa8f9'
      'efa970b3c4df23dcc1f767b28e6b98fb175968c024dcc29db2703c0675634237'
      '107e7fef74441e4e57353e3f75dd7541f82dded95df9d332164ed2c2a8320dcd'
      '855ed725fd5b0a710f2f746247f8c48bd2fa58225246ef9ae66bf4f9b2f390d4'
      'c42b9747c7ec364450368929fadec8af8abe60cce4e928a6410191c5b4d189c3'
      '53e1465431520f09f85d8572178768a9b7d05b481e4fb4b55a01a92e031f6119'
      '3d06cf3474df8a29353efff41e7aee2b5ff66f687dca81b939ce8017d7defd40'
      '091704a227582099d65177c04fc304803af4a06556ce3d281162e1ab1044c0e5'
      '57ad8d4269b8ebbf22e3a2982797b4d9c23ce2f0cb513b45f3d61db3f65a03de'
      '62994a0c88a70a07b29ff36d98e14a02d2aa152799edaaaa490a066bc403e6f9'
      '54bcf56331c2f2ffbc137c9e6750b40ff7a8b0f587fa5d54b83fc0d7792a7fa9'
      '5f6be154a7f8e09200ada659d149a2037aca5b228456b00cb4ebbecf64bb4e84'
      '64b4dd1e48679b19781d8d411059b0781762c7bfeeab603be4d98b0b94c7bd40'
      'd16dd6548937ca2ecaa560aa6da0ac4a1ec7fb6e200e97fd6db44b0bc7eec162'
      '818d9ee8bab50d74cf380a7855e70770ce59e379c7d43dedee9c62e294ad885d'
      '040c42ef0ca490af125beffd11320344a2afbba6b97e2b26720713d9540f8bab'
      '70';

  static const String _developmentSigner =
      'f4b70b6a23b9f16105010b7d8f329e90cb286fe874f1ec0c04c24b24ec47aaca'
      '3cfb6718b38861dc227b259892189caf';

  /// Every trusted authority public key, as bytes.
  static List<Uint8List> get all => [
    for (final hex in _production) _bytes(hex),
    if (_allowDevelopment) _bytes(_development),
  ];

  /// The sealed signer of each of [all], in the same order.
  static List<Uint8List> get signers => [
    for (final hex in _productionSigners) _bytes(hex),
    if (_allowDevelopment) _bytes(_developmentSigner),
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
