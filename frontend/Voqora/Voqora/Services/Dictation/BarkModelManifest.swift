import Foundation

nonisolated struct BarkModelFile: Equatable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

nonisolated enum BarkModelManifest {
    static let repository = "FluidInference/bark-3.0-coreml"
    static let revision = "73b0c0da665d29ea0332e9f0d32da8e26a4cdb38"

    static let bark: [BarkModelFile] = [
        BarkModelFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "6845726bb7bb79b418c1e0019af13eca816ad7a6e3bd8eace241ae63197712c2"),
        BarkModelFile(path: "Decoder.mlmodelc/coremldata.bin", size: 563, sha256: "28a03db82d95bc2c5a48a6c446942ec43452b45d505a77485e5e02b55c3c46dc"),
        BarkModelFile(path: "Decoder.mlmodelc/metadata.json", size: 3427, sha256: "46e72efe6cf0ea73d6a0ca108c71bc398080f1534b43e8f490509353124c6e3a"),
        BarkModelFile(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "34bd2cc0a00dd7a485f0aa90f58d6b516c94ee8f4842de92aad7b581849df289"),
        BarkModelFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "e2331b87b4f9db9f0eff71eae05df427a19d47402882d52ca8eadf1c856040cf"),
        BarkModelFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "03ea5a53546d8685994980f95dba47b2b5d6e80c847515a8b1e8231ab975d233"),
        BarkModelFile(path: "Encoder.mlmodelc/coremldata.bin", size: 557, sha256: "b84bc0a623f0615306c6419592e0702fa023f36783e16ebd77f67b9fc5d9dd0a"),
        BarkModelFile(path: "Encoder.mlmodelc/model.mil", size: 1_012_888, sha256: "a8030e936a37ef01c76de2cd75e45a94c0100cf45332c5bb16d59cf4842890ee"),
        BarkModelFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 398_467_968, sha256: "d0c050671b447917966d4c01ef4a5ccef671115735d9b298b6ec965caa681c27"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8b527affb76296ea13a810f12cb73c4e6303dca68f3830dd28f8c3d60fe22987"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 595, sha256: "1e80f5a625d6df5b41d174bf2837b442d51382532bfd32995dbb1919afd9bfa1"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3571, sha256: "f65d46443115eae860de6334a184cdce83318e126a8961b17d78c33e382b5c72"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/model.mil", size: 11777, sha256: "167357ff6d558349e745047c6e3f610010d047ec21ab6f56df2dbb041f096baa"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "aab5aacdd31dc5644ab3f000f38bc8d94e30d50da585ba49165fa5872a53152a"),
        BarkModelFile(path: "NOTICE", size: 603, sha256: "7760825e72004ccf97f7a8b63a75e2890105a7cae8ca875b70d4df78cff9abcd"),
        BarkModelFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        BarkModelFile(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        BarkModelFile(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        BarkModelFile(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        BarkModelFile(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        BarkModelFile(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    static let barkClean: [BarkModelFile] = [
        BarkModelFile(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "d00e8baa4b1d7fc164d7cbbb96ed294d531ba6fb684a1aa79f66d4e4fbdbd5da"),
        BarkModelFile(path: "Decoder.mlmodelc/coremldata.bin", size: 569, sha256: "b33a57a008e7b138574bac1219037aadd7054caebfc42d0fa4adc97050f6a836"),
        BarkModelFile(path: "Decoder.mlmodelc/metadata.json", size: 3433, sha256: "de3e22da7619f1ba9ae8ab3676ece49a999b93b3ca2a6653687c54b0e69419fc"),
        BarkModelFile(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "34bd2cc0a00dd7a485f0aa90f58d6b516c94ee8f4842de92aad7b581849df289"),
        BarkModelFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "6220cd08cb7eaacf5106da134c40f57e13783342c09f1be250dd31cc1b8b8a94"),
        BarkModelFile(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8f6763508e0d6caad8152bcc72cf8be1647f568c3cdc5c5ff9732c1c69e2734c"),
        BarkModelFile(path: "Encoder.mlmodelc/coremldata.bin", size: 557, sha256: "e08f511d23e5642bc45f6ecc0bc930e00f8f105d6a6c33fe03f83c8da9253070"),
        BarkModelFile(path: "Encoder.mlmodelc/model.mil", size: 1_012_893, sha256: "0442825ac24b17cd861db7a8bda7cda16c3372c8228331e640196965f190583d"),
        BarkModelFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 409_451_136, sha256: "4216107d2214bd058aec94c2e0f9a7e8114f5274cf0c6a28ffb8f21ea56337eb"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "a55f011ca119fc7913ffc905ef48079572c4f54b6e5ed34a033f69c5422be0b6"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 601, sha256: "2f5d97969689b6397b8f2e8ba31a1d4684a41ec373ecf56d4ee751efb2ca5073"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3577, sha256: "989223d0134de212bb206b7311b9f7038d26f86d0d43a88b17deee895d0a931e"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/model.mil", size: 11777, sha256: "167357ff6d558349e745047c6e3f610010d047ec21ab6f56df2dbb041f096baa"),
        BarkModelFile(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "4575e6ec06917259358cf17307fe7aa38d364b736e4b6c9b6e3d49169c760eee"),
        BarkModelFile(path: "NOTICE", size: 615, sha256: "4e627d41fa10efedd84a7dbb915711b0b73c904af1fee8bacdd4a2387bcc5a10"),
        BarkModelFile(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        BarkModelFile(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        BarkModelFile(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        BarkModelFile(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        BarkModelFile(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        BarkModelFile(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
    ]

    static func downloadURL(folder: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(folder)/\(path)")!
    }
}
