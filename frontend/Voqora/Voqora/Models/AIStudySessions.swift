import Foundation

nonisolated struct QuizSession: Equatable, Sendable {
    let questions: [AIQuizQuestion]
    private(set) var answers: [Int: Int] = [:]

    init(questions: [AIQuizQuestion]) {
        self.questions = questions.filter(\.isWellFormed)
    }

    var answeredCount: Int {
        answers.count
    }

    var score: Int {
        answers.filter { questions[$0.key].answerIndex == $0.value }.count
    }

    var isComplete: Bool {
        !questions.isEmpty && answers.count == questions.count
    }

    func choice(for index: Int) -> Int? {
        answers[index]
    }

    func isCorrect(_ index: Int) -> Bool? {
        guard let choice = answers[index], questions.indices.contains(index) else { return nil }
        return questions[index].answerIndex == choice
    }

    mutating func select(_ choice: Int, for index: Int) {
        guard questions.indices.contains(index),
              questions[index].choices.indices.contains(choice),
              answers[index] == nil
        else { return }
        answers[index] = choice
    }

    mutating func restart() {
        answers = [:]
    }
}

nonisolated struct FlashcardSession: Equatable, Sendable {
    let cards: [AIFlashcard]
    private(set) var index = 0
    private(set) var isFlipped = false
    private(set) var known: Set<Int> = []

    init(cards: [AIFlashcard]) {
        self.cards = cards.filter { !$0.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var current: AIFlashcard? {
        cards.indices.contains(index) ? cards[index] : nil
    }

    var canGoBack: Bool {
        index > 0
    }

    var canGoForward: Bool {
        index + 1 < cards.count
    }

    var isCurrentKnown: Bool {
        known.contains(index)
    }

    var knownCount: Int {
        known.count
    }

    var isComplete: Bool {
        !cards.isEmpty && known.count == cards.count
    }

    mutating func flip() {
        guard current != nil else { return }
        isFlipped.toggle()
    }

    mutating func next() {
        guard canGoForward else { return }
        index += 1
        isFlipped = false
    }

    mutating func previous() {
        guard canGoBack else { return }
        index -= 1
        isFlipped = false
    }

    mutating func toggleKnown() {
        guard current != nil else { return }
        if known.contains(index) {
            known.remove(index)
        } else {
            known.insert(index)
            nextUnknown()
        }
    }

    mutating func restart() {
        index = 0
        isFlipped = false
        known = []
    }

    private mutating func nextUnknown() {
        guard let target = ((index + 1) ..< cards.count).first(where: { !known.contains($0) }) else { return }
        index = target
        isFlipped = false
    }
}
