//
//  JSDebugSupport.swift
//  StikDebug
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import JavaScriptCore
import idevice

private func jsException(_ message: String, in context: JSContext?) {
    guard let context else { return }
    context.exception = JSValue(object: message, in: context)
}

private func describeIdeviceError(_ ffiError: UnsafeMutablePointer<IdeviceFfiError>) -> String {
    if let message = ffiError.pointee.message {
        return "error code \(ffiError.pointee.code), msg \(String(cString: message))"
    }
    return "error code \(ffiError.pointee.code)"
}

func handleJSContextSendDebugCommand(_ context: JSContext?, _ commandStr: String, _ debugProxy: OpaquePointer?) -> String? {
    guard let debugProxy else {
        jsException("debug proxy is unavailable", in: context)
        return nil
    }

    guard let command = debugserver_command_new(commandStr, nil, 0) else {
        jsException("failed to allocate debugserver command", in: context)
        return nil
    }

    var response: UnsafeMutablePointer<CChar>?
    let ffiError = debug_proxy_send_command(debugProxy, command, &response)
    debugserver_command_free(command)

    if let ffiError {
        jsException(describeIdeviceError(ffiError), in: context)
        idevice_error_free(ffiError)
        if let response {
            idevice_string_free(response)
        }
        return nil
    }

    defer {
        if let response {
            idevice_string_free(response)
        }
    }

    guard let response else { return nil }
    return String(cString: response)
}

private func hexCharacter(for value: UInt8) -> UInt8 {
    if value < 10 {
        return value + Character("0").asciiValue!
    }
    return value + 87
}

/// The address in hex, as many digits as it needs. A fixed nine digits cut addresses at or above
/// 0x1000000000 (for example 0x7060000000 became 0x060000000).
private func hexAddress(_ address: UInt64) -> [UInt8] {
    Array(String(address, radix: 16).utf8)
}

private func writeChecksum(into buffer: inout [UInt8], at startIndex: Int) {
    var checksum: UInt8 = 0
    var index = startIndex
    while buffer[index] != Character("#").asciiValue! {
        checksum &+= buffer[index]
        index += 1
    }

    buffer[index + 1] = hexCharacter(for: (checksum & 0xf0) >> 4)
    buffer[index + 2] = hexCharacter(for: checksum & 0x0f)
}

private let jitPageSize: UInt64 = 16_384

private func jitPageCount(for regionSize: UInt64) -> Int {
    guard regionSize > 0 else { return 0 }
    return Int(((regionSize - 1) / jitPageSize) + 1)
}

/// One `$M<address>,1:69#<checksum>` packet per page. The packets differ in length with the address,
/// so `ends` holds the end offset of each one.
private func makeBulkWriteCommands(startAddress: UInt64, regionSize: UInt64) -> (bytes: [UInt8], ends: [Int]) {
    let commandCount = jitPageCount(for: regionSize)
    var buffer = [UInt8]()
    buffer.reserveCapacity(commandCount * 26)
    var ends = [Int]()
    ends.reserveCapacity(commandCount)

    var currentAddress = startAddress
    for _ in 0..<commandCount {
        let start = buffer.count
        buffer.append(Character("$").asciiValue!)
        buffer.append(Character("M").asciiValue!)
        buffer.append(contentsOf: hexAddress(currentAddress))
        buffer.append(contentsOf: Array(",1:69#".utf8))
        buffer.append(contentsOf: [0, 0])
        writeChecksum(into: &buffer, at: start + 1)
        ends.append(buffer.count)
        currentAddress += jitPageSize
    }

    return (buffer, ends)
}

func handleJITPageWrite(_ context: JSContext?, _ startAddr: UInt64, _ jitPagesSize: UInt64, _ debugProxy: OpaquePointer?) -> String? {
    guard let debugProxy else {
        jsException("debug proxy is unavailable", in: context)
        return nil
    }

    let (commandBuffer, commandEnds) = makeBulkWriteCommands(startAddress: startAddr, regionSize: jitPagesSize)
    let commandCount = commandEnds.count
    let commandsPerBatch = 128

    for batchStart in stride(from: 0, to: commandCount, by: commandsPerBatch) {
        let commandsToSend = min(commandsPerBatch, commandCount - batchStart)
        let byteOffset = batchStart == 0 ? 0 : commandEnds[batchStart - 1]
        let byteCount = commandEnds[batchStart + commandsToSend - 1] - byteOffset

        let ffiError = commandBuffer.withUnsafeBytes { rawBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
            let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return debug_proxy_send_raw(debugProxy, baseAddress.advanced(by: byteOffset), UInt(byteCount))
        }

        if let ffiError {
            jsException(describeIdeviceError(ffiError), in: context)
            idevice_error_free(ffiError)
            return nil
        }

        for _ in 0..<commandsToSend {
            var response: UnsafeMutablePointer<CChar>?
            let ffiError = debug_proxy_read_response(debugProxy, &response)
            if let response {
                idevice_string_free(response)
            }
            if let ffiError {
                jsException(describeIdeviceError(ffiError), in: context)
                idevice_error_free(ffiError)
                return nil
            }
        }
    }

    return "OK"
}
