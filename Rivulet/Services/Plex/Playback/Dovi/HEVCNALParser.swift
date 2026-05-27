//
//  HEVCNALParser.swift
//  Rivulet
//
//  Parses length-prefixed HEVC NAL units from fMP4 sample data.
//  Used to extract and replace Dolby Vision RPU NAL units (type 62).
//

import Foundation

// MARK: - NAL Unit Types

/// HEVC NAL unit types relevant to Dolby Vision
enum HEVCNALType: UInt8 {
    case trailN = 0
    case trailR = 1
    case idrWRadl = 19
    case idrNLP = 20
    case cra = 21
    case unspec62 = 62  // Dolby Vision RPU
    case unspec63 = 63  // Dolby Vision EL

    /// Whether this NAL type is a video slice
    var isVideoSlice: Bool {
        switch self {
        case .trailN, .trailR, .idrWRadl, .idrNLP, .cra:
            return true
        default:
            return false
        }
    }
}

// MARK: - NAL Unit

/// Represents a parsed NAL unit from HEVC sample data
struct NALUnit {
    /// NAL unit type (0-63)
    let type: UInt8

    /// Full NAL unit data including header (without length prefix)
    let data: Data

    /// Range in the original sample data (includes 4-byte length prefix)
    let range: Range<Int>

    /// Whether this is a Dolby Vision RPU NAL
    var isRPU: Bool {
        type == HEVCNALType.unspec62.rawValue
    }

    /// Whether this is a Dolby Vision Enhancement Layer NAL (type 63 only).
    /// Note: DV P7 FEL uses normal video NAL types with nuh_layer_id=1,
    /// so this property alone is insufficient for FEL detection — use layer_id check instead.
    var isEL: Bool {
        type == HEVCNALType.unspec63.rawValue
    }
}

// MARK: - HEVC NAL Parser

/// Parses HEVC NAL units from fMP4 sample data.
/// fMP4 uses 4-byte length prefixes (not Annex B start codes).
final class HEVCNALParser {

    /// Length prefix size in bytes (fMP4 always uses 4-byte length)
    private let lengthPrefixSize = 4

    // MARK: - Parsing

    /// Parse all NAL units from an fMP4 sample
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: Array of parsed NAL units
    func parseNALUnits(from sampleData: Data) -> [NALUnit] {
        var units: [NALUnit] = []
        var offset = 0

        while offset + lengthPrefixSize < sampleData.count {
            // Read 4-byte big-endian length prefix
            let length = Int(sampleData.readUInt32BE(at: offset))

            guard length > 0, offset + lengthPrefixSize + length <= sampleData.count else {
                break
            }

            let nalStart = offset + lengthPrefixSize
            let nalEnd = nalStart + length
            let nalData = sampleData.subdata(in: nalStart..<nalEnd)

            // Parse NAL unit type from first byte
            // HEVC NAL header: forbidden_zero_bit(1) + nal_unit_type(6) + nuh_layer_id(6) + nuh_temporal_id_plus1(3)
            // nal_unit_type is bits 1-6 of first byte (0 is forbidden bit)
            guard !nalData.isEmpty else {
                offset = nalEnd
                continue
            }

            let nalType = (nalData[0] >> 1) & 0x3F

            units.append(NALUnit(
                type: nalType,
                data: nalData,
                range: offset..<(nalEnd)
            ))

            offset = nalEnd
        }

        return units
    }

    /// Find the RPU NAL unit (type 62) in sample data
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: The RPU NAL unit if found, nil otherwise
    func findRPU(in sampleData: Data) -> NALUnit? {
        guard let rpuRange = findNALRange(in: sampleData, type: HEVCNALType.unspec62.rawValue) else {
            return nil
        }

        let nalStart = rpuRange.lowerBound + lengthPrefixSize
        let nalData = sampleData.subdata(in: nalStart..<rpuRange.upperBound)

        return NALUnit(
            type: HEVCNALType.unspec62.rawValue,
            data: nalData,
            range: rpuRange
        )
    }

