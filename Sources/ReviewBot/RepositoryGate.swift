import Foundation

/// A FIFO mutex keyed by repository slug: one holder at a time per key, while
/// different keys never wait on each other.
///
/// Reviews of different pull requests run concurrently, but the ones from the same
/// repository share a single clone. Two `git fetch`es — or a `worktree add` racing a
/// `worktree remove` — contend for the same ref and index locks inside that one
/// `.git`, and the loser fails with "cannot lock ref" or "unable to create
/// index.lock". That failure is spurious, but nothing downstream can tell: it counts
/// against the request's failure budget and backs the review off. Serializing just
/// the git steps costs seconds; the reviewer CLIs, where a review actually spends its
/// 900 seconds, still overlap freely.
actor RepositoryGate {
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Suspends until `key` is free, then takes it. Every caller must pair this with
    /// exactly one `release` — including on the error path, or the rest of the
    /// repository's reviews wait forever.
    func acquire(_ key: String) async {
        guard held.contains(key) else {
            held.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiting[key, default: []].append(continuation)
        }
    }

    /// Hands `key` to the longest-waiting caller, or frees it when nobody is queued.
    func release(_ key: String) {
        guard var queue = waiting[key], !queue.isEmpty else {
            held.remove(key)
            return
        }
        // Ownership passes straight to the waiter, so the key stays held — releasing
        // it first would let a newcomer jump the queue.
        let next = queue.removeFirst()
        waiting[key] = queue.isEmpty ? nil : queue
        next.resume()
    }
}
