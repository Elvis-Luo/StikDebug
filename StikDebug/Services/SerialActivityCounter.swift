//
//  SerialActivityCounter.swift
//  StikDebug
//

import Foundation

/// A reference count whose work runs asynchronously on its own serial queue, so a caller never waits for it.
/// `onChange` runs on the queue with the new count after every increment and decrement, in the order they were made.
final class SerialActivityCounter {
    let queue: DispatchQueue
    private var count = 0
    private let onChange: (Int) -> Void

    init(queue: DispatchQueue, onChange: @escaping (Int) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    func increment() {
        queue.async {
            self.count += 1
            self.onChange(self.count)
        }
    }

    func decrement() {
        queue.async {
            self.count = max(self.count - 1, 0)
            self.onChange(self.count)
        }
    }

    /// The count, read on the queue (from `onChange` or other work already on it).
    var valueOnQueue: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return count
    }
}