    /// Replace the RPU NAL unit in sample data with new RPU data
    /// - Parameters:
    ///   - sampleData: Original sample data
    ///   - newRPU: New RPU NAL unit data (without length prefix)
    /// - Returns: Modified sample data with replaced RPU, or original if no RPU found
    func replaceRPU(in sampleData: Data, with newRPU: Data) -> Data {
        guard let existingRPU = findRPU(in: sampleData) else {
            return sampleData
        }
        return replaceRPU(in: sampleData, existingRPU: existingRPU, with: newRPU)
    }

    /// Replace an already-found RPU NAL unit with new data (avoids re-parsing)
    /// - Parameters:
    ///   - sampleData: Original sample data
    ///   - existingRPU: The RPU NAL unit previously found via findRPU
    ///   - newRPU: New RPU NAL unit data (without length prefix)
    /// - Returns: Modified sample data with replaced RPU
    func replaceRPU(in sampleData: Data, existingRPU: NALUnit, with newRPU: Data) -> Data {
        var result = Data()
        result.reserveCapacity(sampleData.count + newRPU.count - existingRPU.data.count)

        // Copy data before the RPU
        if existingRPU.range.lowerBound > 0 {
            result.append(sampleData.subdata(in: 0..<existingRPU.range.lowerBound))
        }

        // Write new RPU with length prefix
        var length = UInt32(newRPU.count).bigEndian
        result.append(Data(bytes: &length, count: 4))
        result.append(newRPU)

        // Copy data after the RPU
        if existingRPU.range.upperBound < sampleData.count {
            result.append(sampleData.subdata(in: existingRPU.range.upperBound..<sampleData.count))
        }

        return result
    }

    /// Check if the sample contains a Dolby Vision RPU
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: true if an RPU NAL unit is present
    func hasRPU(in sampleData: Data) -> Bool {
        findNALRange(in: sampleData, type: HEVCNALType.unspec62.rawValue) != nil
    }

    /// Fast scan for RPU NAL (type 62) without allocating NALUnit structs.
    /// Only reads length prefixes and the first byte of each NAL header.
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: true if a NAL type 62 is present
    func hasRPUFast(in sampleData: Data) -> Bool {
        findNALRange(in: sampleData, type: HEVCNALType.unspec62.rawValue) != nil
    }

