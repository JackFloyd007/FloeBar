import Foundation

@main
enum DeferredPresentationTests {
    @MainActor static func main() async {
        let presentation = DeferredPresentation()
        var first: CheckedContinuation<Void, Never>?
        var second: CheckedContinuation<Void, Never>?
        var visible = [Int]()
        presentation.show(after: { await withCheckedContinuation { first = $0 } }, present: { visible.append(1) })
        while first == nil { await Task.yield() }
        precondition(presentation.isPending)
        presentation.cancel()
        precondition(!presentation.isPending)
        presentation.show(after: { await withCheckedContinuation { second = $0 } }, present: { visible.append(2) })
        while second == nil { await Task.yield() }
        first?.resume()
        for _ in 0..<20 { await Task.yield() }
        precondition(visible.isEmpty && presentation.isPending, "late old work cannot present or clear the new request")
        second?.resume()
        while presentation.isPending { await Task.yield() }
        precondition(visible == [2])
        presentation.show(after: {}, present: { visible.append(3) })
        presentation.cancel()
        for _ in 0..<20 { await Task.yield() }
        precondition(visible == [2], "immediate close must suppress presentation")
        print("PASS: deferred presentation close, replacement, late completion and successful display")
    }
}
