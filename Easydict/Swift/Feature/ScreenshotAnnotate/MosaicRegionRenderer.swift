//
//  MosaicRegionRenderer.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights rendered as-is.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Pre-renders mosaic and gaussian-blur tiles that become `.region` items.
///
/// Rendering happens once per drag-commit, not on every frame: the resulting
/// tile is stored inside the annotation, keeping display and export identical.
@MainActor
enum MosaicRegionRenderer {
    // MARK: Internal

    /// Pixellates the source tile. `blockSide` is the average block edge in
    /// source pixels.
    static func pixelated(source: CGImage, blockSide: CGFloat = 10) -> CGImage? {
        let input = CIImage(cgImage: source)

        let filter = CIFilter.pixellate()
        filter.inputImage = input
        filter.scale = Float(max(blockSide, 2))
        filter.center = .zero

        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    /// Gaussian-blurs the source tile, clamped to its own edges first so the
    /// border does not fade into transparency.
    static func blurred(source: CGImage, radius: CGFloat = 12) -> CGImage? {
        let input = CIImage(cgImage: source)

        let clampFilter = CIFilter.affineClamp()
        clampFilter.inputImage = input
        clampFilter.transform = CGAffineTransform.identity

        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = clampFilter.outputImage ?? input
        blurFilter.radius = Float(max(radius, 1))

        guard let blurred = blurFilter.outputImage else { return nil }
        return ciContext.createCGImage(blurred, from: input.extent)
    }

    // MARK: Private

    private static let ciContext = CIContext()
}