    private func findNALRange(in sampleData: Data, type targetType: UInt8) -> Range<Int>? {
        sampleData.withUnsafeBytes { buffer -> Range<Int>? in
            guard let base = buffer.baseAddress else { return nil }
            let count = buffer.count
            var offset = 0

            while offset + lengthPrefixSize < count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length > 0, offset + lengthPrefixSize + length <= count else { break }

                // Read NAL type from first byte: bits 1-6
                let nalType = (base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self) >> 1) & 0x3F
                if nalType == targetType {
                    return offset..<(offset + lengthPrefixSize + length)
                }

                offset += lengthPrefixSize + length
            }
            return nil
        }
    }

    /// Strip all Enhancement Layer NAL units from sample data.
    /// DV Profile 7 is dual-layer (BL + EL + RPU). After converting RPU from P7→P8.1,
    /// the EL NALs are orphaned and cause VideoToolbox to stutter on Apple TV (which
    /// only supports single-layer DV profiles 5/8).
    ///
    /// EL NALs come in two flavors depending on the muxing:
    /// - **MEL/interleaved**: NAL type 63 (unspec63) with layer_id=0
    /// - **FEL**: Normal video NAL types (TRAIL_R, IDR, etc.) with nuh_layer_id=1
    /// Both must be detected and stripped. RPU (type 62) is always kept.
    ///
    /// - Parameter sampleData: Sample data with RPU already converted to P8.1
    /// - Returns: Sample data with EL NALs removed, or original data if no EL found
    func stripEnhancementLayer(from sampleData: Data) -> Data {
        sampleData.withUnsafeBytes { buffer -> Data in
            guard let base = buffer.baseAddress else { return sampleData }
            let count = buffer.count

            // Need at least 2 bytes of NAL header to read layer_id
            guard count > lengthPrefixSize + 2 else { return sampleData }

            // First pass: check if any EL NALs exist (avoid allocation if not needed)
            var hasEL = false
            var offset = 0
            while offset + lengthPrefixSize + 2 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 2, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let byte1 = base.load(fromByteOffset: offset + lengthPrefixSize + 1, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F
                let layerId = (Int(byte0 & 0x01) << 5) | Int((byte1 >> 3) & 0x1F)

                // EL NAL: type 63 (MEL) OR non-zero layer_id (FEL), but never RPU
                if nalType != HEVCNALType.unspec62.rawValue &&
                   (nalType == HEVCNALType.unspec63.rawValue || layerId != 0) {
                    hasEL = true
                    break
                }
                offset += lengthPrefixSize + length
            }

            guard hasEL else { return sampleData }

            // Second pass: copy only BL + RPU NALs to output
            var result = Data()
            result.reserveCapacity(count) // Upper bound; actual will be smaller
            offset = 0

            while offset + lengthPrefixSize + 2 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 2, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let byte1 = base.load(fromByteOffset: offset + lengthPrefixSize + 1, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F
                let layerId = (Int(byte0 & 0x01) << 5) | Int((byte1 >> 3) & 0x1F)
                let nalTotalSize = lengthPrefixSize + length

                // Keep: RPU (type 62), or BL NALs (layer_id=0 and not type 63)
                let isRPU = nalType == HEVCNALType.unspec62.rawValue
                let isEL = nalType == HEVCNALType.unspec63.rawValue || layerId != 0
                if isRPU || !isEL {
                    result.append(
                        UnsafeBufferPointer(
                            start: base.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                            count: nalTotalSize
                        )
                    )
                }

                offset += nalTotalSize
            }

            return result
        }
    }

    // MARK: - hvcC Parameter Set Extraction

    /// Extract all parameter set NAL units from an hvcC box.
    /// Returns individual NAL unit data (without length prefix) for VPS/SPS/PPS.
    ///
    /// hvcC structure: 22-byte header, numOfArrays (1 byte), then arrays of NALUs.
    static func extractParameterSets(from hvcCData: Data) -> [Data] {
        guard hvcCData.count > 23 else { return [] }

        let headerSize = 22
        let numArrays = Int(hvcCData[headerSize])
        var offset = headerSize + 1
        var result: [Data] = []

        for _ in 0..<numArrays {
            guard offset + 3 <= hvcCData.count else { break }
            let numNalus = Int(hvcCData.readUInt16BE(at: offset + 1))
            offset += 3

            for _ in 0..<numNalus {
                guard offset + 2 <= hvcCData.count else { break }
                let naluLength = Int(hvcCData.readUInt16BE(at: offset))
                offset += 2
                guard offset + naluLength <= hvcCData.count else {
                    offset += naluLength
                    continue
                }
                result.append(hvcCData[offset..<(offset + naluLength)])
                offset += naluLength
            }
        }

        return result
    }

    // MARK: - VPS Modification for DV P7→P8.1

    /// Modify VPS NAL units in sample data to indicate single-layer configuration.
    /// After DV P7→P8.1 conversion, the VPS still describes dual-layer (max_layers_minus1=1).
    /// This causes VideoToolbox to expect dual-layer data, producing a black screen.
    /// Setting max_layers_minus1=0 tells VideoToolbox this is single-layer content.
    ///
    /// VPS payload layout (after 2-byte NAL header):
    ///   Byte 0: [vps_id(4)][base_internal(1)][base_avail(1)][max_layers_hi(2)]
    ///   Byte 1: [max_layers_lo(4)][max_sub_layers(3)][nesting(1)]
    ///
    /// - Parameter sampleData: Sample data potentially containing VPS NALs
    /// - Returns: Modified data with VPS max_layers_minus1 set to 0
    func modifyVPSForSingleLayer(in sampleData: Data) -> Data {
        sampleData.withUnsafeBytes { buffer -> Data in
            guard let base = buffer.baseAddress else { return sampleData }
            let count = buffer.count

            // First pass: check if any VPS NALs exist with max_layers_minus1 > 0
            var needsModification = false
            var offset = 0
            while offset + lengthPrefixSize + 4 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 4, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F

                if nalType == 32 { // VPS
                    // Check max_layers_minus1 (6 bits spanning payload bytes 0-1)
                    let payloadOffset = offset + lengthPrefixSize + 2 // Skip 2-byte NAL header
                    let vpsByte0 = base.load(fromByteOffset: payloadOffset, as: UInt8.self)
                    let vpsByte1 = base.load(fromByteOffset: payloadOffset + 1, as: UInt8.self)
                    let maxLayersHi = vpsByte0 & 0x03
                    let maxLayersLo = (vpsByte1 >> 4) & 0x0F
                    let maxLayersMinus1 = (Int(maxLayersHi) << 4) | Int(maxLayersLo)

                    if maxLayersMinus1 > 0 {
                        needsModification = true
                        break
                    }
                }
                offset += lengthPrefixSize + length
            }

            guard needsModification else { return sampleData }

            // Second pass: copy data, modifying VPS NALs
            var result = Data(sampleData)
            offset = 0
            while offset + lengthPrefixSize + 4 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 4, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F

                if nalType == 32 {
                    let payloadOffset = offset + lengthPrefixSize + 2
                    // Clear max_layers_minus1: clear bottom 2 bits of payload byte 0,
                    // clear top 4 bits of payload byte 1
                    result[payloadOffset] = result[payloadOffset] & 0xFC
                    result[payloadOffset + 1] = result[payloadOffset + 1] & 0x0F
                }
                offset += lengthPrefixSize + length
            }

            return result
        }
    }

    /// Modify VPS in raw hvcC extradata to set max_layers_minus1=0 and strip EL parameter sets.
    /// The hvcC box contains parameter set arrays; this method:
    /// 1. Modifies VPS max_layers_minus1 to 0
    /// 2. Removes parameter sets with nuh_layer_id != 0 (EL sets)
    ///
    /// hvcC structure:
    ///   23 bytes header, then numOfArrays (1 byte)
    ///   Each array: flags+type (1 byte), numNalus (2 bytes), then NALUs
    ///   Each NALU: length (2 bytes), data (length bytes)
    static func cleanHvcCForSingleLayer(_ hvcCData: Data) -> Data {
        guard hvcCData.count > 23 else { return hvcCData }

        var result = Data()
        let headerSize = 22 // Everything before numOfArrays
        result.append(hvcCData[0..<headerSize])

        let numArrays = hvcCData[headerSize]
        var offset = headerSize + 1
        var cleanedArrays: [Data] = []

        for _ in 0..<numArrays {
            guard offset + 3 <= hvcCData.count else { break }

            let arrayHeader = hvcCData[offset]
            let nalType = arrayHeader & 0x3F
            let numNalus = Int(hvcCData.readUInt16BE(at: offset + 1))
            offset += 3

            var keptNalus: [Data] = []

            for _ in 0..<numNalus {
                guard offset + 2 <= hvcCData.count else { break }
                let naluLength = Int(hvcCData.readUInt16BE(at: offset))
                offset += 2

                guard offset + naluLength <= hvcCData.count, naluLength >= 2 else {
                    offset += naluLength
                    continue
                }

                var naluData = Data(hvcCData[offset..<(offset + naluLength)])

                // Check layer_id: byte0 bit0 and byte1 bits 7-3
                let byte0 = naluData[0]
                let byte1 = naluData[1]
                let layerId = (Int(byte0 & 0x01) << 5) | Int((byte1 >> 3) & 0x1F)

                if layerId == 0 {
                    // VPS (type 32): modify max_layers_minus1 to 0
                    if nalType == 32, naluData.count >= 4 {
                        naluData[2] = naluData[2] & 0xFC  // Clear max_layers hi 2 bits
                        naluData[3] = naluData[3] & 0x0F  // Clear max_layers lo 4 bits
                    }
                    keptNalus.append(naluData)
                }
                // Skip EL parameter sets (layer_id != 0)

                offset += naluLength
            }

            // Only include array if it has NALUs left
            if !keptNalus.isEmpty {
                var arrayData = Data()
                arrayData.append(arrayHeader)
                var count16 = UInt16(keptNalus.count).bigEndian
                arrayData.append(Data(bytes: &count16, count: 2))
                for nalu in keptNalus {
                    var len16 = UInt16(nalu.count).bigEndian
                    arrayData.append(Data(bytes: &len16, count: 2))
                    arrayData.append(nalu)
                }
                cleanedArrays.append(arrayData)
            }
        }

        // Write cleaned arrays
        result.append(UInt8(cleanedArrays.count))
        for array in cleanedArrays {
            result.append(array)
        }

        return result
    }

    /// Get summary of NAL units in sample (for debugging)
    /// - Parameter sampleData: The raw sample data from fMP4
    /// - Returns: String describing the NAL units present
    func describeSample(_ sampleData: Data) -> String {
        let units = parseNALUnits(from: sampleData)
        let types = units.map { "NAL\($0.type)" }
        return "[\(types.joined(separator: ", "))]"
    }

    // MARK: - SPS VUI Parsing (FullRangeVideo extraction)

    /// Extract `video_full_range_flag` from the SPS VUI within an hvcC extradata blob.
    ///
    /// Returns `true` for full-range, `false` for limited-range, or `nil` if the SPS
    /// can't be parsed or has no VUI. Used to set
    /// `kCMFormatDescriptionExtension_FullRangeVideo` correctly when building a
    /// CMVideoFormatDescription for HEVC: FFmpeg's `AVCodecParameters.color_range`
    /// is `AVCOL_RANGE_UNSPECIFIED` for many HEVC streams whose SPS VUI explicitly
    /// signals limited range, leaving HDR (PQ/HLG) content rendering black on
    /// tvOS — the display layer with no FullRangeVideo flag interprets the
    /// signal as full-range and pushes limited-range pixels off-screen low.
    static func extractFullRangeFlag(fromHvcC hvcCData: Data) -> Bool? {
        let parameterSets = extractParameterSets(from: hvcCData)
        guard let spsNALU = parameterSets.first(where: { isSPSNALU($0) }) else {
            return nil
        }
        return parseSPSFullRangeFlag(spsNALU: spsNALU)
    }

    private static func isSPSNALU(_ nalu: Data) -> Bool {
        guard let first = nalu.first else { return false }
        let nalType = (first >> 1) & 0x3F
        return nalType == 33 // SPS_NUT
    }

    /// Walk an HEVC SPS NAL unit (with 2-byte NAL header) to its VUI and return
    /// `video_full_range_flag`. Returns nil on any parse failure.
    private static func parseSPSFullRangeFlag(spsNALU: Data) -> Bool? {
        guard spsNALU.count >= 3 else { return nil }
        let payloadStart = spsNALU.index(spsNALU.startIndex, offsetBy: 2)
        let rbsp = unescapeEmulationBytes(spsNALU[payloadStart..<spsNALU.endIndex])
        var r = BitReader(rbsp)

        // sps_video_parameter_set_id u(4)
        guard r.readBits(4) != nil else { return nil }
        guard let maxSubLayersRaw = r.readBits(3) else { return nil }
        let maxSubLayersMinus1 = Int(maxSubLayersRaw)
        // sps_temporal_id_nesting_flag u(1)
        guard r.readBits(1) != nil else { return nil }
        guard skipProfileTierLevel(&r, profilePresentFlag: true, maxSubLayersMinus1: maxSubLayersMinus1) else {
            return nil
        }
        // sps_seq_parameter_set_id ue(v)
        guard r.readUE() != nil else { return nil }
        guard let chromaFormatIdc = r.readUE() else { return nil }
        if chromaFormatIdc == 3 {
            // separate_colour_plane_flag u(1)
            guard r.readBits(1) != nil else { return nil }
        }
        // pic_width_in_luma_samples / pic_height_in_luma_samples ue(v) ue(v)
        guard r.readUE() != nil, r.readUE() != nil else { return nil }
        guard let conformanceFlag = r.readBits(1) else { return nil }
        if conformanceFlag == 1 {
            for _ in 0..<4 {
                guard r.readUE() != nil else { return nil }
            }
        }
        // bit_depth_luma_minus8 / bit_depth_chroma_minus8
        guard r.readUE() != nil, r.readUE() != nil else { return nil }
        guard let logMaxPocLsbMinus4 = r.readUE() else { return nil }
        let log2MaxPicOrderCntLsbMinus4 = Int(logMaxPocLsbMinus4)
        guard let subLayerOrderingFlag = r.readBits(1) else { return nil }
        let firstSubLayer = (subLayerOrderingFlag == 1) ? 0 : maxSubLayersMinus1
        if firstSubLayer <= maxSubLayersMinus1 {
            for _ in firstSubLayer...maxSubLayersMinus1 {
                // sps_max_dec_pic_buffering_minus1 / sps_max_num_reorder_pics / sps_max_latency_increase_plus1
                guard r.readUE() != nil, r.readUE() != nil, r.readUE() != nil else { return nil }
            }
        }
        // 6 ue(v) values: log2_min_luma_coding_block_size_minus3,
        // log2_diff_max_min_luma_coding_block_size,
        // log2_min_luma_transform_block_size_minus2,
        // log2_diff_max_min_luma_transform_block_size,
        // max_transform_hierarchy_depth_inter, max_transform_hierarchy_depth_intra.
        for _ in 0..<6 {
            guard r.readUE() != nil else { return nil }
        }
        guard let scalingListEnabled = r.readBits(1) else { return nil }
        if scalingListEnabled == 1 {
            guard let scalingListDataPresent = r.readBits(1) else { return nil }
            if scalingListDataPresent == 1 {
                guard skipScalingListData(&r) else { return nil }
            }
        }
        // amp_enabled_flag, sample_adaptive_offset_enabled_flag
        guard r.readBits(1) != nil, r.readBits(1) != nil else { return nil }
        guard let pcmEnabled = r.readBits(1) else { return nil }
        if pcmEnabled == 1 {
            // pcm_sample_bit_depth_luma_minus1 u(4), pcm_sample_bit_depth_chroma_minus1 u(4)
            guard r.readBits(4) != nil, r.readBits(4) != nil else { return nil }
            // log2_min_pcm_luma_coding_block_size_minus3, log2_diff_max_min_pcm_luma_coding_block_size
            guard r.readUE() != nil, r.readUE() != nil else { return nil }
            // pcm_loop_filter_disabled_flag u(1)
            guard r.readBits(1) != nil else { return nil }
        }
        guard let numStRefSetsRaw = r.readUE() else { return nil }
        let numShortTermRefPicSets = Int(numStRefSetsRaw)
        var numDeltaPocs: [Int] = []
        numDeltaPocs.reserveCapacity(numShortTermRefPicSets)
        for i in 0..<numShortTermRefPicSets {
            guard let count = parseStRefPicSet(&r,
                                               stRpsIdx: i,
                                               numShortTermRefPicSets: numShortTermRefPicSets,
                                               numDeltaPocs: numDeltaPocs) else {
                return nil
            }
            numDeltaPocs.append(count)
        }
        guard let longTermRefPresent = r.readBits(1) else { return nil }
        if longTermRefPresent == 1 {
            guard let numLtRaw = r.readUE() else { return nil }
            let numLtRefPicsSps = Int(numLtRaw)
            for _ in 0..<numLtRefPicsSps {
                // lt_ref_pic_poc_lsb_sps[i] u(log2_max_pic_order_cnt_lsb_minus4 + 4)
                guard r.readBits(log2MaxPicOrderCntLsbMinus4 + 4) != nil else { return nil }
                // used_by_curr_pic_lt_sps_flag[i] u(1)
                guard r.readBits(1) != nil else { return nil }
            }
        }
        // sps_temporal_mvp_enabled_flag, strong_intra_smoothing_enabled_flag
        guard r.readBits(1) != nil, r.readBits(1) != nil else { return nil }
        guard let vuiPresent = r.readBits(1) else { return nil }
        if vuiPresent != 1 { return nil }

        // vui_parameters() — walk to video_full_range_flag.
        guard let aspectRatioPresent = r.readBits(1) else { return nil }
        if aspectRatioPresent == 1 {
            guard let aspectRatioIdc = r.readBits(8) else { return nil }
            if aspectRatioIdc == 255 { // EXTENDED_SAR
                guard r.readBits(16) != nil, r.readBits(16) != nil else { return nil }
            }
        }
        guard let overscanPresent = r.readBits(1) else { return nil }
        if overscanPresent == 1 {
            guard r.readBits(1) != nil else { return nil }
        }
        guard let videoSignalPresent = r.readBits(1) else { return nil }
        if videoSignalPresent != 1 { return nil }
        // video_format u(3)
        guard r.readBits(3) != nil else { return nil }
        guard let videoFullRange = r.readBits(1) else { return nil }
        return videoFullRange == 1
    }

    /// Skip profile_tier_level() syntax (H.265 §7.3.3). We don't need the values.
    /// general profile data is 96 bits; per-sublayer profile data is 88 bits.
    private static func skipProfileTierLevel(_ r: inout BitReader,
                                             profilePresentFlag: Bool,
                                             maxSubLayersMinus1: Int) -> Bool {
        if profilePresentFlag {
            guard r.skipBits(96) else { return false }
        }
        var subProfilePresent = [Bool](repeating: false, count: max(maxSubLayersMinus1, 0))
        var subLevelPresent = [Bool](repeating: false, count: max(maxSubLayersMinus1, 0))
        for i in 0..<maxSubLayersMinus1 {
            guard let sppf = r.readBits(1), let slpf = r.readBits(1) else { return false }
            subProfilePresent[i] = (sppf == 1)
            subLevelPresent[i] = (slpf == 1)
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 {
                guard r.skipBits(2) else { return false } // reserved_zero_2bits
            }
        }
        for i in 0..<maxSubLayersMinus1 {
            if subProfilePresent[i] {
                guard r.skipBits(88) else { return false }
            }
            if subLevelPresent[i] {
                guard r.skipBits(8) else { return false } // sub_layer_level_idc
            }
        }
        return true
    }

    /// Walk scaling_list_data() (H.265 §7.3.4) consuming bits.
    private static func skipScalingListData(_ r: inout BitReader) -> Bool {
        for sizeId in 0..<4 {
            let matrixStep = (sizeId == 3) ? 3 : 1
            var matrixId = 0
            while matrixId < 6 {
                guard let predMode = r.readBits(1) else { return false }
                if predMode == 0 {
                    // scaling_list_pred_matrix_id_delta ue(v)
                    guard r.readUE() != nil else { return false }
                } else {
                    let cap = 1 << (4 + (sizeId << 1))
                    let coefNum = min(64, cap)
                    if sizeId > 1 {
                        // scaling_list_dc_coef_minus8 se(v)
                        guard r.readSE() != nil else { return false }
                    }
                    for _ in 0..<coefNum {
                        // scaling_list_delta_coef se(v)
                        guard r.readSE() != nil else { return false }
                    }
                }
                matrixId += matrixStep
            }
        }
        return true
    }

    /// Walk st_ref_pic_set(stRpsIdx) (H.265 §7.4.7) and return NumDeltaPocs[stRpsIdx].
    private static func parseStRefPicSet(_ r: inout BitReader,
                                         stRpsIdx: Int,
                                         numShortTermRefPicSets: Int,
                                         numDeltaPocs: [Int]) -> Int? {
        var interPrediction = false
        if stRpsIdx != 0 {
            guard let f = r.readBits(1) else { return nil }
            interPrediction = (f == 1)
        }
        if interPrediction {
            var deltaIdxMinus1: UInt32 = 0
            if stRpsIdx == numShortTermRefPicSets {
                guard let d = r.readUE() else { return nil }
                deltaIdxMinus1 = d
            }
            // delta_rps_sign u(1), abs_delta_rps_minus1 ue(v)
            guard r.readBits(1) != nil, r.readUE() != nil else { return nil }
            let rIdx = stRpsIdx - 1 - Int(deltaIdxMinus1)
            guard rIdx >= 0, rIdx < numDeltaPocs.count else { return nil }
            let count = numDeltaPocs[rIdx]
            var newCount = 0
            // j = 0..NumDeltaPocs[RIdx], inclusive.
            for _ in 0...count {
                guard let used = r.readBits(1) else { return nil }
                if used == 1 {
                    newCount += 1
                } else {
                    guard let useDelta = r.readBits(1) else { return nil }
                    if useDelta == 1 { newCount += 1 }
                }
            }
            return newCount
        } else {
            guard let nnp = r.readUE() else { return nil }
            guard let npp = r.readUE() else { return nil }
            for _ in 0..<nnp {
                // delta_poc_s0_minus1[i] ue(v), used_by_curr_pic_s0_flag[i] u(1)
                guard r.readUE() != nil, r.readBits(1) != nil else { return nil }
            }
            for _ in 0..<npp {
                guard r.readUE() != nil, r.readBits(1) != nil else { return nil }
            }
            return Int(nnp + npp)
        }
    }

    /// Strip emulation_prevention_three_byte (0x03 after 0x00 0x00) from raw RBSP.
    private static func unescapeEmulationBytes(_ slice: Data) -> Data {
        var out = Data()
        out.reserveCapacity(slice.count)
        var i = slice.startIndex
        let end = slice.endIndex
        while i < end {
            let next = slice.index(after: i)
            let next2 = (next < end) ? slice.index(after: next) : end
            if next2 < end && slice[i] == 0 && slice[next] == 0 && slice[next2] == 0x03 {
                out.append(0)
                out.append(0)
                i = slice.index(after: next2)
            } else {
                out.append(slice[i])
                i = next
            }
        }
        return out
    }

    /// Bit reader with Exp-Golomb decoding for HEVC RBSP.
    private struct BitReader {
        private let bytes: [UInt8]
        private var bitOffset: Int = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        mutating func readBits(_ n: Int) -> UInt32? {
            guard n >= 0, n <= 32, bitOffset + n <= bytes.count * 8 else { return nil }
            var value: UInt32 = 0
            for _ in 0..<n {
                let byteIdx = bitOffset >> 3
                let bitInByte = 7 - (bitOffset & 0x7)
                let bit = (bytes[byteIdx] >> bitInByte) & 1
                value = (value << 1) | UInt32(bit)
                bitOffset += 1
            }
            return value
        }

        mutating func skipBits(_ n: Int) -> Bool {
            guard n >= 0, bitOffset + n <= bytes.count * 8 else { return false }
            bitOffset += n
            return true
        }

        mutating func readUE() -> UInt32? {
            var leadingZeros = 0
            while leadingZeros < 32 {
                guard let b = readBits(1) else { return nil }
                if b == 1 { break }
                leadingZeros += 1
            }
            if leadingZeros == 0 { return 0 }
            if leadingZeros == 32 { return nil } // overflow guard
            guard let suffix = readBits(leadingZeros) else { return nil }
            return (UInt32(1) << UInt32(leadingZeros)) - 1 + suffix
        }

        mutating func readSE() -> Int32? {
            guard let v = readUE() else { return nil }
            if v == 0 { return 0 }
            let half = Int32((v + 1) >> 1)
            return (v & 1) == 1 ? half : -half
        }
    }

    /// Detailed NAL dump showing type, layer_id, and size for each NAL unit.
    /// Used to diagnose DV P7 FEL content where EL NALs share BL types but differ by layer_id.
    func describeDetailed(_ sampleData: Data) -> String {
        sampleData.withUnsafeBytes { buffer -> String in
            guard let base = buffer.baseAddress else { return "empty" }
            let count = buffer.count
            var descriptions: [String] = []
            var offset = 0

            while offset + lengthPrefixSize + 2 <= count {
                let length = Int(
                    base.advanced(by: offset)
                        .loadUnaligned(as: UInt32.self)
                        .bigEndian
                )
                guard length >= 2, offset + lengthPrefixSize + length <= count else { break }

                let byte0 = base.load(fromByteOffset: offset + lengthPrefixSize, as: UInt8.self)
                let byte1 = base.load(fromByteOffset: offset + lengthPrefixSize + 1, as: UInt8.self)
                let nalType = (byte0 >> 1) & 0x3F
                let layerId = (Int(byte0 & 0x01) << 5) | Int((byte1 >> 3) & 0x1F)

                let layerStr = layerId > 0 ? " L\(layerId)" : ""
                descriptions.append("T\(nalType)\(layerStr) \(length)B")

                offset += lengthPrefixSize + length
            }

            return "[\(descriptions.joined(separator: ", "))]"
        }
    }
}

// Note: Uses Data.readUInt32BE extension from FMP4Demuxer.swift
