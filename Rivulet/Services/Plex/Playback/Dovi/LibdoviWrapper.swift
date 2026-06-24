//
//  LibdoviWrapper.swift
//  Rivulet
//
//  Swift wrapper around the libdovi C API for Dolby Vision RPU parsing and conversion.
//  Used to convert Profile 7 (MEL) and Profile 8.6 content to Profile 8.1 for Apple TV compatibility.
//

import Foundation
import Dovi

// MARK: - Conversion Mode

/// RPU conversion modes supported by libdovi
enum DoviConversionMode: UInt8 {
    /// Don't modify the RPU
    case none = 0

    /// Convert to MEL compatible
    case toMEL = 1

    /// Convert to Profile 8.1 compatible (sets luma/chroma mapping to no-op)
    /// This is the primary mode for P7/P8 → P8.1 conversion on Apple TV
    case toProfile81 = 2

    /// Convert to static Profile 8.4
    case toProfile84Static = 3

    /// Convert to Profile 8.1 preserving luma/chroma mapping
    case toProfile81Preserve = 4
}

// MARK: - RPU Info

/// Information extracted from a parsed RPU
struct DoviRPUInfo {
    /// Profile guessed from RPU header values (5, 7, or 8)
    let profile: UInt8

    /// Enhancement layer type for Profile 7: "MEL" or "FEL"
    /// nil for other profiles
    let elType: String?

    /// Whether this is a Profile 7 MEL (Minimal Enhancement Layer)
    var isMEL: Bool {
        profile == 7 && elType == "MEL"
    }

    /// Whether this is a Profile 7 FEL (Full Enhancement Layer)
    var isFEL: Bool {
        profile == 7 && elType == "FEL"
    }

    /// Whether this RPU needs conversion for Apple TV compatibility
    var needsConversion: Bool {
        // Profile 7 (both MEL and FEL) needs conversion
        if profile == 7 { return true }
        // Profile 8 with certain characteristics may need conversion
        // (handled at higher level based on BL CompatID)
        return false
    }
}

// MARK: - Libdovi Error

/// Errors from libdovi operations
enum LibdoviError: Error, LocalizedError {
    case parseError(String)
    case conversionError(String)
    case writeError(String)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return "RPU parse error: \(msg)"
        case .conversionError(let msg): return "RPU conversion error: \(msg)"
        case .writeError(let msg): return "RPU write error: \(msg)"
        case .invalidData: return "Invalid RPU data"
        }
    }
}

// MARK: - Libdovi Wrapper

/// Swift wrapper for libdovi C API operations
final class LibdoviWrapper {

    // MARK: - Parsing

    /// Parse an RPU from HEVC NAL unit data (type 62 / UNSPEC62)
    /// The data should be the raw NAL unit content (without length prefix)
    /// - Parameter nalData: The RPU NAL unit data
    /// - Returns: Opaque pointer to the parsed RPU (caller must call free())
    /// - Throws: LibdoviError if parsing fails
    func parseRPU(nalData: Data) throws -> OpaquePointer {
        let rpu = nalData.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return dovi_parse_unspec62_nalu(ptr, buffer.count)
        }

        guard let rpu else {
            throw LibdoviError.invalidData
        }

        // Check for parse errors
        if let errorPtr = dovi_rpu_get_error(rpu) {
            let errorMsg = String(cString: errorPtr)
            dovi_rpu_free(rpu)
            throw LibdoviError.parseError(errorMsg)
        }

        return rpu
    }

    // MARK: - Info Extraction

    /// Get information about a parsed RPU
    /// - Parameter rpu: Opaque pointer to parsed RPU
    /// - Returns: RPU info struct with profile and EL type
    func getInfo(rpu: OpaquePointer) -> DoviRPUInfo {
        guard let header = dovi_rpu_get_header(rpu) else {
            return DoviRPUInfo(profile: 0, elType: nil)
        }

        defer { dovi_rpu_free_header(header) }

        let profile = header.pointee.guessed_profile
        let elType: String?

        // libdovi 1.x renamed `subprofile` to `el_type` (subprofile deprecated since 3.2.0).
        // Same semantics: "FEL"/"MEL" for Profile 7, null otherwise.
        if let elTypePtr = header.pointee.el_type {
            elType = String(cString: elTypePtr)
        } else {
            elType = nil
        }

        return DoviRPUInfo(profile: profile, elType: elType)
    }

    // MARK: - Conversion

    /// Convert an RPU to a different profile using the specified mode
    /// - Parameters:
    ///   - rpu: Opaque pointer to parsed RPU (modified in place)
    ///   - mode: Conversion mode
    /// - Throws: LibdoviError if conversion fails
    func convert(rpu: OpaquePointer, mode: DoviConversionMode) throws {
        let result = dovi_convert_rpu_with_mode(rpu, mode.rawValue)

        if result != 0 {
            if let errorPtr = dovi_rpu_get_error(rpu) {
                throw LibdoviError.conversionError(String(cString: errorPtr))
            } else {
                throw LibdoviError.conversionError("Unknown conversion error (code: \(result))")
            }
        }
    }

    // MARK: - Writing

    /// Write the RPU back as an HEVC NAL unit (escaped, with 0x7C01 prefix)
    /// - Parameter rpu: Opaque pointer to parsed RPU
    /// - Returns: The RPU encoded as an HEVC NAL unit
    /// - Throws: LibdoviError if writing fails
    func writeNAL(rpu: OpaquePointer) throws -> Data {
        guard let doviData = dovi_write_unspec62_nalu(rpu) else {
            if let errorPtr = dovi_rpu_get_error(rpu) {
                throw LibdoviError.writeError(String(cString: errorPtr))
            } else {
                throw LibdoviError.writeError("Failed to write NAL unit")
            }
        }

        defer { dovi_data_free(doviData) }

        guard doviData.pointee.len > 0, let dataPtr = doviData.pointee.data else {
            throw LibdoviError.writeError("Empty NAL data returned")
        }

        return Data(bytes: dataPtr, count: doviData.pointee.len)
    }

    // MARK: - Cleanup

    /// Free a parsed RPU
    /// - Parameter rpu: Opaque pointer to parsed RPU
    func free(rpu: OpaquePointer) {
        dovi_rpu_free(rpu)
    }

    // MARK: - Convenience

    /// Convert an RPU NAL to Profile 8.1 in one step
    /// - Parameter nalData: Original RPU NAL unit data
    /// - Returns: Converted RPU NAL unit data, or nil if conversion not needed/failed
    func convertToProfile81(nalData: Data) -> Data? {
        do {
            let rpu = try parseRPU(nalData: nalData)
            defer { free(rpu: rpu) }

            let info = getInfo(rpu: rpu)

            // Only convert if it's a profile that needs conversion
            guard info.profile == 7 || info.profile == 8 else {
                return nil
            }

            try convert(rpu: rpu, mode: .toProfile81)
            return try writeNAL(rpu: rpu)
        } catch {
            playerDebugLog("🎬 [Libdovi] Conversion failed: \(error.localizedDescription)")
            return nil
        }
    }
}
