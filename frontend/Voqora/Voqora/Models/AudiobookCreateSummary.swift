import Foundation

struct AudiobookCreateNotice: Hashable {
    let icon: String
    let text: String
}

enum AudiobookCreateSummary {
    static func isStartDisabled(
        startingProcessing: Bool,
        isImageOnly: Bool,
        useCleanup: Bool,
        hasProvider: Bool,
        providerReadsImages: Bool? = nil
    ) -> Bool {
        if startingProcessing {
            return true
        }
        if isImageOnly, !useCleanup {
            return true
        }
        if isImageOnly, useCleanup, providerReadsImages == false {
            return true
        }
        if useCleanup, !hasProvider {
            return true
        }
        return false
    }

    static func notices(
        for estimate: AudiobookEstimateResponse,
        useCleanup: Bool,
        hasProvider: Bool,
        providerName: String,
        isWebPage: Bool
    ) -> [AudiobookCreateNotice] {
        var notices: [AudiobookCreateNotice] = []
        if useCleanup, estimate.costWarning {
            notices.append(AudiobookCreateNotice(
                icon: "dollarsign.circle.fill",
                text: "\(providerName)'s conservative cost envelope is \(formatCost(estimate.maximumCostUsd ?? estimate.estimatedCostUsd)). " +
                    "The shown estimate may be lower; Voqora will not silently switch to a more expensive tier."
            ))
        }
        if useCleanup, estimate.pricingKnown == false {
            notices.append(AudiobookCreateNotice(
                icon: "dollarsign.circle.fill",
                text: "Voqora has no published rate for \(estimate.llmModel ?? "this model"), so it budgets the book at a conservative rate."
            ))
        }
        if estimate.isImageOnly, hasProvider, estimate.readsImages == false {
            notices.append(AudiobookCreateNotice(
                icon: "doc.viewfinder",
                text: "\(estimate.llmModel ?? providerName) can't read scanned pages. Choose another provider."
            ))
        }
        if estimate.isImageOnly, hasProvider, estimate.readsImages == nil {
            notices.append(AudiobookCreateNotice(
                icon: "doc.viewfinder",
                text: "Voqora can't tell whether \(estimate.llmModel ?? providerName) reads scanned pages."
            ))
        }
        if estimate.isImageOnly, !useCleanup, estimate.readsImages != false {
            notices.append(AudiobookCreateNotice(icon: "doc.viewfinder", text: "This scanned PDF needs AI cleanup to read its text."))
        }
        if let duplicateTitle = estimate.duplicateOfTitle {
            let kind = isWebPage ? "page" : "file"
            notices.append(AudiobookCreateNotice(icon: "doc.on.doc.fill", text: "You already imported this exact \(kind) as \"\(duplicateTitle)\"."))
        }
        return notices
    }

    static func cleanupCostLabel(for estimate: AudiobookEstimateResponse, useCleanup: Bool) -> String {
        guard useCleanup else { return "Off" }
        if estimate.maximumCostUsd == 0 {
            return "Free"
        }
        return formatCost(estimate.estimatedCostUsd)
    }

    static func formatCost(_ usd: Double) -> String {
        if usd < 0.01 {
            return "< $0.01"
        }
        return String(format: "$%.2f", usd)
    }

    static func processingSeconds(for estimate: AudiobookEstimateResponse, voice: String) -> Double {
        ProcessingTimeEstimate.seconds(
            forVoice: voice,
            audioSeconds: estimate.estimatedAudioSeconds,
            baselineSeconds: estimate.estimatedProcessingSeconds
        )
    }

    static func approximate(_ seconds: Double) -> String {
        "~\(DurationFormatter.short(seconds))"
    }

    static func formattedCount(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func characterSummary(of text: String) -> String {
        let characters = text.count
        let words = text.split(whereSeparator: \.isWhitespace).count
        return "\(formattedCount(characters)) characters · \(formattedCount(words)) words"
    }
}
