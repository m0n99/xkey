import Foundation

func concurrentReloadFailure() throws -> String? {
    let old = BrowserProfileEntry(name: "Old", bundleIdentifier: "example.browser", profile: .firefox)
    let new = BrowserProfileEntry(name: "New", bundleIdentifier: "example.browser", profile: .safari)
    let oldData = try JSONEncoder().encode([old])
    let newData = try JSONEncoder().encode([new])
    let firstReadEntered = DispatchSemaphore(value: 0)
    let releaseFirstRead = DispatchSemaphore(value: 0)
    let secondReadEntered = DispatchSemaphore(value: 0)
    let secondCallStarted = DispatchSemaphore(value: 0)
    let lookupFinished = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var reads = 0
    var lookupWasCorrect = false
    let registry = SharedBrowserRegistry(readData: {
        lock.lock()
        reads += 1
        let read = reads
        lock.unlock()
        if read == 1 {
            firstReadEntered.signal()
            _ = releaseFirstRead.wait(timeout: .now() + 5)
            return oldData
        }
        secondReadEntered.signal()
        return newData
    }, writeData: { _ in fatalError("Unexpected write") })

    // Always unblock the reader, including when an assertion fails.
    defer { releaseFirstRead.signal() }
    DispatchQueue.global().async {
        registry.reload()
        firstFinished.signal()
    }
    guard firstReadEntered.wait(timeout: .now() + 5) == .success else { return "first reload did not enter read" }

    DispatchQueue.global().async {
        let isChrome = registry.profile(for: "com.google.Chrome")?.kind == .chromium
        lock.lock()
        lookupWasCorrect = isChrome
        lock.unlock()
        lookupFinished.signal()
    }
    guard lookupFinished.wait(timeout: .now() + 1) == .success else { return "cached lookup blocked behind reload" }
    lock.lock()
    let lookupOK = lookupWasCorrect
    lock.unlock()
    guard lookupOK else { return "cached lookup returned an unexpected profile" }

    DispatchQueue.global().async {
        secondCallStarted.signal()
        registry.reload()
        secondFinished.signal()
    }
    guard secondCallStarted.wait(timeout: .now() + 5) == .success else { return "second reload did not start" }
    guard secondReadEntered.wait(timeout: .now() + .milliseconds(150)) == .timedOut else {
        return "second read entered before the first reload completed"
    }
    releaseFirstRead.signal()
    guard firstFinished.wait(timeout: .now() + 5) == .success,
          secondFinished.wait(timeout: .now() + 5) == .success else { return "reloads did not finish" }
    guard secondReadEntered.wait(timeout: .now() + 1) == .success else { return "second read never entered" }
    guard registry.customEntries == [new], registry.profile(for: new.bundleIdentifier)?.kind == .safari else {
        return "newer snapshot was overwritten"
    }
    return nil
}
