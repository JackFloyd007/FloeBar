@main
enum NativeReorderVerificationTests {
    static func main() {
        typealias Section = NativeReorderVerification.Section<String>
        let hidden = Section(items: ["b", "a"], boundary: nil, side: .before)
        let untouched = Section(items: ["other"], boundary: "absent-handle", side: .before)
        let visible = Section(items: ["c", "d"], boundary: "ice", side: .after)
        let sections = [hidden, untouched, visible]
        precondition(NativeReorderVerification.evaluate(
            sections: sections, touched: ["a", "b"], live: ["b", "a", "ice", "c", "d"]
        ) == .converged, "normal same-row sorting cannot depend on a hidden or unrelated handle")
        precondition(NativeReorderVerification.evaluate(
            sections: sections, touched: ["a", "b"], live: ["a", "b", "ice", "c", "d"]
        ) == .needsMove("b"), "unchanged physical order is not successful sorting")
        precondition(NativeReorderVerification.evaluate(
            sections: sections, touched: ["a", "b"], live: ["b", "ice", "c", "d"]
        ) == .incomplete, "missing source is never treated as a completed drag")
        precondition(NativeReorderVerification.evaluate(
            sections: sections, touched: ["c", "d"], live: ["b", "a", "ice", "c", "d"]
        ) == .converged, "visible-only edits do not require any hidden handles")
        precondition(NativeReorderVerification.evaluate(
            sections: sections, touched: ["c"], live: ["b", "a", "c", "ice", "d"]
        ) == .needsMove("c"), "visible assignments still require the real FloeBar anchor")
        let privateSection = Section(items: ["a"], boundary: "handle", side: .before)
        precondition(NativeReorderVerification.evaluate(
            sections: [privateSection], touched: ["a"], live: ["a", "ice"]
        ) == .incomplete, "a requested physical experimental boundary cannot be omitted")
        precondition(NativeReorderVerification.evaluate(
            sections: [privateSection], touched: ["a"], live: ["a", "handle", "ice"]
        ) == .converged)
        let normalVisible = Section(items: ["figma", "buddy"], boundary: nil, side: .after)
        precondition(NativeReorderVerification.evaluate(
            sections: [normalVisible], touched: ["figma", "buddy"],
            live: ["figma", "buddy", "ice"], enforceSectionOrder: false
        ) == .converged, "saved Visible items may both be physically left of FloeBar")
        let normalHidden = Section(items: ["h2", "h1"], boundary: nil, side: .before)
        precondition(NativeReorderVerification.evaluate(
            sections: [normalHidden, normalVisible], touched: ["h1", "h2", "figma", "buddy"],
            live: ["figma", "h2", "buddy", "h1", "ice"], enforceSectionOrder: false
        ) == .converged, "normal queued edits in different rows do not impose global section order")
        precondition(NativeReorderVerification.evaluate(
            sections: [normalVisible], touched: ["figma", "buddy"],
            live: ["buddy", "figma", "ice"], enforceSectionOrder: false
        ) == .needsMove("figma"), "normal mode still rejects an unchanged real order")
        let normalUnified = Section(items: ["h", "v", "a"], boundary: nil, side: .after)
        precondition(NativeReorderVerification.evaluate(
            sections: [normalUnified], touched: ["h", "v", "a"], live: ["h", "v", "a", "ice"], enforceSectionOrder: false
        ) == .converged)
        precondition(NativeReorderVerification.evaluate(
            sections: [normalUnified], touched: ["h", "v", "a"], live: ["v", "h", "a", "ice"], enforceSectionOrder: false
        ) == .needsMove("h"), "normal one-row verification enforces cross-historical-section order")
        for ordered in [true, false] {
            for hits in [(false, true), (true, false), (false, false)] {
                do {
                    _ = try NativeReorderVerification.confirmedEndpointOrder(sourceHit: hits.0, targetHit: hits.1, alreadyOrdered: ordered)
                    preconditionFailure("retained/invisible endpoints cannot succeed, including ordinal no-op")
                } catch NativeReorderFailure.endpointUnavailable { } catch { preconditionFailure("wrong reason") }
            }
            precondition((try! NativeReorderVerification.confirmedEndpointOrder(sourceHit: true, targetHit: true, alreadyOrdered: ordered)) == ordered)
        }
        for hits in [(true, true), (false, true), (true, false), (false, false)] {
            for ownership in [(true, true), (false, true), (true, false), (false, false)] {
                var sourceChecks = 0
                var targetChecks = 0
                func sourceOwned() -> Bool { sourceChecks += 1; return ownership.0 }
                func targetOwned() -> Bool { targetChecks += 1; return ownership.1 }
                do {
                    _ = try NativeReorderVerification.confirmedEndpointOrder(sourceHit: hits.0, targetHit: hits.1, alreadyOrdered: false, sourceOwned: sourceOwned(), targetOwned: targetOwned())
                    precondition(hits.0 && hits.1)
                } catch let reason as NativeReorderFailure {
                    let expected: NativeReorderFailure = (!hits.0 && ownership.0) || (!hits.1 && ownership.1) ? .applicationHidden : .endpointUnavailable
                    precondition(reason == expected)
                } catch { preconditionFailure() }
                if hits.0 { precondition(sourceChecks == 0) }
                if hits.1 { precondition(targetChecks == 0) }
            }
        }
        var feedback = NativeReorderFeedbackState()
        feedback.begin(generation: 1)
        feedback.finishReadback(generation: 1, failure: .inputInterrupted)
        precondition(feedback.phase == .arranging, "cannot publish a failure before actual-order readback")
        feedback.beginReadback(generation: 1)
        precondition(feedback.phase == .readingActualOrder)
        feedback.begin(generation: 2)
        feedback.finishReadback(generation: 1, failure: .inputInterrupted)
        precondition(feedback.phase == .arranging, "new edit suppresses late failure for the superseded edit")
        feedback.beginReadback(generation: 2)
        feedback.finishReadback(generation: 2)
        precondition(feedback.phase == .confirmed)
        feedback.beginReadback(generation: 1)
        feedback.finishReadback(generation: 1, failure: .verificationUnconfirmed)
        precondition(feedback.phase == .confirmed, "older readback cannot replace a newer confirmed result")
        feedback.beginReadback(generation: 3)
        feedback.finishReadback(generation: 2)
        precondition(feedback.phase == .readingActualOrder, "cancelled backend waits for its own readback")
        feedback.finishReadback(generation: 3, failure: .modeChanged)
        precondition(feedback.phase == .stopped(.modeChanged))
        feedback.beginReadback(generation: 3)
        feedback.finishReadback(generation: 3, failure: .applicationHidden)
        precondition(feedback.phase == .stopped(.applicationHidden))
        feedback.begin(generation: 4)
        feedback.finishReadback(generation: 3, failure: .displayChanged)
        precondition(feedback.phase == .arranging)
        feedback.beginReadback(generation: 4)
        feedback.finishReadback(generation: 4, failure: .inputInterrupted, succeeded: false)
        precondition(feedback.phase == .readbackUnavailable(.inputInterrupted),
            "cancelled/unpublished scan cannot claim the actual order is shown or remain indefinitely busy")
        feedback.begin(generation: 5)
        feedback.finishReadback(generation: 4, failure: .inputInterrupted)
        precondition(feedback.phase == .arranging)
        feedback.beginReadback(generation: 5)
        feedback.finishReadback(generation: 5, failure: .endpointUnavailable)
        let obsoleteRecovery = feedback.beginOverflowExpansion(generation: 5)!
        precondition(feedback.phase == .expandingOverflow)
        precondition(feedback.phase == .expandingOverflow)
        feedback.begin(generation: 6)
        feedback.finishOverflowExpansion(generation: 5, token: obsoleteRecovery, succeeded: true)
        precondition(feedback.phase == .arranging, "late expansion cannot publish over a new edit")
        precondition(feedback.beginOverflowExpansion(generation: 6) == nil, "recovery cannot start while a reorder is active")
        feedback.beginReadback(generation: 6)
        feedback.finishReadback(generation: 6, failure: .endpointUnavailable)
        let failedRecovery = feedback.beginOverflowExpansion(generation: 6)!
        feedback.finishOverflowExpansion(generation: 6, token: failedRecovery, succeeded: false)
        precondition(feedback.phase == .overflowExpansionFailed)
        let closingRecovery = feedback.beginOverflowExpansion(generation: 6)!
        feedback.cancelOverflowExpansion(generation: 6)
        precondition(feedback.phase == .stopped(.endpointUnavailable), "closing Layout cannot leave a recovery spinner")
        let reopenedRecovery = feedback.beginOverflowExpansion(generation: 6)!
        feedback.cancelOverflowExpansion(generation: 6, token: closingRecovery)
        feedback.finishOverflowExpansion(generation: 6, token: closingRecovery, succeeded: true)
        precondition(feedback.phase == .expandingOverflow, "old close/reopen completion cannot replace new recovery")
        feedback.finishOverflowExpansion(generation: 6, token: reopenedRecovery, succeeded: true)
        precondition(feedback.phase == .overflowExpanded, "explicit recovery only prepares a fresh user edit")
        feedback.beginReadback(generation: 7)
        feedback.finishReadback(generation: 7, failure: .endpointUnavailable)
        let unavailableRecovery = feedback.beginOverflowExpansion(generation: 7)!
        feedback.finishOverflowExpansion(generation: 7, token: unavailableRecovery, succeeded: false)
        precondition(feedback.prepareOverflowFailureRefresh(generation: 7))
        precondition(feedback.phase == .idle, "refresh clears only the completed recovery failure")
        feedback.finishOverflowExpansion(generation: 7, token: unavailableRecovery, succeeded: true)
        precondition(feedback.phase == .idle, "old recovery completion cannot override a refreshed list")
        precondition(!feedback.prepareOverflowFailureRefresh(generation: 7))
        feedback.begin(generation: 8)
        precondition(!feedback.prepareOverflowFailureRefresh(generation: 7))
        precondition(!feedback.prepareOverflowFailureRefresh(generation: 8))
        feedback.cancelOverflowExpansion(generation: 7, token: unavailableRecovery)
        precondition(feedback.phase == .arranging, "stale refresh/recovery cannot erase a new user move")
        print("PASS: generation-isolated feedback requires completed current readback and suppresses obsolete outcomes")
        print("PASS: real-item reorder verification, unrelated boundary independence and required anchor protection")
    }
}
